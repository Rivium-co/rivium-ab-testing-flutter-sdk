import 'rivium_api_client.dart' show RiviumTokenProvider;

/// Configuration for standalone RiviumFeatureFlags SDK
class RiviumFeatureFlagsConfig {
  /// API key for authentication (format: rv_live_xxx or rv_test_xxx)
  final String apiKey;

  /// Base URL for the API
  final String baseUrl;

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

  /// Enable offline caching of flags
  final bool enableOfflineCache;

  const RiviumFeatureFlagsConfig({
    required this.apiKey,
    this.baseUrl = 'https://abtest.rivium.co',
    this.tokenProvider,
    this.userToken,
    this.debug = false,
    this.enableOfflineCache = true,
  });
}
