import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rivium_ab_testing/src/rivium_api_client.dart';
import 'package:test/test.dart';

String tokenFor(String sub, {int expiresIn = 3600}) {
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': sub, 'exp': exp})))
      .replaceAll('=', '');
  return 'header.$payload.signature';
}

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
    await api.get('/public/flags');

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

    await api.get('/a');
    await api.get('/b');

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

    final response = await api.get('/public/init');

    expect(response.statusCode, 200);
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

    final response = await api.get('/public/init');

    expect(response.statusCode, 401);
    expect(requests, 2);
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

    await api.get('/a');
    user = 'bob';
    api.clearToken();
    await api.get('/b');

    expect(subs, ['alice', 'bob']);
  });

  test('a failing tokenProvider does not break the request', () async {
    late http.Request seen;
    final api = RiviumApiClient(
      apiKey: 'k',
      baseUrl: 'https://abtest.test',
      tokenProvider: () async => throw Exception('offline'),
      httpClient: MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }),
    );

    final response = await api.get('/public/flags');

    expect(response.statusCode, 200);
    expect(seen.headers.containsKey('x-user-token'), isFalse);
  });
}
