# M1/M2 implementation checkpoint

Historical checkpoint: this records M1/M2 implementation and verification as of 2026-10-17. For current product status and open acceptance checks, see the [overview](overview.md).

## Baseline review completion — 2026-10-17

See [baseline-review.md](baseline-review.md) for the independent security/architecture/UI reviews and dispositions. Corrected body selection/undo across Settings, retained-state collection deletion, unused binary hex allocation and unbounded fixture teardown; added explicit Rename request… action. Final SwiftPM test run passed46 tests with zero failures (Core38/AppModel8), closing the earlier driver-completion limitation below. Release bundle built, signature verified and native rename/Cancel/restart plus editor-selection/undo checked in an isolated workspace. One new functional regression was added; no comprehensive coverage expansion.

User subsequently requested Swift/Makefile tooling. Removed both Python helpers: `make app` packages the release bundle using packaging/Info.plist; tests automatically build/run PostieHTTPFixture, a separate Swift executable. Final `make test` passes all 46 tests; `make app`, strict signature verification, isolated launch and `make fixture` startup passed. Build overrides are documented in README.md. Generated fixture binaries are not part of the app bundle.

## Approved usability follow-up — complete locally, 2026-10-17

- [x] T-36: trailing editable blank query/header rows, continuous entry and keyboard focus.
- [x] T-37: whole disclosure-heading click targets; response headers collapsed initially.
- [x] T-38: manual one-hop redirect from captured request, preserving settings and observed chain.
- [x] T-39: default data at ~/.config/postie; keep explicit directory overrides; no silent migration/merge.
- [x] T-40: :name whole-path-segment parameters, encoded values, missing/duplicate diagnostics, persistence.
- [x] T-41: full-width method/URL/Send toolbar above both panes; fix user-reported narrow-window clipping with compact layout constraints.
- [x] Independent verification/review, rebuilt bundle and real UI checks.
- [x] T-43: Request/Settings tabs with execution options in Settings.
- [x] T-44: response pane fills assigned width without redundant right-side gap.
- [x] T-45/T-46: response/request bodies grow vertically, one vertical scroll owner per pane, native editing/undo intact.

T-42 session request log is recorded but deferred. No runtime config inspection or migration is authorised by this implementation. Path parameters are separate from future {{variable}} substitution. Existing stored requests without path parameter metadata must continue loading. Manual redirect follows the captured hop without consulting changed draft data or repeating the origin request. Keep existing 10-hop/cross-origin credential policy. Primary reference: [RFC 9110 redirect semantics](https://www.rfc-editor.org/rfc/rfc9110.html#name-redirection-3xx).

Started 2026-10-17. User explicitly authorised implementation of M1/M2 with subagents and delegated remaining decisions using best judgement. Paste cURL is deferred. No M3–M5 functionality is implied by this authorisation.

## Scope and decisions

### Usability completion evidence — 2026-10-17

- Final rebuilt test products passed independently via direct XCTest bundle invocation: Core 38/38 (3.142 seconds), AppModel 7/7 (0.581 seconds), zero failures. The final SwiftPM driver rebuilt in 1.82 seconds but emitted no case output within a 30-second bound and was stopped; this is not a passing driver result. Its build-only log is `/Volumes/Data/tmp/postie-usability-validation/full-test-final-ui.log`. An earlier full 45-test run passed before the final native editor changes; latest direct bundle results supersede it for behavioral verification.
- Unsupported file-scheme redirects sometimes fail before Foundation calls the redirect delegate. The narrow test now uses explicit 1-second inactivity/2-second overall limits and a 4-second collector bound. It accepts only the known sanitized failure or a completed, non-followable HTTP response; arbitrary failures are not accepted. Production redirect behavior was not weakened.
- Independent source reviews closed all substantiated findings. Final debug bundle built and `codesign --verify --strict dist/Postie.app` passed. Native checks covered continuous query/header entry, encoded path values, collapsed headers and whole-heading clicks, captured manual redirect despite changed draft, full-width toolbar, Settings persistence, cancellation, and stable editing across model ticks.
- Both bodies now grow vertically under their pane's sole outer vertical scrollbar. Response raw text retains horizontal scrolling and the 1 MiB preview bound. Native request checks covered 80-line paste, undo/redo, caret reveal, raw text preservation and switching requests. The measured response width gap was removed using an AppKit split with persistent SwiftUI hosts.
- The observed compact layout at 1120×772 was checked. Exact 900×600/1000×700 resizing and IME composition were not exercised; minimum constraints and composition protection were source-reviewed. No user runtime data was inspected or migrated.
- Tester accidentally invoked an XCTest usage diagnostic that printed environment values in tool output. User was informed; tester confirmed no such data was saved to project files or validation logs. The diagnostic was not repeated or used.

- Build a dependency-free SwiftPM macOS app with PostieCore and PostieApp targets. One package, no external dependencies or package framework. macOS 27.0 deployment baseline matches the verified 27.0.1 build host; Xcode reports 27.0/Swift 6.4. Validate compilation before claiming runnable support.
- Bundle a locally runnable .app for verification. Do not inspect signing identities or Keychain. Encryption/auth/scoped variable resolution are M3 and excluded; unexpanded variable tokens must not silently be sent.
- Use the accepted v3 side-by-side/stacked layout; raw native text editing is sufficient for M1/M2. Syntax highlighting, palette, snapshots and cURL remain later milestones. Avoid fake working controls for deferred features.
- Implement independent per-request runs, single-flight by identity, progress/cancel, observed redirect headers, 10-hop limit and cross-origin auth stripping. Cache/cookie persistence disabled; HTTP/HTTPS only. Explicit header/query rows preserve order; concrete platform header fidelity is bounded by URLSession.
- File-backed response body storage and bounded preview; no persisted response history. Approved time/byte defaults apply. A null overall timeout/byte cap disables that app-level limit; inactivity timeout stays a positive finite value. Keep actual API configuration finite where required.
- Persistence uses UUID collection directories, ordered collection.json IDs and per-request JSON, atomic file replacement, explicit orphan recovery and no automatic resurrection. Unsupported/malformed files are preserved. A process-lifetime OS lock prevents competing writers; second instance presents an error rather than writing.
- Keep the test fixture local and synthetic: GET/POST echo, redirects/loop/cross-origin, delayed/large/unknown-length bodies; no public request execution. Focused fault/restart persistence tests use isolated temporary directories. Test and GUI runs must use explicit isolated data directories, not any existing user app data.

## Interfaces and ownership

Main agent owns Package.swift, Models.swift, integration, packaging and durable docs. Workers own HTTP execution, persistence, and UI in separate files. Public model definitions are in Sources/PostieCore/Models.swift. Any interface change must be coordinated first.

## Checklist

- [x] Inspect workspace/toolchain and document authorised boundary.
- [x] Define shared value models and package targets.
- [x] Implement/verify HTTP execution and file-backed body lifecycle.
- [x] Implement/verify collections, index recovery and autosave persistence.
- [x] Implement native editor, concurrent-run UI and activity navigation.
- [x] Integrate and independently test/review.
- [x] Launch isolated app and inspect real UI against the accepted layout.
- [x] Update milestone evidence, handoff and material decisions.

## Completion evidence — 2026-10-17

M1 and M2 are complete locally: T-01–T-11, T-29, T-33 and T-34. Text/JSON payload bytes use raw editing; syntax selection/highlighting is M4.

- Independent verification passed 36 tests, zero failures: 30 core (12 HTTP integration, 5 preview, 5 preparation, 8 store) and 6 app-model tests. Log: `/Volumes/Data/tmp/postie-verify-2026-10-17/logs/swift-test-frozen-final.log`.
- Checks cover GET/POST, raw query fidelity, 302/307 method handling, redirects disabled/10-hop cap/cross-origin credential stripping, concurrency/single-flight, cancel/rerun, idle/overall/byte limits, large/chunked/binary responses, bounded previews and owned-session cleanup. Store/model checks cover restart, writer locks, unknown/malformed/future documents, explicit orphan recovery, failed writes/partial deletion, autosave ordering, navigation, overlapping CRUD, failed termination saves and draft retention when membership is unknown.
- Independent review identified and verified fixes for nullable-cap persistence, transient body cleanup, partial-delete UI state, final effective method, cancelled-state presentation, query encoding, uncertain-membership draft retention and termination draining accepted structural mutations. Final independent source review found no blocking findings.
- At the 2026-10-17 checkpoint, the final debug app rebuilt after fixes and `codesign --verify --strict dist/Postie.app` passed; that build occupied approximately 4 MiB on disk. This is a historical artifact-size observation, not a current measurement. No distribution signature/notarisation or performance benchmark is claimed.
- Actual native UI exercised in a fresh synthetic loopback workspace: successful GET; collapsed redirects/final expanded; intermediate headers; two concurrent downloads; disabled Send for the running identity; Open Request navigation; Cancel from editor and activity list; accurate zero-active state; last name edit preserved through quit/rebuild/restart. Final build visibly displays `200 OK`. Structure matches the accepted side-by-side/stacked direction, without a claim of pixel parity with generated concepts.

## Decisions and verification limits for review

- Minimum deployment is macOS 27.0, matching the available macOS 27.0.1/Xcode 27/Swift 6.4 host. Older macOS support is unverified. This is a reversible implementation choice.
- No focused deterministic test covers termination racing an accepted structural mutation or its 10-second drain timeout. Independent source review verified ordering; timeout keeps the app open with an error. Unreadable metadata shares the malformed-metadata protective path but has no separate app-model test.
- Only synthetic local endpoints and isolated data/body directories were used. No user runtime configuration, signing identities or Keychain contents were inspected. A later tester diagnostic accidentally printed process environment values; see the usability verification notes below. Real-server TLS/proxy behaviour and arbitrary disk/power-loss failures are not exhaustively exercised.
- Header sets reflect Foundation APIs, not exact wire bytes. Automatic cookies/cache are disabled. Null overall/byte limits disable app-level enforcement; OS/network limits still apply.
- Initial M1/M2 default was user Application Support/Postie; the completed usability follow-up changes this to ~/.config/postie without migration. Bodies use temporary-directory/Postie. Directory arguments override both. Packaging allows explicit HTTP through `NSAllowsArbitraryLoads`; normal HTTPS certificate validation remains enabled. The helper builds/stages an ad-hoc bundle without launching it.
- M3–M5 remain unimplemented: variables/auth/encryption, syntax selectors/highlighting, palette, snapshots and cURL import/export. Literal headers/bodies persist as entered; this slice does not claim secret encryption. BodySyntax is persisted model metadata without editor behaviour yet.

Direct Xcode Swift binaries avoid xcrun cache warnings. Nested manifest sandboxing failed with `sandbox-exec: sandbox_apply: Operation not permitted`; the trusted dependency-free build uses `--disable-sandbox`. The outer tool sandbox also blocked generated manifests/maps, so auto-review approved build/test invocations outside it with explicit isolated cache/config/security paths and credential stores disabled. No approval rejection occurred.
