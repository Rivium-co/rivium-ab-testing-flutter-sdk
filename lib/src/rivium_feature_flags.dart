import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'platform.dart';
import 'rivium_feature_flags_config.dart';
import 'rivium_api_client.dart';
import 'rivium_ab_testing_error.dart';
import 'models/feature_flag.dart';
import 'offline/offline_storage.dart';

/// Callback for feature flag events
typedef FeatureFlagCallback = void Function(
    String event, Map<String, dynamic>? data);

/// RiviumFeatureFlags - Standalone Feature Flags SDK for Flutter
///
/// Use this when you only need feature flags without A/B testing.
/// Works independently — no experiment setup, no event tracking required.
///
/// ```dart
/// final flags = await RiviumFeatureFlags.init(
///   RiviumFeatureFlagsConfig(apiKey: 'rv_live_xxx'),
/// );
/// await flags.setUserId('user-123');
///
/// if (await flags.isEnabled('dark-mode')) {
///   // Show dark mode
/// }
/// ```
class RiviumFeatureFlags {
  static RiviumFeatureFlags? _instance;

  final RiviumFeatureFlagsConfig _config;
  late final RiviumApiClient _api;
  OfflineStorage? _storage;
  List<CachedFeatureFlag> _cachedFlags = [];
  String? _userId;
  Map<String, dynamic> _userAttributes = {};
  bool _isInitialized = false;
  bool _isOnline = true;
  FeatureFlagCallback? _callback;

  /// False inside RiviumAbTesting, which owns the client and the user.
  bool _standalone = true;
  void Function()? _onAwaitingUserToken;

  /// What the service last answered per flag for this user. Preferred over
  /// evaluating on the device when the service cannot be asked.
  final Map<String, Map<String, dynamic>> _serverEvaluations = {};

  RiviumFeatureFlags._({required RiviumFeatureFlagsConfig config})
      : _config = config;

  /// Get the singleton instance. Must call [init] first.
  static RiviumFeatureFlags get instance {
    if (_instance == null) {
      throw RiviumAbTestingError.notInitialized();
    }
    return _instance!;
  }

  /// Initialize the standalone feature flags SDK
  static Future<RiviumFeatureFlags> init(
    RiviumFeatureFlagsConfig config, {
    FeatureFlagCallback? callback,
  }) async {
    if (_instance != null && _instance!._isInitialized) {
      return _instance!;
    }

    final sdk = RiviumFeatureFlags._(config: config);
    sdk._callback = callback;
    sdk._api = RiviumApiClient(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
      tokenProvider: config.tokenProvider,
      userToken: config.userToken,
      debug: config.debug,
    );

    // Initialize offline cache if enabled
    if (config.enableOfflineCache) {
      sdk._storage = OfflineStorage();
      await sdk._storage!.init();
      sdk._cachedFlags = await sdk._storage!.getCachedFlags();
      sdk._userId = await sdk._storage!.getUserId();
    }

    // Check connectivity
    try {
      sdk._isOnline = await RiviumPlatform.isOnline();
    } catch (_) {
      sdk._isOnline = true; // Assume online if check fails
    }

    sdk._api
      ..onAwaitingUserToken = sdk._handleAwaitingUserToken
      ..onTokenUser = sdk._handleTokenUser
      ..onSignedOut = sdk._forgetUser
      ..onTokenRejected = (code) => sdk._callback?.call('error', {
            'message': 'User token rejected: $code',
            'code': code,
          });

    sdk._isInitialized = true;
    _instance = sdk;

    // Fetch fresh flags if online
    if (sdk._isOnline) {
      sdk._fetchFlags();
    }

    callback?.call('initialized', {'offline': !sdk._isOnline});

    // Without a user token yet, the SDK waits for one.
    unawaited(sdk._api.start());

    return sdk;
  }

  /// Create an instance without singleton (for use inside RiviumAbTesting)
  static Future<RiviumFeatureFlags> createInternal({
    required String apiKey,
    required String baseUrl,
    required bool debug,
    required OfflineStorage storage,
    required bool isOnline,
    FeatureFlagCallback? callback,
    RiviumApiClient? api,
  }) async {
    final config = RiviumFeatureFlagsConfig(
      apiKey: apiKey,
      baseUrl: baseUrl,
      debug: debug,
      enableOfflineCache: true,
    );
    final sdk = RiviumFeatureFlags._(config: config);
    // Shares the parent SDK's client, so both send the same user token.
    sdk._api = api ?? RiviumApiClient(apiKey: apiKey, baseUrl: baseUrl, debug: debug);
    sdk._standalone = false;
    sdk._storage = storage;
    sdk._callback = callback;
    sdk._cachedFlags = await storage.getCachedFlags();
    sdk._isOnline = isOnline;
    sdk._isInitialized = true;
    return sdk;
  }

  /// Set user ID for rollout and targeting
  ///
  /// Use the same id your server puts in the user token.
  Future<void> setUserId(String userId) async {
    if (!_isInitialized) return;
    final changed = userId != _userId;
    if (changed) {
      // Another person: the last user's attributes and token are not theirs.
      _userAttributes = {};
      _serverEvaluations.clear();
      if (_standalone) _api.clearToken(keepUnidentified: true);
    }
    _userId = userId;
    await _storage?.saveUserId(userId);
    if (_standalone && changed) unawaited(_api.start());
  }

  /// Forget the user, for example at sign-out: their id, attributes and
  /// token are dropped and the SDK waits for the next user token.
  Future<void> clearUserId() async {
    if (!_isInitialized) return;
    if (_standalone) {
      // Clears the user through onSignedOut.
      await _api.setUserToken(null);
    } else {
      await _forgetUser();
    }
  }

  /// Get current user ID
  String? getUserId() => _userId;

  /// True while the SDK has no user token: nobody is signed in yet, or the
  /// token provider returned null or failed. Flags are then evaluated from
  /// the cached flag list, or the default value is returned; nothing is sent.
  bool get isAwaitingUserToken => _api.isAwaitingUserToken;

  /// Called each time the SDK starts waiting for a user token. The
  /// `awaitingUserToken` event of the init callback reports the same.
  void onAwaitingUserToken(void Function() callback) {
    _onAwaitingUserToken = callback;
  }

  /// Hand the SDK a user token minted by your server, for example right
  /// after sign-in or when you refreshed it. A token of another user drops
  /// the last user's attributes first.
  ///
  /// Pass `null` when the user signs out.
  Future<void> setUserToken(String? token) async {
    if (!_isInitialized) return;
    await _api.setUserToken(token);
  }

  /// Set or remove the token provider after [init]. The provider is asked
  /// straight away.
  Future<void> setTokenProvider(RiviumTokenProvider? provider) async {
    if (!_isInitialized) return;
    await _api.setTokenProvider(provider);
  }

  /// Ask the token provider again now. Call this when the user signs in or
  /// out. Does nothing without a provider.
  Future<void> refreshUserToken() async {
    if (!_isInitialized) return;
    await _api.refreshUserToken();
  }

  /// Set user attributes for targeting rules
  void setUserAttributes(Map<String, dynamic> attributes) {
    if (!_isInitialized) return;
    _userAttributes = {..._userAttributes, ...attributes};
    _serverEvaluations.clear();
  }

  /// Check if a feature flag is enabled
  ///
  /// The service decides. Its last answer, then the cached flag list, are
  /// used when it cannot be asked (offline, or no user token yet).
  Future<bool> isEnabled(String flagKey, {bool defaultValue = false}) async {
    if (!_isInitialized) return defaultValue;

    final evaluation = await _evaluateOnServer(flagKey);
    if (evaluation != null) {
      final enabled = evaluation['enabled'];
      return enabled is bool ? enabled : defaultValue;
    }

    // Offline fallback: local evaluation
    final cached = _cachedFlags.where((f) => f.key == flagKey);
    if (cached.isNotEmpty) {
      return _evaluateFlagLocally(cached.first).enabled;
    }

    return defaultValue;
  }

  /// Get the value of a feature flag
  Future<dynamic> getValue(String flagKey, {dynamic defaultValue}) async {
    if (!_isInitialized) return defaultValue;

    final evaluation = await _evaluateOnServer(flagKey);
    if (evaluation != null) {
      return evaluation['value'] ?? defaultValue;
    }

    // Offline fallback: local evaluation
    final cached = _cachedFlags.where((f) => f.key == flagKey);
    if (cached.isNotEmpty) {
      final result = _evaluateFlagLocally(cached.first);
      return result.value ?? defaultValue;
    }

    return defaultValue;
  }

  /// Get all feature flags
  Future<List<FeatureFlag>> getAll() async {
    if (!_isInitialized) return [];

    if (_isOnline) {
      try {
        final response = await _api.get('/public/flags');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final flagsList = (data['flags'] as List?) ?? [];
          final flags = flagsList
              .map((f) =>
                  FeatureFlag.fromMap(Map<String, dynamic>.from(f)))
              .toList();

          // Cache flags locally
          _cachedFlags = flagsList
              .map((f) => CachedFeatureFlag(
                    key: f['key'] as String,
                    enabled: f['enabled'] as bool? ?? false,
                    rolloutPercentage:
                        f['rolloutPercentage'] as int? ?? 100,
                    targetingRules: f['targetingRules'] != null
                        ? Map<String, dynamic>.from(
                            f['targetingRules'] as Map)
                        : null,
                    variants: (f['variants'] as List?)
                        ?.map((v) => CachedFlagVariant(
                              key: v['key'] as String,
                              value: v['value'],
                              weight: v['weight'] as int? ?? 0,
                            ))
                        .toList(),
                    defaultValue: f['defaultValue'],
                    cachedAt: DateTime.now(),
                  ))
              .toList();
          await _storage?.cacheFlags(_cachedFlags);

          return flags;
        }
      } catch (e) {
        if (_config.debug) {
          print('RiviumFeatureFlags: Failed to get flags: $e');
        }
      }
    }

    // Return cached flags
    return _cachedFlags
        .map((f) => FeatureFlag(
              key: f.key,
              enabled: f.enabled,
              rolloutPercentage: f.rolloutPercentage,
              targetingRules: f.targetingRules,
              variants: f.variants
                  ?.map((v) => FlagVariant(
                        key: v.key,
                        value: v.value,
                        weight: v.weight,
                      ))
                  .toList(),
              defaultValue: f.defaultValue,
            ))
        .toList();
  }

  /// Refresh flags from server
  Future<void> refresh() async {
    if (!_isInitialized) return;
    await _fetchFlags();
  }

  /// Check if online
  bool get isOnline => _isOnline;

  /// Get cached flags (without server call)
  List<CachedFeatureFlag> get cachedFlags => List.unmodifiable(_cachedFlags);

  /// Update online status (used by RiviumAbTesting internally)
  void updateOnlineStatus(bool online) {
    _isOnline = online;
  }

  /// Reset state
  Future<void> reset() async {
    await _storage?.clearFlagCache();
    _cachedFlags = [];
    _userId = null;
    _userAttributes = {};
    _serverEvaluations.clear();
    if (_standalone) _api.clearToken();
    _isInitialized = false;
    if (identical(_instance, this)) _instance = null;
  }

  /// Dispose resources
  void dispose() {
    // No timers or subscriptions to clean up
  }

  // ============================================
  // PRIVATE METHODS
  // ============================================

  /// The service's answer for [flagKey]: fresh when it can be asked, else
  /// its last answer for this user. Null when there is none.
  Future<Map<String, dynamic>?> _evaluateOnServer(String flagKey) async {
    final userId = _userId;
    if (_isOnline && userId != null) {
      try {
        final response = await _api.post(
          '/public/flag-evaluation',
          {
            'flagKey': flagKey,
            'userId': userId,
            'userAttributes': _userAttributes,
          },
          userId: userId,
        );

        if (response != null &&
            response.statusCode >= 200 &&
            response.statusCode < 300) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && userId == _userId) {
            _serverEvaluations[flagKey] = data;
            return data;
          }
        }
      } catch (e) {
        if (_config.debug) {
          print('RiviumFeatureFlags: Failed to evaluate flag: $e');
        }
      }
    }
    return _serverEvaluations[flagKey];
  }

  void _handleAwaitingUserToken() {
    _callback?.call('awaitingUserToken', null);
    _onAwaitingUserToken?.call();
  }

  /// A token of [userId] is about to be used.
  Future<void> _handleTokenUser(String userId) async {
    if (userId == _userId) return;
    _userAttributes = {};
    _serverEvaluations.clear();
    _userId = userId;
    await _storage?.saveUserId(userId);
  }

  Future<void> _forgetUser() async {
    _userId = null;
    _userAttributes = {};
    _serverEvaluations.clear();
    if (_standalone) await _storage?.removeUserId();
  }

  Future<void> _fetchFlags() async {
    try {
      final response = await _api.get('/public/flags');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final flagsList = (data['flags'] as List?) ?? [];
        _cachedFlags = flagsList
            .map((f) => CachedFeatureFlag(
                  key: f['key'] as String,
                  enabled: f['enabled'] as bool? ?? false,
                  rolloutPercentage:
                      f['rolloutPercentage'] as int? ?? 100,
                  targetingRules: f['targetingRules'] != null
                      ? Map<String, dynamic>.from(
                          f['targetingRules'] as Map)
                      : null,
                  variants: (f['variants'] as List?)
                      ?.map((v) => CachedFlagVariant(
                            key: v['key'] as String,
                            value: v['value'],
                            weight: v['weight'] as int? ?? 0,
                          ))
                      .toList(),
                  defaultValue: f['defaultValue'],
                  cachedAt: DateTime.now(),
                ))
            .toList();
        await _storage?.cacheFlags(_cachedFlags);

        _callback?.call(
            'featureFlagsRefreshed', {'count': _cachedFlags.length});

        if (_config.debug) {
          print(
              'RiviumFeatureFlags: Fetched ${_cachedFlags.length} flags');
        }
      }
    } catch (e) {
      if (_config.debug) {
        print('RiviumFeatureFlags: Failed to fetch flags: $e');
      }
      _callback?.call(
          'error', {'message': 'Failed to fetch flags: $e'});
    }
  }

  /// Evaluate a feature flag locally (offline fallback). An approximation:
  /// the service's own answer is used whenever there is one.
  _FlagEvalResult _evaluateFlagLocally(CachedFeatureFlag flag) {
    if (!flag.enabled) {
      return _FlagEvalResult(
        enabled: false,
        value: flag.defaultValue ?? false,
      );
    }

    // Check targeting rules
    if (flag.targetingRules != null && flag.targetingRules!.isNotEmpty) {
      if (!_evaluateTargetingRules(flag.targetingRules!, _userAttributes)) {
        return _FlagEvalResult(
          enabled: false,
          value: flag.defaultValue ?? false,
        );
      }
    }

    // Check rollout percentage. Without a user there is no bucket, so a
    // partial rollout is off rather than on for everyone.
    if (flag.rolloutPercentage < 100) {
      final userId = _userId;
      if (userId == null ||
          _getBucket(userId, flag.key) >= flag.rolloutPercentage) {
        return _FlagEvalResult(
          enabled: false,
          value: flag.defaultValue ?? false,
        );
      }
    }

    // Multivariate flag
    if (flag.variants != null && flag.variants!.isNotEmpty) {
      final variantBucket =
          _getFlagVariantBucket(_userId ?? '', flag.key);
      int cumulative = 0;
      for (final variant in flag.variants!) {
        cumulative += variant.weight;
        if (variantBucket < cumulative) {
          return _FlagEvalResult(
            enabled: true,
            value: variant.value,
            variant: variant.key,
          );
        }
      }
      return _FlagEvalResult(
        enabled: true,
        value: flag.variants!.first.value,
        variant: flag.variants!.first.key,
      );
    }

    return _FlagEvalResult(enabled: true, value: true);
  }

  bool _evaluateTargetingRules(
    Map<String, dynamic> rules,
    Map<String, dynamic> userContext,
  ) {
    if (rules.isEmpty) return true;

    for (final entry in rules.entries) {
      if (!_evaluateRule(entry.key, entry.value, userContext)) {
        return false;
      }
    }
    return true;
  }

  bool _evaluateRule(
    String key,
    dynamic rule,
    Map<String, dynamic> context,
  ) {
    final value = context[key];

    if (rule is Map<String, dynamic>) {
      if (rule.containsKey('equals')) return value == rule['equals'];
      if (rule.containsKey('notEquals')) return value != rule['notEquals'];
      if (rule.containsKey('in') && rule['in'] is List) {
        return (rule['in'] as List).contains(value);
      }
      if (rule.containsKey('notIn') && rule['notIn'] is List) {
        return !(rule['notIn'] as List).contains(value);
      }
      if (rule.containsKey('greaterThan')) {
        return value is num &&
            rule['greaterThan'] is num &&
            value > rule['greaterThan'];
      }
      if (rule.containsKey('lessThan')) {
        return value is num &&
            rule['lessThan'] is num &&
            value < rule['lessThan'];
      }
      if (rule.containsKey('greaterThanOrEqual')) {
        return value is num &&
            rule['greaterThanOrEqual'] is num &&
            value >= rule['greaterThanOrEqual'];
      }
      if (rule.containsKey('lessThanOrEqual')) {
        return value is num &&
            rule['lessThanOrEqual'] is num &&
            value <= rule['lessThanOrEqual'];
      }
      if (rule.containsKey('contains') && value is String) {
        return value.contains(rule['contains'] as String);
      }
      if (rule.containsKey('regex') && value is String) {
        // The pattern comes from the flag's rules. A malformed one must not
        // break flag evaluation, and a huge input must not stall the app.
        if (value.length > 1000) return false;
        try {
          return RegExp(rule['regex'] as String).hasMatch(value);
        } catch (_) {
          return false;
        }
      }
      if (rule.containsKey('exists')) {
        return rule['exists'] == true ? value != null : value == null;
      }
      if (rule.containsKey('and') && rule['and'] is List) {
        return (rule['and'] as List)
            .every((r) => _evaluateRule(key, r, context));
      }
      if (rule.containsKey('or') && rule['or'] is List) {
        return (rule['or'] as List)
            .any((r) => _evaluateRule(key, r, context));
      }
    }

    return value == rule;
  }

  int _getBucket(String userId, String salt) {
    final input = '$userId:$salt';
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    final hashHex = digest.toString().substring(0, 8);
    return int.parse(hashHex, radix: 16) % 100;
  }

  int _getFlagVariantBucket(String userId, String flagKey) {
    final input = '$userId:$flagKey:variant';
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    final hashHex = digest.toString().substring(0, 8);
    return int.parse(hashHex, radix: 16) % 100;
  }
}

/// Internal result type for local flag evaluation
class _FlagEvalResult {
  final bool enabled;
  final dynamic value;
  final String? variant;

  _FlagEvalResult({required this.enabled, this.value, this.variant});
}
