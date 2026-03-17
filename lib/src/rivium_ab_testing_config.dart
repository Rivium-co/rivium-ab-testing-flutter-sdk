/// Configuration for RiviumAbTesting SDK
class RiviumAbTestingConfig {
  /// API key for authentication (format: rv_live_xxx or rv_test_xxx)
  final String apiKey;

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
