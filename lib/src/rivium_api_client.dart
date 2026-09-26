import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Returns a Rivium user token for the signed-in user, minted by your server.
typedef RiviumTokenProvider = Future<String> Function();

/// Every call to the A/B Testing service goes through here: the API key, the
/// signed user token, and one retry with a fresh token when the service says
/// the token expired.
///
/// The API key ships inside the app, so it proves nothing about which user a
/// request is for. The user token does: the customer's server mints it with
/// the project's server secret, and the service takes the user from it.
class RiviumApiClient {
  RiviumApiClient({
    required this.apiKey,
    required this.baseUrl,
    this.tokenProvider,
    this.userToken,
    this.debug = false,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Fetch a new token this long before the current one expires.
  static const Duration tokenRefreshSkew = Duration(seconds: 60);

  final String apiKey;
  final String baseUrl;
  final RiviumTokenProvider? tokenProvider;
  final String? userToken;
  final bool debug;
  final http.Client _http;

  String? _token;
  int _tokenExpiresAt = 0; // seconds since epoch
  Future<String?>? _tokenInFlight;

  /// True when requests carry a user token, so the service credits them to
  /// the token's user rather than to any userId in the body.
  bool get usesUserToken => tokenProvider != null || userToken != null;

  Future<http.Response> get(String path) => _send('GET', path, null, true);

  Future<http.Response> post(String path, Object body) =>
      _send('POST', path, jsonEncode(body), true);

  /// Forget the cached token, e.g. when another user signs in.
  void clearToken() {
    _token = null;
    _tokenExpiresAt = 0;
  }

  Future<http.Response> _send(
      String method, String path, String? body, bool retry) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
    };
    final token = await _currentToken();
    if (token != null) {
      headers['x-user-token'] = token;
    }

    final uri = Uri.parse('$baseUrl$path');
    final response = method == 'GET'
        ? await _http.get(uri, headers: headers)
        : await _http.post(uri, headers: headers, body: body);

    if (response.statusCode == 401 && retry && usesUserToken) {
      final code = _errorCode(response.body);
      if (code == 'token_expired' && tokenProvider != null) {
        clearToken();
        return _send(method, path, body, false);
      }
      if (code != null && debug) {
        // ignore: avoid_print
        print('RiviumAbTesting: user token rejected ($code)');
      }
    }
    return response;
  }

  Future<String?> _currentToken() {
    if (userToken != null) return Future.value(userToken);
    if (tokenProvider == null) return Future.value(null);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_token != null &&
        _tokenExpiresAt - tokenRefreshSkew.inSeconds > now) {
      return Future.value(_token);
    }
    return _tokenInFlight ??= _fetchToken();
  }

  Future<String?> _fetchToken() async {
    try {
      final token = await tokenProvider!();
      _token = token;
      _tokenExpiresAt = _expiry(token);
      return token;
    } catch (e) {
      if (debug) {
        // ignore: avoid_print
        print('RiviumAbTesting: tokenProvider failed: $e');
      }
      return _token;
    } finally {
      _tokenInFlight = null;
    }
  }

  /// `exp` from the token payload; 0 (fetch again next time) if unreadable.
  static int _expiry(String token) {
    try {
      final parts = token.split('.');
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload['exp'];
      return exp is num ? exp.toInt() : 0;
    } catch (_) {
      return 0;
    }
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded['code'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}
