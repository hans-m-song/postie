# Initial baseline review

Started 2026-10-17. User authorised independent general review, correction of substantiated issues, and checking in the baseline. Origin is `https://github.com/hans-m-song/postie.git`; local HEAD does not yet exist and origin advertises no branches. Review scope is the whole implementation, not a diff. Generated bundles, build caches and runtime data are excluded.

## Checklist

- [x] Confirm source scope, Git state and origin without inspecting credentials/runtime data.
- [x] Independent HTTP/storage security review.
- [x] Independent architecture/performance review.
- [x] Independent native UI/specification review.
- [x] Triage findings; implement bounded corrections and independently verify them.
- [x] Run existing main-functional checks and rebuild the app where needed.
- [x] Replace Python tooling with Makefile packaging and Swift HTTP fixture; review and re-run existing functional gates.
- [x] Audit repository contents, record limitations and prepare the initial baseline. Git history/upstream record the publication state.

Testing constraint: user explicitly prefers tests of main functional requirements, not comprehensive testing. Add regression cases only for concrete consequential findings. Avoid speculative abstractions, benchmarks, CI infrastructure or deferred product features.

## Findings and disposition

| ID | Review | Finding | Disposition |
|---|---|---|---|
| BASE-01 | UI/specification, medium | Request/Settings switches destroy body selection/undo by removing the native editor subtree. | Fixed with retained, inactive-hidden subtree; independent source review and native check passed. Undo across activity/request navigation is outside this correction. |
| BASE-02 | Architecture, medium | Collection deletion only drains visible members, missing retained dirty/unavailable indexed requests after recovery/reload. | Fixed by draining/clearing all tracked collection identities. Independent source review and one isolated functional regression passed. |
| BASE-03 | Performance, optional | Binary previews allocate per-byte hexadecimal strings unused by the UI. | Removed unused formatting; classification/truncation tests pass. No measured speedup claimed. |
| BASE-04 | User usability feedback | The plain request-name text field lacks an obvious rename affordance. | Added Rename request… using existing dialog/autosave. Independent source review and native rename/Cancel/restart passed. |
| BASE-05 | Functional verification | Core suite intermittently blocks after HTTP test completion in fixture `Process.waitUntilExit()`. | Thread sample located teardown wait. Replaced it with bounded owned-child cleanup in both test helpers; independent review and full SwiftPM run passed. Updated stale binary assertion. No production networking change. |

Native release-build verification passed: body selection (`beta`) remains selected after a Settings round trip; Undo removes the prior paste and Redo restores it. Settings exposes no hidden request fields in accessibility. Explicit Rename request… updates sidebar/title; Cancel leaves the name unchanged, and renamed request/body restore after quit/restart. Validation used a fresh synthetic workspace and separate app bundle ID, not user runtime data. The observed window was 900×652; exact minimum-height behavior and IME remain unexercised.

Final `swift test` passed all 46 tests: Core38 (HTTP15, preparation9, store9, preview5) and AppModel8, zero failures. Build7.78 seconds; tests approximately3.2 seconds. Output was captured in the execution tool result, not a final raw log file. This supersedes the earlier incomplete SwiftPM-driver result in implementation.md. Only one new functional regression was added; existing preview assertions were adapted.

Release build passed (14.25 seconds); `codesign --verify --strict dist/Postie.app` passed. Executable is approximately3.1 MiB on disk, not a memory/CPU benchmark. The isolated validation app was closed after checks.

Raw pre-fix valid-run evidence: `/Volumes/Data/tmp/postie-baseline-diagnosis/core.log` and `stacks.txt`. Apple documents that [waitUntilExit polls the current run loop until the task completes](https://developer.apple.com/documentation/foundation/process/waituntilexit()); this review does not establish the underlying Foundation defect, only the observed unbounded wait at the test seam. Fixture startup's existing blocking read remains outside this correction.

Diagnostic incident: a tester violated the explicit restriction on unverified XCTest selector flags. Invalid usage printed process environment values and briefly saved that output to a temporary log. Tester reported deleting the log; main stopped the agent and informed the user. No values were reused or placed in repository files. Subsequent main-agent diagnosis used only valid bundle invocations. This incident is not evidence of a Postie application vulnerability.

Security review found no substantiated actionable defect in the current HTTP, preparation, storage, preview or packaging surface. This is a bounded review, not a security certification. Real-server TLS/proxy behavior, abrupt power-loss recovery, exact minimum window sizing and IME composition remain unverified. Existing implementation limits remain documented in implementation.md; auth/encryption, syntax/highlighting, snapshots, palette, cURL and session logs are deferred.

Initial branch choice: `main`, following the common GitHub convention; origin was empty, so no existing remote branch is renamed. Runtime data and generated build products remain excluded. SwiftPM local metadata is ignored.

Before publication the user clarified that project tooling should also use Swift or Makefiles. Replaced the Python packaging helper with Makefile/static plist and the synthetic server with a dependency-free Swift executable. It is a test-only product, not bundled with Postie. Independent replacement-source reviews found no actionable findings.

Final replacement gates passed on 2026-10-17: `make test` built in 11.54 seconds and passed all 46 tests (Core 38, AppModel 8), zero failures. `make app` built release in 13.06 seconds; strict signature verification and isolated launch/restart smoke check passed. `make fixture` built and emitted its selected loopback port, then was intentionally interrupted. No Python source files remain. These results supersede pre-conversion verification above; no extra test cases were added for tooling conversion.
