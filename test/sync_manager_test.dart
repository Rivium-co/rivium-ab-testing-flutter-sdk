import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivium_ab_testing/src/offline/offline_storage.dart';
import 'package:rivium_ab_testing/src/offline/sync_manager.dart';
import 'package:rivium_ab_testing/src/rivium_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'helpers.dart';

OfflineEvent event(int i, {String userId = 'alice'}) => OfflineEvent(
      id: 'evt_$i',
      experimentId: 'exp',
      variantId: 'v',
      userId: userId,
      eventType: 'view',
      timestamp: DateTime.now(),
    );

void main() {
  late OfflineStorage storage;
  late List<http.Request> requests;
  late http.Response Function(http.Request) answer;
  late List<String> failures;
  String? user;

  SyncManager manager({String? token, SyncConfig? config}) {
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      userToken: token,
      httpClient: MockClient((request) async {
        requests.add(request);
        return answer(request);
      }),
    );
    return SyncManager(
      api: api,
      storage: storage,
      currentUserId: () => user,
      config: config,
      onSyncEvent: (e, data) {
        if (e == SyncEvent.syncFailed) failures.add(data!['error'] as String);
      },
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = OfflineStorage();
    await storage.init();
    requests = [];
    failures = [];
    user = 'alice';
    answer = (request) =>
        json({'synced': eventsOf(request).length, 'failed': 0});
  });

  test('the queue holds at most 1,000 events, oldest dropped', () async {
    await storage.saveOfflineEvents(List.generate(1000, event));
    // Even if the saved config asks for more.
    final sync = manager(config: const SyncConfig(maxOfflineEvents: 50000));

    for (var i = 1000; i < 1005; i++) {
      await sync.queueEvent(event(i));
    }

    final queued = await storage.getOfflineEvents();
    expect(queued, hasLength(1000));
    expect(queued.first.id, 'evt_5');
    expect(queued.last.id, 'evt_1004');
    expect(requests, isEmpty, reason: 'no token: parked, not sent');
  });

  test('events go out in batches of at most 100', () async {
    await storage.saveOfflineEvents(List.generate(250, event));
    final sync = manager(
        token: tokenFor('alice'),
        config: const SyncConfig(maxBatchSize: 500));

    final result = await sync.flush();

    expect(requests.map((r) => eventsOf(r).length), [100, 100, 50]);
    expect(result.synced, 250);
    expect(await storage.getOfflineEventCount(), 0);
    final ids = requests.expand(eventsOf).map((e) => e['clientEventId']);
    expect(ids.toSet(), hasLength(250), reason: 'no event sent twice');
  });

  test('flushes do not overlap', () async {
    await storage.saveOfflineEvents(List.generate(120, event));
    final sync = manager(token: tokenFor('alice'));

    await Future.wait([sync.flush(), sync.flush(), sync.sync()]);
    await sync.flush();

    final ids = requests.expand(eventsOf).map((e) => e['clientEventId']);
    expect(ids, hasLength(120));
    expect(ids.toSet(), hasLength(120));
  });

  test('without a token nothing is sent and nothing is reported', () async {
    await storage.saveOfflineEvents(List.generate(3, event));
    final sync = manager();

    for (var i = 0; i < 3; i++) {
      await sync.sync();
    }
    await sync.flush();

    expect(requests, isEmpty);
    expect(failures, isEmpty);
    expect(await storage.getOfflineEventCount(), 3);
  });

  test('without a user the events stay parked', () async {
    user = null;
    await storage.saveOfflineEvents([event(1, userId: '')]);
    final sync = manager(token: tokenFor('alice'));

    await sync.flush();

    expect(requests, isEmpty);
    expect(await storage.getOfflineEventCount(), 1);
  });

  test('events the service rejects are dropped, not sent again', () async {
    await storage.saveOfflineEvents(List.generate(4, event));
    answer = (_) => json({'synced': 1, 'failed': 3});
    final sync = manager(token: tokenFor('alice'));

    final result = await sync.flush();

    expect(requests, hasLength(1));
    expect(result.failed, 3);
    expect(await storage.getOfflineEventCount(), 0);
  });

  test('a failing service: events kept, one error, no request per tick',
      () async {
    await storage.saveOfflineEvents(List.generate(3, event));
    answer = (_) => json({'message': 'down'}, 503);
    final sync = manager(token: tokenFor('alice'));

    for (var i = 0; i < 5; i++) {
      await sync.sync();
    }

    expect(requests, hasLength(1));
    expect(failures, ['Sync failed: 503']);
    expect(await storage.getOfflineEventCount(), 3);
  });

  test('401 without a token code: kept, reported once', () async {
    await storage.saveOfflineEvents(List.generate(2, event));
    answer = (_) => json({'message': 'Invalid API key'}, 401);
    final sync = manager(token: tokenFor('alice'));

    await sync.sync();
    await sync.sync();
    await sync.flush();
    await sync.flush();

    expect(failures, hasLength(1));
    expect(await storage.getOfflineEventCount(), 2);
  });

  test('event limit reached: events kept, sending stops, one error',
      () async {
    await storage.saveOfflineEvents(List.generate(150, event));
    answer = (_) => json({'code': 'event_limit_reached'}, 403);
    final sync = manager(token: tokenFor('alice'));

    await sync.flush();
    await sync.sync();
    await sync.sync();

    expect(requests, hasLength(1));
    expect(failures, ['Event limit reached']);
    expect(await storage.getOfflineEventCount(), 150);
  });

  test('429: nothing more is sent until Retry-After has passed', () async {
    await storage.saveOfflineEvents(List.generate(150, event));
    answer = (_) => http.Response('{}', 429, headers: {'retry-after': '60'});
    final sync = manager(token: tokenFor('alice'));

    await sync.flush();
    await sync.sync();
    await sync.flush();

    expect(requests, hasLength(1));
    expect(failures, isEmpty);
    expect(await storage.getOfflineEventCount(), 150);
  });

  test('a batch the service calls malformed is dropped, the rest goes on',
      () async {
    await storage.saveOfflineEvents(List.generate(150, event));
    var first = true;
    answer = (request) {
      if (first) {
        first = false;
        return json({'message': 'bad'}, 400);
      }
      return json({'synced': eventsOf(request).length, 'failed': 0});
    };
    final sync = manager(token: tokenFor('alice'));

    await sync.flush();
    await sync.flush();

    expect(requests.map((r) => eventsOf(r).length), [100, 50]);
    expect(await storage.getOfflineEventCount(), 0);
  });

  test('keepOnlyEventsOf drops everyone else\'s events', () async {
    await storage.saveOfflineEvents([
      event(1, userId: ''),
      event(2, userId: 'alice'),
      event(3, userId: 'bob'),
    ]);
    final sync = manager();

    await sync.keepOnlyEventsOf('alice');
    expect((await storage.getOfflineEvents()).map((e) => e.id), ['evt_2']);

    await sync.keepOnlyEventsOf(null);
    expect(await storage.getOfflineEvents(), isEmpty);
  });
}
