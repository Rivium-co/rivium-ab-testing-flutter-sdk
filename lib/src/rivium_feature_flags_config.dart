/// Configuration for standalone RiviumFeatureFlags SDK
class RiviumFeatureFlagsConfig {
  /// API key for authentication (format: rv_live_xxx or rv_test_xxx)
  final String apiKey;

  /// Base URL for the API
  final String baseUrl;

  /// Enable debug logging
  final bool debug;

  /// Enable offline caching of flags
  final bool enableOfflineCache;

  const RiviumFeatureFlagsConfig({
    required this.apiKey,
    this.baseUrl = 'https://abtest.rivium.co',
    this.debug = false,
    this.enableOfflineCache = true,
  });
}
