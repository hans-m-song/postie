# Handoff

Updated 2026-10-17. M1–M4 and collection follow-up T-52–T-55 are complete locally. Keep commits local, never push without a new request. Prior baseline commit96624aa; final local commit records the follow-up. Canonical decisions/reviews/limits: docs/collection-settings.md. Main alone edits .agents documents.

## Delivered

Collection Variables/Headers/Auth page; name opens page, arrow expands requests, right-click actions and no ellipsis. Request method inset tightened. Shared headers with case-insensitive request override and disabled-row suppression. Request auth Inherit/None/Basic/Bearer; old requests explicit, newly created inherit. Name/Value/Secret tables with trailing entry rows and reversible checkboxes. Native URL autocomplete with scope/secret metadata, keyboard acceptance and undo.

## Verification

Independent final make test passed82 (Core58/App24), zero failures. Release build passed. Source reviews repaired URL-tail deletion, unstable trailing-row promotion and failed-secret target cleanup on rename/retry/plain conversion/navigation; final narrow recheck found no substantiated blocker. Repository audit found no unrelated feature changes/artifacts. Native passed collection page/right-click; variable full-name promotion/Tab/value; collection header entry; inherited request scope, request override and disabled suppression; autocomplete labels/Down/Tab/Escape/undo/request-switch dismissal; Secret check/uncheck; shared Bearer execution and same-binary restart decryption; legacy explicit None retained.

## Artifacts

Normal output dist/Postie.app, release/ad-hoc signed. Build root /Volumes/Data/cache/postie-m34; logs /Volumes/Data/tmp/postie-m34/collection-functional-final.log and collection-dist-final.log. make app/test/fixture use Swift/Makefile/plist, no Python. Use verified make test only, never XCTest help/unverified flags.

Synthetic .build/collection-validation/Postie.app uses ID dev.postie.validation.collections.20261017b, matching new Keychain service suffix .workspace-encryption. Data/bodies are only under that ignored collection-validation folder; app closed. Fixture session12258 at127.0.0.1:54611 stopped intentionally. Do not delete synthetic Keychain items automatically. Any future launch must use explicit synthetic --data-directory/--body-directory; never default config.

## Limits and next scope

M5/cURL/snapshots/T-42 request log/sync remain deferred. No TaskView project authorised; approved local roadmap. No worktree. IME/light-mode runtime/performance/distribution/TLS/proxy behavior not claimed. Completion matching is capped but effective metadata list construction still scales with configured names. Failed-secret UI fault paths were source-reviewed, not native fault-injected. Stable signing needed before promising Keychain continuity across changed binaries.

Never inspect environment, PII, existing runtime configuration/credentials, .env/.config/.aws/.ssh, or existing Keychain items. Only synthetic directories/fakekeys/loopback/exact new services. OS protected dialogs/passwords require user handoff. No comprehensive test expansion.
