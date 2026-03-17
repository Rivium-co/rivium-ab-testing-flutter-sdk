/// Assignment result
class Assignment {
  final String experimentId;
  final String experimentKey;
  final String variantId;
  final String variantKey;
  final String variantName;
  final bool isControl;
  final Map<String, dynamic>? config;

  const Assignment({
    required this.experimentId,
    required this.experimentKey,
    required this.variantId,
    required this.variantKey,
    required this.variantName,
    required this.isControl,
    this.config,
  });

  factory Assignment.fromMap(Map<String, dynamic> map) {
    return Assignment(
      experimentId: map['experimentId'] as String,
      experimentKey: map['experimentKey'] as String? ?? '',
      variantId: map['variantId'] as String,
      variantKey: map['variantKey'] as String? ?? '',
      variantName: map['variantName'] as String? ?? '',
      isControl: map['isControl'] as bool? ?? false,
      config: map['config'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'experimentId': experimentId,
      'experimentKey': experimentKey,
      'variantId': variantId,
      'variantKey': variantKey,
      'variantName': variantName,
      'isControl': isControl,
      'config': config,
    };
  }
}
