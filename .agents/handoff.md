# Handoff

2026-10-26 — T128 stable response rendering accepted. The user confirmed that performance is much better and the appearance looks good. Check in the response viewport, deferred stable highlighting, response-only input guards, regression tests and research/architecture notes as an isolated scope. Existing HAR import and audit changes remain separate.

Validation: 13 focused cases; four benchmark shapes in two temporary cases; independent source review; full suite 548 cases with 546 passed, two existing filesystem skips and zero failures; lint, release build and strict signatures passed. No functional changes since those gates. The local bundle was refreshed without restarting Postie. Known limit remains: a 950 kB single line takes roughly 5.3 seconds for native initial layout even without highlighting. Further handling needs a separate design decision; user acceptance is for the current trial, not a claim that every large-file case is resolved.


## Latest checkpoint — 2026-10-22

Active follow-up: user confirmed PDF/HTML sizing and external opening work and authorized check-in, then T104–T110 security/reliability/UI fixes with current-source re-review. User selected one main window for T108. Current-source reviews confirm findings persist; the snapshot encryption test explanation needs correction because encryption precedes body validation, though its catch-all assertion still needs repair. Main owns integration/docs/build lock. Fresh baseline `make test` passed all 393 tests (Core164/Control19/Automation32/App178); lint and whitespace checks passed. Logs: /Volumes/Data/tmp/postie-followup-baseline-tests.log and postie-followup-baseline-lint.log. Initial sandbox manifest-write restriction was resolved by approved scoped test execution. No follow-up source changes yet. A synthetic casing probe found /Volumes/Data/tmp case-insensitive; T106 needs an isolated case-sensitive test volume.

- [ ] Clarify acceptance and check in authorized body-support scope.
- [ ] Revalidate and fix T104 snapshot masking and T105 IPC budgets.
- [ ] Revalidate and fix T106 recovery and T107 meaningful test repairs.
- [ ] Resolve T108 window policy; implement T109 accessibility and T110 localized timers.
- [ ] Independent source/blind-test reviews, scoped tests, final build/checks and user handoff.

Embedded CSS/JavaScript formatting is deferred; no formatter packaging or integration should proceed. This supersedes the older evaluation instructions below.

Current direction: user declined Prettier because it is JavaScript rather than native, then approved evaluating native CSS/JavaScript libraries. Prettier/helper proposal is rejected; do not integrate it or treat prior evaluation approval as dependency authorization. Existing source wrapping was positively received, but broad T111–T114 acceptance remains separate. Evaluate native compiled parser/formatter options (Swift, C/C++, Rust libraries as candidates, distinguishing language/runtime and integration cost), without adding dependencies or writing an ad-hoc formatter. Native JSON formatting already exists; any embedded JSON integration still needs a concrete scoped implementation proposal before edits.

Current selected follow-up is complete locally: user approved default-on Wrap text for Raw/Pretty source previews (live/history/snapshots) and evaluation of mature embedded CSS/JS/JSON formatting. Wrapping is implemented and rebuilt; no formatter dependency is approved or added. See docs/embedded-formatter-evaluation.md for the decision-ready proposal and primary sources. Parent explicitly promised to return a concrete dependency choice before integration. Keep captured bytes, rendered HTML and external exports on original source; invalid embedded blocks must remain unchanged. No new acceptance or commit inferred from this approval.

- [x] Shared default-on wrap control and native wrapped-line/horizontal-overflow verification.
- [x] Primary-source formatter comparison and standalone Swift/JavaScriptCore prototype.
- [x] 14 focused tests, lint/syntax, rebuilt app and strict signatures for wrapping.
- [ ] User acceptance of wrapping, then commit only accepted scope.
- [ ] Dependency decision presented to user before embedded formatter integration.

Wrap evidence: /Volumes/Data/tmp/postie-wrap-tests.log, postie-wrap-lint.log, postie-wrap-syntax.log, postie-wrap-build.log. Updated dist/Postie.app; previous generated bundle /Volumes/Data/tmp/postie-before-wrap.8HajZL/Postie.app. No full-suite rerun for this narrow UI change (prior full baseline392). Wrap state defaults on and persists within the view across syntax/Raw/Pretty; it is excluded from formatting identity, so toggle does not reread/reformat. Source review clear; checkbox interaction and native acceptance remain manual. All existing uncommitted T111–T114 work preserved.

Formatter proposal: pinned Prettier3.9.10 standalone + Acorn/ESTree/PostCSS local resources for CSS/JS, native JSONPresentation for JSON. Selected JS609,350 bytes; full notices/first-party license give973,012 raw bytes; installed/compressed delta unmeasured. Synthetic Swift/JSC prototype formatted CSS/JS, rejected invalid JS with unchanged fallback, and did not execute response source marker; no Node/browser/network host globals. Parent measured one small warm-cache run:0.03s,21,446,656-byte maxRSS, not a worst-case or app-memory guarantee. Recommend short-lived helper process for hard wall-clock cancellation/crash separation; no documented JSC hard memory quota found, and no large/adversarial resource benchmark or helper packaging implemented. Ask user to approve dependency/helper before code; no package/vendor assets added. Prototype files under /Volumes/Data/tmp/embedded-formatter-evaluation are temporary; doc has exact paths/hashes/command and official links.

User verified HTML/embedded source highlighting and reported PDF/rendered HTML viewports too small. Approved follow-up is implemented: native previews fill remaining pane height; PDF opens an exported copy in Preview, HTML opens an exported captured document in the default HTTPS browser. User explicitly accepts browser JavaScript/network rules externally. No Expand, separate Postie window or extra confirmation dialog. Full 392 tests, lint/syntax, release build and strict signatures passed. dist/Postie.app refreshed; prior generated bundle /Volumes/Data/tmp/postie-before-preview-followup.BACZfE/Postie.app. Running user app was not restarted. Follow-up and remaining T111–T114 user acceptance are pending; uncommitted. Do not commit the whole pending slice on partial HTML acceptance.

Follow-up evidence: /Volumes/Data/tmp/postie-preview-followup-full-tests.log (Core164/Control19/Automation32/App177), postie-preview-followup-lint.log, postie-preview-followup-syntax.log and postie-preview-followup-build.log. Native PDF snapshot resize test first reproduced the fixed-height defect, then passed; native WebKit resize, scrolling-height stability and small-pane checks passed. Export tests cover exact PDF bytes, independence after source deletion, private/atomic files, cleanup on unavailable sources, injected openers and HTML base/doctype/inert markup/linear entity handling. Actual external-app delivery and navigation/copy races are not automated; source guards/cancellation were reviewed. A 280-point minimum applies to the whole HTML preview, including controls; its WebView can be smaller. Scroll-position preservation on resize is not a requirement; height stability while scrolling is tested.

Shared ResponseBodyViewport uses stable content coordinates and reserves section padding; ExternalResponseBodyExport streams PDF in 64 KiB chunks and bounds HTML at 5 MiB. Successful exports stay in unique private OS-temporary folders, independent of run/snapshot lifetimes. Relative base handling rejects unsupported named entities explicitly. Source review findings were fixed/rechecked; test-only review found no additional production defect. User should quit/reopen dist/Postie.app and verify sizing plus Open in Preview/Open in Browser. Initial 379-test checkpoint below is historical for build/evidence; product policies still apply.

T111–T114 now explicitly selected/authorized. Working baseline clean 8f0a225 before this slice. User confirmed: original-file references; MCP/CLI local-path configuration allowed; NO temporary upload copies/spool; metadata-only upload snapshots; HTML resource opt-in current-preview-only; PDF 25 MB threshold + Load anyway + unsaved password field. Direct streaming mutation detection is best-effort and must not claim frozen bytes. No real user file/config/Keychain inspection authorized for development; use synthetic fixtures.

- [x] Policies and high-level architecture established (docs/body-format-plan.md).
- [x] T111 Core MIME/markup scanner/Pretty, App highlighting and shared text presentation/schema integration.
- [x] T112 native PDF and visible-file ownership/deletion/termination, including a hosted snapshot test.
- [x] T113 captured HTML rendering, disabled JS, default resource blocking/opt-in with loopback HTTP/TCP checks.
- [x] T114 raw file stream, multipart, redirect replay, MCP/CLI dispatcher and metadata-only file snapshot compatibility.
- [x] Independent source/blind-test reviews; full 379 tests, lint/syntax, release build and strict signatures.
- [ ] User verification, then commit accepted scope under standing instruction. No commit/push yet.

Final local checkpoint: 379 tests passed (Core164, Control19, Automation32, App164). After removing temporary PDF screenshot diagnostics and restoring off-screen test hosting, its focused regression passed again. Lint/syntax, release build and strict signature verification passed. Updated dist/Postie.app from /Volumes/Data/tmp/postie-body-formats-build/Postie.app; prior generated app is /Volumes/Data/tmp/postie-before-body-formats.Phc1e5/Postie.app. The running user app was not killed or relaunched. User should quit and reopen dist/Postie.app for acceptance.

Workers are finished. Core owns MIME/scanner/formatter and upload streams/transport/storage. Shared App wrapper selects Text/PDF/Rendered; PDF resource invalidation clears native consumers before lease release/deletion/shutdown. Rendered HTML consumes complete bounded UTF-8 captured source and resets resource opt-in by source identity. Upload configuration references originals; resolved multipart text stays in encrypted snapshot context, plaintext template metadata never receives resolved text. Existing JSON editing aids remain JSON-only.

Fixed during verification: embedded CSS/JSON colon scanning, public InputStream delegate contract, WebKit child-document resource rule, snapshot hosting model injection, encoded xml:space preservation, and permanent upload-body removal after POST→303 GET→307/308 GET. Source reviewer rechecked all three substantive findings; blind test gaps prompted persisted multipart assertions, inline script/resource-hint/opt-in-reset checks, password reopening and MCP/CLI dispatcher uploads. The hosted PDF harness initially collapsed to header height; fixed native test sizing, removed diagnostic screenshot code. No live endpoints, real user files, runtime configuration or Keychain were accessed.

Evidence: /Volumes/Data/tmp/postie-body-formats-full-tests.log, postie-hosted-pdf-test.log, postie-body-formats-lint.log, postie-body-formats-syntax.log, postie-body-formats-build.log. Residual limits: conservative HTML formatting falls back for malformed/omitted tags; rendering tests do not establish comprehensive DNS isolation; original-file mutation checks cannot guarantee immutability against undetectable in-place edits; completed-read hashes are not server acknowledgements. Native visual/interaction acceptance remains pending. Review-fix queue T104–T110 and deferred OTA branch remain separate.

User explicitly confirmed Command-Shift-P works on 2026-10-22. Shortcut and its documentation are being checked in locally; no push. All earlier pending verification/check-in notes below are historical. No outstanding implementation remains for T115–T117; T111 HTML/XML is the next selected feature.

User accepted the rebuilt navigation/history/palette on 2026-10-22 (“seems to work well”); checked in integrated scope locally as 0476bf1. Earlier uncommitted/pending-acceptance notes below are historical; this is not a claim of independent exhaustive native/VoiceOver validation. User then approved Command-Shift-P to open `>` commands with the caret after the prefix. Added only the menu shortcut using existing showRequestSearch(query:) and caret behavior; Command-P blank and Command-F @ remain. Strict lint, release build and signature checks passed, dist/Postie.app refreshed. Logs /Volumes/Data/tmp/postie-command-shortcut-lint.log and postie-command-shortcut-build.log. No new/repeated tests for this two-line binding change. New shortcut stays uncommitted until user verification.

T117 refinement implemented locally: no-prefix unified ALL result kinds, @requests/#collections/>commands/$variables, CmdP blank/CmdF@. Native field places caret after prefill with zero selection even on an already-open focus revision. Parent integrated focus-revision model/menu/docs; both workers completed. All prior dirty work preserved; no commit.

- [x] Refinement scope clarified and approved.
- [x] Unified categories/type-exclusive filtered modes with visual/keyboard typed ID order preserved.
- [x] Native prefix caret and focused synthetic checks: actual field editor automatic focus/insertion, repeated focus revisions, selection preservation, emoji offsets, modifier flags and IME keys.
- [x] Source/test review complete; 23 focused tests passed without warnings, lint/syntax passed. /Volumes/Data/tmp/postie-palette-revision-tests.log. No full-suite rerun for this refinement (previous baseline311).
- [x] Clean release build and strict signatures passed; dist/Postie.app refreshed. Previous generated bundle /Volumes/Data/tmp/postie-before-unified.4TjMqi/Postie.app. Build log /Volumes/Data/tmp/postie-palette-revision-build.log.
- [ ] User verification before commit.

Earlier T117 baseline (shortcuts superseded above): page/creation commands, name-only variable previews/secret metadata, breadcrumb padding and history-row hit-test fix. Existing T115/T116 uncommitted work preserved. No runtime config, Keychain or real endpoint reads performed.

- [x] Scope approved, no existing explicit Command-F binding found.
- [x] Palette catalog/view and route integration; action queues creation intent before closing.
- [x] All 311 tests passed without warnings, including 10 palette/model tests; lint/syntax passed. Independent source/blind-test reviews clear. Logs /Volumes/Data/tmp/postie-palette-tests.log, postie-palette-lint.log, postie-palette-syntax.log.
- [x] Clean release build and strict signatures passed; dist/Postie.app refreshed. Previous generated bundle: /Volumes/Data/tmp/postie-before-palette.kD1MDk/Postie.app. Build log /Volumes/Data/tmp/postie-palette-build.log.
- [ ] User verification before commit.

T115/T116 implemented and locally verified: centered breadcrumb, all collection/request rows, collection Requests initial tab, and session-only per-execution history beside frozen details. Explicit variable/Auth/Header jumps preserved. User chose 10 completed runs or 100 MB combined additional logical capture/body retention, oldest completed eviction, active visible. Workers completed; parent integrated docs/build/signatures. Changes uncommitted, native/user acceptance pending.

- [x] Retention policy and exact-run lease approach agreed.
- [x] Core shared lease capability and tests; independent static review clear.
- [x] Session store/lifecycle/eviction and tests; exact rerun body, stale cancel, source remap/deletion, combined budget and shutdown checked.
- [x] Split history UI and metadata/body inspection; adaptive narrow controls and separate body-view module.
- [x] All 301 tests passed without warnings (Core140, Control19, Automation28, App114), including 10 new history tests; lint/syntax passed. /Volumes/Data/tmp/postie-session-history-full-tests.log.
- [x] Clean release app build and strict signatures passed, dist/Postie.app refreshed. Prior generated bundle: /Volumes/Data/tmp/postie-before-history.TOrRgm/Postie.app. Build log: /Volumes/Data/tmp/postie-session-history-build.log.
- [ ] User/native verification before check-in.

Final history source review found no actionable ownership/lifecycle defect. Blind test audit strengthened payload retention controls, cancellation assertions and bounded fixture/inspection waits. One test-only timeout was caused by retaining the original CollectionStore owner during restart; the test now releases it before reopening. UI review fixed narrow picker overflow and matched Pretty's existing 5 MiB bound/message. Raw/body display previews are1MiB. No user runtime config, Keychain or real endpoint access; one synthetic loopback fixture exercises actual AppModel completion/rerun. Internal ongoing navigation aliases remain; visible route is Request History/Command-2. Current history changes uncommitted pending user verification.

Earlier T115 baseline (superseded by refinements above): sidebar hidden initially with remembered visibility; icon-only toolbar controls; layout in global Appearance; one collection/request/snapshot switcher, Command-K. The final unfiltered list now shows every collection/request; AppModel has collection-tab and execution-history lifecycle integration. T111 remains next after acceptance of this slice; no HTML/XML implementation.

- [x] Toolbar/settings and shared metadata switcher implemented in separate bounded workers; unused old palette removed.
- [x] Eight focused search/history/snapshot-navigation tests passed without warnings; make lint and make syntax passed.
- [x] Independent source review clear after duplicate/accessible-label fixes; test-only audit checked moved/orphan snapshot assertions; final scope audit confirmed no cross-scope source changes.
- [x] Clean release app build and strict signatures passed; fresh bundle copied to dist/Postie.app, prior generated bundle retained at /Volumes/Data/tmp/postie-before-t115.jUHv3a/Postie.app to avoid carrying old Sparkle contents forward.
- [ ] User/native checks: CmdK, keyboard/mouse navigation, Escape/focus restoration, current destination marks, duplicate result labels, sidebar toggle/restart persistence, appearance/layout setting and VoiceOver. No native runtime validation claimed.
- [ ] Local check-in after user confirms; no push.

Logs: /Volumes/Data/tmp/postie-workspace-navigation-tests-final.log and postie-workspace-navigation-build.log. No real requests/runtime data/Keychain or credentials read. Parent owns docs/build lock; workers finished. Local OTA branch remains deferred/ota-updates.

OTA relocation complete: user requested its own branch and a clean working branch. deferred/ota-updates contains preservation commit88ebb7a (28 files), based on db42d35. Returned to main; source worktree clean. Local .codex/.vscode and existing Terraform cache/state/settings are preserved and ignored only through .git/info/exclude; contents never inspected or committed. Distribution remains unaccepted/undeployed. No stash or worktree created. Earlier uncommitted-OTA references below are superseded.

Next user-selected slice is T-111 HTML/XML Pretty source views and syntax highlighting, including embedded CSS/JS/JSON. docs/body-format-plan.md records the proposed contract/gates, pending implementation-plan confirmation. T-112 native PDFKit preview approach accepted, T-113 rendered HTML (external requests off by default with opt-in resources; JavaScript execution explicitly excluded), and T-114 arbitrary uploads are separate future slices. No feature code written. T-104–T-110 remain queued; next-T104 recommendation superseded by user priority.

User requested separate commits. Completed locally: 9fb17f6 formatting/Linux CI, 5973276 ordering/MCP/CLI foundation, 85fa94c MCP request discovery. Documentation is reconciled in the accompanying documentation commit; all36 staged README/docs files have valid relative links. No push. Index-only staging preserved all working source; deferred OTA integration remains uncommitted in Package/Makefile/PostieApp/HTTPSettingsEditor and separate updater/infra/scripts/release files. Private .codex/.vscode untouched.

The staged foundation was exported to /Volumes/Data/tmp/postie-split-validation and independently reviewed for staging boundaries. All279 tests passed without warnings, including the automation Settings entry and excluding Sparkle: /Volumes/Data/tmp/postie-checkin-foundation-tests.log. Discovery then passed27 focused tests and strict formatting in the same isolated snapshot: /Volumes/Data/tmp/postie-checkin-discovery-tests.log. Final release app/CLI snapshot builds and strict signatures passed without warnings: /Volumes/Data/tmp/postie-checkin-build.log. These artifacts are in the temporary snapshot, preserving the user's existing dist app. Earlier records below retain the sequence; this checkpoint supersedes their uncommitted/schema-cache/user-acceptance status.

T-103 user-accepted: after restarting the Codex session, tool metadata exposes collectionName across all eight collection-taking tools and optional query on requests.list. A live buildsight query `bcc sta` returned only get qbcc stats; no send. User replied “Sounds like it worked.” Schema-cache and acceptance gates are resolved. T-104–T-110 remain queued; no review fixes implemented. Next proposed correctness task is T-104 snapshot credential-header masking, requiring synthetic reproduction first.

User replied “Sounds good” to the proposed plan. T-103 implemented: optional requests.list query matches saved name/path, MCP schemas advertise collectionName, dispatcher retains legacy collectionID and rejects both selectors. Duplicate accessible names yield ambiguity error, no uniqueness migration. New pure RequestDiscovery helper has no vault/network dependency. Paths exclude origin templates/authority/query/fragment and keep percent escapes literal. No other review fixes applied.

All 27 focused AppAutomationTests/AutomationContractTests/MCPTransportTests passed without warnings; make lint passed. Log /Volumes/Data/tmp/postie-discovery-tests-final.log. Independent source review clear after correcting template-origin hostname/port suffix extraction; blind test audit clear after adding interior substring assertions. App/CLI release builds and strict signatures passed; artifacts refreshed in dist, log /Volumes/Data/tmp/postie-discovery-build.log. User acceptance/check-in pending; reopen rebuilt Postie and refresh MCP schemas before testing. No real HTTP sends, runtime configuration/Keychain reads, commit or push.

User requested every review finding be recorded as an immediate follow-up, then selected MCP partial request discovery first and collection names rather than UUID selectors. Added docs/immediate-follow-ups.md T-103–T-110 and linked roadmap. Approved requests.list optional query matches request name or saved URL path case-insensitively, without variable/secret resolution; collectionName used for MCP selectors, IDs retained internally and CLI compatibility preserved. Window ownership remains a separate unconfirmed product choice. Older cleanup/source-review state below remains applicable.

Live discovery checks after user restarted Postie, 2026-10-22: MCP collectionName with mixed case/whitespace plus interior name substring returned only get qbcc stats; path-only interior substring returned three matching requests. No-match and origin-variable-name queries returned none. Blank query and legacy collectionID returned identical five-item ordering. Both selectors returned invalidArguments; nonexistent collection returned notFound. Read-only calls only, no sends or workspace mutation. Codex session still advertises old collectionID-only tool metadata, although new arguments reach current app successfully; schema refresh remains unverified. Duplicate-name and exclusion behavior for this slice remain synthetic-tested only. User acceptance/check-in still pending.

Updated 2026-10-21. This is the current resumption state. Durable decisions and older evidence remain in [log.md](log.md); product status is [roadmap](../docs/roadmap.md).

## Active work

User approved documentation cleanup, README logo, normalized Swift formatting, and Linux CI. User then requested a swiftui-pro review delegated by module plus independent unit-test reviews without implementation context. Implementation/review is complete locally; user review/check-in remains.

- README uses existing packaging/Postie.png; no image regeneration.
- Current guides and historical status banners reconciled. Roadmap opening is canonical; dated task records remain historical.
- .swift-format sets4 spaces/120 columns; structural rewrite rules were disabled. Sources, Tests and Package.swift were normalized with official Swift6.4.1 Linux formatter.
- Linux workflow .github/workflows/ci.yml checks strict formatting, per-file syntax, actionlint and event-range whitespace. Tools scripts and Make lint/format/syntax targets added. Image/checkout/actionlint pinned; no credentials, build, deployment or macOS runner required.
- No hosted GitHub run observed, no push/deployment performed.
- Review findings recorded in [review-2026-10-21.md](../docs/review-2026-10-21.md). No functional review fixes applied.

## Verification

All279 existing package tests passed (Core138, Control19, Automation26, App96), no warnings/failures: /Volumes/Data/tmp/postie-cleanup-tests.log. App/CLI release rebuild and strict signatures passed: postie-cleanup-release.log. Artifacts dist/Postie.app and dist/postie refreshed.

Pinned Linux formatter+parser passed in source-only copy /Volumes/Data/tmp/postie-linux-ci-verification, with no runtime/agent config mounted. Intentionally invalid Swift file made parser fail; removed afterward. Local make lint/make syntax, actionlint, Bash syntax and normal/zero/missing-base whitespace checks passed. Relative Markdown links verified. See docs/ci.md for evidence paths.

## Review findings awaiting a new fix plan

Module reviewers used current source; no fixed diff attribution and no runtime reproduction claimed.

1. Snapshot request-template projection can lose inherited custom API-key header sensitivity.
2. CLI arguments/envelope frame budgets differ; oversized replies close IPC without a bounded correlated error.
3. Case-sensitive move recovery reconstructs lowercase paths for otherwise supported mixed-case directories.
4. WindowGroup shares singleton navigation/search across windows; decide single-window versus scene-local state.
5. Custom variable autocomplete lacks accessibility elements/selection announcements.
6. Global published clock invalidates unrelated views while idle; performance impact unmeasured.

Two blind reviewers read only all11 Core test files and all21 App/Automation/Control test files. Most tests are meaningful; targeted weaknesses include a snapshot failure test reaching the wrong error, ungated concurrency/stale-cancel scenarios, unbounded fixture/continuation waits, and vacuous plaintext/source-variable assertions. Strengthen existing cases instead of adding comprehensive coverage.

## Product work and commits

- b066227: layout/snapshots and resolved JSON export.
- 661e149: manual workspace key transfer.
- 983c27d: snapshot navigation regression.
- 2234b28: snapshot collapsing/counts.
- 3cca2f1: frozen unused-secret capture, encrypted snapshot support and actual-send opt-in.

Ordering/MCP/CLI foundations, sanitizer/policy UI, CLI diagnostic, CI and formatting are now checked in by the separate commits above. User standing rule: commit only user-verified scope locally; no push. Partial staging keeps deferred distribution changes separate. Recheck index/status before future staging.

## Live acceptance already established

User confirmed basic drag ordering and cross-collection moves. Intermittent wrong insertion became unreproducible; user deferred investigation.

Real Codex MCP list/start/get, Block, Unredacted, inherited/explicit redacted mode routing and cached-ID request exclusion were exercised. After fix, freshness became {{test}} under inherited redaction; user accepted. No request edits/policy changes made by agent in these checks.

Real CLI list/read/start/result, ongoing listing, cancellation and temporary snapshot create/read/rename/delete passed. Temporary snapshot deleted. Rebuilt CLI with app closed gave correct Open Postie guidance. Live operations explicitly authorized.

Remaining live gates: new snapshot redaction, collection exclusion across children, ordering/MCP-enabled restart persistence, MCP-specific create/edit/snapshot mutations, final settings/drag-feedback acceptance. These do not replace fixing the newly reviewed correctness issues.

## Operational boundaries

- Preserve unrelated distribution work: infra/, scripts/, Tests/ReleaseTests/, AppUpdater/Sparkle changes and packaging/Postie-512.png. OTA/deployment deferred; no release suite.
- Never inspect/stage .vscode/ or .codex/; preserve local user/editor/agent configuration.
- No runtime config, actual Keychain contents, env vars or credentials read. Use explicit synthetic workspaces and fake keys for tests.
- No Python/Ruby tooling. Swift/Bash/Make.
- No active subagent edits or separate worktree; all review workers read-only/completed.
- Memory updates not requested; do not write memory.

## Local build commands

Use existing .build/automation-check cache. Parent owns compiler/build lock. SwiftPM test options are documented in Makefile; sandbox execution may require the existing narrow cache/build escalation. Run make app cli BUILD_DIR=.build/automation-check CONFIGURATION=release and strict codesign checks when source changes warrant them. Do not confuse local/synthetic checks with native/user/deployment verification.
Native formatter research completed on 2026-10-22: see docs/native-formatter-evaluation.md. Proposed first candidate is standalone Oxfmt (compiled Rust, not Swift), invoked only for extracted CSS/JS blocks; whole HTML remains excluded because its formatter is Prettier-backed. Alternative is a native Rust helper linking Malva and dprint TypeScript crates. No dependency or prototype added. Packaging size, runtime, cancellation and configuration isolation remain unverified; obtain approval before implementation. Existing dirty T111–T114 work and its acceptance boundaries remain unchanged.
Latest decision (2026-10-22): user deferred embedded CSS/JavaScript formatting. Native evaluation is research only, with no dependency or integration selected. Do not start packaging trials or formatter implementation. Existing highlighting, wrapping and JSON formatting remain; broader T111–T114 verification and commit boundaries are unchanged.
