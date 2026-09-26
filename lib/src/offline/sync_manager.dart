import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
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

  SyncConfig _config;
  Timer? _syncTimer;
  bool _isOnline = true;
  bool _isSyncing = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  SyncManager({
    required this.api,
    required this.storage,
    this.onSyncEvent,
    this.currentUserId,
    SyncConfig? config,
  }) : _config = config ?? const SyncConfig();

  /// Initialize the sync manager
  Future<void> init() async {
    await storage.init();

    // Load server config
    final savedConfig = await storage.getSdkConfig();
    if (savedConfig != null) {
      _config = SyncConfig.fromJson(savedConfig);
    }

    // Start connectivity monitoring
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);

    // Check initial connectivity
    final result = await Connectivity().checkConnectivity();
    _isOnline = !result.contains(ConnectivityResult.none);

    // Start periodic sync
    _startSyncTimer();

    // Sync immediately if online and has pending events
    if (_isOnline) {
      final eventCount = await storage.getOfflineEventCount();
      if (eventCount > 0) {
        sync();
      }
    }
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
    if (events.length >= _config.maxOfflineEvents) {
      // Remove oldest events
      final toRemove = events.length - _config.maxOfflineEvents + 1;
      events.removeRange(0, toRemove);
    }

    events.add(event);
    await storage.saveOfflineEvents(events);

    onSyncEvent?.call(SyncEvent.eventsQueued, {
      'count': events.length,
      'eventId': event.id,
    });

    // Sync immediately if online and batch is full
    if (_isOnline && events.length >= _config.maxBatchSize) {
      sync();
    }
  }

  /// Sync pending events with server
  Future<SyncResult> sync() async {
    if (_isSyncing) {
      return SyncResult(synced: 0, failed: 0, pending: 0);
    }

    // Check if there are events to sync before starting
    final eventCount = await storage.getOfflineEventCount();
    if (eventCount == 0) {
      return SyncResult(synced: 0, failed: 0, pending: 0);
    }

    _isSyncing = true;
    onSyncEvent?.call(SyncEvent.syncStarted, null);

    try {
      var events = await storage.getOfflineEvents();

      // Another user's leftover events can't be sent under this user's
      // token: they would be credited to the wrong person.
      if (api.usesUserToken) {
        final userId = currentUserId?.call();
        final own = events.where((e) => e.userId == userId).toList();
        if (own.length != events.length) {
          await storage.saveOfflineEvents(own);
          events = own;
        }
      }

      if (events.isEmpty) {
        return SyncResult(synced: 0, failed: 0, pending: 0);
      }

      // Take batch of events
      final batch = events.take(_config.maxBatchSize).toList();
      final deviceId = await storage.getOrCreateDeviceId();

      final response = await api.post('/public/sync', {
          'events': batch.map((e) => <String, dynamic>{
              'experimentId': e.experimentId,
              'variantId': e.variantId,
              'userId': e.userId,
              'eventType': e.eventType,
              'eventName': e.eventName,
              'eventValue': e.eventValue,
              'metadata': e.metadata,
              'timestamp': e.timestamp.toIso8601String(),
              'clientEventId': e.id,
            }).toList(),
          'deviceId': deviceId,
          'sdkVersion': 'flutter-$riviumAbTestingSdkVersion',
        });

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        final synced = result['synced'] as int? ?? 0;
        final failed = result['failed'] as int? ?? 0;

        // The service has taken the whole batch. Events it could not record
        // (an experiment that no longer exists, say) would fail again, so
        // they are not retried.
        await storage.removeOfflineEvents(batch.map((e) => e.id).toList());

        final remaining = await storage.getOfflineEventCount();

        onSyncEvent?.call(SyncEvent.syncCompleted, {
          'synced': synced,
          'failed': failed,
          'pending': remaining,
        });

        return SyncResult(synced: synced, failed: failed, pending: remaining);
      } else if (response.statusCode == 401) {
        // No valid user token yet (or the project requires one): keep the
        // events and send them once a token is available.
        throw Exception('Sync not authorized: ${response.statusCode}');
      } else if (response.statusCode >= 400 &&
          response.statusCode < 500 &&
          response.statusCode != 429) {
        // The request itself is wrong; the same events cannot succeed.
        await storage.removeOfflineEvents(batch.map((e) => e.id).toList());
        throw Exception('Sync refused: ${response.statusCode}');
      } else {
        throw Exception('Sync failed: ${response.statusCode}');
      }
    } catch (e) {
      onSyncEvent?.call(SyncEvent.syncFailed, {'error': e.toString()});
      final pending = await storage.getOfflineEventCount();
      return SyncResult(synced: 0, failed: 0, pending: pending, error: e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  /// Force flush all events
  Future<SyncResult> flush() async {
    SyncResult totalResult = SyncResult(synced: 0, failed: 0, pending: 0);

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

      if (result.synced == 0 || result.error != null) {
        break; // No progress or error, stop trying
      }
    }

    return totalResult;
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

  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      Duration(seconds: _config.syncIntervalSeconds),
      (_) {
        if (_isOnline) {
          sync();
        }
      },
    );
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final wasOnline = _isOnline;
    _isOnline = !results.contains(ConnectivityResult.none);

    if (_isOnline != wasOnline) {
      onSyncEvent?.call(
        _isOnline ? SyncEvent.onlineMode : SyncEvent.offlineMode,
        null,
      );

      // Sync immediately when coming online
      if (_isOnline) {
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

  SyncResult({
    required this.synced,
    required this.failed,
    required this.pending,
    this.error,
  });

  bool get hasError => error != null;

  @override
  String toString() =>
      'SyncResult(synced: $synced, failed: $failed, pending: $pending, error: $error)';
}
