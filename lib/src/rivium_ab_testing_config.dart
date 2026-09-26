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
  final RiviumTokenProvider? tokenProvider;

  /// A user token you already hold. [tokenProvider] is preferred: a static
  /// token expires.
  final String? userToken;

  /// Enable debug logging
  final bool debug;

  /// Interval for flushing events (in milliseconds)
  final int flushInterval;

  /// Maximum events to queue before forcing flush
  final int maxQueueSize;

  /// Enable automatic tracking
  final bool autoTrack;

  const RiviumAbTestingConfig({
    required this.apiKey,
    this.tokenProvider,
    this.userToken,
    this.debug = false,
    this.flushInterval = 30000,
    this.maxQueueSize = 100,
    this.autoTrack = true,
  });

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
