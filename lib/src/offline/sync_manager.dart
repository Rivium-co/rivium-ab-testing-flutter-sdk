import 'dart:async';
import 'dart:convert';
import '../platform.dart';
import '../rivium_api_client.dart';
import '../sdk_version.dart';
import 'offline_storage.dart';

/// Configuration for sync manager
class SyncConfig {
  final int syncIntervalSeconds;
  final int maxBatchSize;
  final int maxOfflineEvents;
  final int maxRetries;
  final Duration retryDelay;

  const SyncConfig({
    this.syncIntervalSeconds = 30,
    this.maxBatchSize = 100,
    this.maxOfflineEvents = 1000,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 5),
  });

  factory SyncConfig.fromJson(Map<String, dynamic> json) => SyncConfig(
        syncIntervalSeconds: json['syncIntervalSeconds'] as int? ?? 30,
        maxBatchSize: json['maxBatchSize'] as int? ?? 100,
        maxOfflineEvents: json['maxOfflineEvents'] as int? ?? 1000,
        maxRetries: json['maxRetries'] as int? ?? 3,
      );
}

/// Callback for sync events
typedef SyncCallback = void Function(SyncEvent event, Map<String, dynamic>? data);

enum SyncEvent {
  syncStarted,
  syncCompleted,
  syncFailed,
  eventsQueued,
  offlineMode,
  onlineMode,
}

/// Manages offline event sync with the RiviumAbTesting server
class SyncManager {
  final RiviumApiClient api;
  final OfflineStorage storage;
  final SyncCallback? onSyncEvent;

  /// The signed-in user. With a user token the service credits every event in
  /// a batch to the token's user, so only this user's events may be sent.
  final String? Function()? currentUserId;

  /// The queue never holds more events than this, whatever the config says.
  static const int queueLimit = 1000;

  /// The most events the service takes in one request.
  static const int batchLimit = 100;

  static const Duration _maxBackoff = Duration(minutes: 15);

  SyncConfig _config;
  Timer? _syncTimer;
  bool _isOnline = true;
  bool _isSyncing = false;
  StreamSubscription<bool>? _connectivitySubscription;

  int _failures = 0;
  DateTime? _backoffUntil;
  String? _lastReportedError;

  SyncManager({
    required this.api,
    required this.storage,
    this.onSyncEvent,
    this.currentUserId,
    SyncConfig? config,
  }) : _config = config ?? const SyncConfig();

  int get _queueSize {
    final size = _config.maxOfflineEvents;
    return size < 1 || size > queueLimit ? queueLimit : size;
  }

  int get _batchSize {
    final size = _config.maxBatchSize;
    return size < 1 || size > batchLimit ? batchLimit : size;
  }

  /// Initialize the sync manager
  Future<void> init() async {
    await storage.init();

    // Load server config
    final savedConfig = await storage.getSdkConfig();
    if (savedConfig != null) {
      _config = SyncConfig.fromJson(savedConfig);
    }

    // Start connectivity monitoring
    _connectivitySubscription =
        RiviumPlatform.onlineChanges().listen(_onConnectivityChanged);

    // Check initial connectivity
    try {
      _isOnline = await RiviumPlatform.isOnline();
    } catch (_) {
      _isOnline = true; // Assume online if check fails
    }

    // Start periodic sync
    _startSyncTimer();
  }

  /// Update sync configuration
  void updateConfig(SyncConfig config) {
    _config = config;
    _startSyncTimer();
  }

  /// Queue an event for sync
  Future<void> queueEvent(OfflineEvent event) async {
    final events = await storage.getOfflineEvents();

    // Enforce max offline events limit
    if (events.length >= _queueSize) {
      // Remove oldest events
      final toRemove = events.length - _queueSize + 1;
      events.removeRange(0, toRemove);
    }

    events.add(event);
    await storage.saveOfflineEvents(events);

    onSyncEvent?.call(SyncEvent.eventsQueued, {
      'count': events.length,
      'eventId': event.id,
    });

    // Sync immediately if online and batch is full
    if (_isOnline && events.length >= _batchSize) {
      sync();
    }
  }

  /// Keep only the events recorded for [userId]; with null, none. Events of
  /// anyone else cannot be credited to this user and are never sent.
  Future<void> keepOnlyEventsOf(String? userId) async {
    if (userId == null) {
      await storage.clearOfflineEvents();
      return;
    }
    final events = await storage.getOfflineEvents();
    final own = events.where((e) => e.userId == userId).toList();
    if (own.length != events.length) {
      await storage.saveOfflineEvents(own);
    }
  }

  /// Sync one batch of pending events with server.
  ///
  /// Nothing is sent while there is no user token, while a rate limit or a
  /// back-off after a failure is running, or for a user who is not signed in.
  /// With [pinned] only the token already held is used (see
  /// [RiviumApiClient.post]) and a running back-off is ignored.
  Future<SyncResult> sync({bool pinned = false}) async {
    if (_isSyncing) {
      return SyncResult(synced: 0, failed: 0, pending: 0);
    }
    if (!pinned && _backoffUntil != null) {
      if (_backoffUntil!.isAfter(DateTime.now())) {
        return SyncResult(synced: 0, failed: 0, pending: 0);
      }
      _backoffUntil = null;
    }

    final userId = currentUserId?.call();
    if (userId == null) {
      // Nobody to credit the events to yet: they stay parked.
      return SyncResult(synced: 0, failed: 0, pending: 0);
    }

    _isSyncing = true;
    try {
      var events = await storage.getOfflineEvents();

      // Another user's leftover events can't be sent under this user's
      // token: they would be credited to the wrong person.
      final own = events.where((e) => e.userId == userId).toList();
      if (own.length != events.length) {
        await storage.saveOfflineEvents(own);
        events = own;
      }
      if (events.isEmpty) {
        return SyncResult(synced: 0, failed: 0, pending: 0);
      }

      // Take batch of events
      final batch = events.take(_batchSize).toList();
      final deviceId = await storage.getOrCreateDeviceId();

      final response = await api.post(
        '/public/sync',
        {
          'events': batch
              .map((e) => <String, dynamic>{
                    'experimentId': e.experimentId,
                    'variantId': e.variantId,
                    'userId': e.userId,
                    'eventType': e.eventType,
                    'eventName': e.eventName,
                    'eventValue': e.eventValue,
                    'metadata': e.metadata,
                    'timestamp': e.timestamp.toIso8601String(),
                    'clientEventId': e.id,
                  })
              .toList(),
          'deviceId': deviceId,
          'sdkVersion': 'flutter-$riviumAbTestingSdkVersion',
        },
        userId: userId,
        pinned: pinned,
      );

      if (response == null) {
        // Not sent: waiting for a user token, or a rate limit is running.
        return SyncResult(
            synced: 0, failed: 0, pending: events.length, notSent: true);
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        final result = _decode(response.body);
        final synced = result['synced'] as int? ?? batch.length;
        final failed = result['failed'] as int? ?? 0;

        // The service has taken the whole batch. Events it could not record
        // (an experiment that no longer exists, another user's event) would
        // fail again, so they are not retried.
        await storage.removeOfflineEvents(batch.map((e) => e.id).toList());
        _failures = 0;
        _backoffUntil = null;
        _lastReportedError = null;

        final remaining = events.length - batch.length;

        onSyncEvent?.call(SyncEvent.syncCompleted, {
          'synced': synced,
          'failed': failed,
          'pending': remaining,
        });

        return SyncResult(
            synced: synced,
            failed: failed,
            pending: remaining,
            sent: batch.length);
      }

      if (status == 429) {
        // The client holds every request back until Retry-After has passed.
        return SyncResult(
            synced: 0, failed: 0, pending: events.length, notSent: true);
      }

      final String error;
      if (status == 403 &&
          _errorCode(response.body) == 'event_limit_reached') {
        // The plan's event limit: keep the events, try again later.
        error = 'Event limit reached';
      } else if (status == 400 || status == 413 || status == 422) {
        // The request itself is wrong; the same events cannot succeed.
        await storage.removeOfflineEvents(batch.map((e) => e.id).toList());
        _report('Sync refused: $status');
        return SyncResult(
            synced: 0,
            failed: batch.length,
            pending: events.length - batch.length,
            sent: batch.length,
            error: 'Sync refused: $status');
      } else if (status == 401 || status == 403) {
        error = 'Sync not authorized: $status';
      } else {
        error = 'Sync failed: $status';
      }
      return _failed(error, events.length);
    } catch (e) {
      final pending = await storage.getOfflineEventCount();
      return _failed(e.toString(), pending);
    } finally {
      _isSyncing = false;
    }
  }

  /// Force flush all events
  Future<SyncResult> flush() async {
    SyncResult totalResult = SyncResult(synced: 0, failed: 0, pending: 0);
    // A failed attempt must not keep an explicit flush from trying.
    _backoffUntil = null;

    while (true) {
      final count = await storage.getOfflineEventCount();
      if (count == 0) break;

      final result = await sync();
      totalResult = SyncResult(
        synced: totalResult.synced + result.synced,
        failed: totalResult.failed + result.failed,
        pending: result.pending,
        error: result.error,
      );

      if (result.sent == 0 || result.error != null) {
        break; // No progress or error, stop trying
      }
    }

    return totalResult;
  }

  /// Send the signed-in user's remaining events with the token already held,
  /// before another user takes over.
  Future<void> flushPinned() async {
    while (true) {
      final result = await sync(pinned: true);
      if (result.sent == 0 || result.error != null || result.pending == 0) {
        break;
      }
    }
  }

  /// Check if currently online
  bool get isOnline => _isOnline;

  /// Get pending event count
  Future<int> getPendingEventCount() => storage.getOfflineEventCount();

  /// Dispose resources
  void dispose() {
    _syncTimer?.cancel();
    _connectivitySubscription?.cancel();
  }

  /// Keep the events, wait longer after each failure, and tell the app once.
  SyncResult _failed(String error, int pending) {
    _failures++;
    final doublings = _failures > 6 ? 6 : _failures - 1;
    final interval = _config.syncIntervalSeconds;
    final wait = Duration(seconds: (interval < 1 ? 30 : interval) << doublings);
    _backoffUntil =
        DateTime.now().add(wait > _maxBackoff ? _maxBackoff : wait);
    _report(error);
    return SyncResult(synced: 0, failed: 0, pending: pending, error: error);
  }

  void _report(String error) {
    if (_lastReportedError == error) return;
    _lastReportedError = error;
    onSyncEvent?.call(SyncEvent.syncFailed, {'error': error});
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static String? _errorCode(String body) {
    final code = _decode(body)['code'];
    return code is String ? code : null;
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    final seconds = _config.syncIntervalSeconds;
    _syncTimer = Timer.periodic(
      Duration(seconds: seconds < 1 ? 30 : seconds),
      (_) {
        if (_isOnline) {
          sync();
        }
      },
    );
  }

  void _onConnectivityChanged(bool online) {
    final wasOnline = _isOnline;
    _isOnline = online;

    if (_isOnline != wasOnline) {
      onSyncEvent?.call(
        _isOnline ? SyncEvent.onlineMode : SyncEvent.offlineMode,
        null,
      );

      // Sync immediately when coming online
      if (_isOnline) {
        _backoffUntil = null;
        sync();
      }
    }
  }
}

/// Result of a sync operation
class SyncResult {
  final int synced;
  final int failed;
  final int pending;
  final String? error;

  /// How many events went out in the request (0 when none was made).
  final int sent;

  /// True when nothing was sent because the SDK is waiting: for a user
  /// token, or for a rate limit to pass. The events are kept.
  final bool notSent;

  SyncResult({
    required this.synced,
    required this.failed,
    required this.pending,
    this.error,
    this.sent = 0,
    this.notSent = false,
  });

  bool get hasError => error != null;

  @override
  String toString() =>
      'SyncResult(synced: $synced, failed: $failed, pending: $pending, error: $error)';
}
