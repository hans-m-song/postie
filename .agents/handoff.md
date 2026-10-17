# Handoff

Updated 2026-10-17. M1–M4 and follow-ups T-52–T-56 are complete locally. Keep commits local; never push without a new request. Prior collection follow-up commitbc4eb54, baseline96624aa. Main alone edits .agents documents. No incomplete worker or worktree.

## Latest delivery: T-56

Referenced-variable summary now has View for full ordinary values, Reveal/Hide for secrets, and full-value Copy for both without requiring Reveal. Decryption only occurs on explicit action. Revealed text and pending operations clear/invalidate on dismissal, tab/navigation/value/scope/request change. Copy intentionally writes plaintext to the system clipboard; hiding does not clear the clipboard. Uses existing AppModel reveal API and unchanged persistence.

Independent review closed captured-tab-state timing using a live Binding and live model selection/value guards; no remaining finding. Independent make test passed82 (Core58/App24), zero failures. Release build passed. Native synthetic checks passed full ordinary View/Copy, secret Copy without Reveal, Reveal/Hide, tab dismissal and compact layout. No new automated tests; no delayed-Keychain fault injection or clipboard-contention test.

## Earlier delivery

Collection Variables/Headers/Auth page; name opens page, arrow expands requests, right-click actions without ellipsis; tighter method inset. Shared headers with request override/disabled suppression; old auth explicit, new requests inherit. Name/Value/Secret trailing-row tables and reversible checkbox. Native URL completion. Evidence/limits: docs/collection-settings.md; roadmap T-56 contains latest verification. M5/cURL/snapshots/T-42 request log/sync remain deferred. Approved local roadmap; no TaskView project.

## Build and isolated artifacts

Normal output dist/Postie.app release/ad-hoc signed. Build root /Volumes/Data/cache/postie-m34; logs /Volumes/Data/tmp/postie-m34/referenced-tests.log, referenced-layout-final.log, referenced-dist-final.log. Swift/Makefile/plist only. Use verified make test; never XCTest help/unverified flags.

New synthetic app .build/referenced-validation/Postie.app, ID dev.postie.validation.references.20261017a, same service suffix .workspace-encryption. Data/bodies only beneath that ignored validation folder; app closed. Prior .build/collection-validation app also closed; fixture12258 stopped. Do not delete synthetic Keychain items automatically. Future validation must launch with explicit --data-directory/--body-directory, never user defaults. No existing user data/keys inspected.

## Constraints and residual limits

Never inspect environment, PII, existing runtime configuration/credentials, .env/.config/.aws/.ssh or existing Keychain items. Only synthetic directories/fakekeys/loopback/exact new services. OS protected dialogs/passwords require user. No comprehensive tests.

IME/light-mode runtime/performance/distribution/TLS/proxy behavior unclaimed. Stable signing needed before promising Keychain continuity across changed binaries. Completion matcher capped, but effective metadata construction scales with configured names. Failed-secret UI fault paths independently source-reviewed rather than native fault-injected.
