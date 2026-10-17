# Handoff

Updated 2026-10-17. M1–M4 are complete locally. Final native focus/drawing checks, independent66 functional tests, release build and strict signature passed. No incomplete worker. See docs/implementation-m3-m4.md for decisions, audits and residual limits. Computer Use blocks UserNotificationCenter; OS volume permissions require the user, and login passwords require handoff.

## Scope and state

M3/M4 adds three variable scopes, single-pass templates, Basic/Bearer, encrypted values/Keychain key, native None/JSON/template/path highlighting, Raw/Pretty, variable-source summary and Command-K search. M5/cURL/snapshots/T-42 log remain deferred. Local roadmap is approved; no TaskView project. Local completion commit on main records this work; prior commit52b90df. Keep commits local, never push without a new request. Main alone edits .agents docs. No worktree created.

## Verification

Independent security review found no substantiated blocker. Independent UI review found identity reuse, double-debounce edit loss and editable busy secret inputs; corrected and rechecked. Full tests exposed non-atomic workspace publication; fixed without weakening old tests. Final independent make test passes66 (Core53/App13), zero failures; diff check passes. Only main functional tests added.

Native passed: loopback scoped/path/body/header substitution, Bearer, secret conversion, same-binary restart/decryption, ordinary edit/immediate quit, URL variable/path/missing colors, body undo across syntax changes, None retaining template cues, search path/arrow/Return/no-match/Escape restoring selection, compact syntax/response layout. Native row promotion lost focus and URL editing doubled glyphs; State focus/transition guards/idle drawing repairs passed full header entry and Tab, hidden-tab input isolation, and single-draw URL editing with missing cues. Bounded metadata-only variable source summary showed correct scope precedence.

Actual new-service Keychain creation and same-binary restart passed. Resigned ad-hoc rebuild prompted for access; user reported approval. Unattended update continuity is not established. Never weaken ACLs; stable signing remains future work. No existing user keys queried.

## Build and isolated artifacts

make app/test/fixture; override SWIFT/BUILD_DIR/APP_DIR/CONFIGURATION. Swift /Volumes/Data/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift. Build root /Volumes/Data/cache/postie-m34, TMPDIR /Volumes/Data/tmp/postie-m34. Trusted builds need escalation for manifests/maps; Makefile disables credential stores. Implementation/tooling Swift/Makefile/plist only.

dist/Postie.app is release, macOS27.0+, ad-hoc signed; final strict signature passed. Synthetic logs /Volumes/Data/tmp/postie-m34/independent-tests.log and release-build-final.log.

Synthetic apps /Volumes/Data/cache/postie-m34-validation/Postie.app (dev.postie.validation.m34.20261017a; dedicated Keychain service suffix .workspace-encryption) and /Volumes/Data/cache/postie-m34-visual/Postie.app (dev.postie.validation.m34.visual; use ordinary Other request only) are closed. Matching data/bodies below /Volumes/Data/tmp/postie-m34-validation and postie-m34-visual. Always launch with explicit directory overrides, never default user config. Old validation cleanup had one automatic-review timeout then a successful verified retry. Do not delete synthetic Keychain items automatically.

Fixture session57799 at127.0.0.1:57501 was intentionally stopped with Ctrl-C. No validation services remain running.

## Next actions

M5 is next when authorised: cURL export, later import and immutable snapshots per roadmap. Stable signing is needed before promising unattended Keychain continuity across updates. No further M3/M4 implementation task is pending; do not broaden tests or revisit TaskView without a new request.

## Constraints and limits

Never inspect environment, PII, existing runtime config/credentials, .env/.config/.aws/.ssh or enumerate Keychain. Synthetic stores/new exact services only. Never use XCTest help/unverified flags (historical baseline diagnostic violated environment ban; not repeated). Use make test.

No IME/light-mode runtime/performance/distribution/TLS/proxy claim. Formatting cap5MiB input/output, highlight1MiB UTF-8, raw preview1MiB; response files remain complete. Cancellation/deletion test asserts model ownership but lacks endpoint-hit counter. API headers are not wire-exact. Config without its Keychain key cannot recover secrets.
