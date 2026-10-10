import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rivium_ab_testing/rivium_ab_testing.dart';
import 'package:rivium_ab_testing/src/offline/offline_storage.dart';
import 'package:rivium_ab_testing/src/platform.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late FakeService service;
  late List<String> events;
  late List<Map<String, dynamic>?> errors;
  RiviumAbTesting? sdk;

  Future<RiviumAbTesting> start({
    RiviumTokenProvider? tokenProvider,
    String? userToken,
  }) async {
    final started = await RiviumAbTesting.init(
      RiviumAbTestingConfig(
        apiKey: 'rv_test_k',
        tokenProvider: tokenProvider,
        userToken: userToken,
      ),
      baseUrl: 'https://abtest.test',
      callback: (event, data) {
        events.add(event);
        if (event == 'error') errors.add(data);
      },
    );
    sdk = started;
    await settle();
    return started;
  }

  setUp(() {
    service = FakeService()..install();
    events = [];
    errors = [];
  });

  tearDown(() async {
    await sdk?.reset();
    sdk = null;
    RiviumPlatform.restoreDefaults();
  });

  group('no user token yet', () {
    test('nothing is sent for a user, the default is returned, events are parked',
        () async {
      // A running experiment in the cache: the SDK must not pick from it.
      service.experiments = [
        {
          'id': 'id-checkout',
          'key': 'checkout',
          'name': 'Checkout',
          'trafficAllocation': 100,
          'variants': [
            {'id': 'v1', 'key': 'new', 'name': 'new', 'trafficSplit': 100},
          ],
        }
      ];
      final ab = await start(tokenProvider: () => null);
      var awaitingCalls = 0;
      ab.onAwaitingUserToken(() => awaitingCalls++);

      expect(ab.isAwaitingUserToken, isTrue);
      expect(events.where((e) => e == 'awaitingUserToken'), hasLength(1));

      // No user id either: 0.2.0 threw USER_NOT_SET here.
      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      await ab.trackView('checkout');
      expect(await ab.getPendingEventCount(), 1);

      // The anonymous event belongs to nobody; alice's own are kept.
      await ab.setUserId('alice');
      await ab.trackClick('checkout');
      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      expect(await ab.getVariantConfig('checkout'), isNull);
      await ab.trackConversion('checkout', value: 5);
      await ab.flush();
      await settle();

      expect(service.posts(), isEmpty);
      expect(await ab.getPendingEventCount(), 2);
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
      expect(events, isNot(contains('experimentAssigned')));
      expect(errors, isEmpty);
      expect(awaitingCalls, 0, reason: 'once per transition, already waiting');
    });

    test('no provider at all behaves the same', () async {
      final ab = await start();
      await ab.setUserId('alice');

      expect(ab.isAwaitingUserToken, isTrue);
      expect(await ab.getVariant('checkout'), 'control');
      expect(await ab.isFeatureEnabled('dark-mode', defaultValue: true), isTrue);
      await ab.trackClick('checkout');
      await ab.flush();

      expect(service.posts(), isEmpty);
      expect(errors, isEmpty);
    });

    test('a provider that throws is not an error', () async {
      final ab = await start(tokenProvider: () async => throw Exception('x'));
      await ab.setUserId('alice');

      expect(await ab.getVariant('checkout'), 'control');
      expect(ab.isAwaitingUserToken, isTrue);
      expect(service.posts(), isEmpty);
      expect(errors, isEmpty);
    });

    test('the server says token_required: default, nothing cached, no retry',
        () async {
      service.experiments = [
        {
          'id': 'id-checkout',
          'key': 'checkout',
          'name': 'Checkout',
          'trafficAllocation': 100,
          'variants': [
            {'id': 'v1', 'key': 'new', 'name': 'new', 'trafficSplit': 100},
          ],
        }
      ];
      service.onPost = (_) => tokenError('token_required');
      final ab = await start(userToken: 'not-a-rivium-token');
      await ab.setUserId('alice');

      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      await ab.trackView('checkout');
      await ab.flush();

      expect(service.posts(), hasLength(1));
      expect(ab.isAwaitingUserToken, isTrue);
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
      expect(await ab.getPendingEventCount(), 1);
      expect(errors, isEmpty);
    });
  });

  group('the token arrives', () {
    test('provider null, then a token: variant fetched and events sent',
        () async {
      String? session;
      final ab = await start(tokenProvider: () => session);
      await ab.trackView('checkout'); // before anyone is known: anonymous
      await ab.setUserId('alice');
      expect(await ab.getVariant('checkout'), 'control');
      await ab.trackClick('checkout');
      await ab.trackConversion('checkout', value: 9.5);
      expect(service.posts(), isEmpty);

      session = tokenFor('alice');
      await ab.refreshUserToken();
      await settle();

      expect(ab.isAwaitingUserToken, isFalse);
      final assigns = service.posts('/public/assign');
      expect(assigns, hasLength(1));
      expect(assigns.single.headers['x-user-token'], session);
      expect(events, contains('experimentAssigned'));
      expect(await ab.getVariant('checkout'), 'B');

      // Only alice's events: the anonymous one cannot be credited to her.
      final sent = service.posts('/public/sync').expand(eventsOf).toList();
      expect(sent.map((e) => e['eventType']), ['click', 'conversion']);
      expect(sent.every((e) => e['userId'] == 'alice'), isTrue);
      expect(sent.map((e) => e['clientEventId']).toSet(), hasLength(2));
      expect(await ab.getPendingEventCount(), 0);
      expect(errors, isEmpty);
    });

    test('setUserToken does the same without a provider', () async {
      final ab = await start();
      await ab.setUserId('alice');
      await ab.getVariant('checkout');
      await ab.trackView('checkout');

      await ab.setUserToken(tokenFor('alice'));
      await settle();

      expect(service.posts('/public/assign'), hasLength(1));
      expect(service.posts('/public/sync').expand(eventsOf), hasLength(1));
      expect(await ab.getVariant('checkout'), 'B');
    });

    test('the token says who the user is when setUserId was never called',
        () async {
      final ab = await start(tokenProvider: () => tokenFor('alice'));

      expect(ab.getUserId(), 'alice');
      expect(await ab.getVariant('checkout'), 'B');
      final body = jsonDecode(service.posts('/public/assign').single.body);
      expect(body['userId'], 'alice');
    });

    test('a 0.2.0 app that only calls setUserId at sign-in carries on',
        () async {
      String? session;
      final ab = await start(tokenProvider: () => session);
      expect(ab.isAwaitingUserToken, isTrue);

      session = tokenFor('alice');
      await ab.setUserId('alice');
      await settle();

      expect(ab.isAwaitingUserToken, isFalse);
      expect(await ab.getVariant('checkout'), 'B');
    });
  });

  group('answers of the service', () {
    for (final status in [200, 201]) {
      test('assign answered with $status is an assignment', () async {
        service.assignStatus = status;
        final ab = await start(tokenProvider: () => tokenFor('alice'));

        expect(await ab.getVariant('checkout'), 'B');
        expect(await ab.getVariantConfig('checkout'), {'colour': 'B'});
        // Sticky: answered from the cache from now on.
        expect(await ab.getVariant('checkout'), 'B');
        expect(service.posts('/public/assign'), hasLength(1));
      });

      test('flag evaluation answered with $status wins over the device',
          () async {
        // On the device the flag looks off; the service says on.
        service.flags = [
          {'key': 'dark-mode', 'enabled': false, 'rolloutPercentage': 100},
        ];
        service.onPost = (request) =>
            request.url.path == '/public/flag-evaluation'
                ? json({'enabled': true, 'value': 'blue'}, status)
                : null;
        final ab = await start(tokenProvider: () => tokenFor('alice'));

        expect(await ab.isFeatureEnabled('dark-mode'), isTrue);
        expect(await ab.getFeatureValue('dark-mode'), 'blue');
      });
    }

    test('the service\'s last flag answer is kept when it cannot be asked',
        () async {
      service.flags = [
        {'key': 'dark-mode', 'enabled': false, 'rolloutPercentage': 100},
      ];
      var down = false;
      service.onPost = (request) {
        if (request.url.path != '/public/flag-evaluation') return null;
        return down ? json({}, 503) : json({'enabled': true, 'value': 1});
      };
      final ab = await start(tokenProvider: () => tokenFor('alice'));
      expect(await ab.isFeatureEnabled('dark-mode'), isTrue);

      down = true;
      expect(await ab.isFeatureEnabled('dark-mode'), isTrue);
    });

    test('inExperiment false: the variant is shown but not kept', () async {
      service.onPost = (request) => request.url.path == '/public/assign'
          ? json(assignment('checkout', 'control', inExperiment: false))
          : null;
      final ab = await start(tokenProvider: () => tokenFor('alice'));

      expect(await ab.getVariant('checkout', defaultVariant: 'x'), 'control');
      expect(await ab.getVariant('checkout', defaultVariant: 'x'), 'control');

      expect(service.posts('/public/assign'), hasLength(1));
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
      expect(events, isNot(contains('experimentAssigned')));
      expect(errors, isEmpty);
    });

    test('an error status gives the default and no variant from the device',
        () async {
      service.experiments = [
        {
          'id': 'id-checkout',
          'key': 'checkout',
          'name': 'Checkout',
          'trafficAllocation': 100,
          'variants': [
            {'id': 'v1', 'key': 'new', 'name': 'new', 'trafficSplit': 100},
          ],
        }
      ];
      service.onPost = (_) => json({'message': 'down'}, 503);
      final ab = await start(tokenProvider: () => tokenFor('alice'));

      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
    });

    test('token_invalid is reported once and not retried', () async {
      service.onPost = (_) => tokenError('token_invalid');
      final ab = await start(tokenProvider: () => tokenFor('alice'));

      await ab.getVariant('checkout');
      await ab.getVariant('checkout');
      await ab.trackView('checkout');
      await ab.flush();

      expect(service.posts(), hasLength(1));
      expect(errors, hasLength(1));
      expect(errors.single!['code'], 'token_invalid');
    });
  });

  group('user switch and sign-out', () {
    void checkNoEventUnderAnotherToken() {
      for (final request in service.posts('/public/sync')) {
        final tokenUser = subOf(request.headers['x-user-token']);
        for (final event in eventsOf(request)) {
          expect(event['userId'], tokenUser,
              reason: 'an event of ${event['userId']} went out with the '
                  'token of $tokenUser');
        }
      }
    }

    test('setUserId(other): nothing of the last user goes under the new token',
        () async {
      var user = 'alice';
      // Always inside the refresh window, so every ordinary request asks the
      // provider again - which by then answers for the next user.
      final ab = await start(
          tokenProvider: () => tokenFor(user, expiresIn: 30));
      service.onPost =
          (request) => request.url.path == '/public/sync' && user == 'alice'
              ? json({'message': 'down'}, 503)
              : null;
      ab.setUserAttributes({'plan': 'pro'});
      expect(await ab.getVariant('checkout'), 'B');
      await ab.trackView('checkout');
      await ab.trackClick('checkout');
      service.onPost = null;

      user = 'bob';
      await ab.setUserId('bob');
      await settle();
      await ab.trackView('checkout');
      await ab.flush();

      checkNoEventUnderAnotherToken();
      final sent = service.posts('/public/sync').expand(eventsOf).toList();
      expect(sent.where((e) => e['userId'] == 'alice'), hasLength(2));
      expect(sent.where((e) => e['userId'] == 'bob'), hasLength(1));

      // Bob starts clean: no variant and no attributes of alice.
      service.requests.clear();
      expect(await ab.getVariant('checkout'), 'B');
      final body = jsonDecode(service.posts('/public/assign').single.body);
      expect(body['userId'], 'bob');
      expect(body['userAttributes'], isEmpty);
    });

    test('a token of another user: the last user\'s data goes first',
        () async {
      final ab = await start();
      await ab.setUserToken(tokenFor('alice'));
      await settle();
      // Alice's events stay queued: the service is down for now.
      service.onPost = (request) => request.url.path == '/public/sync'
          ? json({'message': 'down'}, 503)
          : null;
      expect(await ab.getVariant('checkout'), 'B');
      await ab.trackView('checkout');
      await ab.flush();
      expect(await ab.getPendingEventCount(), 1);
      service.onPost = null;
      service.requests.clear();

      await ab.setUserToken(tokenFor('bob'));
      await settle();

      expect(ab.getUserId(), 'bob');
      checkNoEventUnderAnotherToken();
      expect(await ab.getPendingEventCount(), 0);
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
    });

    test('clearUserId: variants, events and token are gone, the SDK waits',
        () async {
      final ab = await start(tokenProvider: () => tokenFor('alice'));
      expect(await ab.getVariant('checkout'), 'B');
      service.onPost = (_) => json({'message': 'down'}, 503);
      await ab.trackView('checkout');
      service.requests.clear();

      await ab.clearUserId();
      service.onPost = null;
      await settle();

      expect(ab.getUserId(), isNull);
      expect(ab.isAwaitingUserToken, isTrue);
      expect(await ab.getPendingEventCount(), 0);
      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      await ab.flush();
      checkNoEventUnderAnotherToken();
      expect(service.posts('/public/assign'), isEmpty);
      expect(errors.where((e) => '${e?['message']}'.contains('token')), isEmpty);
    });

    test('setUserToken(null) signs out too', () async {
      final ab = await start(userToken: tokenFor('alice'));
      expect(ab.getUserId(), 'alice');
      expect(await ab.getVariant('checkout'), 'B');

      await ab.setUserToken(null);

      expect(ab.getUserId(), isNull);
      expect(ab.isAwaitingUserToken, isTrue);
      expect(await OfflineStorage().getCachedAssignments(), isEmpty);
    });
  });

  group('no crash paths', () {
    test('calls after reset return defaults instead of throwing', () async {
      final ab = await start(tokenProvider: () => tokenFor('alice'));
      await ab.reset();

      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      expect(await ab.getVariantConfig('checkout'), isNull);
      expect(await ab.isFeatureEnabled('f', defaultValue: true), isTrue);
      expect(await ab.getFeatureValue('f', defaultValue: 3), 3);
      expect(await ab.getFeatureFlags(), isEmpty);
      expect(ab.getExperiments(), isEmpty);
      expect(await ab.getPendingEventCount(), 0);
      expect(ab.isAwaitingUserToken, isFalse);
      await ab.trackPurchase('checkout', value: 1);
      await ab.setUserId('alice');
      await ab.setUserToken(null);
      await ab.refreshUserToken();
      await ab.clearUserId();
      await ab.flush();
    });

    test('init refuses a plain http baseUrl and can be called again',
        () async {
      await expectLater(
        RiviumAbTesting.init(
          const RiviumAbTestingConfig(apiKey: 'k'),
          baseUrl: 'http://abtest.example.com',
        ),
        throwsArgumentError,
      );

      final ab = await start(tokenProvider: () => tokenFor('alice'));
      expect(await ab.getVariant('checkout'), 'B');
    });

    test('a broken answer gives the default', () async {
      service.onPost = (_) => http.Response('<html>', 200);
      final ab = await start(tokenProvider: () => tokenFor('alice'));

      expect(await ab.getVariant('checkout', defaultVariant: 'old'), 'old');
      expect(await ab.isFeatureEnabled('f', defaultValue: true), isTrue);
    });
  });

  group('standalone feature flags', () {
    RiviumFeatureFlags? flags;

    tearDown(() async {
      await flags?.reset();
      flags = null;
    });

    test('waits for a token, then asks the service', () async {
      service.flags = [
        {'key': 'dark-mode', 'enabled': true, 'rolloutPercentage': 50},
      ];
      String? session;
      final seen = <String>[];
      flags = await RiviumFeatureFlags.init(
        RiviumFeatureFlagsConfig(
          apiKey: 'k',
          baseUrl: 'https://abtest.test',
          tokenProvider: () => session,
        ),
        callback: (event, _) => seen.add(event),
      );
      await settle();

      expect(flags!.isAwaitingUserToken, isTrue);
      expect(seen, contains('awaitingUserToken'));
      // A partial rollout and nobody to bucket: off, not on for everyone.
      expect(await flags!.isEnabled('dark-mode'), isFalse);
      expect(service.posts(), isEmpty);
      expect(seen, isNot(contains('error')));

      session = tokenFor('alice');
      await flags!.refreshUserToken();

      expect(flags!.isAwaitingUserToken, isFalse);
      expect(flags!.getUserId(), 'alice');
      expect(await flags!.isEnabled('dark-mode'), isTrue);
      expect(service.posts('/public/flag-evaluation'), hasLength(1));

      await flags!.clearUserId();
      expect(flags!.getUserId(), isNull);
      expect(flags!.isAwaitingUserToken, isTrue);
    });
  });
}
