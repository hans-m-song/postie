# Handoff

Updated 2026-10-17. M1/M2, usability T-36–T-41/T-43–T-46, baseline review T-47, rename T-48 and Swift/Makefile tooling T-49 are complete locally. No worker remains incomplete. Git origin is https://github.com/hans-m-song/postie.git and branch main; consult Git history/status for publication state.

## Read first

docs/baseline-review.md records current reviews, findings, verification and limitations. docs/implementation.md includes historical milestone evidence; docs/roadmap.md tracks deferred work. docs/interfaces.md and docs/structure.md describe current boundaries. Main alone edits this handoff and log.

## Current deliverable and verification

dist/Postie.app is the release bundle, macOS27.0+, ad-hoc signature verified. Final make test passed all46 tests (Core38/AppModel8), zero failures, using the Swift fixture. Make app built in13.06seconds; strict signature and isolated launch passed. Make fixture emitted its loopback port, then was intentionally stopped.

Independent security, architecture/performance and UI/specification reviews closed substantiated findings. Corrected retained-request collection deletion, body selection/undo across Settings, unused binary formatting and fixture teardown. Explicit Rename request… works through the sidebar context menu; native Save/Cancel/restart and editor selection/undo/redo passed.

## Build and tests

Run from repository root: make app, make test, make fixture. Override SWIFT, BUILD_DIR, APP_DIR, CONFIGURATION on the make command line. All project implementation/tooling is Swift or Makefile/plist; both Python helpers were removed. PostieHTTPFixture is a separate test product, not bundled with the app. Tests launch its sibling executable automatically.

Latest isolated build root: /Volumes/Data/cache/postie-native-baseline; TMPDIR /Volumes/Data/tmp/postie-native-baseline. Restricted agent builds need authorised escalation for generated SwiftPM manifests/maps; credential stores remain disabled. Direct Swift: /Volumes/Data/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift.

The final isolated GUI used /Volumes/Data/cache/postie-baseline-validation/Postie.app and /Volumes/Data/tmp/postie-baseline-validation data/bodies; it was closed after checks. Never open user runtime data to reproduce these checks.

## Limits and standing constraints

Default data ~/.config/postie via Foundation home directory, no automatic migration/merge; explicit directory overrides remain. Literal configuration is plaintext. Auth/variables/encryption, syntax/highlighting/palette, snapshots/cURL and T-42 session log remain deferred. M1/M2 approval does not authorise them.

Only synthetic loopback and isolated workspaces exercised. TLS/proxy/power-loss behavior, exact900×600 sizing and IME remain unverified;900×652 layout observed. Termination mutation-race/10second timeout is source-reviewed only. Headers represent Foundation APIs, not wire bytes. No distribution/notarisation or performance benchmark claimed. Fixture startup still uses a blocking readiness read; teardown is bounded.

A tester violated the ban on unverified XCTest flags and printed environment values to tool output/a temporary log. Tester reported deleting the log; main stopped the agent and informed the user. No values reused or recorded in repository. Never repeat that diagnostic. Future test invocations must use verified SwiftPM commands; never inspect env/runtime config/credentials/PII/Keychain.

Local roadmap remains approved; no TaskView project created. Build/runtime artifacts are ignored; initial baseline includes source, tests, docs and prior visual concepts. No worktree created or pruned.
