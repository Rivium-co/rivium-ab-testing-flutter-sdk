import 'variant.dart';

/// Experiment status
enum ExperimentStatus {
  draft,
  running,
  paused,
  completed,
  archived,
}

/// Experiment model
class Experiment {
  final String id;
  final String key;
  final String name;
  final ExperimentStatus status;
  final int trafficAllocation;
  final List<Variant> variants;
  final Map<String, dynamic>? targetingRules;

  const Experiment({
    required this.id,
    required this.key,
    required this.name,
    required this.status,
    required this.trafficAllocation,
    required this.variants,
    this.targetingRules,
  });

  factory Experiment.fromMap(Map<String, dynamic> map) {
    return Experiment(
      id: map['id'] as String,
      key: map['key'] as String,
      name: map['name'] as String,
      status: _parseStatus(map['status'] as String?),
      trafficAllocation: map['trafficAllocation'] as int? ?? 100,
      variants: (map['variants'] as List<dynamic>?)
              ?.map((v) => Variant.fromMap(v as Map<String, dynamic>))
              .toList() ??
          [],
      targetingRules: map['targetingRules'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'key': key,
      'name': name,
      'status': status.name,
      'trafficAllocation': trafficAllocation,
      'variants': variants.map((v) => v.toMap()).toList(),
      'targetingRules': targetingRules,
    };
  }

  static ExperimentStatus _parseStatus(String? status) {
    switch (status) {
      case 'running':
        return ExperimentStatus.running;
      case 'paused':
        return ExperimentStatus.paused;
      case 'completed':
        return ExperimentStatus.completed;
      case 'archived':
        return ExperimentStatus.archived;
      default:
        return ExperimentStatus.draft;
    }
  }
}
