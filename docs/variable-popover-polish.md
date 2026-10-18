# Variable popover presentation

Approved 2026-10-18. T-68–T-69 are complete locally.

- [x] T-68 implementation: autocomplete shows a bounded ordinary-value preview below each name, scope on the right, and a lock/Secret indicator instead of secret values. Effective scope precedence is unchanged; completion never decrypts values. At most six rows are visible, with scrolling through up to 20 matches and keyboard selection scrolled into view.
- [x] T-69 implementation: compact native inspector with a single-line value field and source/navigation footer. Secrets remain masked until the eye action is clicked. Remove the oversized title and gray scroll area; preserve token anchoring, editing focus, dismissal and stale-result guards.
- [x] Focused functional verification, independent source review/scope audit and release build/signature.
- [x] Native visual/keyboard checks and local commit.

The inspector uses intrinsic content height, with an additional error line when needed. Scope navigation remains explicit and never sends. Body inspection, extra editor features, M5 and memory-budget work remain outside this slice. Validation uses synthetic directories/values and a new validation-only Keychain service if secret checks are needed.

Native sizing uses [NSHostingView intrinsic sizing](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions) and the popover's [content size](https://developer.apple.com/documentation/appkit/nspopover/contentsize). The read-only field and action controls do not become the initial keyboard responder.

## Verification checkpoint — 2026-10-18

Independent `make test` passed 109 tests (Core61/App48), zero failures, after correcting the Xcode 27 API spelling to `scrollToVisible`. New tests cover ordinary preview bounding/whitespace, secret preview exclusion and effective scope. Source review and scope audit found no blocking findings. Release build and strict signature verification passed; normal output is dist/Postie.app.

Final integrated verification passed 115 tests (Core61/App54), zero failures or compiler warnings. Native checks confirmed ordinary previews, keyboard selection through eight matches, compact ordinary/secret inspectors, retained input focus, definition navigation and explicit synthetic secret Reveal/Hide. The masked inspector exposes a constant eight bullets. Pointer selection after manual scrolling and error-line resizing were not exercised.

The initial automation lookup stalled and attached to an instance without validation-directory arguments; it stopped at the workspace lock. That instance was closed. The final isolated launch arguments were verified before UI checks. No user configuration or existing Keychain items were accessed. A new validation-only encryption key was created for synthetic values; do not delete it automatically. The test app was closed and temporary keep-awake assertion stopped.
