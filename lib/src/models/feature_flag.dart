/// Feature flag model
class FeatureFlag {
  final String key;
  final bool enabled;
  final int rolloutPercentage;
  final Map<String, dynamic>? targetingRules;
  final List<FlagVariant>? variants;
  final dynamic defaultValue;

  const FeatureFlag({
    required this.key,
    required this.enabled,
    this.rolloutPercentage = 100,
    this.targetingRules,
    this.variants,
    this.defaultValue,
  });

  factory FeatureFlag.fromMap(Map<String, dynamic> map) {
    return FeatureFlag(
      key: map['key'] as String,
      enabled: map['enabled'] as bool? ?? false,
      rolloutPercentage: map['rolloutPercentage'] as int? ?? 100,
      targetingRules: map['targetingRules'] as Map<String, dynamic>?,
      variants: (map['variants'] as List<dynamic>?)
          ?.map((v) => FlagVariant.fromMap(v as Map<String, dynamic>))
          .toList(),
      defaultValue: map['defaultValue'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'enabled': enabled,
      'rolloutPercentage': rolloutPercentage,
      'targetingRules': targetingRules,
      'variants': variants?.map((v) => v.toMap()).toList(),
      'defaultValue': defaultValue,
    };
  }
}

/// Feature flag variant
class FlagVariant {
  final String key;
  final dynamic value;
  final int weight;

  const FlagVariant({
    required this.key,
    this.value,
    this.weight = 0,
  });

  factory FlagVariant.fromMap(Map<String, dynamic> map) {
    return FlagVariant(
      key: map['key'] as String,
      value: map['value'],
      weight: map['weight'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'key': key,
      'value': value,
      'weight': weight,
    };
  }
}
