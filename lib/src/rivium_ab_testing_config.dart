import 'rivium_api_client.dart' show RiviumTokenProvider;

/// Configuration for RiviumAbTesting SDK
class RiviumAbTestingConfig {
  /// API key for authentication (format: rv_live_xxx or rv_test_xxx)
  final String apiKey;

  /// Returns a Rivium user token for the signed-in user, minted by YOUR
  /// server (POST https://auth.rivium.co/users/token with your server
  /// secret). The service then takes the user from the token instead of
  /// trusting the userId this app sends. Called when a token is needed and
  /// again shortly before it expires. Required for
  /// assigning variants, tracking events and evaluating flags. Never put the server secret in the app.
  ///
  /// Return null while no one is signed in: the SDK then waits for a token
  /// ([RiviumAbTesting.isAwaitingUserToken]) instead of failing. Call
  /// [RiviumAbTesting.refreshUserToken] when the user signs in or out.
  final RiviumTokenProvider? tokenProvider;

  /// A user token you already hold. [tokenProvider] is preferred: a static
  /// token expires. Hand over a newer one with [RiviumAbTesting.setUserToken].
  final String? userToken;

  /// Enable debug logging
  final bool debug;

  /// Interval for flushing events (in milliseconds).
  ///
  /// Leave it out to follow the send interval set in the Rivium console
  /// (30 seconds until the console's value is known). A value you pass is
  /// your own choice and is always used.
  final int flushInterval;

  /// True when [flushInterval] was passed to the constructor.
  final bool hasOwnFlushInterval;

  /// Maximum events to queue before forcing flush
  final int maxQueueSize;

  /// Enable automatic tracking
  final bool autoTrack;

  const RiviumAbTestingConfig({
    required this.apiKey,
    this.tokenProvider,
    this.userToken,
    this.debug = false,
    int? flushInterval,
    this.maxQueueSize = 100,
    this.autoTrack = true,
  })  : flushInterval = flushInterval ?? 30000,
        hasOwnFlushInterval = flushInterval != null;

  /// Create config from API key only
  factory RiviumAbTestingConfig.fromApiKey(String apiKey) {
    return RiviumAbTestingConfig(apiKey: apiKey);
  }

  Map<String, dynamic> toMap() {
    return {
      'apiKey': apiKey,
      'debug': debug,
      'flushInterval': flushInterval,
      'maxQueueSize': maxQueueSize,
      'autoTrack': autoTrack,
    };
  }
}
