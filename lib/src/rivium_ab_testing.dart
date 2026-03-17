import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'rivium_ab_testing_config.dart';
import 'rivium_ab_testing_error.dart';
import 'rivium_feature_flags.dart';
import 'models/experiment.dart';
import 'models/feature_flag.dart';
import 'models/variant.dart';
import 'offline/offline_storage.dart';
import 'offline/sync_manager.dart';

/// Callback for SDK events
typedef RiviumAbTestingCallback = void Function(
    String event, Map<String, dynamic>? data);

/// RiviumAbTesting - Pure Dart A/B Testing SDK for Flutter
///
/// Supports all Flutter platforms (iOS, Android, Web, Desktop).
class RiviumAbTesting {
  static RiviumAbTesting? _instance;

  final RiviumAbTestingConfig _config;
  final String _baseUrl;

  late final OfflineStorage _storage;
  late final SyncManager _syncManager;
  late final RiviumFeatureFlags _featureFlags;

  String? _userId;
  Map<String, dynamic> _userAttributes = {};
  List<CachedExperiment> _cachedExperiments = [];
  bool _isInitialized = false;

  RiviumAbTestingCallback? _callback;

  RiviumAbTesting._({
    required RiviumAbTestingConfig config,
    String? baseUrl,
  })  : _config = config,
        _baseUrl = baseUrl ?? 'https://abtest.rivium.co';

  /// Get the singleton instance. Must call [init] first.
  static RiviumAbTesting get instance {
    if (_instance == null) {
      throw RiviumAbTestingError.notInitialized();
    }
    return _instance!;
  }

  /// Initialize the SDK
  static Future<RiviumAbTesting> init(
    RiviumAbTestingConfig config, {
    RiviumAbTestingCallback? callback,
    String? baseUrl,
  }) async {
    if (_instance != null && _instance!._isInitialized) {
      return _instance!;
    }

    final sdk = RiviumAbTesting._(config: config, baseUrl: baseUrl);
    sdk._callback = callback;

    sdk._storage = OfflineStorage();
    await sdk._storage.init();

    // Load saved user ID
    sdk._userId = await sdk._storage.getUserId();

    // Load cached experiments
    sdk._cachedExperiments = await sdk._storage.getCachedExperiments();

    // Initialize sync manager
    sdk._syncManager = SyncManager(
      apiKey: config.apiKey,
      baseUrl: sdk._baseUrl,
      storage: sdk._storage,
      onSyncEvent: sdk._onSyncEvent,
    );
    await sdk._syncManager.init();

    // Initialize feature flags (shares storage, no separate singleton)
    sdk._featureFlags = await RiviumFeatureFlags.createInternal(
      apiKey: config.apiKey,
      baseUrl: sdk._baseUrl,
      debug: config.debug,
      storage: sdk._storage,
      isOnline: sdk._syncManager.isOnline,
      callback: callback != null
          ? (event, data) => callback(event, data)
          : null,
    );

    sdk._isInitialized = true;
    _instance = sdk;

    // Fetch fresh experiments and flags if online
    if (sdk._syncManager.isOnline) {
      sdk._fetchExperiments();
      sdk._featureFlags.refresh();
    }

    callback?.call('initialized', {'offline': !sdk._syncManager.isOnline});

    return sdk;
  }

  /// Set user ID for experiment assignment and feature flag targeting
  Future<void> setUserId(String userId) async {
    _ensureInitialized();
    _userId = userId;
    await _storage.saveUserId(userId);
    await _featureFlags.setUserId(userId);
  }

  /// Get current user ID
  String? getUserId() => _userId;

  /// Set user attributes for targeting
  void setUserAttributes(Map<String, dynamic> attributes) {
    _ensureInitialized();
    _userAttributes = {..._userAttributes, ...attributes};
    _featureFlags.setUserAttributes(attributes);
  }

  /// Get the standalone feature flags instance (for direct access)
  RiviumFeatureFlags get featureFlags {
    _ensureInitialized();
    return _featureFlags;
  }

  /// Get variant for an experiment
  Future<String> getVariant(
    String experimentKey, {
    String defaultVariant = 'control',
  }) async {
    _ensureInitialized();

    if (_userId == null) {
      throw RiviumAbTestingError(
          'USER_NOT_SET', 'User ID not set. Call setUserId() first.');
    }

    // Check cached assignment (sticky bucketing)
    final cachedAssignment =
        await _storage.getCachedAssignment(experimentKey);
    if (cachedAssignment != null) {
      return cachedAssignment.variantName;
    }

    // Try server assignment if online
    if (_syncManager.isOnline) {
      try {
        final response = await http.post(
          Uri.parse('$_baseUrl/public/assign'),
          headers: {
            'Content-Type': 'application/json',
            'x-api-key': _config.apiKey,
          },
          body: jsonEncode({
            'experimentKey': experimentKey,
            'userId': _userId,
            'userAttributes': _userAttributes,
          }),
        );

        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          final data = body['data'] as Map<String, dynamic>;
          final variantName = data['variantName'] as String;

          // Cache the assignment with full server data
          await _storage.cacheAssignment(CachedAssignment(
            experimentId: data['experimentId'] as String,
            experimentKey: data['experimentKey'] as String? ?? experimentKey,
            variantId: data['variantId'] as String,
            variantKey: data['variantKey'] as String? ?? '',
            variantName: variantName,
            config: data['config'] != null
                ? Map<String, dynamic>.from(data['config'] as Map)
                : null,
            isControl: data['isControl'] as bool? ?? false,
            assignedAt: DateTime.now(),
          ));

          _callback?.call('experimentAssigned', {
            'experimentKey': experimentKey,
            'variantKey': data['variantKey'] ?? variantName,
            'config': data['config'],
          });

          return variantName;
        }
      } catch (e) {
        if (_config.debug) {
          print(
              'RiviumAbTesting: Failed to get assignment from server: $e');
        }
      }
    }

    // Offline fallback: local bucketing
    return _getLocalAssignment(experimentKey, defaultVariant);
  }

  /// Get variant configuration
  Future<Map<String, dynamic>?> getVariantConfig(
      String experimentKey) async {
    _ensureInitialized();

    // Check cached assignment first
    final cachedAssignment =
        await _storage.getCachedAssignment(experimentKey);
    if (cachedAssignment != null && cachedAssignment.config != null) {
      return cachedAssignment.config;
    }

    // Fallback to cached experiment variant config
    final experiments =
        _cachedExperiments.where((e) => e.key == experimentKey);
    if (experiments.isNotEmpty && cachedAssignment != null) {
      final variant = experiments.first.variants
          .where((v) => v.id == cachedAssignment.variantId);
      if (variant.isNotEmpty) {
        return variant.first.config;
      }
    }

    return null;
  }

  /// Track a view event
  Future<void> trackView(String experimentKey) async {
    await _trackEvent(experimentKey, EventType.view);
  }

  /// Track a click event
  Future<void> trackClick(String experimentKey) async {
    await _trackEvent(experimentKey, EventType.click);
  }

  /// Track a conversion event
  Future<void> trackConversion(String experimentKey,
      {double? value}) async {
    await _trackEvent(experimentKey, EventType.conversion,
        eventValue: value);
  }

  /// Track a custom event
  Future<void> trackCustomEvent(
    String experimentKey,
    String eventName, {
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, EventType.custom,
        eventName: eventName, metadata: properties);
  }

  // ============================================
  // ENGAGEMENT EVENTS
  // ============================================

  /// Track a scroll event
  Future<void> trackScroll(
    String experimentKey, {
    double? depth,
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, EventType.scroll,
        eventValue: depth,
        metadata: properties);
  }

  /// Track a form submission
  Future<void> trackFormSubmit(
    String experimentKey, {
    String? formName,
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, EventType.formSubmit,
        eventName: formName,
        metadata: properties);
  }

  /// Track a search event
  Future<void> trackSearch(
    String experimentKey, {
    String? query,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (query != null) 'query': query,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.search,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a share event
  Future<void> trackShare(
    String experimentKey, {
    String? method,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (method != null) 'method': method,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.share,
        metadata: props.isNotEmpty ? props : null);
  }

  // ============================================
  // E-COMMERCE EVENTS
  // ============================================

  /// Track an add to cart event
  Future<void> trackAddToCart(
    String experimentKey, {
    double? value,
    String? productId,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (productId != null) 'productId': productId,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.addToCart,
        eventValue: value,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a remove from cart event
  Future<void> trackRemoveFromCart(
    String experimentKey, {
    double? value,
    String? productId,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (productId != null) 'productId': productId,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.removeFromCart,
        eventValue: value,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a begin checkout event
  Future<void> trackBeginCheckout(
    String experimentKey, {
    double? value,
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, EventType.beginCheckout,
        eventValue: value,
        metadata: properties);
  }

  /// Track a purchase event
  Future<void> trackPurchase(
    String experimentKey, {
    required double value,
    String? transactionId,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (transactionId != null) 'transactionId': transactionId,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.purchase,
        eventValue: value,
        metadata: props.isNotEmpty ? props : null);
  }

  // ============================================
  // MEDIA EVENTS
  // ============================================

  /// Track a video start event
  Future<void> trackVideoStart(
    String experimentKey, {
    String? videoId,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (videoId != null) 'videoId': videoId,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.videoStart,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a video complete event
  Future<void> trackVideoComplete(
    String experimentKey, {
    String? videoId,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (videoId != null) 'videoId': videoId,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.videoComplete,
        metadata: props.isNotEmpty ? props : null);
  }

  // ============================================
  // USER AUTH EVENTS
  // ============================================

  /// Track a sign up event
  Future<void> trackSignUp(
    String experimentKey, {
    String? method,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (method != null) 'method': method,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.signUp,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a login event
  Future<void> trackLogin(
    String experimentKey, {
    String? method,
    Map<String, dynamic>? properties,
  }) async {
    final props = <String, dynamic>{
      if (method != null) 'method': method,
      ...?properties,
    };
    await _trackEvent(experimentKey, EventType.login,
        metadata: props.isNotEmpty ? props : null);
  }

  /// Track a logout event
  Future<void> trackLogout(
    String experimentKey, {
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, EventType.logout,
        metadata: properties);
  }

  // ============================================
  // GENERIC EVENT TRACKING
  // ============================================

  /// Track any event type with full control
  Future<void> track(
    String experimentKey,
    EventType eventType, {
    String? eventName,
    double? eventValue,
    Map<String, dynamic>? properties,
  }) async {
    await _trackEvent(experimentKey, eventType,
        eventName: eventName,
        eventValue: eventValue,
        metadata: properties);
  }

  /// Refresh experiments from server
  Future<void> refreshExperiments() async {
    _ensureInitialized();
    await _fetchExperiments();
  }

  /// Get all experiments
  List<Experiment> getExperiments() {
    _ensureInitialized();
    return _cachedExperiments
        .map((e) => Experiment(
              id: e.id,
              key: e.key,
              name: e.name,
              status: ExperimentStatus.running,
              trafficAllocation: e.trafficAllocation,
              variants: e.variants
                  .map((v) => Variant(
                        id: v.id,
                        key: v.key,
                        name: v.name,
                        trafficSplit: v.trafficSplit,
                        isControl: v.isControl,
                        config: v.config,
                      ))
                  .toList(),
              targetingRules: e.targetingRules,
            ))
        .toList();
  }

  /// Check if a feature flag is enabled
  Future<bool> isFeatureEnabled(String featureKey,
      {bool defaultValue = false}) async {
    _ensureInitialized();
    return _featureFlags.isEnabled(featureKey, defaultValue: defaultValue);
  }

  /// Get the value of a feature flag
  Future<dynamic> getFeatureValue(String featureKey,
      {dynamic defaultValue}) async {
    _ensureInitialized();
    return _featureFlags.getValue(featureKey, defaultValue: defaultValue);
  }

  /// Get all feature flags
  Future<List<FeatureFlag>> getFeatureFlags() async {
    _ensureInitialized();
    return _featureFlags.getAll();
  }

  /// Refresh feature flags from server
  Future<void> refreshFeatureFlags() async {
    _ensureInitialized();
    await _featureFlags.refresh();
  }

  /// Flush pending events to server
  Future<void> flush() async {
    _ensureInitialized();
    await _syncManager.flush();
  }

  /// Check if online
  bool get isOnline => _isInitialized && _syncManager.isOnline;

  /// Get pending event count
  Future<int> getPendingEventCount() async {
    _ensureInitialized();
    return _syncManager.getPendingEventCount();
  }

  /// Reset SDK state
  Future<void> reset() async {
    if (_isInitialized) {
      await _storage.clearAll();
      _syncManager.dispose();
    }
    _userId = null;
    _userAttributes = {};
    _cachedExperiments = [];
    _isInitialized = false;
    _instance = null;
  }

  /// Dispose resources
  void dispose() {
    if (_isInitialized) {
      _syncManager.dispose();
    }
  }

  // ============================================
  // PRIVATE METHODS
  // ============================================

  void _ensureInitialized() {
    if (!_isInitialized) {
      throw RiviumAbTestingError.notInitialized();
    }
  }

  Future<void> _trackEvent(
    String experimentKey,
    EventType eventType, {
    String? eventName,
    double? eventValue,
    Map<String, dynamic>? metadata,
  }) async {
    _ensureInitialized();

    if (_userId == null) {
      throw RiviumAbTestingError(
          'USER_NOT_SET', 'User ID not set. Call setUserId() first.');
    }

    // Resolve experiment UUID and variant UUID from cached data
    String experimentId = experimentKey;
    String variantId = '';

    final cachedAssignment =
        await _storage.getCachedAssignment(experimentKey);
    if (cachedAssignment != null) {
      experimentId = cachedAssignment.experimentId;
      variantId = cachedAssignment.variantId;
    } else {
      // Look up experiment in cache by key to get UUID
      final experiments =
          _cachedExperiments.where((e) => e.key == experimentKey);
      if (experiments.isNotEmpty) {
        experimentId = experiments.first.id;
      }
    }

    final event = OfflineEvent(
      id: _generateEventId(),
      experimentId: experimentId,
      variantId: variantId,
      userId: _userId!,
      eventType: eventType.value,
      eventName: eventName ?? eventType.value,
      eventValue: eventValue,
      metadata: metadata,
      timestamp: DateTime.now(),
    );

    await _syncManager.queueEvent(event);

    if (_config.debug) {
      print(
          'RiviumAbTesting: Queued ${eventType.value} event for experiment $experimentKey');
    }
  }

  /// Fetch experiments from /public/experiments (has key fields)
  Future<void> _fetchExperiments() async {
    try {
      // Fetch experiments (has key fields) and config in parallel
      final results = await Future.wait([
        http.get(
          Uri.parse('$_baseUrl/public/experiments'),
          headers: {'x-api-key': _config.apiKey},
        ),
        http.get(
          Uri.parse(
              '$_baseUrl/public/init?platform=flutter&sdkVersion=2.0.0'),
          headers: {'x-api-key': _config.apiKey},
        ),
      ]);

      final experimentsResponse = results[0];
      final initResponse = results[1];

      // Parse experiments from /public/experiments (wrapped in data)
      if (experimentsResponse.statusCode == 200) {
        final body = jsonDecode(experimentsResponse.body);
        final experimentsList = (body['data'] as List?) ?? [];
        _cachedExperiments = experimentsList.map((e) {
          final variants = (e['variants'] as List?) ?? [];
          return CachedExperiment(
            id: e['id'] as String,
            key: e['key'] as String? ?? e['id'] as String,
            name: e['name'] as String,
            trafficAllocation: e['trafficAllocation'] as int? ?? 100,
            targetingRules: e['targetingRules'] != null
                ? Map<String, dynamic>.from(e['targetingRules'] as Map)
                : null,
            variants: variants
                .map((v) => CachedVariant(
                      id: v['id'] as String,
                      key: v['key'] as String? ?? v['id'] as String,
                      name: v['name'] as String,
                      config: v['config'] != null
                          ? Map<String, dynamic>.from(v['config'] as Map)
                          : null,
                      isControl: v['isControl'] as bool? ?? false,
                      trafficSplit: v['trafficSplit'] as int? ?? 50,
                    ))
                .toList(),
            cachedAt: DateTime.now(),
          );
        }).toList();

        await _storage.cacheExperiments(_cachedExperiments);

        _callback?.call(
            'experimentsRefreshed', {'count': _cachedExperiments.length});

        if (_config.debug) {
          print(
              'RiviumAbTesting: Fetched ${_cachedExperiments.length} experiments');
        }
      }

      // Parse config from /public/init
      if (initResponse.statusCode == 200) {
        final initData = jsonDecode(initResponse.body);
        if (initData['config'] != null) {
          await _storage
              .saveSdkConfig(Map<String, dynamic>.from(initData['config']));
          _syncManager
              .updateConfig(SyncConfig.fromJson(initData['config']));
        }
      }
    } catch (e) {
      if (_config.debug) {
        print('RiviumAbTesting: Failed to fetch experiments: $e');
      }
      _callback?.call(
          'error', {'message': 'Failed to fetch experiments: $e'});
    }
  }

  Future<String> _getLocalAssignment(
    String experimentKey,
    String defaultVariant,
  ) async {
    // Find experiment in cache by key
    final matches =
        _cachedExperiments.where((e) => e.key == experimentKey);
    if (matches.isEmpty) {
      return defaultVariant;
    }

    final experiment = matches.first;

    // Check traffic allocation using experiment UUID for hashing
    // Backend: hashUserId(userId, experimentId) -> parseInt(hex, 16)
    // Backend: userBucket = userHash % 100
    // Backend: if (userBucket >= experiment.trafficAllocation) -> not in experiment
    final userHash = _getHash(_userId!, experiment.id);
    final bucket = userHash % 100;

    if (bucket >= experiment.trafficAllocation) {
      final controlVariant = experiment.variants
          .where((v) => v.isControl)
          .toList();
      return controlVariant.isNotEmpty
          ? controlVariant.first.name
          : defaultVariant;
    }

    // Assign to variant based on traffic split
    // Backend: selectVariant(variants, userHash) -> sorts by name, bucket = userHash % 100, bucket < cumulative
    final sortedVariants = [...experiment.variants]
      ..sort((a, b) => a.name.compareTo(b.name));

    int cumulativeSplit = 0;

    for (final variant in sortedVariants) {
      cumulativeSplit += variant.trafficSplit;
      if (bucket < cumulativeSplit) {
        await _storage.cacheAssignment(CachedAssignment(
          experimentId: experiment.id,
          experimentKey: experimentKey,
          variantId: variant.id,
          variantKey: variant.key,
          variantName: variant.name,
          config: variant.config,
          isControl: variant.isControl,
          assignedAt: DateTime.now(),
        ));

        _callback?.call('experimentAssigned', {
          'experimentKey': experimentKey,
          'variantKey': variant.key,
          'config': variant.config,
        });

        return variant.name;
      }
    }

    return defaultVariant;
  }

  /// Get raw hash integer (before modulo)
  /// Matches backend: MD5("userId:salt") -> parseInt(hex.substring(0,8), 16)
  int _getHash(String userId, String salt) {
    final input = '$userId:$salt';
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    final hashHex = digest.toString().substring(0, 8);
    return int.parse(hashHex, radix: 16);
  }

  String _generateEventId() {
    final random = Random();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = random.nextInt(999999).toString().padLeft(6, '0');
    return 'evt_${timestamp}_$randomPart';
  }

  void _onSyncEvent(SyncEvent event, Map<String, dynamic>? data) {
    switch (event) {
      case SyncEvent.syncCompleted:
        _callback?.call('syncCompleted', data);
        break;
      case SyncEvent.syncFailed:
        _callback?.call('error', {'message': data?['error'] ?? 'Sync failed'});
        break;
      case SyncEvent.offlineMode:
        _callback?.call('offlineMode', null);
        _featureFlags.updateOnlineStatus(false);
        break;
      case SyncEvent.onlineMode:
        _callback?.call('onlineMode', null);
        // Refresh experiments and flags when coming online
        _fetchExperiments();
        _featureFlags.updateOnlineStatus(true);
        _featureFlags.refresh();
        break;
      default:
        break;
    }

    if (_config.debug) {
      print('RiviumAbTesting: Sync event: $event, data: $data');
    }
  }
}

/// Event types for tracking
enum EventType {
  view,
  click,
  conversion,
  custom,
  scroll,
  formSubmit,
  search,
  share,
  addToCart,
  removeFromCart,
  beginCheckout,
  purchase,
  videoStart,
  videoComplete,
  signUp,
  login,
  logout,
}

extension EventTypeExtension on EventType {
  String get value {
    switch (this) {
      case EventType.view:
        return 'view';
      case EventType.click:
        return 'click';
      case EventType.conversion:
        return 'conversion';
      case EventType.custom:
        return 'custom';
      case EventType.scroll:
        return 'scroll';
      case EventType.formSubmit:
        return 'form_submit';
      case EventType.search:
        return 'search';
      case EventType.share:
        return 'share';
      case EventType.addToCart:
        return 'add_to_cart';
      case EventType.removeFromCart:
        return 'remove_from_cart';
      case EventType.beginCheckout:
        return 'begin_checkout';
      case EventType.purchase:
        return 'purchase';
      case EventType.videoStart:
        return 'video_start';
      case EventType.videoComplete:
        return 'video_complete';
      case EventType.signUp:
        return 'sign_up';
      case EventType.login:
        return 'login';
      case EventType.logout:
        return 'logout';
    }
  }
}
