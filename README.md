# Rivium AB Testing Flutter SDK

A/B Testing and Feature Flags SDK for Flutter with offline-first sync.

[![pub.dev](https://img.shields.io/pub/v/rivium_ab_testing)](https://pub.dev/packages/rivium_ab_testing)
[![Flutter 3.3+](https://img.shields.io/badge/Flutter-3.3+-blue.svg)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Features

- A/B testing with automatic variant assignment
- Feature flags with targeting rules and rollout percentages
- Sticky bucketing — users stay in the same variant
- Offline-first event queue with automatic sync
- Safe to start before sign-in: the SDK waits for a user token
- 17 built-in event types (view, click, conversion, purchase, etc.)
- Works on **all Flutter platforms** (Android, iOS, Web, macOS, Linux, Windows)

## Installation

```bash
flutter pub add rivium_ab_testing
```

Or add to your `pubspec.yaml`:

```yaml
dependencies:
  rivium_ab_testing: ^0.2.3
```

Then run:

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:rivium_ab_testing/rivium_ab_testing.dart';

// 1. Initialize the SDK
await RiviumAbTesting.init(
  RiviumAbTestingConfig(
    apiKey: 'rv_live_xxx',
    // Your server mints this for the signed-in user (see "User tokens").
    // Return null while no one is signed in.
    tokenProvider: () async {
      if (yourSessionToken == null) return null;
      final res = await http.post(Uri.parse('https://your-api.example.com/rivium-token'),
          headers: {'Authorization': 'Bearer $yourSessionToken'});
      return jsonDecode(res.body)['token'] as String;
    },
  ),
);

// 2. Set user ID: the same id your server puts in the token.
//    Call it again on login, and clearUserId() on logout.
await RiviumAbTesting.instance.setUserId('user-123');

// 3. Get variant for an experiment
final variant = await RiviumAbTesting.instance.getVariant('checkout-redesign');
print('Assigned to: $variant');

// 4. Track conversion
await RiviumAbTesting.instance.trackConversion('checkout-redesign', value: 49.99);

// 5. Force sync pending events
await RiviumAbTesting.instance.flush();
```

## User tokens

The API key ships inside your app, so anyone can read it. On its own it can't
prove which user a request is for. Your server can: it holds your project's
**server secret** and mints a short-lived token for the signed-in user
(`POST https://auth.rivium.co/users/token`, or `createUserToken()` in the
Node.js SDK). The SDK sends it with every request, and the service takes the
user from the token instead of from the app.

The SDK calls `tokenProvider` at start, when it needs a token, again shortly
before it expires, and once more if the service reports it expired. Call
`refreshUserToken()` when the user signs in or out. If you would rather fetch
the token yourself, call `setUserToken(token)` after `init` and again whenever
you refresh it, and `setUserToken(null)` at sign-out.

The user id you pass to `setUserId` must be the id your server puts in the
token. Calling `setUserId` with a different user, a token of a different user,
or `clearUserId()` drops the last user's variants, attributes, token and
pending events before anything is sent for the next user.

A token is **required**: assigning variants, tracking events and
evaluating flags are refused without one (reading the experiment and flag
lists is not, so the app can load them before anyone signs in). The same token works for Rivium Chat and Sync.

**Never put the server secret in the app.**

### Before your user signs in

You can call `init` before anyone is signed in. While there is no token
(`tokenProvider` returned `null` or failed, or none was set) the SDK is
**awaiting a user token**: `getVariant` returns the default variant, flags
come from the cached flag list or their default, events are kept on the device
(up to 1,000) and nothing is sent, and no error is reported. Once a token
arrives the SDK fetches the variants you asked for meanwhile (listen for
`experimentAssigned`) and sends the pending events. Events recorded while no
one was signed in belong to no user and cannot be credited: only events
recorded for the user who signs in are sent, the rest are dropped.

```dart
final ab = RiviumAbTesting.instance;

ab.isAwaitingUserToken;            // true while there is no user token
ab.onAwaitingUserToken(() { });    // called each time the SDK starts waiting

await ab.refreshUserToken();       // after sign-in or sign-out: ask tokenProvider again
await ab.setUserToken(token);      // or hand the token over yourself (null = signed out)
await ab.clearUserId();            // sign-out: forget the user and their data
```

## A/B Testing

### Get Variant

```dart
final variant = await RiviumAbTesting.instance.getVariant(
  'experiment-key',
  defaultVariant: 'control', // returned while the service has not assigned one
);

if (variant == 'variant-a') {
  // Show new design
} else {
  // Show control
}
```

### Get Variant Config

```dart
final config = await RiviumAbTesting.instance.getVariantConfig('experiment-key');
// config is a Map<String, dynamic> set in the Rivium dashboard
```

The service decides the variant, and the SDK remembers it. `getVariant` never
throws: without a user, a user token or a connection it returns the remembered
variant, or `defaultVariant`.

## Feature Flags

```dart
// Check if feature is enabled
final enabled = await RiviumAbTesting.instance.isFeatureEnabled('dark-mode');

// Get feature value (string, number, JSON, etc.)
final value = await RiviumAbTesting.instance.getFeatureValue(
  'max-upload-size',
  defaultValue: 10,
);

// Get all flags
final flags = await RiviumAbTesting.instance.getFeatureFlags();

// Refresh flags from server
await RiviumAbTesting.instance.refreshFeatureFlags();
```

## Event Tracking

Track user interactions with 17 built-in event types:

```dart
// Core events
await RiviumAbTesting.instance.trackView('experiment-key');
await RiviumAbTesting.instance.trackClick('experiment-key');
await RiviumAbTesting.instance.trackConversion('experiment-key', value: 99.99);

// Custom event
await RiviumAbTesting.instance.trackCustomEvent(
  'experiment-key',
  'button_tap',
  properties: {'button': 'subscribe'},
);

// E-commerce events
await RiviumAbTesting.instance.trackAddToCart('experiment-key', value: 29.99, productId: 'sku-123');
await RiviumAbTesting.instance.trackPurchase('experiment-key', value: 59.99, transactionId: 'txn-456');
await RiviumAbTesting.instance.trackRemoveFromCart('experiment-key', value: 29.99);
await RiviumAbTesting.instance.trackBeginCheckout('experiment-key', value: 59.99);

// Engagement events
await RiviumAbTesting.instance.trackScroll('experiment-key', depth: 0.75);
await RiviumAbTesting.instance.trackFormSubmit('experiment-key', formName: 'signup');
await RiviumAbTesting.instance.trackSearch('experiment-key', query: 'shoes');
await RiviumAbTesting.instance.trackShare('experiment-key', method: 'twitter');

// Media events
await RiviumAbTesting.instance.trackVideoStart('experiment-key', videoId: 'vid-001');
await RiviumAbTesting.instance.trackVideoComplete('experiment-key', videoId: 'vid-001');

// Auth events
await RiviumAbTesting.instance.trackSignUp('experiment-key', method: 'google');
await RiviumAbTesting.instance.trackLogin('experiment-key', method: 'email');
await RiviumAbTesting.instance.trackLogout('experiment-key');
```

### Generic Event Tracking

```dart
await RiviumAbTesting.instance.track(
  'experiment-key',
  EventType.custom,
  eventName: 'my_event',
  eventValue: 42.0,
  properties: {'key': 'value'},
);
```

## User Attributes

Set attributes for targeting rules:

```dart
await RiviumAbTesting.instance.setUserId('user-123');

RiviumAbTesting.instance.setUserAttributes({
  'plan': 'premium',
  'country': 'US',
  'age': 28,
});
```

## Offline Support

Events are queued locally and automatically synced when the device comes online:

```dart
// Check online status
final online = RiviumAbTesting.instance.isOnline;

// Get number of pending events
final pending = await RiviumAbTesting.instance.getPendingEventCount();

// Force sync
await RiviumAbTesting.instance.flush();
```

## Lifecycle

```dart
// Initialize with debug logging
await RiviumAbTesting.init(
  RiviumAbTestingConfig(apiKey: 'rv_live_xxx', tokenProvider: fetchRiviumToken),
  callback: (event, data) {
    print('SDK event: $event, data: $data');
  },
);

// Refresh experiments from server
await RiviumAbTesting.instance.refreshExperiments();

// Get all experiments
final experiments = RiviumAbTesting.instance.getExperiments();

// Reset all state (clears cache, assignments, events)
await RiviumAbTesting.instance.reset();

// Dispose when done
RiviumAbTesting.instance.dispose();
```

## API Reference

| Method | Description |
|---|---|
| `RiviumAbTesting.init(config)` | Initialize the SDK |
| `setUserId(id)` | Set user ID for assignment |
| `clearUserId()` | Forget the user at sign-out |
| `getUserId()` | Get current user ID |
| `isAwaitingUserToken` | True while there is no user token |
| `onAwaitingUserToken(callback)` | Called when the SDK starts waiting for a token |
| `setUserToken(token)` | Hand over a user token (`null` = signed out) |
| `refreshUserToken()` | Ask `tokenProvider` again, after sign-in or sign-out |
| `setTokenProvider(provider)` | Set or remove the token provider after `init` |
| `setUserAttributes(attrs)` | Set targeting attributes |
| `getVariant(key)` | Get assigned variant |
| `getVariantConfig(key)` | Get variant configuration |
| `isFeatureEnabled(key)` | Check if feature flag is on |
| `getFeatureValue(key)` | Get feature flag value |
| `getFeatureFlags()` | Get all feature flags |
| `refreshFeatureFlags()` | Refresh flags from server |
| `refreshExperiments()` | Refresh experiments from server |
| `getExperiments()` | Get all experiments |
| `flush()` | Force sync pending events |
| `reset()` | Clear all state and cache |
| `dispose()` | Release resources |

## Documentation

- [Rivium Console](https://console.rivium.co)
- [Flutter SDK Docs](https://console.rivium.co/dashboard/rivium-abtest/docs/flutter)

## License

MIT
