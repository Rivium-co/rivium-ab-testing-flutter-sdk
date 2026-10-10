## 0.2.2

- Waits for a user token when the app starts before sign-in: `getVariant` returns
  your default and events are kept until a token arrives. New
  `isAwaitingUserToken`, `onAwaitingUserToken()`, `setUserToken()`,
  `refreshUserToken()`, `setTokenProvider()` and `clearUserId()`;
  `tokenProvider` may return `null`.
- `getVariant` and the `track…` methods no longer throw without a user id.
- Variants are decided by the service only; without an answer the SDK returns
  the cached assignment or your default.
- Sign-out and user switch clear the previous user's variants, attributes and
  pending events.
- The event queue holds at most 1,000 events, sends them in batches and backs
  off when the service is busy.
- `baseUrl` must be https (plain http only for localhost).

## 0.2.0

- Signed user tokens: new `tokenProvider` option. Your server mints a Rivium user token and the SDK sends it with every request. Required for assigning variants, tracking and flag evaluation.
- `setUserId` with a different user now clears the previous user's variants and token.
- Fixed server-side assignment and event sync.

## 0.1.0+2

- Comprehensive README with full usage examples and API reference

## 0.1.0+1

- Updated documentation and README

## 0.1.0

- Initial release
- A/B testing with experiment variants and sticky assignments
- Feature flags with targeting rules and rollout percentages
- All 17 event types (view, click, conversion, custom, scroll, form_submit, search, share, add_to_cart, remove_from_cart, begin_checkout, purchase, video_start, video_complete, sign_up, login, logout)
- Offline-first event queue with automatic sync
- Local bucketing with MD5 hash
- Works on all Flutter platforms (Android, iOS, Web, macOS, Linux, Windows)
