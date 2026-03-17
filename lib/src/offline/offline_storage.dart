import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Event data structure for offline storage
class OfflineEvent {
  final String id;
  final String experimentId;
  final String variantId;
  final String userId;
  final String eventType;
  final String? eventName;
  final double? eventValue;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  final int retryCount;

  OfflineEvent({
    required this.id,
    required this.experimentId,
    required this.variantId,
    required this.userId,
    required this.eventType,
    this.eventName,
    this.eventValue,
    this.metadata,
    required this.timestamp,
    this.retryCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'experimentId': experimentId,
        'variantId': variantId,
        'userId': userId,
        'eventType': eventType,
        'eventName': eventName,
        'eventValue': eventValue,
        'metadata': metadata,
        'timestamp': timestamp.toIso8601String(),
        'retryCount': retryCount,
      };

  factory OfflineEvent.fromJson(Map<String, dynamic> json) => OfflineEvent(
        id: json['id'] as String,
        experimentId: json['experimentId'] as String,
        variantId: json['variantId'] as String,
        userId: json['userId'] as String,
        eventType: json['eventType'] as String,
        eventName: json['eventName'] as String?,
        eventValue: json['eventValue'] != null
            ? (json['eventValue'] as num).toDouble()
            : null,
        metadata: json['metadata'] != null
            ? Map<String, dynamic>.from(json['metadata'] as Map)
            : null,
        timestamp: DateTime.parse(json['timestamp'] as String),
        retryCount: json['retryCount'] as int? ?? 0,
      );

  OfflineEvent copyWith({int? retryCount}) => OfflineEvent(
        id: id,
        experimentId: experimentId,
        variantId: variantId,
        userId: userId,
        eventType: eventType,
        eventName: eventName,
        eventValue: eventValue,
        metadata: metadata,
        timestamp: timestamp,
        retryCount: retryCount ?? this.retryCount,
      );
}

/// Cached experiment data
class CachedExperiment {
  final String id;
  final String key;
  final String name;
  final int trafficAllocation;
  final List<CachedVariant> variants;
  final Map<String, dynamic>? targetingRules;
  final DateTime cachedAt;

  CachedExperiment({
    required this.id,
    required this.key,
    required this.name,
    required this.trafficAllocation,
    required this.variants,
    this.targetingRules,
    required this.cachedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'name': name,
        'trafficAllocation': trafficAllocation,
        'variants': variants.map((v) => v.toJson()).toList(),
        'targetingRules': targetingRules,
        'cachedAt': cachedAt.toIso8601String(),
      };

  factory CachedExperiment.fromJson(Map<String, dynamic> json) =>
      CachedExperiment(
        id: json['id'] as String,
        key: json['key'] as String? ?? json['id'] as String,
        name: json['name'] as String,
        trafficAllocation: json['trafficAllocation'] as int,
        variants: (json['variants'] as List)
            .map((v) => CachedVariant.fromJson(Map<String, dynamic>.from(v)))
            .toList(),
        targetingRules: json['targetingRules'] != null
            ? Map<String, dynamic>.from(json['targetingRules'] as Map)
            : null,
        cachedAt: DateTime.parse(json['cachedAt'] as String),
      );
}

class CachedVariant {
  final String id;
  final String key;
  final String name;
  final Map<String, dynamic>? config;
  final bool isControl;
  final int trafficSplit;

  CachedVariant({
    required this.id,
    required this.key,
    required this.name,
    this.config,
    required this.isControl,
    required this.trafficSplit,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'name': name,
        'config': config,
        'isControl': isControl,
        'trafficSplit': trafficSplit,
      };

  factory CachedVariant.fromJson(Map<String, dynamic> json) => CachedVariant(
        id: json['id'] as String,
        key: json['key'] as String? ?? json['id'] as String,
        name: json['name'] as String,
        config: json['config'] != null
            ? Map<String, dynamic>.from(json['config'] as Map)
            : null,
        isControl: json['isControl'] as bool? ?? false,
        trafficSplit: json['trafficSplit'] as int? ?? 50,
      );
}

/// Cached assignment (sticky bucketing)
class CachedAssignment {
  final String experimentId;
  final String experimentKey;
  final String variantId;
  final String variantKey;
  final String variantName;
  final Map<String, dynamic>? config;
  final bool isControl;
  final DateTime assignedAt;

  CachedAssignment({
    required this.experimentId,
    required this.experimentKey,
    required this.variantId,
    required this.variantKey,
    required this.variantName,
    this.config,
    this.isControl = false,
    required this.assignedAt,
  });

  Map<String, dynamic> toJson() => {
        'experimentId': experimentId,
        'experimentKey': experimentKey,
        'variantId': variantId,
        'variantKey': variantKey,
        'variantName': variantName,
        'config': config,
        'isControl': isControl,
        'assignedAt': assignedAt.toIso8601String(),
      };

  factory CachedAssignment.fromJson(Map<String, dynamic> json) =>
      CachedAssignment(
        experimentId: json['experimentId'] as String,
        experimentKey: json['experimentKey'] as String? ?? '',
        variantId: json['variantId'] as String,
        variantKey: json['variantKey'] as String? ?? '',
        variantName: json['variantName'] as String,
        config: json['config'] != null
            ? Map<String, dynamic>.from(json['config'] as Map)
            : null,
        isControl: json['isControl'] as bool? ?? false,
        assignedAt: DateTime.parse(json['assignedAt'] as String),
      );
}

/// Cached feature flag
class CachedFeatureFlag {
  final String key;
  final bool enabled;
  final int rolloutPercentage;
  final Map<String, dynamic>? targetingRules;
  final List<CachedFlagVariant>? variants;
  final dynamic defaultValue;
  final DateTime cachedAt;

  CachedFeatureFlag({
    required this.key,
    required this.enabled,
    this.rolloutPercentage = 100,
    this.targetingRules,
    this.variants,
    this.defaultValue,
    required this.cachedAt,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'enabled': enabled,
        'rolloutPercentage': rolloutPercentage,
        'targetingRules': targetingRules,
        'variants': variants?.map((v) => v.toJson()).toList(),
        'defaultValue': defaultValue,
        'cachedAt': cachedAt.toIso8601String(),
      };

  factory CachedFeatureFlag.fromJson(Map<String, dynamic> json) =>
      CachedFeatureFlag(
        key: json['key'] as String,
        enabled: json['enabled'] as bool? ?? false,
        rolloutPercentage: json['rolloutPercentage'] as int? ?? 100,
        targetingRules: json['targetingRules'] != null
            ? Map<String, dynamic>.from(json['targetingRules'] as Map)
            : null,
        variants: (json['variants'] as List?)
            ?.map(
                (v) => CachedFlagVariant.fromJson(Map<String, dynamic>.from(v)))
            .toList(),
        defaultValue: json['defaultValue'],
        cachedAt: json['cachedAt'] != null
            ? DateTime.parse(json['cachedAt'] as String)
            : DateTime.now(),
      );
}

class CachedFlagVariant {
  final String key;
  final dynamic value;
  final int weight;

  CachedFlagVariant({
    required this.key,
    this.value,
    this.weight = 0,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'weight': weight,
      };

  factory CachedFlagVariant.fromJson(Map<String, dynamic> json) =>
      CachedFlagVariant(
        key: json['key'] as String,
        value: json['value'],
        weight: json['weight'] as int? ?? 0,
      );
}

/// Offline storage manager for RiviumAbTesting SDK
class OfflineStorage {
  static const String _eventsKey = 'rivium_ab_testing_offline_events';
  static const String _experimentsKey = 'rivium_ab_testing_cached_experiments';
  static const String _assignmentsKey = 'rivium_ab_testing_cached_assignments';
  static const String _flagsKey = 'rivium_ab_testing_cached_flags';
  static const String _configKey = 'rivium_ab_testing_sdk_config';
  static const String _userIdKey = 'rivium_ab_testing_user_id';
  static const String _deviceIdKey = 'rivium_ab_testing_device_id';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ============================================
  // EVENT QUEUE
  // ============================================

  Future<List<OfflineEvent>> getOfflineEvents() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_eventsKey);
    if (jsonStr == null) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((e) => OfflineEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> saveOfflineEvents(List<OfflineEvent> events) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(events.map((e) => e.toJson()).toList());
    await prefs.setString(_eventsKey, jsonStr);
  }

  Future<void> addOfflineEvent(OfflineEvent event) async {
    final events = await getOfflineEvents();
    events.add(event);
    await saveOfflineEvents(events);
  }

  Future<void> removeOfflineEvents(List<String> eventIds) async {
    final events = await getOfflineEvents();
    events.removeWhere((e) => eventIds.contains(e.id));
    await saveOfflineEvents(events);
  }

  Future<void> clearOfflineEvents() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_eventsKey);
  }

  Future<int> getOfflineEventCount() async {
    final events = await getOfflineEvents();
    return events.length;
  }

  // ============================================
  // EXPERIMENT CACHE
  // ============================================

  Future<List<CachedExperiment>> getCachedExperiments() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_experimentsKey);
    if (jsonStr == null) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((e) => CachedExperiment.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> cacheExperiments(List<CachedExperiment> experiments) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(experiments.map((e) => e.toJson()).toList());
    await prefs.setString(_experimentsKey, jsonStr);
  }

  Future<CachedExperiment?> getCachedExperiment(String experimentId) async {
    final experiments = await getCachedExperiments();
    try {
      return experiments.firstWhere((e) => e.id == experimentId);
    } catch (e) {
      return null;
    }
  }

  Future<void> clearExperimentCache() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_experimentsKey);
  }

  // ============================================
  // ASSIGNMENT CACHE (Sticky Bucketing)
  // ============================================

  Future<Map<String, CachedAssignment>> getCachedAssignments() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_assignmentsKey);
    if (jsonStr == null) return {};

    try {
      final Map<String, dynamic> jsonMap = jsonDecode(jsonStr);
      return jsonMap.map((key, value) => MapEntry(
            key,
            CachedAssignment.fromJson(Map<String, dynamic>.from(value)),
          ));
    } catch (e) {
      return {};
    }
  }

  Future<void> cacheAssignment(CachedAssignment assignment) async {
    final assignments = await getCachedAssignments();
    assignments[assignment.experimentKey] = assignment;
    await _saveAssignments(assignments);
  }

  Future<CachedAssignment?> getCachedAssignment(
      String experimentKey) async {
    final assignments = await getCachedAssignments();
    return assignments[experimentKey];
  }

  Future<void> _saveAssignments(
      Map<String, CachedAssignment> assignments) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(
        assignments.map((key, value) => MapEntry(key, value.toJson())));
    await prefs.setString(_assignmentsKey, jsonStr);
  }

  Future<void> clearAssignmentCache() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_assignmentsKey);
  }

  // ============================================
  // FEATURE FLAG CACHE
  // ============================================

  Future<List<CachedFeatureFlag>> getCachedFlags() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_flagsKey);
    if (jsonStr == null) return [];

    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((e) => CachedFeatureFlag.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> cacheFlags(List<CachedFeatureFlag> flags) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(flags.map((f) => f.toJson()).toList());
    await prefs.setString(_flagsKey, jsonStr);
  }

  Future<CachedFeatureFlag?> getCachedFlag(String flagKey) async {
    final flags = await getCachedFlags();
    try {
      return flags.firstWhere((f) => f.key == flagKey);
    } catch (e) {
      return null;
    }
  }

  Future<void> clearFlagCache() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_flagsKey);
  }

  // ============================================
  // SDK CONFIG
  // ============================================

  Future<Map<String, dynamic>?> getSdkConfig() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_configKey);
    if (jsonStr == null) return null;

    try {
      return jsonDecode(jsonStr);
    } catch (e) {
      return null;
    }
  }

  Future<void> saveSdkConfig(Map<String, dynamic> config) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config));
  }

  // ============================================
  // USER & DEVICE ID
  // ============================================

  Future<String?> getUserId() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    return prefs.getString(_userIdKey);
  }

  Future<void> saveUserId(String userId) async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, userId);
  }

  Future<String> getOrCreateDeviceId() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = _generateUuid();
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  // ============================================
  // CLEAR ALL
  // ============================================

  Future<void> clearAll() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await prefs.remove(_eventsKey);
    await prefs.remove(_experimentsKey);
    await prefs.remove(_assignmentsKey);
    await prefs.remove(_flagsKey);
    await prefs.remove(_configKey);
    await prefs.remove(_userIdKey);
    // Keep device ID for consistency
  }

  // ============================================
  // HELPERS
  // ============================================

  String _generateUuid() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replaceAllMapped(
      RegExp(r'[xy]'),
      (match) {
        final r = (random + (DateTime.now().microsecond % 16)) % 16 | 0;
        final v = match.group(0) == 'x' ? r : (r & 0x3 | 0x8);
        return v.toRadixString(16);
      },
    );
  }
}
