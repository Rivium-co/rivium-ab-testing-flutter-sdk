/// RiviumAbTesting SDK errors
class RiviumAbTestingError implements Exception {
  final String code;
  final String message;

  const RiviumAbTestingError(this.code, this.message);

  factory RiviumAbTestingError.notInitialized() {
    return const RiviumAbTestingError('NOT_INITIALIZED', 'RiviumAbTesting SDK not initialized');
  }

  factory RiviumAbTestingError.invalidConfig(String message) {
    return RiviumAbTestingError('INVALID_CONFIG', 'Invalid configuration: $message');
  }

  factory RiviumAbTestingError.networkError(String message) {
    return RiviumAbTestingError('NETWORK_ERROR', 'Network error: $message');
  }

  factory RiviumAbTestingError.experimentNotFound(String key) {
    return RiviumAbTestingError('EXPERIMENT_NOT_FOUND', 'Experiment not found: $key');
  }

  factory RiviumAbTestingError.apiError(int code, String message) {
    return RiviumAbTestingError('API_ERROR', 'API error ($code): $message');
  }

  @override
  String toString() => 'RiviumAbTestingError[$code]: $message';
}
