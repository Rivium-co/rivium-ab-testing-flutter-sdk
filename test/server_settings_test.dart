import 'package:rivium_ab_testing/rivium_ab_testing.dart';
import 'package:rivium_ab_testing/src/offline/offline_storage.dart';
import 'package:rivium_ab_testing/src/offline/sync_manager.dart';
import 'package:rivium_ab_testing/src/platform.dart';
import 'package:rivium_ab_testing/src/rivium_api_client.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The send interval and the list cache the console sets, and the time on
/// each event.
void main() {
  late FakeService service;
  late List<Map<String, dynamic>?> errors;
  late DateTime now;
  RiviumAbTesting? sdk;

  Future<RiviumAbTesting> start({int? flushInterval, String? userToken}) async {
    final started = await RiviumAbTesting.init(
      flushInterval == null
          ? RiviumAbTestingConfig(apiKey: 'rv_test_k', userToken: userToken)
          : RiviumAbTestingConfig(
              apiKey: 'rv_test_k',
              userToken: userToken,
              flushInterval: flushInterval,
            ),
      baseUrl: 'https://abtest.test',
      callback: (event, data) {
        if (event == 'error') errors.add(data);
      },
    );
    sdk = started;
    await settle();
    return started;
  }

  setUp(() {
    service = FakeService()..install();
    errors = [];
    now = DateTime.utc(2026, 10, 11, 12);
    RiviumPlatform.now = () => now;
  });

  tearDown(() async {
    await sdk?.reset();
    sdk = null;
    RiviumPlatform.restoreDefaults();
  });

  group('what the console says', () {
    test('values are read and kept inside safe bounds', () {
      SyncConfig read(Object? sync, Object? cache) => SyncConfig.fromJson(
          {'syncIntervalSeconds': sync, 'cacheTtlSeconds': cache});

      expect(read(60, 120).syncIntervalSeconds, 60);
      expect(read(60, 120).cacheTtlSeconds, 120);
      // Never more often than every 10 seconds / once a minute.
      expect(read(1, 1).syncIntervalSeconds, 10);
      expect(read(1, 1).cacheTtlSeconds, 60);
      expect(read(99999999, 99999999).syncIntervalSeconds, 3600);
      expect(read(99999999, 99999999).cacheTtlSeconds, 86400);
      // Missing, zero, negative, a fraction, text: the built-in values.
      for (final bad in [null, 0, -5, 12.5, '45', true]) {
        expect(read(bad, bad).syncIntervalSeconds, 30, reason: '$bad');
        expect(read(bad, bad).cacheTtlSeconds, 300, reason: '$bad');
      }
      expect(read(45.0, 600.0).syncIntervalSeconds, 45);
      expect(const SyncConfig().cacheTtlSeconds, 300);
    });

    test('the config keeps its meaning for existing code', () {
      const plain = RiviumAbTestingConfig(apiKey: 'k');
      expect(plain.flushInterval, 30000);
      expect(plain.hasOwnFlushInterval, isFalse);
      expect(RiviumAbTestingConfig.fromApiKey('k').hasOwnFlushInterval, isFalse);
      const own = RiviumAbTestingConfig(apiKey: 'k', flushInterval: 5000);
      expect(own.flushInterval, 5000);
      expect(own.hasOwnFlushInterval, isTrue);
      expect(own.toMap()['flushInterval'], 5000);
    });

    test('an interval the app chose wins over the console\'s', () async {
      service.config = {'syncIntervalSeconds': 600, 'cacheTtlSeconds': 120};
      final started =
          await start(flushInterval: 1000, userToken: tokenFor('alice'));
      await started.trackView('checkout');
      expect(service.posts('/public/sync'), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(service.posts('/public/sync'), hasLength(1));
    });
  });

  group('the send interval inside the sync manager', () {
    SyncManager manager({int? own, SyncConfig? config}) => SyncManager(
          api: RiviumApiClient(apiKey: 'k', baseUrl: 'https://abtest.test'),
          storage: OfflineStorage(),
          ownSyncIntervalSeconds: own,
          config: config,
        );

    test('the console\'s value is used, and a new one from the next refresh',
        () {
      final sync = manager();
      expect(sync.syncIntervalSeconds, 30);
      sync.updateConfig(SyncConfig.fromJson({'syncIntervalSeconds': 60}));
      expect(sync.syncIntervalSeconds, 60);
      sync.updateConfig(SyncConfig.fromJson({'syncIntervalSeconds': 3}));
      expect(sync.syncIntervalSeconds, 10);
      sync.dispose();
    });

    test('the app\'s own value stays, whatever the console says', () {
      final sync = manager(own: 5);
      expect(sync.syncIntervalSeconds, 5);
      sync.updateConfig(SyncConfig.fromJson({'syncIntervalSeconds': 60}));
      expect(sync.syncIntervalSeconds, 5);
      expect(sync.listCache, const Duration(seconds: 300));
      sync.dispose();
    });
  });

  group('the experiment list', () {
    test('is reused while it is fresh and asked for again once it is stale',
        () async {
      service.config = {'syncIntervalSeconds': 60, 'cacheTtlSeconds': 120};
      final started = await start(userToken: tokenFor('alice'));
      final lists = service.gets('/public/experiments').length;
      final inits = service.gets('/public/init').length;
      expect(lists, 1);

      now = now.add(const Duration(seconds: 119));
      for (var i = 0; i < 5; i++) {
        await started.getVariant('checkout');
      }
      await settle();
      expect(service.gets('/public/experiments'), hasLength(lists));
      expect(service.gets('/public/init'), hasLength(inits));

      // The console changed the cache time in the meantime.
      service.config = {'syncIntervalSeconds': 60, 'cacheTtlSeconds': 600};
      now = now.add(const Duration(seconds: 2));
      await Future.wait(
          [for (var i = 0; i < 5; i++) started.getVariant('checkout')]);
      await settle();
      // One refresh, however many callers.
      expect(service.gets('/public/experiments'), hasLength(lists + 1));
      expect(service.gets('/public/init'), hasLength(inits + 1));

      // The new value is in use without a restart.
      now = now.add(const Duration(seconds: 599));
      await started.getVariant('checkout');
      await settle();
      expect(service.gets('/public/experiments'), hasLength(lists + 1));
      now = now.add(const Duration(seconds: 2));
      await started.trackView('checkout');
      await settle();
      expect(service.gets('/public/experiments'), hasLength(lists + 2));
    });

    test('a refresh that fails is not repeated on every call and is not an error',
        () async {
      final started = await start(userToken: tokenFor('alice'));
      final lists = service.gets('/public/experiments').length;
      errors.clear();

      service.readStatus = 500;
      now = now.add(const Duration(seconds: 301));
      for (var i = 0; i < 5; i++) {
        await started.getVariant('checkout');
        await settle();
      }
      expect(service.gets('/public/experiments'), hasLength(lists + 1));
      expect(errors, isEmpty);

      service.readStatus = 200;
      now = now.add(const Duration(seconds: 61));
      await started.getVariant('checkout');
      await settle();
      expect(service.gets('/public/experiments'), hasLength(lists + 2));
    });
  });

  test('every event carries the time it was recorded, in milliseconds',
      () async {
    RiviumPlatform.now = DateTime.now;
    final started = await start(userToken: tokenFor('alice'));
    final before = DateTime.now().millisecondsSinceEpoch;
    await started.trackView('checkout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await started.trackPurchase('checkout', value: 9.5);
    final after = DateTime.now().millisecondsSinceEpoch;
    await started.flush();

    final sent = service.posts('/public/sync').expand(eventsOf).toList();
    expect(sent, hasLength(2));
    final times = sent.map((e) => e['timestamp']).toList();
    expect(times, everyElement(isA<int>()));
    expect(times.every((t) => (t as int) >= before && t <= after), isTrue);
    expect(times[0] as int, lessThan(times[1] as int));
  });
}
