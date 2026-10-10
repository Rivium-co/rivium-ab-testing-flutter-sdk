import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivium_ab_testing/src/rivium_api_client.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('sends the api key and no user token when none is configured', () async {
    late http.Request seen;
    final api = RiviumApiClient(
      apiKey: 'rv_live_k',
      baseUrl: 'https://abtest.test',
      httpClient: MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }),
    );

    await api.get('/public/flags');

    expect(seen.headers['x-api-key'], 'rv_live_k');
    expect(seen.headers.containsKey('x-user-token'), isFalse);
    expect(api.usesUserToken, isFalse);
  });

  test('sends the token and reuses it until close to expiry', () async {
    var providerCalls = 0;
    final tokens = <String?>[];
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async {
        providerCalls++;
        return tokenFor('alice');
      },
      httpClient: MockClient((req) async {
        tokens.add(req.headers['x-user-token']);
        return http.Response('{}', 200);
      }),
    );

    await api.post('/public/assign', {'experimentKey': 'x'});
    await api.post('/public/flag-evaluation', {'flagKey': 'f'});

    expect(providerCalls, 1);
    expect(tokens, hasLength(2));
    expect(tokens[0], isNotNull);
    expect(tokens[1], tokens[0]);
  });

  test('fetches a new token when the cached one is about to expire', () async {
    var providerCalls = 0;
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      // Expires inside the refresh window, so it is never reused.
      tokenProvider: () async {
        providerCalls++;
        return tokenFor('alice', expiresIn: 30);
      },
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );

    await api.post('/a', {});
    await api.post('/b', {});

    expect(providerCalls, 2);
  });

  test('on token_expired: refetches the token and retries once', () async {
    var providerCalls = 0;
    var requests = 0;
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async {
        providerCalls++;
        return tokenFor('alice');
      },
      httpClient: MockClient((_) async {
        requests++;
        return requests == 1
            ? http.Response(jsonEncode({'code': 'token_expired'}), 401)
            : http.Response('{}', 200);
      }),
    );

    final response = await api.post('/public/assign', {});

    expect(response!.statusCode, 200);
    expect(requests, 2);
    expect(providerCalls, 2);
  });

  test('does not retry forever when the token keeps failing', () async {
    var requests = 0;
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async => tokenFor('alice'),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response(jsonEncode({'code': 'token_expired'}), 401);
      }),
    );

    final rejected = <String>[];
    api.onTokenRejected = rejected.add;

    expect(await api.post('/public/assign', {}), isNull);
    expect(requests, 2);

    // The token is not tried again, and the app hears about it once.
    expect(await api.post('/public/assign', {}), isNull);
    expect(requests, 2);
    expect(api.isAwaitingUserToken, isTrue);
    expect(rejected, ['token_expired']);
  });

  test('clearToken forces a new token for the next user', () async {
    var user = 'alice';
    final subs = <String>[];
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async => tokenFor(user),
      httpClient: MockClient((req) async {
        final payload = req.headers['x-user-token']!.split('.')[1];
        subs.add(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))))['sub']);
        return http.Response('{}', 200);
      }),
    );

    await api.post('/a', {});
    user = 'bob';
    api.clearToken();
    await api.post('/b', {});

    expect(subs, ['alice', 'bob']);
  });

  test('reads carry the api key only and never ask for a token', () async {
    var providerCalls = 0;
    late http.Request seen;
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async {
        providerCalls++;
        throw Exception('offline');
      },
      httpClient: MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }),
    );

    final response = await api.get('/public/flags');

    expect(response.statusCode, 200);
    expect(seen.headers.containsKey('x-user-token'), isFalse);
    expect(providerCalls, 0);
  });

  group('awaiting a user token', () {
    late List<http.Request> requests;
    late http.Response Function(http.Request) answer;
    late int awaitingCalls;

    RiviumApiClient client({RiviumTokenProvider? provider, String? token}) {
      final api = RiviumApiClient(
        apiKey: 'k',
        baseUrl: 'https://abtest.test',
        tokenProvider: provider,
        userToken: token,
        httpClient: MockClient((req) async {
          requests.add(req);
          return answer(req);
        }),
      );
      api.onAwaitingUserToken = () => awaitingCalls++;
      return api;
    }

    setUp(() {
      requests = [];
      awaitingCalls = 0;
      answer = (_) => http.Response('{}', 200);
    });

    test('no provider and no token: nothing is sent', () async {
      final api = client();

      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/sync', {}), isNull);

      expect(requests, isEmpty);
      expect(api.isAwaitingUserToken, isTrue);
      expect(awaitingCalls, 1);
    });

    test('a provider that returns null is asked once, not per request',
        () async {
      var providerCalls = 0;
      final api = client(provider: () {
        providerCalls++;
        return null;
      });

      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/assign', {}), isNull);

      expect(requests, isEmpty);
      expect(providerCalls, 1);
      expect(awaitingCalls, 1);
    });

    test('a provider that throws means waiting, not a request without a token',
        () async {
      var providerCalls = 0;
      final api = client(provider: () async {
        providerCalls++;
        throw Exception('no session');
      });

      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/assign', {}), isNull);

      expect(requests, isEmpty);
      expect(providerCalls, 1);
      expect(api.isAwaitingUserToken, isTrue);
    });

    test('refreshUserToken leaves the waiting state once there is a token',
        () async {
      String? session;
      var ready = 0;
      final api = client(provider: () => session);
      api.onUserTokenReady = () => ready++;

      await api.start();
      expect(api.isAwaitingUserToken, isTrue);

      session = tokenFor('alice');
      await api.refreshUserToken();
      await Future<void>.delayed(Duration.zero);

      expect(api.isAwaitingUserToken, isFalse);
      expect(ready, 1);
      final response = await api.post('/public/assign', {});
      expect(response!.statusCode, 200);
      expect(requests.single.headers['x-user-token'], session);
    });

    test('setUserToken(null) goes back to waiting', () async {
      final api = client();
      var signedOut = 0;
      api.onSignedOut = () async => signedOut++;

      await api.setUserToken(tokenFor('alice'));
      expect(api.isAwaitingUserToken, isFalse);
      expect((await api.post('/public/assign', {}))!.statusCode, 200);

      await api.setUserToken(null);

      expect(api.isAwaitingUserToken, isTrue);
      expect(signedOut, 1);
      expect(await api.post('/public/assign', {}), isNull);
      expect(requests, hasLength(1));
    });

    test('token_required: waiting, and the request is not repeated', () async {
      answer = (_) => tokenError('token_required');
      final api = client(token: 'opaque');
      await api.start();

      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/assign', {}), isNull);

      expect(requests, hasLength(1));
      expect(api.isAwaitingUserToken, isTrue);
      expect(awaitingCalls, 1);
    });

    test('token_expired and the refresh gives no token: waiting, no retry',
        () async {
      String? session = tokenFor('alice');
      var providerCalls = 0;
      answer = (_) => tokenError('token_expired');
      final api = client(provider: () {
        providerCalls++;
        return session;
      });

      await api.start();
      session = null;
      expect(await api.post('/public/assign', {}), isNull);

      expect(requests, hasLength(1));
      expect(providerCalls, 2);
      expect(api.isAwaitingUserToken, isTrue);
    });

    test('concurrent requests share one token refresh', () async {
      var providerCalls = 0;
      var expired = true;
      answer = (_) {
        if (expired) {
          return tokenError('token_expired');
        }
        return http.Response('{}', 200);
      };
      final api = client(provider: () async {
        providerCalls++;
        if (providerCalls == 2) expired = false;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return tokenFor('alice-$providerCalls');
      });
      await api.start();

      final responses = await Future.wait([
        api.post('/a', {}),
        api.post('/b', {}),
        api.post('/c', {}),
      ]);

      expect(responses.map((r) => r?.statusCode), [200, 200, 200]);
      expect(providerCalls, 2);
    });

    test('token_invalid: not retried, reported once', () async {
      answer = (_) => tokenError('token_invalid');
      final rejected = <String>[];
      final api = client(provider: () => tokenFor('alice'));
      api.onTokenRejected = rejected.add;

      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/assign', {}), isNull);
      expect(await api.post('/public/sync', {}), isNull);

      expect(requests, hasLength(1));
      expect(rejected, ['token_invalid']);
    });

    test('a request for one user is never sent with another user\'s token',
        () async {
      final api = client(provider: () => tokenFor('bob'));

      expect(await api.post('/public/sync', {}, userId: 'alice'), isNull);
      expect(requests, isEmpty);
      expect((await api.post('/public/sync', {}, userId: 'bob'))!.statusCode,
          200);
    });

    test('a pinned request uses the token in hand and never the provider',
        () async {
      var user = 'alice';
      var providerCalls = 0;
      // Inside the refresh window: an ordinary request would ask again.
      final api = client(provider: () {
        providerCalls++;
        return tokenFor(user, expiresIn: 30);
      });
      await api.start();
      user = 'bob';

      await api.post('/public/sync', {}, userId: 'alice', pinned: true);

      expect(providerCalls, 1);
      expect(subOf(requests.single.headers['x-user-token']), 'alice');
    });

    test('a token of another user is announced before it is used', () async {
      var user = 'alice';
      final order = <String>[];
      final api = client(provider: () => tokenFor(user));
      api.onTokenUser = (id) async => order.add('user:$id');
      answer = (req) {
        order.add('sent:${subOf(req.headers['x-user-token'])}');
        return http.Response('{}', 200);
      };

      await api.post('/a', {});
      user = 'bob';
      await api.refreshUserToken();
      await api.post('/b', {});

      expect(order, ['user:alice', 'sent:alice', 'user:bob', 'sent:bob']);
    });

    test('429: Retry-After is honoured', () async {
      answer = (_) =>
          http.Response('{}', 429, headers: {'retry-after': '120'});
      final api = client(token: tokenFor('alice'));
      await api.start();

      final first = await api.post('/public/sync', {});
      expect(first!.statusCode, 429);
      expect(await api.post('/public/sync', {}), isNull);
      expect(await api.post('/public/assign', {}), isNull);

      expect(requests, hasLength(1));
      final wait = api.rateLimitedUntil!.difference(DateTime.now());
      expect(wait.inSeconds, inInclusiveRange(110, 120));
      expect(api.isAwaitingUserToken, isFalse);
    });
  });

  group('baseUrl', () {
    test('https is accepted, and http for local development only', () {
      for (final ok in [
        'https://abtest.rivium.co',
        'http://localhost:3007',
        'http://127.0.0.1:3007',
        'http://10.0.2.2:3007',
      ]) {
        RiviumApiClient.checkBaseUrl(ok);
      }
      for (final bad in [
        'http://abtest.rivium.co',
        'http://192.168.1.20:3007',
        'http://localhost.example.com',
        'ftp://localhost',
        'abtest.rivium.co',
      ]) {
        expect(() => RiviumApiClient.checkBaseUrl(bad), throwsArgumentError,
            reason: bad);
      }
    });

    test('the message says what is allowed', () {
      expect(
        () => RiviumApiClient(apiKey: 'k', baseUrl: 'http://example.com'),
        throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message',
            allOf(contains('https'), contains('localhost')))),
      );
    });
  });
}
