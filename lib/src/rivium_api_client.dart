import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'platform.dart';

/// Returns a Rivium user token for the signed-in user, minted by your server,
/// or null when no one is signed in.
typedef RiviumTokenProvider = FutureOr<String?> Function();

/// Every call to the A/B Testing service goes through here: the API key, the
/// signed user token, and one retry with a fresh token when the service says
/// the token expired.
///
/// The API key ships inside the app, so it proves nothing about which user a
/// request is for. The user token does: the customer's server mints it with
/// the project's server secret, and the service takes the user from it.
///
/// Without a token the client is "awaiting a user token": requests that act
/// for a user are not sent at all, and [post] answers null.
class RiviumApiClient {
  RiviumApiClient({
    required this.apiKey,
    required this.baseUrl,
    RiviumTokenProvider? tokenProvider,
    String? userToken,
    this.debug = false,
    http.Client? httpClient,
  })  : _provider = tokenProvider,
        _initialToken =
            (userToken != null && userToken.isNotEmpty) ? userToken : null,
        _http = httpClient ?? RiviumPlatform.httpClient() {
    checkBaseUrl(baseUrl);
  }

  /// Fetch a new token this long before the current one expires.
  static const Duration tokenRefreshSkew = Duration(seconds: 60);

  /// Wait this long before asking the provider again after it failed.
  static const Duration tokenRetryDelay = Duration(seconds: 60);

  /// A provider that has not answered after this long counts as failed.
  static const Duration tokenProviderTimeout = Duration(seconds: 30);

  /// Used when a 429 carries no readable `Retry-After`.
  static const Duration defaultRetryAfter = Duration(seconds: 30);

  final String apiKey;
  final String baseUrl;
  final bool debug;
  final http.Client _http;

  RiviumTokenProvider? _provider;
  String? _initialToken;

  String? _token;
  int _tokenExpiresAt = 0; // seconds since epoch
  Future<String?>? _tokenInFlight;
  int _generation = 0;

  /// The user of the last token taken into use, while they are signed in.
  String? _tokenUser;
  bool _signedIn = false;

  bool _awaiting = false;
  DateTime? _askAgainAt;
  String? _rejectedToken;
  DateTime? _rateLimitedUntil;

  /// Called once each time the client starts waiting for a user token.
  void Function()? onAwaitingUserToken;

  /// Called when a token becomes available after there was none, or when it
  /// belongs to another user than the last one.
  void Function()? onUserTokenReady;

  /// Called, and awaited, before a token of another user than the last one is
  /// used, so nothing of the last user is left to be sent with it.
  Future<void> Function(String userId)? onTokenUser;

  /// Called, and awaited, when the user signed out: the provider returned
  /// null while a token was held, or the token was removed.
  Future<void> Function()? onSignedOut;

  /// Called once for a token the service refuses (`token_invalid`, or
  /// `token_expired` again right after a refresh).
  void Function(String code)? onTokenRejected;

  /// The plain-http hosts allowed for local development.
  static const List<String> _developmentHosts = [
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
  ];

  /// Throws unless [baseUrl] is https, or http to a local development host.
  /// The API key and the user token travel in every request.
  static void checkBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    final ok = uri != null &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' ||
            (uri.scheme == 'http' && _developmentHosts.contains(uri.host)));
    if (!ok) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an https URL. Plain http is accepted only for local '
            'development (localhost, 127.0.0.1, 10.0.2.2)',
      );
    }
  }

  RiviumTokenProvider? get tokenProvider => _provider;

  /// True when the app supplies user tokens (a provider or a token).
  bool get usesUserToken =>
      _provider != null || _token != null || _initialToken != null;

  /// True while there is no user token to send.
  bool get isAwaitingUserToken => _awaiting;

  /// Requests that act for a user are held back until this time (HTTP 429).
  DateTime? get rateLimitedUntil {
    final until = _rateLimitedUntil;
    return until != null && until.isAfter(DateTime.now()) ? until : null;
  }

  /// A read that needs the API key only (experiments, flags, config). Sent
  /// without the user token, so it works before anyone is signed in.
  Future<http.Response> get(String path) => _http.get(
        Uri.parse('$baseUrl$path'),
        headers: _headers(null),
      );

  /// A request that acts for a user. Null when it was not sent or cannot be
  /// used: no user token, the token is for another user than [userId], the
  /// service refused the token, or a rate limit is being honoured.
  ///
  /// With [pinned] only the token already held is used: the provider is not
  /// asked, so the request can never go out under a newer user's token.
  Future<http.Response?> post(
    String path,
    Object body, {
    String? userId,
    bool pinned = false,
  }) =>
      _send(path, jsonEncode(body), userId, pinned, true);

  /// Get a token to work with: the one from the config, or the provider's.
  /// Without one the client is waiting from here on.
  Future<void> start() async {
    final initial = _initialToken;
    if (initial != null) {
      _initialToken = null;
      await _adopt(initial);
      return;
    }
    if (_provider != null) {
      await refreshUserToken();
    } else if (_token == null) {
      _setAwaiting();
    }
  }

  /// Make sure a token is there or being asked for, e.g. because the app
  /// reports a sign-in. An answer already on its way is waited for first.
  Future<void> ensureToken() async {
    final pending = _tokenInFlight;
    if (pending != null) await pending;
    if (_token == null) await start();
  }

  /// Use [token] from now on. Null means the user signed out.
  Future<void> setUserToken(String? token) async {
    _generation++;
    _initialToken = null;
    if (token == null || token.isEmpty) {
      await _signOut();
      return;
    }
    _rejectedToken = null;
    await _adopt(token);
  }

  /// Set or remove the provider. A new provider is asked straight away.
  Future<void> setTokenProvider(RiviumTokenProvider? provider) async {
    _provider = provider;
    if (provider != null) await refreshUserToken();
  }

  /// Ask the provider again now. Does nothing without a provider.
  Future<void> refreshUserToken() async {
    if (_provider == null) return;
    // An answer already on its way may be from before the sign-in or sign-out.
    final pending = _tokenInFlight;
    if (pending != null) await pending;
    _askAgainAt = null;
    _rejectedToken = null;
    await (_tokenInFlight ??= _fetchToken());
  }

  /// Forget the token, e.g. when another user signs in. With
  /// [keepUnidentified] a token handed in by the app whose user cannot be
  /// read is kept.
  void clearToken({bool keepUnidentified = false}) {
    if (keepUnidentified &&
        _provider == null &&
        _token != null &&
        subjectOf(_token!) == null) {
      return;
    }
    _generation++;
    _token = null;
    _tokenExpiresAt = 0;
    _tokenUser = null;
    _signedIn = false;
    _askAgainAt = null;
    _rejectedToken = null;
  }

  Map<String, String> _headers(String? token) => {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        if (token != null) 'x-user-token': token,
      };

  Future<http.Response?> _send(String path, String body, String? userId,
      bool pinned, bool retry) async {
    if (rateLimitedUntil != null) return null;
    if (_initialToken != null) await start();

    final token = pinned ? _heldToken() : await _currentToken();
    if (token == null) {
      if (!pinned) _setAwaiting();
      return null;
    }
    // The service credits the request to the token's user.
    final tokenUser = subjectOf(token);
    if (userId != null && tokenUser != null && tokenUser != userId) {
      return null;
    }

    final response = await _http.post(Uri.parse('$baseUrl$path'),
        headers: _headers(token), body: body);

    if (response.statusCode == 429) {
      _rateLimitedUntil = DateTime.now().add(_retryAfter(response));
      return response;
    }
    if (response.statusCode != 401) return response;

    final code = _errorCode(response.body);
    if (code == 'token_required') {
      if (!pinned) _refuse(token, code!, report: false);
      return null;
    }
    if (code == 'token_expired') {
      if (pinned) return null;
      if (retry && _provider != null) {
        if (_token == token) {
          _token = null;
          _tokenExpiresAt = 0;
        }
        return _send(path, body, userId, pinned, false);
      }
      // A token handed in by the app ran out, or the fresh one is expired too.
      _refuse(token, code!, report: !retry);
      return null;
    }
    if (code == 'token_invalid') {
      if (!pinned) _refuse(token, code!, report: true);
      return null;
    }
    return response;
  }

  /// Stop using [token] and wait for another one.
  void _refuse(String token, String code, {required bool report}) {
    if (debug) {
      // ignore: avoid_print
      print('RiviumAbTesting: user token rejected ($code)');
    }
    final first = _rejectedToken != token;
    _rejectedToken = token;
    if (_token == token) {
      _token = null;
      _tokenExpiresAt = 0;
    }
    _signedIn = false;
    _askAgainAt =
        _provider != null ? DateTime.now().add(tokenRetryDelay) : null;
    _setAwaiting();
    if (report && first) _safely(() => onTokenRejected?.call(code));
  }

  /// The token in hand if it has not run out, without asking the provider.
  String? _heldToken() {
    final token = _token;
    if (token == null) return null;
    if (_tokenExpiresAt != 0 && _tokenExpiresAt <= _nowSeconds()) return null;
    return token;
  }

  Future<String?> _currentToken() {
    final token = _token;
    if (token != null &&
        (_provider == null ||
            _tokenExpiresAt - tokenRefreshSkew.inSeconds > _nowSeconds())) {
      return Future.value(token);
    }
    if (_provider == null) return Future.value(null);
    if (_tokenInFlight != null) return _tokenInFlight!;
    if (_awaiting) {
      // Nobody is signed in until the app says so (refreshUserToken); after
      // a failure the provider may be asked again, but not on every call.
      final again = _askAgainAt;
      if (again == null || again.isAfter(DateTime.now())) {
        return Future.value(null);
      }
    }
    return _tokenInFlight = _fetchToken();
  }

  Future<String?> _fetchToken() async {
    final generation = _generation;
    try {
      String? token;
      var failed = false;
      try {
        token = await Future<String?>.sync(() => _provider!())
            .timeout(tokenProviderTimeout);
      } catch (e) {
        failed = true;
        if (debug) {
          // ignore: avoid_print
          print('RiviumAbTesting: tokenProvider failed: $e');
        }
      }
      // The app set or cleared the token meanwhile: this answer is stale.
      if (generation != _generation) return _heldToken();

      if (token == null || token.isEmpty) {
        if (failed) {
          final held = _heldToken();
          if (held != null) return held;
          _token = null;
          _tokenExpiresAt = 0;
          _signedIn = false;
          _askAgainAt = DateTime.now().add(tokenRetryDelay);
        } else {
          await _signOut(onlyIfSignedIn: true);
        }
        _setAwaiting();
        return null;
      }
      if (token == _rejectedToken) {
        _askAgainAt = DateTime.now().add(tokenRetryDelay);
        _setAwaiting();
        return null;
      }
      await _adopt(token);
      return _token;
    } finally {
      _tokenInFlight = null;
    }
  }

  Future<void> _adopt(String token) async {
    final user = subjectOf(token);
    final userChanged = user != null && user != _tokenUser;
    if (userChanged) {
      // The last user's token is still in place while their data is cleared.
      await _guarded(() => onTokenUser?.call(user));
    }
    final ready = !_signedIn || _awaiting || userChanged;
    _token = token;
    _tokenExpiresAt = _expiry(token);
    _tokenUser = user;
    _signedIn = true;
    _askAgainAt = null;
    _awaiting = false;
    if (ready) {
      scheduleMicrotask(() => _safely(() => onUserTokenReady?.call()));
    }
  }

  Future<void> _signOut({bool onlyIfSignedIn = false}) async {
    if (_signedIn || !onlyIfSignedIn) {
      await _guarded(() => onSignedOut?.call());
    }
    _token = null;
    _tokenExpiresAt = 0;
    _tokenUser = null;
    _signedIn = false;
    _askAgainAt = null;
    _rejectedToken = null;
    _setAwaiting();
  }

  void _setAwaiting() {
    if (_awaiting) return;
    _awaiting = true;
    if (debug) {
      // ignore: avoid_print
      print('RiviumAbTesting: awaiting a user token');
    }
    _safely(() => onAwaitingUserToken?.call());
  }

  /// A callback of the app must not break the request it was called from.
  void _safely(void Function() callback) {
    try {
      callback();
    } catch (_) {}
  }

  Future<void> _guarded(Future<void>? Function() callback) async {
    try {
      await callback();
    } catch (_) {}
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  static Duration _retryAfter(http.Response response) {
    final seconds = int.tryParse(response.headers['retry-after'] ?? '');
    if (seconds == null || seconds <= 0) return defaultRetryAfter;
    return Duration(seconds: seconds > 3600 ? 3600 : seconds);
  }

  static Map<String, dynamic>? _payload(String token) {
    try {
      final parts = token.split('.');
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return payload is Map<String, dynamic> ? payload : null;
    } catch (_) {
      return null;
    }
  }

  /// `exp` from the token payload; 0 (fetch again next time) if unreadable.
  static int _expiry(String token) {
    final exp = _payload(token)?['exp'];
    return exp is num ? exp.toInt() : 0;
  }

  /// The user a token was minted for (`sub`), or null if unreadable.
  static String? subjectOf(String token) {
    final sub = _payload(token)?['sub'];
    return sub is String && sub.isNotEmpty ? sub : null;
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      final code = decoded is Map ? decoded['code'] : null;
      return code is String ? code : null;
    } catch (_) {
      return null;
    }
  }
}
