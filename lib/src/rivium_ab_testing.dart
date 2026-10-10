import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'rivium_ab_testing_config.dart';
import 'rivium_ab_testing_error.dart';
import 'rivium_api_client.dart';
import 'sdk_version.dart';
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

  late final RiviumApiClient _api;
  late final OfflineStorage _storage;
  late final SyncManager _syncManager;
  late final RiviumFeatureFlags _featureFlags;

  String? _userId;
  Map<String, dynamic> _userAttributes = {};
  List<CachedExperiment> _cachedExperiments = [];
  bool _isInitialized = false;

  RiviumAbTestingCallback? _callback;
  void Function()? _onAwaitingUserToken;

  /// Experiments the app asked about while no variant could be fetched.
  /// Their assignments are fetched once a user token is there.
  final Set<String> _wantedExperiments = {};

  /// Variants the service gave to a user who is not part of the experiment
  /// (targeting, traffic). Kept for this run only: never a sticky assignment.
  final Map<String, String> _notInExperiment = {};

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
  ///
  /// May be called before anyone is signed in: without a user token the SDK
  /// waits for one (see [isAwaitingUserToken]). [baseUrl] must be https;
  /// plain http is accepted only for local development (localhost,
  /// 127.0.0.1, 10.0.2.2).
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

    sdk._api = RiviumApiClient(
      apiKey: config.apiKey,
      baseUrl: sdk._baseUrl,
      tokenProvider: config.tokenProvider,
      userToken: config.userToken,
      debug: config.debug,
    );

    sdk._storage = OfflineStorage();
    await sdk._storage.init();

    // Load saved user ID
    sdk._userId = await sdk._storage.getUserId();

    // Load cached experiments
    sdk._cachedExperiments = await sdk._storage.getCachedExperiments();

    // Initialize sync manager
    sdk._syncManager = SyncManager(
      api: sdk._api,
      storage: sdk._storage,
      onSyncEvent: sdk._onSyncEvent,
      currentUserId: () => sdk._userId,
    );
    try {
      await sdk._syncManager.init();

      // Initialize feature flags (shares storage, no separate singleton)
      sdk._featureFlags = await RiviumFeatureFlags.createInternal(
        apiKey: config.apiKey,
        baseUrl: sdk._baseUrl,
        debug: config.debug,
        storage: sdk._storage,
        isOnline: sdk._syncManager.isOnline,
        api: sdk._api,
        callback: callback != null
            ? (event, data) => callback(event, data)
            : null,
      );
      final savedUserId = sdk._userId;
      if (savedUserId != null) {
        await sdk._featureFlags.setUserId(savedUserId);
      }
    } catch (_) {
      // Leave nothing running, so init can simply be called again.
      sdk._syncManager.dispose();
      rethrow;
    }

    sdk._api
      ..onAwaitingUserToken = sdk._handleAwaitingUserToken
      ..onUserTokenReady = sdk._resume
      ..onTokenUser = sdk._handleTokenUser
      ..onSignedOut = (() => sdk._switchUser(null))
      ..onTokenRejected = (code) => sdk._callback?.call('error', {
            'message': 'User token rejected: $code',
            'code': code,
          });

    sdk._isInitialized = true;
    _instance = sdk;

    // A token from the config says who the user is.
    if (config.userToken != null) {
      await sdk._api.start();
    }

    // Fetch fresh experiments and flags if online
    if (sdk._syncManager.isOnline) {
      sdk._fetchExperiments();
      sdk._featureFlags.refresh();
    }

    callback?.call('initialized', {'offline': !sdk._syncManager.isOnline});

    // Ask the provider for the first token. Without one the SDK waits.
    if (config.userToken == null) {
      unawaited(sdk._api.start());
    }

    return sdk;
  }

  /// Set user ID for experiment assignment and feature flag targeting
  ///
  /// Use the same id your server puts in the user token. Call it again on
  /// login. When the user changes, the last user's pending events are sent
  /// first (under their own token only), then their variants, attributes,
  /// remaining events and token are dropped. On logout call [clearUserId].
  Future<void> setUserId(String userId) async {
    if (!_usable('setUserId')) return;
    final previous = _userId;
    if (userId != previous) {
      await _switchUser(userId);
      if (previous != null) _api.clearToken(keepUnidentified: true);
    }
    // A sign-in is the usual reason for this call: if there is no token,
    // ask for one now. The user's parked events follow it.
    unawaited(_api.ensureToken());
  }

  /// Forget the user, for example at sign-out: their variants, attributes,
  /// pending events and token are dropped, and the SDK waits for the next
  /// user token.
  Future<void> clearUserId() async {
    if (!_usable('clearUserId')) return;
    // Clears the user through onSignedOut.
    await _api.setUserToken(null);
  }

  /// Get current user ID
  String? getUserId() => _userId;

  /// True while the SDK has no user token: nobody is signed in yet, or the
  /// token provider returned null or failed.
  ///
  /// While waiting, [getVariant] returns the default variant, events are
  /// kept on the device and nothing is sent for a user. The SDK carries on
  /// by itself once it has a token (see [setUserToken], [refreshUserToken]).
  bool get isAwaitingUserToken =>
      _isInitialized && _api.isAwaitingUserToken;

  /// Called each time the SDK starts waiting for a user token. The
  /// `awaitingUserToken` event of the [init] callback reports the same.
  void onAwaitingUserToken(void Function() callback) {
    _onAwaitingUserToken = callback;
  }

  /// Hand the SDK a user token minted by your server, for example right
  /// after sign-in or when you refreshed it. With a
  /// [RiviumAbTestingConfig.tokenProvider] the SDK does this for you.
  ///
  /// If the SDK was waiting for a token it carries on now: it fetches the
  /// variants that were asked for meanwhile and sends the user's pending
  /// events. A token of another user drops the last user's data first.
  ///
  /// Pass `null` when the user signs out (same as [clearUserId]).
  Future<void> setUserToken(String? token) async {
    if (!_usable('setUserToken')) return;
    await _api.setUserToken(token);
  }

  /// Set or remove the token provider after [init]. The provider is asked
  /// straight away.
  Future<void> setTokenProvider(RiviumTokenProvider? provider) async {
    if (!_usable('setTokenProvider')) return;
    await _api.setTokenProvider(provider);
  }

  /// Ask the token provider again now. Call this when the user signs in or
  /// out. Does nothing without a provider.
  Future<void> refreshUserToken() async {
    if (!_usable('refreshUserToken')) return;
    await _api.refreshUserToken();
  }

  /// Set user attributes for targeting
  void setUserAttributes(Map<String, dynamic> attributes) {
    if (!_usable('setUserAttributes')) return;
    _userAttributes = {..._userAttributes, ...attributes};
    _notInExperiment.clear();
    _featureFlags.setUserAttributes(attributes);
  }

  /// Get the standalone feature flags instance (for direct access)
  RiviumFeatureFlags get featureFlags {
    _ensureInitialized();
    return _featureFlags;
  }

  /// Get variant for an experiment
  ///
  /// Never throws. Returns [defaultVariant] while the service cannot be
  /// asked: no user, no user token yet ([isAwaitingUserToken]), or no
  /// answer. A variant is decided by the service only; an assignment it gave
  /// earlier is returned from the cache.
  Future<String> getVariant(
    String experimentKey, {
    String defaultVariant = 'control',
  }) async {
    if (!_usable('getVariant')) return defaultVariant;

    try {
      // Check cached assignment (sticky bucketing)
      final cachedAssignment =
          await _storage.getCachedAssignment(experimentKey);
      if (cachedAssignment != null) {
        return cachedAssignment.variantName;
      }
      final outside = _notInExperiment[experimentKey];
      if (outside != null) return outside;

      final userId = _userId;
      if (userId == null || !_syncManager.isOnline) {
        _wantedExperiments.add(experimentKey);
        return defaultVariant;
      }

      final variant = await _assign(experimentKey, userId);
      if (variant != null) return variant;
      _wantedExperiments.add(experimentKey);
    } catch (e) {
      _wantedExperiments.add(experimentKey);
      if (_config.debug) {
        print('RiviumAbTesting: Failed to get assignment from server: $e');
      }
    }

    return defaultVariant;
  }

  /// Get variant configuration
  Future<Map<String, dynamic>?> getVariantConfig(
      String experimentKey) async {
    if (!_usable('getVariantConfig')) return null;

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
    if (!_usable('refreshExperiments')) return;
    _notInExperiment.clear();
    await _fetchExperiments();
  }

  /// Get all experiments
  List<Experiment> getExperiments() {
    if (!_usable('getExperiments')) return [];
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
    if (!_usable('isFeatureEnabled')) return defaultValue;
    return _featureFlags.isEnabled(featureKey, defaultValue: defaultValue);
  }

  /// Get the value of a feature flag
  Future<dynamic> getFeatureValue(String featureKey,
      {dynamic defaultValue}) async {
    if (!_usable('getFeatureValue')) return defaultValue;
    return _featureFlags.getValue(featureKey, defaultValue: defaultValue);
  }

  /// Get all feature flags
  Future<List<FeatureFlag>> getFeatureFlags() async {
    if (!_usable('getFeatureFlags')) return [];
    return _featureFlags.getAll();
  }

  /// Refresh feature flags from server
  Future<void> refreshFeatureFlags() async {
    if (!_usable('refreshFeatureFlags')) return;
    await _featureFlags.refresh();
  }

  /// Flush pending events to server
  Future<void> flush() async {
    if (!_usable('flush')) return;
    await _syncManager.flush();
  }

  /// Check if online
  bool get isOnline => _isInitialized && _syncManager.isOnline;

  /// Get pending event count
  Future<int> getPendingEventCount() async {
    if (!_usable('getPendingEventCount')) return 0;
    return _syncManager.getPendingEventCount();
  }

  /// Reset SDK state
  Future<void> reset() async {
    if (_isInitialized) {
      await _storage.clearAll();
      _syncManager.dispose();
      _api.clearToken();
    }
    _userId = null;
    _userAttributes = {};
    _cachedExperiments = [];
    _wantedExperiments.clear();
    _notInExperiment.clear();
    _isInitialized = false;
    if (identical(_instance, this)) _instance = null;
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

  /// False, with a debug note, when the SDK is not initialised. A call made
  /// too early or after [reset] is skipped: it must not crash the app.
  bool _usable(String method) {
    if (_isInitialized) return true;
    if (_config.debug) {
      print('RiviumAbTesting: $method ignored, the SDK is not initialized');
    }
    return false;
  }

  /// Ask the service for [userId]'s variant. Null when there is no answer:
  /// no user token yet, a rate limit, or an error status.
  Future<String?> _assign(String experimentKey, String userId) async {
    final response = await _api.post(
      '/public/assign',
      {
        'experimentKey': experimentKey,
        'userId': userId,
        'userAttributes': _userAttributes,
      },
      userId: userId,
    );
    if (response == null ||
        response.statusCode < 200 ||
        response.statusCode >= 300) {
      return null;
    }

    final body = jsonDecode(response.body);
    final data = body['data'] as Map<String, dynamic>;
    final variantName = data['variantName'] as String;

    // The user changed while the request was on its way.
    if (userId != _userId) return null;
    _wantedExperiments.remove(experimentKey);

    if (data['inExperiment'] == false) {
      // Sees this variant without taking part. Not an assignment: the
      // service is asked again next run.
      _notInExperiment[experimentKey] = variantName;
      return variantName;
    }

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

  /// Everything of the signed-in user goes before [next] (null: nobody)
  /// takes over, so nothing of theirs can be sent or shown for [next].
  Future<void> _switchUser(String? next) async {
    final previous = _userId;
    if (previous == next) return;
    if (previous != null && _syncManager.isOnline) {
      // Their own token only: the provider may already answer for [next].
      await _syncManager.flushPinned();
    }
    await _storage.clearAssignmentCache();
    _userAttributes = {};
    _wantedExperiments.clear();
    _notInExperiment.clear();
    _userId = next;
    await _syncManager.keepOnlyEventsOf(next);
    if (next != null) {
      await _storage.saveUserId(next);
      await _featureFlags.setUserId(next);
    } else {
      await _storage.removeUserId();
      await _featureFlags.clearUserId();
    }
  }

  /// A token of [userId] is about to be used.
  Future<void> _handleTokenUser(String userId) => _switchUser(userId);

  void _handleAwaitingUserToken() {
    _callback?.call('awaitingUserToken', null);
    _onAwaitingUserToken?.call();
  }

  /// A user token is there, or the connection is back: carry on with what
  /// was waiting for it.
  Future<void> _resume() async {
    if (!_isInitialized || !_syncManager.isOnline) return;
    try {
      final userId = _userId;
      if (userId != null) {
        for (final experimentKey in _wantedExperiments.toList()) {
          await _assign(experimentKey, userId);
        }
      }
      await _syncManager.flush();
    } catch (e) {
      if (_config.debug) {
        print('RiviumAbTesting: Failed to continue with the user token: $e');
      }
    }
  }

  Future<void> _trackEvent(
    String experimentKey,
    EventType eventType, {
    String? eventName,
    double? eventValue,
    Map<String, dynamic>? metadata,
  }) async {
    if (!_usable('track')) return;

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

    // Without a user the event is parked as anonymous. It can only be sent
    // for the user it was recorded for.
    final event = OfflineEvent(
      id: _generateEventId(),
      experimentId: experimentId,
      variantId: variantId,
      userId: _userId ?? '',
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
        _api.get('/public/experiments'),
        _api.get(
            '/public/init?platform=flutter&sdkVersion=$riviumAbTestingSdkVersion'),
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

  static final Random _random = _secureRandom();

  static Random _secureRandom() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }

  /// Sent as `clientEventId`, so the service stores a repeated event once.
  String _generateEventId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = List.generate(
        4, (_) => _random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'))
        .join();
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
        // The token provider may have failed for lack of a connection.
        if (_api.isAwaitingUserToken && _api.tokenProvider != null) {
          unawaited(_api.refreshUserToken());
        } else {
          unawaited(_resume());
        }
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
