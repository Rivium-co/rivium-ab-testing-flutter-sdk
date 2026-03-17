import 'package:flutter/material.dart';
import 'package:rivium_ab_testing/rivium_ab_testing.dart';

/// ============================================
/// CONFIGURATION — matches the test scenario in
/// docs/ABTEST_FLAGS_TEST_SCENARIO.md
/// ============================================
const apiKey = 'YOUR_API_KEY_HERE';
const baseUrl = 'https://abtest.rivium.co'; // or http://localhost:3007

// Experiments created in Part 2 of the test scenario
const experimentCheckout = 'checkout-flow-test';
const experimentPricing = 'pricing-page-test';

// Feature flags created in Part 3 (managed via RiviumFlags)
const flagDarkMode = 'dark_mode';
const flagOnboardingFlow = 'onboarding_flow';
const flagDarkModeSettings = 'dark_mode_settings';
const flagHolidayBanner = 'holiday_banner';

void main() {
  runApp(const RiviumExampleApp());
}

class RiviumExampleApp extends StatelessWidget {
  const RiviumExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rivium AB Testing Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C3AED)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<String> _logs = [];
  bool _isInitialized = false;
  String? _currentVariant;
  Map<String, dynamic>? _variantConfig;

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.insert(0, '[$timestamp] $message');
      if (_logs.length > 100) _logs.removeLast();
    });
  }

  // ============================================
  // 1. INITIALIZATION
  // ============================================

  Future<void> _initSDK() async {
    _log('Initializing SDK...');
    try {
      await RiviumAbTesting.init(
        RiviumAbTestingConfig(
          apiKey: apiKey,
          debug: true,
          flushInterval: 10000, // 10 seconds for testing
          maxQueueSize: 50,
          autoTrack: true,
        ),
        callback: (event, data) {
          _log('Event: $event ${data != null ? "- $data" : ""}');
        },
      );

      setState(() => _isInitialized = true);
      _log('SDK initialized successfully');
    } catch (e) {
      _log('Init failed: $e');
    }
  }

  // ============================================
  // 2. USER MANAGEMENT
  // ============================================

  Future<void> _setUser() async {
    try {
      await RiviumAbTesting.instance.setUserId('user-premium-123');
      _log('User ID set: user-premium-123');

      // Attributes match targeting rules from test scenario:
      // - country "in" ["US","CA"] on checkout experiment
      // - plan "equals" "premium" on dark_mode flag
      // - age >= 18 on checkout experiment
      RiviumAbTesting.instance.setUserAttributes({
        'plan': 'premium',
        'country': 'US',
        'age': 25,
        'appVersion': '2.1.0',
        'platform': 'flutter',
      });
      _log('User attributes set (premium, US, age=25)');
    } catch (e) {
      _log('Set user failed: $e');
    }
  }

  // ============================================
  // 3. EXPERIMENT — Checkout Flow Test
  //    (targeting: country in [US,CA], age >= 18)
  // ============================================

  Future<void> _getCheckoutVariant() async {
    try {
      final variant = await RiviumAbTesting.instance.getVariant(
        experimentCheckout,
        defaultVariant: 'control',
      );
      setState(() => _currentVariant = variant);
      _log('Checkout variant: $variant');
    } catch (e) {
      _log('Get checkout variant failed: $e');
    }
  }

  Future<void> _getCheckoutConfig() async {
    try {
      final config =
          await RiviumAbTesting.instance.getVariantConfig(experimentCheckout);
      setState(() => _variantConfig = config);
      _log('Checkout config: $config');
      if (config != null) {
        _log('  layout: ${config["layout"]}');
        _log('  button_color: ${config["button_color"]}');
      }
    } catch (e) {
      _log('Get checkout config failed: $e');
    }
  }

  // ============================================
  // 4. EXPERIMENT — Pricing Page Test
  //    (no targeting rules, 100% traffic)
  // ============================================

  Future<void> _getPricingVariant() async {
    try {
      final variant = await RiviumAbTesting.instance.getVariant(
        experimentPricing,
        defaultVariant: 'control',
      );
      _log('Pricing variant: $variant');
    } catch (e) {
      _log('Get pricing variant failed: $e');
    }
  }

  // ============================================
  // 5. LIST EXPERIMENTS
  // ============================================

  Future<void> _getExperiments() async {
    try {
      final experiments = RiviumAbTesting.instance.getExperiments();
      _log('Experiments (${experiments.length}):');
      for (final exp in experiments) {
        _log('  - ${exp.name} [${exp.status.name}] '
            '(${exp.variants.length} variants, '
            '${exp.trafficAllocation}% traffic)');
      }
    } catch (e) {
      _log('Get experiments failed: $e');
    }
  }

  // ============================================
  // 6. CORE EVENT TRACKING (checkout experiment)
  // ============================================

  Future<void> _trackView() async {
    try {
      await RiviumAbTesting.instance.trackView(experimentCheckout);
      _log('Tracked: VIEW ($experimentCheckout)');
    } catch (e) {
      _log('Track view failed: $e');
    }
  }

  Future<void> _trackClick() async {
    try {
      await RiviumAbTesting.instance.trackClick(experimentCheckout);
      _log('Tracked: CLICK ($experimentCheckout)');
    } catch (e) {
      _log('Track click failed: $e');
    }
  }

  Future<void> _trackConversion() async {
    try {
      await RiviumAbTesting.instance.trackConversion(
        experimentCheckout,
        value: 49.99,
      );
      _log('Tracked: CONVERSION (\$49.99)');
    } catch (e) {
      _log('Track conversion failed: $e');
    }
  }

  Future<void> _trackCustomEvent() async {
    try {
      await RiviumAbTesting.instance.trackCustomEvent(
        experimentCheckout,
        'button_hover',
        properties: {'duration_ms': 1500, 'element': 'cta_button'},
      );
      _log('Tracked: CUSTOM (button_hover)');
    } catch (e) {
      _log('Track custom event failed: $e');
    }
  }

  // ============================================
  // 7. ENGAGEMENT EVENTS
  // ============================================

  Future<void> _trackEngagementEvents() async {
    try {
      await RiviumAbTesting.instance.trackScroll(
        experimentCheckout,
        depth: 75.0,
        properties: {'page': 'product_detail'},
      );
      _log('Tracked: SCROLL (depth: 75%)');

      await RiviumAbTesting.instance.trackFormSubmit(
        experimentCheckout,
        formName: 'shipping_address',
        properties: {'fields_count': 5},
      );
      _log('Tracked: FORM_SUBMIT (shipping_address)');

      await RiviumAbTesting.instance.trackSearch(
        experimentCheckout,
        query: 'express shipping',
        properties: {'results_count': 3},
      );
      _log('Tracked: SEARCH (express shipping)');

      await RiviumAbTesting.instance.trackShare(
        experimentCheckout,
        method: 'copy_link',
        properties: {'content_id': 'product-456'},
      );
      _log('Tracked: SHARE (copy_link)');
    } catch (e) {
      _log('Engagement tracking failed: $e');
    }
  }

  // ============================================
  // 8. E-COMMERCE EVENTS
  // ============================================

  Future<void> _trackEcommerceEvents() async {
    try {
      await RiviumAbTesting.instance.trackAddToCart(
        experimentCheckout,
        value: 49.99,
        productId: 'SKU-001',
        properties: {'quantity': 2, 'category': 'electronics'},
      );
      _log('Tracked: ADD_TO_CART (SKU-001, \$49.99)');

      await RiviumAbTesting.instance.trackRemoveFromCart(
        experimentCheckout,
        value: 49.99,
        productId: 'SKU-001',
      );
      _log('Tracked: REMOVE_FROM_CART (SKU-001)');

      await RiviumAbTesting.instance.trackBeginCheckout(
        experimentCheckout,
        value: 149.97,
        properties: {'items_count': 3, 'coupon': 'SAVE10'},
      );
      _log('Tracked: BEGIN_CHECKOUT (\$149.97)');

      await RiviumAbTesting.instance.trackPurchase(
        experimentCheckout,
        value: 134.97,
        transactionId: 'TXN-12345',
        properties: {
          'items_count': 3,
          'payment_method': 'credit_card',
          'currency': 'USD',
        },
      );
      _log('Tracked: PURCHASE (TXN-12345, \$134.97)');
    } catch (e) {
      _log('E-commerce tracking failed: $e');
    }
  }

  // ============================================
  // 9. MEDIA EVENTS
  // ============================================

  Future<void> _trackMediaEvents() async {
    try {
      await RiviumAbTesting.instance.trackVideoStart(
        experimentCheckout,
        videoId: 'onboarding-video',
        properties: {'duration': 120, 'quality': '1080p'},
      );
      _log('Tracked: VIDEO_START (onboarding-video)');

      await RiviumAbTesting.instance.trackVideoComplete(
        experimentCheckout,
        videoId: 'onboarding-video',
        properties: {'watch_time': 118},
      );
      _log('Tracked: VIDEO_COMPLETE (onboarding-video)');
    } catch (e) {
      _log('Media tracking failed: $e');
    }
  }

  // ============================================
  // 10. AUTH EVENTS
  // ============================================

  Future<void> _trackAuthEvents() async {
    try {
      await RiviumAbTesting.instance.trackSignUp(
        experimentCheckout,
        method: 'google',
        properties: {'referral': 'organic'},
      );
      _log('Tracked: SIGN_UP (google)');

      await RiviumAbTesting.instance.trackLogin(
        experimentCheckout,
        method: 'email',
        properties: {'remember_me': true},
      );
      _log('Tracked: LOGIN (email)');

      await RiviumAbTesting.instance.trackLogout(
        experimentCheckout,
        properties: {'session_duration': 3600},
      );
      _log('Tracked: LOGOUT');
    } catch (e) {
      _log('Auth tracking failed: $e');
    }
  }

  // ============================================
  // 11. GENERIC TRACKING
  // ============================================

  Future<void> _trackGenericEvent() async {
    try {
      await RiviumAbTesting.instance.track(
        experimentCheckout,
        EventType.custom,
        eventName: 'page_load_time',
        eventValue: 2.3,
        properties: {'page': '/checkout', 'cached': false},
      );
      _log('Tracked: GENERIC (page_load_time, 2.3s)');
    } catch (e) {
      _log('Generic tracking failed: $e');
    }
  }

  // ============================================
  // 12. FEATURE FLAGS (via AbTest SDK proxy)
  //     Billed under riviumABTesting
  // ============================================

  Future<void> _testFeatureFlags() async {
    try {
      // Boolean flag with targeting (plan = premium, 50% rollout)
      final darkMode = await RiviumAbTesting.instance.isFeatureEnabled(
        flagDarkMode,
        defaultValue: false,
      );
      _log('Flag "$flagDarkMode" enabled: $darkMode');

      // Multivariate flag (3 variants: control 60%, video 25%, interactive 15%)
      final onboarding = await RiviumAbTesting.instance.getFeatureValue(
        flagOnboardingFlow,
        defaultValue: 'classic_onboarding',
      );
      _log('Flag "$flagOnboardingFlow" value: $onboarding');

      // Dependent flag (requires dark_mode to be enabled)
      final darkSettings = await RiviumAbTesting.instance.isFeatureEnabled(
        flagDarkModeSettings,
        defaultValue: false,
      );
      _log('Flag "$flagDarkModeSettings" enabled: $darkSettings '
          '(depends on dark_mode=$darkMode)');

      // Scheduled flag (should be OFF until scheduled date)
      final holiday = await RiviumAbTesting.instance.isFeatureEnabled(
        flagHolidayBanner,
        defaultValue: false,
      );
      _log('Flag "$flagHolidayBanner" enabled: $holiday (scheduled)');

      // Get all flags
      final flags = await RiviumAbTesting.instance.getFeatureFlags();
      _log('All flags (${flags.length}):');
      for (final flag in flags) {
        _log('  - ${flag.key}: enabled=${flag.enabled}, '
            'rollout=${flag.rolloutPercentage}%');
      }

      // Refresh from server
      await RiviumAbTesting.instance.refreshFeatureFlags();
      _log('Feature flags refreshed');
    } catch (e) {
      _log('Feature flags test failed: $e');
    }
  }

  // ============================================
  // 13. SYNC & LIFECYCLE
  // ============================================

  Future<void> _flush() async {
    try {
      final pendingCount =
          await RiviumAbTesting.instance.getPendingEventCount();
      _log('Pending events: $pendingCount');

      await RiviumAbTesting.instance.flush();
      _log('Flush completed');

      final remaining = await RiviumAbTesting.instance.getPendingEventCount();
      _log('Remaining events: $remaining');
    } catch (e) {
      _log('Flush failed: $e');
    }
  }

  Future<void> _refreshExperiments() async {
    try {
      await RiviumAbTesting.instance.refreshExperiments();
      _log('Experiments refreshed');
    } catch (e) {
      _log('Refresh failed: $e');
    }
  }

  Future<void> _reset() async {
    try {
      await RiviumAbTesting.instance.reset();
      setState(() {
        _isInitialized = false;
        _currentVariant = null;
        _variantConfig = null;
      });
      _log('SDK reset');
    } catch (e) {
      _log('Reset failed: $e');
    }
  }

  // ============================================
  // 14. MULTI-USER TEST (holdout + exclusion)
  // ============================================

  Future<void> _testMultipleUsers() async {
    _log('=== MULTI-USER TEST (20 users) ===');
    int holdoutCount = 0;
    int checkoutAssigned = 0;
    int pricingAssigned = 0;

    for (int i = 1; i <= 20; i++) {
      await RiviumAbTesting.instance.setUserId('test-user-$i');
      RiviumAbTesting.instance.setUserAttributes({
        'country': 'US',
        'plan': 'premium',
        'age': 25,
      });

      final checkoutVariant = await RiviumAbTesting.instance.getVariant(
        experimentCheckout,
        defaultVariant: 'control',
      );
      final pricingVariant = await RiviumAbTesting.instance.getVariant(
        experimentPricing,
        defaultVariant: 'control',
      );

      final isHoldout =
          checkoutVariant == 'control' && pricingVariant == 'control';
      if (isHoldout) holdoutCount++;
      if (checkoutVariant != 'control') checkoutAssigned++;
      if (pricingVariant != 'control') pricingAssigned++;

      _log('  User $i: checkout=$checkoutVariant, pricing=$pricingVariant');
    }

    _log('--- Summary ---');
    _log('  Possible holdout: $holdoutCount/20');
    _log('  Checkout non-control: $checkoutAssigned/20');
    _log('  Pricing non-control: $pricingAssigned/20');

    // Restore original user
    await RiviumAbTesting.instance.setUserId('user-premium-123');
    _log('Restored user: user-premium-123');
    _log('=== MULTI-USER TEST COMPLETE ===');
  }

  // ============================================
  // 15. RUN ALL — Full test scenario
  // ============================================

  Future<void> _runAllTests() async {
    _log('=== RUNNING FULL TEST SCENARIO ===');
    await _initSDK();
    await _setUser();

    // Experiments
    await _getExperiments();
    await _getCheckoutVariant();
    await _getCheckoutConfig();
    await _getPricingVariant();

    // All event types (18 events)
    await _trackView();
    await _trackClick();
    await _trackConversion();
    await _trackCustomEvent();
    await _trackEngagementEvents();
    await _trackEcommerceEvents();
    await _trackMediaEvents();
    await _trackAuthEvents();
    await _trackGenericEvent();

    // Feature flags (4 flags)
    await _testFeatureFlags();

    // Flush everything
    await _flush();

    _log('=== FULL TEST SCENARIO COMPLETE ===');
    _log('Check billing: ~18 events under riviumABTesting');
    _log('Check billing: flag evals under riviumFlags');
  }

  // ============================================
  // UI
  // ============================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rivium AB Testing'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: () => setState(() => _logs.clear()),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: _isInitialized ? Colors.green.shade50 : Colors.red.shade50,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isInitialized ? Icons.check_circle : Icons.error,
                      color: _isInitialized ? Colors.green : Colors.red,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isInitialized ? 'SDK Initialized' : 'SDK Not Initialized',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _isInitialized ? Colors.green : Colors.red,
                      ),
                    ),
                  ],
                ),
                if (_currentVariant != null)
                  Chip(
                    label: Text('Variant: $_currentVariant'),
                    backgroundColor: Colors.purple.shade50,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                if (_variantConfig != null)
                  Chip(
                    label: Text('Config: ${_variantConfig!.length} keys'),
                    backgroundColor: Colors.blue.shade50,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ),

          // Buttons
          Expanded(
            flex: 1,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSection('Setup', [
                    _buildButton(
                        'Run Full Scenario', _runAllTests, Colors.purple),
                    _buildButton('Init SDK', _initSDK, Colors.blue),
                    _buildButton('Set User', _setUser, Colors.blue),
                  ]),
                  _buildSection('Experiments', [
                    _buildButton(
                        'Checkout Variant', _getCheckoutVariant, Colors.teal),
                    _buildButton(
                        'Checkout Config', _getCheckoutConfig, Colors.teal),
                    _buildButton(
                        'Pricing Variant', _getPricingVariant, Colors.teal),
                    _buildButton(
                        'List Experiments', _getExperiments, Colors.teal),
                    _buildButton('Refresh Experiments', _refreshExperiments,
                        Colors.teal),
                  ]),
                  _buildSection('Core Events', [
                    _buildButton('Track View', _trackView, Colors.orange),
                    _buildButton('Track Click', _trackClick, Colors.orange),
                    _buildButton(
                        'Track Conversion', _trackConversion, Colors.orange),
                    _buildButton(
                        'Track Custom', _trackCustomEvent, Colors.orange),
                    _buildButton(
                        'Track Generic', _trackGenericEvent, Colors.orange),
                  ]),
                  _buildSection('Specialized Events', [
                    _buildButton('Engagement Events', _trackEngagementEvents,
                        Colors.indigo),
                    _buildButton('E-Commerce Events', _trackEcommerceEvents,
                        Colors.indigo),
                    _buildButton(
                        'Media Events', _trackMediaEvents, Colors.indigo),
                    _buildButton(
                        'Auth Events', _trackAuthEvents, Colors.indigo),
                  ]),
                  _buildSection('Feature Flags', [
                    _buildButton(
                        'Test All Flags', _testFeatureFlags, Colors.green),
                  ]),
                  _buildSection('Advanced', [
                    _buildButton('Multi-User Test', _testMultipleUsers,
                        Colors.deepPurple),
                  ]),
                  _buildSection('Lifecycle', [
                    _buildButton('Flush Events', _flush, Colors.amber),
                    _buildButton('Reset SDK', _reset, Colors.red),
                  ]),
                ],
              ),
            ),
          ),

          // Log panel
          Container(
            height: 200,
            width: double.infinity,
            color: Colors.grey.shade900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'Logs (${_logs.length})',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _logs[index],
                        style: TextStyle(
                          color: _logs[index].contains('failed') ||
                                  _logs[index].contains('Error')
                              ? Colors.redAccent
                              : _logs[index].contains('Tracked:')
                                  ? Colors.greenAccent
                                  : _logs[index].contains('===')
                                      ? Colors.amberAccent
                                      : Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: children,
        ),
      ],
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed, Color color) {
    return ElevatedButton(
      onPressed:
          _isInitialized || label == 'Init SDK' || label == 'Run Full Scenario'
              ? onPressed
              : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(fontSize: 12),
      ),
      child: Text(label),
    );
  }
}
