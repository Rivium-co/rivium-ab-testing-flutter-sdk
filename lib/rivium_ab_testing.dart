/// RiviumAbTesting - A/B Testing SDK for Flutter
///
/// Pure Dart implementation. Works on all Flutter platforms
/// (iOS, Android, Web, macOS, Windows, Linux).
///
/// Features:
/// - A/B testing with automatic variant assignment
/// - Offline support with local caching
/// - Sticky bucketing (users stay in same variant)
/// - Event tracking with automatic sync
/// - Feature flags
///
/// Usage:
/// ```dart
/// import 'package:rivium_ab_testing/rivium_ab_testing.dart';
///
/// // Initialize
/// await RiviumAbTesting.init(RiviumAbTestingConfig(apiKey: 'rv_live_xxx'));
///
/// // Set user ID
/// await RiviumAbTesting.instance.setUserId('user-123');
///
/// // Get variant for experiment
/// final variant = await RiviumAbTesting.instance.getVariant('experiment-key');
/// print('Assigned to: $variant');
///
/// // Track conversion
/// await RiviumAbTesting.instance.trackConversion('experiment-key', value: 99.99);
///
/// // Force sync events
/// await RiviumAbTesting.instance.flush();
/// ```
library rivium_ab_testing;

// Core SDK
export 'src/rivium_ab_testing.dart';
export 'src/rivium_ab_testing_config.dart';
export 'src/rivium_ab_testing_error.dart';

// Standalone Feature Flags
export 'src/rivium_feature_flags.dart';
export 'src/rivium_feature_flags_config.dart';

// Models
export 'src/models/experiment.dart';
export 'src/models/variant.dart';
export 'src/models/assignment.dart';
export 'src/models/feature_flag.dart';

// Offline support
export 'src/offline/offline_storage.dart' show OfflineEvent, CachedExperiment, CachedVariant, CachedAssignment, CachedFeatureFlag, CachedFlagVariant;
export 'src/offline/sync_manager.dart' show SyncResult, SyncEvent;
