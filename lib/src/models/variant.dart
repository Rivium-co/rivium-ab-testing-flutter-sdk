/// Variant model
class Variant {
  final String id;
  final String key;
  final String name;
  final int trafficSplit;
  final bool isControl;
  final Map<String, dynamic>? config;

  const Variant({
    required this.id,
    required this.key,
    required this.name,
    required this.trafficSplit,
    required this.isControl,
    this.config,
  });

  factory Variant.fromMap(Map<String, dynamic> map) {
    return Variant(
      id: map['id'] as String,
      key: map['key'] as String,
      name: map['name'] as String,
      trafficSplit: map['trafficSplit'] as int? ?? 0,
      isControl: map['isControl'] as bool? ?? false,
      config: map['config'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'key': key,
      'name': name,
      'trafficSplit': trafficSplit,
      'isControl': isControl,
      'config': config,
    };
  }
}
