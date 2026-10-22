# Decision log

## 2026-10-22 — Deferred OTA branch and body formats

User requested moving OTA work to its own branch. Preserved28 enumerated source/docs/packaging files as88ebb7a on deferred/ota-updates and returned to main. No local Terraform settings/state or credentials committed/read. Locally ignored .codex/.vscode and Terraform cache/state/settings through .git/info/exclude without reading contents. Main source worktree clean after relocation; no push/deployment/release test.

User selected HTML/XML body support next, clarified first slice is Pretty source view plus highlighting, including embedded CSS/JS/JSON highlighting rather than execution. Native PDFKit approach accepted; arbitrary uploads and rendered HTML proposed separately. Rendered HTML must block external requests by default with resource opt-in; JavaScript execution explicitly out of scope. Recorded T-111–T-114 plan, pending confirmation; no feature code or new acceptance claimed.

## 2026-10-22 — Immediate review follow-ups and MCP discovery proposal

User instructed splitting the accepted work into separate commits. 9fb17f6 normalizes only committed Swift sources and adds Linux quality gates; 5973276 adds ordering/MCP/CLI foundation with no discovery/Sparkle code; 85fa94c adds discovery/named selectors and five focused tests. Used index-only snapshots so working source and deferred distribution remain preserved. Independent staging reviewer found no boundary defects. All279 foundation tests passed in exported snapshot, then27 discovery/transport tests passed with no warnings; strict formatting passed. Logs /Volumes/Data/tmp/postie-checkin-foundation-tests.log and postie-checkin-discovery-tests.log. No real sends/runtime configuration/Keychain/environment access, push or deployment.

Final isolated committed app/CLI release builds and strict signatures passed without warnings, /Volumes/Data/tmp/postie-checkin-build.log. Snapshot artifacts are under /Volumes/Data/tmp/postie-split-validation/dist; working dist was not overwritten. Documentation commit reconciles committed architecture/dependencies and README logo; deferred distribution claims remain only in unstaged working variants. No hosted CI run/deployment performed.

Fresh Codex session exposes updated schemas: collectionName selectors and requests.list query; live name substring `bcc sta` returned only get qbcc stats. User accepted T-103 (“Sounds like it worked”). Read-only checks only. Source check-in boundary remains unresolved because automation/CLI foundations are uncommitted and Package.swift contains mixed deferred Sparkle dependencies; do not stage whole tree or commit an incomplete discovery fragment.

User requested all review findings be queued immediately and prioritised partial request search by path/name with collection names. Recorded stable T-103–T-110 specs, preserving static-versus-reproduced findings and existing verification boundaries. User approved extending requests.list instead of another tool, case-insensitive substring matching on saved names/paths without resolving secrets, and name-based MCP collection selectors with internal UUIDs/CLI compatibility. Duplicate accessible names return an ambiguity error; no uniqueness migration. T-103 implementation authorized; other review fixes remain queued.

T-103 implemented with pure RequestDiscovery matcher and shared AppModel collection-name resolver. New schemas advertise names; dispatcher retains legacy IDs for CLI/cached clients, rejects both selectors and checks MCP access before name ambiguity. Preserved order and handle identities. Independent source review caught and corrected templated-origin hostname/port suffix extraction. Test-only reviewer caught missing interior-substring positives; added meaningful name/path assertions. All27 focused tests passed without warnings; make lint, app/CLI release builds and strict signatures passed. Logs /Volumes/Data/tmp/postie-discovery-tests-final.log and postie-discovery-build.log. User/live acceptance pending; no real sends, runtime config/Keychain reads, commit, push or deployment. T-104–T-110 queued separately.

User restarted app and requested live test. Read-only MCP requests.list passed interior name/path search, trimmed mixed-case collection selector, no-match/origin exclusion, identical blank-query/legacy-ID ordering, dual-selector invalidArguments and nonexistent-name notFound. No sends/edits. Codex session tool metadata remains cached with old ID-only schema, but new arguments reach app successfully. Fresh metadata, live duplicates/exclusions and user acceptance remain unverified; no commit/push.

## 2026-10-21 — Documentation, formatting, Linux CI and independent review

User approved docs/logo cleanup and full Swift formatting normalization, then requested swiftui-pro/module reviews and test-only meaningfulness reviews. Refreshed current guides, marked historical checkpoints, condensed handoff, and retained stable roadmap history. Existing logo reused. Four-space/120-column formatter configuration and pinned Linux formatting/parser/actionlint/whitespace workflow added; no hosted run/deployment claim. All279 existing package tests, release app/CLI builds/signatures, Linux formatter/parser, local lint/syntax and actionlint passed; negative syntax fixture correctly failed. No functional refactor applied.

Independent module reviews identified snapshot custom-header masking context loss, IPC frame-budget mismatch/oversized error handling, mixed-case path recovery, and three UI presentation/state concerns. Blind reviewers saw no production context and found generally meaningful tests with specific false-positive/race/hang weaknesses. Full evidence and proposed next scope are in docs/review-2026-10-21.md. Source findings are static, not runtime-confirmed; test concerns do not prove production bugs. Fixes need a scoped follow-up approval. Work remains local/uncommitted pending user review.

## 2026-10-21 — Verified secret capture committed

User accepted inherited live redaction. Local commit `3cca2f1` contains self-contained core secret-capture/snapshot changes, actual-send opt-in, focused capture tests and snapshot docs. MCP sanitizer/projection and CLI diagnostic are still pending with their larger automation foundations; no whole-scope acceptance/check-in claimed, no push.

## 2026-10-21 — Unused secret redaction and app-closed CLI fixes

Both user-observed bugs reproduced with synthetic red tests. Missing socket/directory lstat failures now classify ENOENT as unavailable, preserving unsafe metadata/type/owner/mode checks; CLI guidance explicitly names Postie. New sends separately freeze effective encrypted variables even if unused, bounded to128 attempted secrets/1MiB, persist only inside encrypted snapshot context, and feed redaction with referenced-name precedence. Unavailable/over-limit capture marks incomplete and withholds redacted output; requests still send, cancellation propagates. General preparation helpers default capture off; actual AppModel send explicitly on, authentication preview off. New snapshot optional field is backward compatible; old snapshots are not retroactively supplied mutable live secrets. Gate91 passed, no warnings/failures. Packaging/user verification pending.

## 2026-10-21 — Explicit unredacted MCP response mode

User approved renaming the redacted option and adding unredacted response viewing at global/collection/request scope; explicitly selected unredacted response headers and URLs too, including redirects. Existing allow serialization remains redacted and default remains block. Added a distinct unredacted mode; exclusions and bounded previews remain. App projection computes bounded candidate outputs while retaining the live body lease and selects by latest policy/access after final awaits, supporting downgrades without returning a stale raw candidate. Direct secret reads, request projection and CLI behavior remain unchanged. Independent source review found no remaining actionable issue; deterministic concurrent downgrade/native client verification not claimed. Focused checks/build pending.

## 2026-10-21 — Collection settings and deferred insertion report

User approved moving collection MCP access/response-view controls to their own Settings tab. Retained tab rendering and existing policy guards are preserved; collection navigation stores sections generically. User confirmed cross-collection moves work, but reported intermittent wrong insertion positions, then explicitly deferred investigation when unable to reproduce. No drag placement fix or native reproduction claimed.

## 2026-10-21 — Snapshot disclosure and existing navigation commands

User confirmed working; locally committed snapshot-only source, focused test and snapshot documentation as `2234b28`. No push. Other pending drag/automation/distribution changes remain untouched and uncommitted.

User approved collapsed-by-default snapshot children with a visible count. Added independent count/chevron buttons for live and deleted request groups; sidebar-owned memory retains expansion through collection collapse without persisting configuration. Review caught request-ID-only aliasing across collections; corrected to full RequestIdentity with a focused isolation regression. Cross-collection moves reset expansion. No captured content or storage changes. Native user acceptance remains pending.

User requested standard Command-[ and Command-] navigation. Current PostieApp already registers Back/Forward with SwiftUI command infrastructure, matching shortcuts and history availability, so no command-source changes were necessary. Logic checks do not establish native keyboard delivery.

## 2026-10-21 — Verified snapshot fix committed; drag feedback follow-up

User confirmed snapshot navigation fixed. Committed only SnapshotDetailView's one-line removal, hosted regression and focused snapshot documentation locally as983c27d; no push. Broader T96/T97/T98 and unrelated dirty work remain separate.

User reported a drag insertion line sometimes remaining after completion. Existing row-local state cleared only on target exit/performDrop. Lifted feedback into one sidebar-owned target/edge object and wired Apple's macOS26+ `onDragSessionUpdated` lifecycle: initial/end (including cancel) clears, active/late transfer completion preserves, disappearing sidebar clears. Target-conditional clearing prevents old target exits from erasing the new target. Source payload and drop operations unchanged. Independent source review clear;15 focused lifecycle/ordering/snapshot-navigation checks passed with no failures/warnings. Tests use native phase values but do not prove delivery from legacy onDrag during a live gesture; native/user verification remains pending. No AppModel/store or real configuration/Keychain access for this fix.

## 2026-10-20 — Snapshot loading callback reclaimed navigation

User reported that sidebar clicks briefly highlighted and snapshot content flashed without leaving the snapshot. A hosted SwiftUI regression reproduced twice: a stale SnapshotDetailView loading task invoked `selectSnapshot`, overwriting a later collection selection and corrupting Back/Forward history. Removed the one redundant `.task` call; AppModel sidebar/history entry points already initiate loading. Independent review confirmed no legitimate load path depends on the view callback. The regression and existing snapshot/history checks passed12 cases with no failures/warnings. Release rebuild and strict nested signature check passed; `dist/Postie.app` refreshed. User acceptance pending; no commit. Tests use only synthetic files and a fake key store.

## 2026-10-20 — Ordering and local automation implementation decisions

Final local verification:154 selected functional/regression checks passed (Core75, Control12, Automation22, App45), with no failures/warnings. Release app/CLI packaging, strict signatures and CLI help passed. Independent source reviews clear after fixes documented in `docs/automation-implementation.md`. Native automation pipe startup failed on the isolated synthetic bundle; no native gesture/Codex compatibility acceptance claimed. No commit/push pending user verification.

- User approved T96/T97/T98 together. Cross-collection moves inherit destination defaults, retain request templates/overrides, carry sidebar snapshot association, and reject active runs. Snapshot captures remain immutable.
- Persist collection order, per-snapshot grouping and exclusion tombstones in an additive workspace index. Cross-collection changes use a recoverable journal; preserve unknown metadata and malformed files. Excluded retained snapshots remain excluded after source deletion, as explicitly confirmed by the user.
- MCP listener defaults off, remembers enabled state, uses loopback authenticated stateless HTTP/SSE and UI-only access/response policies. Collection exclusion is a hard child deny. Global response viewing defaults Block; even Allow applies frozen known-secret replacement. CLI uses a separate protected same-user socket and existing app instance; no caller-controlled raw-mode switch on MCP. Direct variable reads remain nonsecret on both channels.
- Core policy/store, sidebar/AppModel and automation projection were delegated with separate ownership. Existing thread capacity prevented spawning further agents; reuse the three active workers for subsequent transport, host and independent review phases.
- Independent review identified and corrected IPC socket ownership/correlation/allocation issues and partial option override loss. HTTP adapter lifetime is insufficient to track accepted writes because SDK request tasks can outlive transport waiters; track dispatcher work separately and refuse termination when bounded graceful drain is incomplete. Never retry or cancel accepted writes implicitly.
- Independent ordering review identified incomplete snapshot inventories as a privacy/grouping risk during source delete/move. Structural mutations must be refused until snapshot enumeration is healthy. Automated verification is still in progress; no current acceptance/build success/commit is claimed here.

## 2026-10-18 — T-57 response presentation completed locally

- User approved fresh JSON/+json Pretty defaults, wrapped other/raw/fallback text, existing binary behavior and unchanged preview/formatting limits. Width-aware TextKit sizing reuses the growing-editor approach; successful Pretty keeps long-line horizontal scrolling under the pane's outer vertical scroll.
- Source review caught automatic formatting of JSON-labeled binary bodies. Formatting now waits for a loaded nonbinary preview; binary selects disabled Raw. Independent recheck found no remaining issue. Source bytes and Content-Type unchanged.
- Existing82 functional tests passed, zero failures; no new automated tests. Release build/strict signature passed. Native loopback verified JSON/+json defaults, manualRaw, invalid/6MiB fallback, binaryJSON, plain unbroken text, reflow at335/464pt via sidebar toggle and full-height scrolling. Divider drag did not move; not claimed as resize evidence. No new memory/IME/light-mode profile.
- Added bounded /presentation validation variants in the Swift fixture. Isolated response app and fixture closed, user runtime/Keychain untouched. Memory-budget work remains paused;66c4443 records assessment only. Local check-in, no push.

## 2026-10-17 — T-56 referenced variable value actions completed locally

- User approved View full ordinary values, Reveal/Hide encrypted values, and full-value Copy without prior Reveal. ReferencedVariableRow resolves request > collection > global and reuses existing on-demand Keychain decryption; it does not change persisted configuration.
- Revealed buffers clear and pending operations invalidate on dismissal, tab/navigation/value/scope/request changes. Independent review identified captured tab-state timing; a live activity Binding plus model selection/value checks closes it. Final source review found no remaining issue.
- Independent existing82 tests passed, zero failures; no automated tests added for the UI-only change. Release builds passed. Synthetic native checks verified full ordinary viewing/copy, secret Copy without Reveal, explicit Reveal/Hide and tab dismissal. Compact label wrapping repaired and visually rechecked. Delayed-Keychain fault injection was not performed.
- Copy intentionally writes plaintext to the system clipboard; hiding does not erase the clipboard. Existing user configuration/keys were not inspected. New isolated service dev.postie.validation.references.20261017a.workspace-encryption only; validation app closed. Local-only commit; no push.

## 2026-10-17 — T-52–T-55 collection settings follow-up completed locally

- User approved collection page, shared headers/auth, reversible variable table, URL autocomplete and tighter request-method inset; additionally requested collection context-menu actions with no ellipsis. Name opens settings; arrow expands/collapses requests.
- Collection JSON atomically stores headers/auth/variables, preserving membership/name/unknown fields. Header names resolve before case-insensitive request override; disabled request rows suppress inherited names without resolving unused values. Existing auth stays explicit; new requests inherit. Effective scope remains request > collection > global.
- Secret conversion updates the model only after encrypt/decrypt succeeds. Conversion failure preserves old value/type without blocking Quit; explicit secret Save failures require retry/discard. Independent review found stale failed-save targets after rename/retry/plain promotion; centralized exact-owner/name discard repaired these paths. Trailing rows share structural identity and preserve native focus.
- Autocomplete uses metadata only and native text editing/undo. Repaired replacement ranges so following paths/templates survive. Matcher work/results bounded; effective metadata construction still scales with configured names. No dynamic variables added.
- Independent final82 functional tests passed (Core58/App24), zero failures. Release build passed. Final source review found no substantiated blocker; repository audit found no scope expansion. Native synthetic collection/table/completion/inheritance/checkbox/Bearer/restart checks passed. See docs/collection-settings.md for evidence and limits.
- Only new synthetic Keychain service/data used; app and fixture closed. Keep commit local; no push. M5/cURL/snapshots/log/sync remain deferred.

## 2026-10-17 — T-50 table alignment and typography

- User reported misaligned header columns and requested monospaced inputs. Matched query/header heading/row horizontalpadding8pt and checkbox/placeholder rails26pt, with equal flexible column constraints. Path headings match their row constraints.
- Method/URL, query/header names/values, path values and numeric settings inputs now use monospace. Body was already monospace; human-facing names/labels retain native fonts. Widened response-size input to120pt after native check caught default-number clipping.
- Release rebuild and strict signature check passed. Isolated900×652 native window verified aligned populated/blank rows, path columns, fonts, continuous Tab entry/focus and complete default byte count. Scoped independent source review found no findings. No automated tests added/rerun for presentation-only changes. Synthetic validation app closed, user config untouched; local-only Git preference retained.

## 2026-10-17 — Baseline committed locally

- Created baseline commit a3aa26ba7c2cfc8b813f4b6a6cc85e5b12ae239f on main, containing reviewed Swift/Makefile sources, focused functional tests and project documentation/mockups. Generated bundles/runtime data excluded.
- Automatic approval review rejected git push before execution because local check-in did not clearly authorise uploading the project to GitHub. Main reported the rejection and asked about that concrete payload/destination. User explicitly answered Keep the commit local. No push occurred; do not infer push authorisation from configured origin in future.

## 2026-10-17 — Reviewed initial baseline ready for check-in

- Closed the two medium lifecycle findings, removed unused binary hex allocation, added explicit Rename request… and corrected fixture teardown after thread sampling located the unbounded wait. Independent follow-up reviews found no substantiated issues.
- User clarified that project tooling should use Swift or Makefiles. Replaced both Python helpers with Makefile/static plist and a separate Swift loopback fixture; production app remains Swift-only and fixture is not bundled. Independent replacement reviews passed.
- Final make test passed all 46 functional tests (Core38/AppModel8); one consequential regression added, existing assertions adapted, no comprehensive test expansion. Make app release build, strict signature verification, isolated launch and make fixture startup passed. Native selection/undo and rename/Cancel/restart passed. No user runtime data inspected or migrated.
- Origin remained empty at final check; main selected. Repository contents audited, generated builds/runtime data excluded. Git history/upstream are authoritative for publication state.

## 2026-10-17 — Initial baseline review authorised

- User requested independent general review, a secure/efficient baseline and Git check-in after configuring origin. Confirmed no local HEAD and no advertised origin branches; chose main for initial publication. User explicitly limits tests to main functional requirements.
- Three read-only reviewers examined HTTP/storage security, architecture/performance and native UI/specification. No actionable security finding; medium findings concern lost body undo/selection on tab switches and incomplete collection deletion cleanup after damaged-member recovery. Optional unused binary hex allocation is being removed. No broad refactor or deferred feature work justified.
- Delegated three narrow corrections with protected surfaces and independent re-verification planned. See docs/baseline-review.md.
- Independent tester later violated the explicit ban on unverified XCTest selector flags; the invalid invocation printed environment values and briefly wrote them to a temporary diagnostic log. Tester reported deleting that log; main stopped the agent, informed the user and did not reuse the diagnostic. Main owns further diagnosis through valid one-bundle invocations only. No such values are recorded here.

## 2026-10-17 — Usability follow-up completed locally

- T-36–T-41/T-43–T-46 implemented, independently reviewed and native UI checked. Both bodies grow under their pane's outer vertical scrollbar; native request paste/undo/redo/caret reveal verified. Response preview remains bounded.
- Final rebuilt direct XCTest bundles passed Core38/AppModel7, zero failures. SwiftPM driver rebuilt but stalled without case output for30 seconds and was stopped. No final driver success claimed; unsupported Location test now explicitly bounded, production behavior unchanged.
- Final debug app built/signature verified. Compact layout checked at1120×772; exact minimum sizing/IME unexercised. Current Git repository has untracked project files; no commit/merge performed. Updated completion docs/handoff, no runtime migration.

## 2026-10-17 — Usability follow-up approved

- User approved trailing blank query/header rows, whole-heading accordion hit targets, initially collapsed response headers, manual redirect following, ~/.config/postie default, path parameters and full-width URL toolbar.
- User requested a request log as a later feature; recorded T-42, deferred. T-36–T-41 track current work. No implicit config migration/merge; existing runtime directories will not be inspected.
- Bounded workers own path preparation/persistence, manual HTTP continuation/AppModel/default path, and native views respectively. Main owns integration/docs; independent review and isolated verification follow.
- User reported compact-window clipping during native validation; T-41 expanded to correct layout minima and constrain long content, retaining side-by-side panes.
- During validation user requested Request/Settings tabs with redirect/time/size options under Settings, and correction of a response-right unused band. Added T-43/T-44; UI worker owns bounded follow-up. Initial compact correction visibly restored the full sidebar and Send at 1120px; exact900/1000px resize could not be exercised through available UI dragging, so do not claim that evidence.
- Runtime probes measured HSplit container830px versus child widths395+394 plus1px divider, leaving40px unallocated. A local NSSplitViewController with persistent NSHostingControllers removes the band; explicit host sizingOptions=[] delegates size constraints to the split items. Probes were removed. Native Settings values, input focus through model ticks and Cmd-Return were checked.
- User requested one vertical scroll owner for each pane, with request/response bodies growing vertically. Recorded T-45/T-46; a bounded native growing request editor is authorised for this change, not general syntax-highlighting work.
- A tester accidentally invoked XCTest help/usage in a form that printed process environment values in tool output. Main informed the user and directed no repetition/use. Tester confirmed no environment-derived data was saved to the project or validation logs. Do not reproduce that diagnostic.
- Unsupported file-scheme redirect test exposed a platform assumption: URLSession can fail before its redirect delegate callback, leaving no HTTP response record. Kept production behavior; narrowed test to require a sanitized terminal failure without redirect/completion/cancellation in that platform path. Targeted correction passed.

## 2026-10-17 — M1/M2 completed locally

- Dependency-free SwiftPM core/native app, HTTP execution, flat collection persistence, autosave and Ongoing Requests implemented by bounded workers with regular checkpoints. Paste cURL deferred; no M3–M5 functionality shipped.
- Independent verification passed 30 core and 6 app-model tests, zero failures. Final independent source review found no blocking issues. Corrected nullable-cap merge, body cleanup ordering, raw query fidelity, redirect effective method, cancellation presentation, partial-delete reconciliation, unknown-membership draft retention and termination draining accepted mutations.
- Final debug bundle rebuilt and ad-hoc signature verified. Actual isolated GUI checked GET, redirects/headers, two concurrent runs, both cancellation routes, activity navigation, running Send disabled, and last edit retained across quit/restart. Approximately 4 MiB on disk; no memory/CPU benchmark or notarisation claim.
- Minimum macOS 27.0 chosen to match available macOS 27.0.1/Xcode 27 host. Older-platform support remains unverified. Ordinary literal configuration is plaintext; auth/encryption and syntax highlighting remain later work.
- Verification gap: termination structural-mutation race/10-second timeout source-reviewed without a focused deterministic test. Unreadable metadata shares the tested malformed path but lacks a separate model test. See implementation.md for exact evidence and limits.
- The authorised notify-discord milestone command completed successfully after verification. The app was left open against its isolated synthetic GUI workspace, with no requests in flight.

## 2026-10-17 — Initial scope recorded

- User agreed to macOS-only personal use, flat collections, HTTP initially, global/collection/request variables, and literal template substitution.
- User deferred scripts, functions, UUID/timestamp generation and OpenAPI importing. Existing storage specifications and Git integration are unnecessary initially.
- User requested highlighting for input bodies, templates and responses; JSON-only initial highlighting was included in the accepted roadmap.
- Recorded five vertical milestones and stable T-01–T-28 task IDs. No implementation has started.
- Local JSON, Keychain references, SwiftUI/URLSession and a possible AppKit editor are the proposed technical approach, not verified implementation.
- No project files were found during initial inventory, and git status reported that the directory is not a Git repository. No AGENTS.md or CLAUDE.md file was found; instructions supplied in conversation govern the work.

## 2026-10-17 — Independent documentation review

- Read-only reviewer DOC-REVIEW-01 inspected all five initial documents and reported three medium planning gaps: response limits scheduled after execution, ambiguous plaintext/Keychain boundaries, and unspecified result ownership during overlapping sends/edits.
- Main agent recorded findings/dispositions in docs/review.md and amended the plan. Policy values and concurrency choice remain unapproved; acceptance now requires decisions before affected implementation.
- Clarified that ordinary literal configuration is not automatically protected by Keychain; structured secrets must not pass through plaintext autosave.
- TaskView project selection was requested asynchronously; no tracking records have been created.
- Follow-up DOC-REVIEW-02 confirmed R-01–R-03 are addressed for planning with no substantiated residual material gaps. Implementation still requires relevant policy decisions and approval.

## 2026-10-17 — Local access to sensitive values

- User clarified that sensitive values may be accessible to the local user and endorsed Keychain storage.
- Updated overview and M5 credential-copy task: viewing/editing and deliberate copying may expose values; no mandatory redaction or extra app-level approval flow is required. Reveal/masking UI remains undecided. Development-agent restrictions on reading secrets remain in force.

## 2026-10-17 — File layout and request search proposal

- User agreed to explore an ordered request-ID index in collection.json alongside one file per request and requested independent adversarial review.
- User requested command-palette-style request search by name or URL/path. Recorded proposed navigation-only behaviour and case-insensitive matching; these details await review, not implementation.
- Added storage.md/navigation.md and stable T-29 (index/recovery, M2), T-30 (request palette, M4). Existing task IDs are preserved.
- User deferred iCloud sync to later exploration; it is not an implementation dependency.

## 2026-10-17 — Explicit saved exchanges

- During storage/palette review, user requested saving an instance of a request and response.
- Added snapshots.md and T-31 in M5; automatic history remains deferred. Execution-time request/response identity is required; snapshot-specific secret capture and recovery remain open design details for independent review.
- DOC-REVIEW-03 reported one low palette gap: identical visible labels. Added ID-based disambiguation and prefix-collision acceptance. Reviewer substantiated no other material storage/palette findings. Snapshot review continues separately as DOC-REVIEW-04.
- DOC-REVIEW-04 verified the palette correction and reported no new material snapshot findings. Captured secret representation remains an implementation prerequisite. Added the requested bounded-retention clarification, pending a final narrow check.
- DOC-REVIEW-04A confirmed bounded unsaved-exchange retention addresses the clarification; design remains proposed pending implementation approval.

## 2026-10-17 — Encryption proposal under review

- User proposed retaining snapshot templates with encrypted captured variable values and extending encrypted values to live secret variables. Named environments remain deferred.
- Recorded candidate AES-GCM envelopes in JSON with an app-level Keychain key, frozen snapshot input maps and context binding; this replaces the per-secret Keychain approach as the proposal being reviewed.
- Added stable T-32. User requested encryption-specific independent adversarial review, then another independent overall-plan review. Both are documentation reviews, not implementation approval.
- ENC-REVIEW-01 found one medium gap: separately edited query entries were missing from snapshot capture fields. Added ordered query templates, duplicate/empty-value handling and verification; reviewer confirmed fixed and no remaining material findings. A different reviewer is now checking the overall plan.
- PLAN-REVIEW-05 completed the separate overall review: no substantiated material defects or dependency cycles. Proposal is ready for concrete design decisions, not implementation approval. Recorded prioritised milestone prerequisites and review limitations in docs/review.md; updated handoff. No code or runtime tests were produced.

## 2026-10-17 — Execution clarification and simpler at-rest proposal

- User requested straightforward encryption at rest, allowing decrypted values in memory. Simplified the candidate envelope: removed record/field context binding, rename-dependent re-encryption and rotation machinery. Keychain app-key storage and no-plaintext-fallback remain.
- User requested a Follow redirects setting with expandable full available headers for intermediate exchanges; automatic cookie storage can wait. Exact wire-header visibility is not promised.
- User confirmed concurrent execution of different request configurations, at most one in-flight run per request, with obvious activity and cancellation. Extended T-05/T-06 and added T-33 for file-backed body lifecycle.
- Recorded per-request latest transient results to support concurrency, file-backed bodies/bounded previews and snapshot metadata/body sidecars with staging. Numeric deadlines/size thresholds remain proposals, not approved defaults.
- Prior review conclusions apply to historical drafts; these revisions have not received another independent review. No application code was written.

## 2026-10-17 — Ongoing requests view and visual concepts

- User requested a view of all ongoing requests with navigation back to the owning request configuration, plus visual mockups of the various views.
- Added T-34 to M1 and activity-view navigation/acceptance. Mockups are visual proposals, not an approved interface or runnable app.
- Generated four concepts using built-in image_gen, then revised/visually inspected side-by-side editor, ongoing requests, redirect inspection and palette views. Assets and exact generation/edit prompts are in docs/mockups. Corrected generated scope/layout errors; current files end in -v2.png.
- User requested snapshots beneath originating requests in the sidebar and a side-by-side request/response layout; switching can wait. User allowed physical co-location only if simpler; retained separate disk storage to preserve source-deletion independence. Deleted-source discoverability remains open. These images are native-style concepts, not actual SwiftUI/AppKit rendering or approved implementation.

## 2026-10-17 — Stacked editor sections and syntax selection

- User requested query/headers/body stacked in the same Request view, with Auth/Variables separate tabs. Response headers/body/redirects are similarly stacked; redirect hops start collapsed and final response expanded.
- User requested selectable syntax, initially None and JSON only. Recorded presentation-only selection with independent template cues and explicit formatting; XML/other modes remain deferred.
- Revising the current editor concept to replace the superseded tab-based layout. No application code written.
- Generated and visually inspected 01-request-editor-v3.png: stacked sections, only Request/Auth/Variables tabs, collapsed redirects/final expanded, and None/JSON selector. Saved exact prompt; README marks older tab-based concept backgrounds as superseded.
- User accepted the v3 editor visual direction ("looks good") and requested remaining open decision threads. Implementation, platform/signing and concrete numerical defaults remain unapproved.
- User subsequently agreed to recommended open-thread defaults and requested Paste cURL as an import exception. Recorded approved execution defaults, 10-hop/cross-origin policy, historical sidebar placeholders and local planning; added T-35 and curl-import.md. General config import/export stays deferred. Host version read returned 27.0.1; intended primary-Mac/signing remains unverified. No implementation or broader test approval inferred.

## 2026-10-17 — M1/M2 implementation authorised

- User explicitly requested implementation of M1/M2 with subagents, regular supervision, best-judgement decisions and later review notes. Paste cURL can wait. Recorded exact scope/ownership in implementation.md/interfaces.md.
- Created dependency-free SwiftPM package, core shared models, native app worker, HTTP worker and persistence worker. Separate core target enables focused tests within one package.
- Xcode27/Swift6.4 host verified. Sandbox blocked generated SwiftPM/XCBuild files; an auto-review-approved escalated trusted build with credential stores disabled compiled core and full app. No user signing identities/Keychain/runtime data were inspected.
- Independent review identified nullable-limit merge, transient body cleanup, partial-delete UI state, final redirect method and cancellation outcome defects. Store cap fix is implemented with a regression; other fixes are assigned to original owners and independent tests are underway. No milestone completion claimed.

## 2026-10-17 — M3/M4 implementation in progress

- User authorised M3/M4, including URL variable/path parameter highlighting and the accepted v3 mockup direction. Current checklist and concrete decisions are in docs/implementation-m3-m4.md; M5 remains deferred.
- Core persistence, template preparation and encryption workers completed their bounded source changes. The isolated core target compiled after correcting one missing return; all 53 core functional tests passed, using synthetic stores, fake keys and loopback HTTP. Actual built-app Keychain continuity remains unverified.
- AppModel worker implemented scoped save/flush, conservative key creation and accepted secret-commit handling. Parent added run-specific cancellation to prevent an obsolete preparation callback from cancelling a later run. Native field/body highlighting and auth/variable UI workers are still implementing; independent core/security review is underway.

## 2026-10-17 — M3/M4 completed locally

- Three scopes, single-pass literal templates, Basic/Bearer, AES-GCM/Keychain, native None/JSON/template/path highlighting, bounded Raw/Pretty, variable source summary and Command-K search implemented. No M5 feature expansion. Persisted models remain templates/ciphertext; only effective referenced secrets unlock.
- Independent security review found no substantiated blocker. Independent UI review identified state crossing request identities, a second debounce losing edits, and edits during busy secret operations. Owners corrected all; recheck closed findings. Full tests caught workspace publication before readiness; atomic load/initial-load ordering fixed, old tests retained.
- Native validation caught promoted-row focus loss and doubled URL drawing. State-backed native focus, queued transition guards and editing-cell drawing fix passed full header entry/Tab, hidden-tab input isolation and single-render missing cues. None/JSON preserved body undo; palette Escape restored selection. Compact response-control labels were corrected against minimum-size screenshots.
- Final independent make test passed66 (Core53/App13), release build and strict signature passed. Actual new synthetic Keychain key creation, secret conversion/Bearer and same-binary restart passed. Resigned rebuild prompted for access; user approved, unattended rebuild continuity remains unverified. Do not weaken ACLs. OS removable-volume dialogs require user action because Computer Use blocks UserNotificationCenter.
- Only isolated synthetic paths/new services/loopback were used, never existing runtime config or keys. Owned validation apps closed and fixture stopped. Local commit only, no push. Details and residual IME/light/performance/signing limits: docs/implementation-m3-m4.md.

## 2026-10-17 — Memory capacity assessment, no implementation

- User clarified increased footprint across feature builds rather than an observed session leak. Used synthetic current-release UI and loopback responses, RSS counters only. Measurements and independent source audit recorded in docs/memory-baseline.md.
- RSS was99–113MiB empty,142MiB empty editor,162MiB smallJSON,210–216MiB for8/32MiB body with1MiB preview. No historical matched-build comparison or allocation attribution; no leak conclusion. App/fixture closed.
- Proposed selected-request-only preview retention and100 request-body undo groups; implementation awaits approval. No source changes or tests/builds for assessment.

## 2026-10-18 — T-58–T-63 authoring and header privacy

Completed approved follow-up; see docs/authoring-follow-up.md for verification. Send-time lowercase sensitivity flags preserve request header masking across redirects without extra variable decryption or schema changes; names derived from secrets also mask. Explicit Reveal/Copy retains access. Response bodies unchanged. Completion uses names/scope metadata, with auth suggestions after Show and literal variable definitions excluded. Native editor focus capture fixes first-focus colors; JSON-only direct-key pairing preserves paste/undo. References moved to Variables; narrow secret controls use icon fallback. Independent93 functional tests, source reviews and isolated native checks passed. Memory and drag-drop remain deferred.

## 2026-10-18 — T-64–T-67 inherited headers and authoring

Completed approved one-table read-only inherited headers/source jump, JSON newline indentation/selection wrapping, and single-line variable inspector with explicit Reveal/definition navigation. Templated header names cannot be case-folded before variable resolution; status now reports uncertainty, with regression coverage. New inspector presentation defers beyond field selection, avoids first-responder candidates and updates open anchors through positioningRect. Preserve native field typing/undo. Body inspector remains out of scope.

User reported revealed secret name/value overlap in collection/request tables; native reproduction isolated the fixed68pt name row that replaced table columns. Shared editing now retains Name/Value columns and one-line Hide/Cancel/Save. Long-name collection and335pt request layouts passed through shared Replace/Show path; earlier actual synthetic Reveal passed. Independent final106 tests, source review/scope audit and release/signature checks passed. See docs/inherited-headers-and-editing.md for precise native evidence and limits. No memory/M5 change; no push.

## 2026-10-18 — T-68–T-69 implementation checkpoint

Approved ordinary autocomplete value previews and compact inspector. Completion previews are capped256chars/singleline, effective-scope-aware, and discard encrypted values without decryption. Six44pt rows visible with native scrolling through existing20match cap. Inspector uses enabled read-only non-focusable native valuefield, eyeaction/sourcefooter and intrinsic sizing with error-line updates. Lifecycleguards retained. Independent109 tests (Core61/App48), source review/scopeaudit and release/strictsignature passed. Xcode27 API rename to scrollToVisible corrected after compilegate.

Native acceptance/localcommit remain pending: initial getApp lookup reported27499.6804s despite30stimeout; own validation window remains inactive after targeted inputs/Raise. User asked conditionalunlock confirmation. No nativepassclaimed. compactValidation binding now exists; reuse it. Explicit isolated .build/compact-validation app/data/bodies, ID dev.postie.validation.compact.20261018a; no secretkeycreatedyet, no network/userdataaccess. Awakeassertion80701 started near2026-10-18 00:48UTC for1800s; old77407 likelyexpired. See taskdoc/handoff. No M5/memory change or push.

## 2026-10-18 — T-68–T-73 completion

Implemented approved compact value previews/inspector, bounded identity-based session navigation, inherited header highlighting/table consistency, native-font one-line body minimum and closed partial autocomplete. Independent final 115 tests (Core61/App54), zero failures/compiler warnings; source reviews/scope audit clear. Native validation confirmed draft-preserving keyboard history, one-step definition return, canonical partial completion, eighth list selection, ordinary/secret inspector and explicit fake secret Reveal/Hide, body growth/shrink and aligned gutters. Unexercised: pointer after scroll/error resize/IME/light mode/performance.

Corrected earlier automation diagnosis: lookup attached to no-argument validation instance stopped at workspace lock, not proven screen-lock cause. Closed exact instance, verified final isolated arguments, used synthetic data/new validation encryption key only; no network sends/user config/real Keychain reads. Test app closed and temporary wake assertion stopped. Documentation reconciled; final distributable built and signature checked. Local commit only; no push. Deferred memory/M5 scope unchanged.

## 2026-10-18 — T-74–T-75 request accordions

Replaced request section tabs with per-request session accordions; counts/defaults/query-path addition behavior and explicit history/definition restore verified. Reused readonly native field/inspector for inherited headers and injected owner across native hosting root. Native narrow-column bleed fixed with compression priorities and drawing clip. Variables retain ordinary drafts while clearing secrets; authorized saves finish and operation-matched cleanup prevents stale failure from discarding newer target state.

Independent final119 tests (Core61/App58), zero failures/warnings; source review clear and native layout/expansion/history/effective-scope/popup action/error checks passed. First compile failed on missing auth summary return, corrected; final tests rerun after rendering fix. Initial inherited popup AX button limitation resolved on final relaunch, then GoDef and malformed Reveal action verified. No Keychain reads/new key/network sends/userdata. Test app closed, own wake assertion stopped. Final app/signature verified; local check-in only/no push. Future-only bulk editT76 and request tabsT77 recorded; no M5/memory changes.

## 2026-10-18 — T-78 restored section tabs

User reversed T74 layout: restored Request/Auth/Variables/Settings tabs; Request keeps four initially expanded accordions with session collapse choices and counts. Reused section history and removed obsolete accordion restoration event. Hidden Headers/Auth unmount; retained Variables/Body activity guards clear transient state. Reference scan keys include identity. Reviewer queued-scroll tab guard added.

Independent exact-source118 tests (Core61/App57), no failures/warnings; source review and scope audit clear. Native defaults/tab/history/GoDef/popup dismissal/body draft retention passed. Final release/signature verified. Synthetic-only checks, no requests or Keychain/userdata access. App closed, own wake assertion stopped. Current docs reconciled; multi-request tabs/bulk edit/M5/memory remain deferred. Check in locally only; no push.

## 2026-10-18 — T79/T80 query synchronization and HTTP defaults

Approved and completed canonical baseURL+ordered query rows with provenance-preserving encoding, disabled-row retention, legacy send-order normalization and literal/real template distinction. Global HTTP defaults persist in globals.json; per-field optional overrides distinguish inheritance from explicit unlimited. Empty inputs restore inheritance and show global placeholders; legacy concrete request settings retained. DecimalKB/MB conversion leaves byte counts unchanged. Independent review fixes and155-test/native/release verification recorded in docs/query-and-global-settings.md. No push/commit or real user data accessed.

## 2026-10-18 — API key auth

Added encrypted header-based API key auth, manual request header precedence and custom credential cross-origin stripping. Independent review,168 distinct functional tests, native editor and release/signature checks recorded in docs/api-key-authentication.md. No real credentials accessed.

## 2026-10-18 — Header provenance and read-only auth rows

T82 captures header origin during preparation and propagates it per observed hop; response UI never consults mutable live config for labels. Auth preview is explicit-only and transient.173 functionaltests and isolated nativechecks documented in docs/header-tables.md. No push or realcredential access.

## 2026-10-18 — T-83 inherited authentication
- Fixed request Auth source navigation to explicitly select collection Auth.
- Added read-only inherited type/public fields and masked derived header with explicit Reveal/Hide; request-scoped variable context, existing preview guards and local reveal reset on scope changes retained.
- Verified release build, 173 existing functional tests, strict signature/diff checks and isolated native 335-point summary/destination/Back navigation. Synthetic malformed envelope reveal fails safely; no real Keychain credential or user workspace accessed. Successful credential reveal not exercised natively.
- Changes remain local and uncommitted. Selected parameter polish, Copy as cURL and native snapshots remain next.

## 2026-10-18 — Adaptive slate blue template highlighting
Approved template palette: dark #7D9DC7, light #45658F. Shared dynamic NSColor now colours variable/path syntax and path table names; referenced-variable names use the same palette, missing/invalid markers retain red. Release built successfully, signature/diff checks passed. Isolated native screenshots verified URL path, table path name and variable value in both dark and forced-light appearance. No new automated tests for this colour-only change. Changes uncommitted; .vscode remains unrelated/untracked.

## 2026-10-18 — Appearance preference
Added global Settings > Appearance > Theme (System/Light/Dark), default System. AppTheme maps to preferredColorScheme; AppStorage persists the app-local UI preference in UserDefaults, independently of workspace HTTP configuration. Native isolated checks verified immediate Light/Dark switching, Light persistence after process relaunch and System returning to macOS dark appearance. Release build/signature/diff checks passed. No new automated tests for this small native preference UI. Validation app closed; changes uncommitted.

## 2026-10-18 — Template colour saturation refinement
User approved more saturated shared template colours: dark #6F9DD8, light #365F96. Changed only the existing dynamic palette RGB values; variable/path consumers and missing/invalid red unchanged.

## 2026-10-18 — Further template palette refinement
User approved trial palette dark #5B9FEF and light #245BA8. Updated the existing shared dynamic template colour only; all variable/path consumers inherit the change.

## 2026-10-18 — Appearance check-in
User accepted final palette dark #5B9FEF / light #245BA8 and authorized local check-in. Includes shared variable/path colours, table path-name tint and persistent System/Light/Dark preference. Latest release build and signature/diff checks passed; native appearance switching and relaunch persistence previously verified. No push. Next selected slice remains parameter polish, followed by Copy as cURL and native snapshots.

## 2026-10-18 — T84 completed locally
After user unlocked screen, native checks resumed successfully. 335pt query/path cells wrap3lines, short rows compact; expanded query live edits update URL and autocomplete Return works. Readonly path-name expansion retains blue, Tab moves query name to value, light/dark screenshots passed. Popover scrollbar set to1 exposed END_MARKER at end of6.6KB value; wheel automation targeted underlying area, so no scrolling defect established. 173 existing tests, independent source/scope checks, release/signature/diff passed. No Core/storage changes, no new automated tests. Isolated app closed. Changes uncommitted, unrelated .vscode preserved. Next selected work: Copy as cURL, then native snapshots; HAR deferred.

## 2026-10-19 — T84 automatic growth refinement completed locally
User rejected expand-control appearance and approved unbounded automatic inline wrapping. Removed controls/popovers/localScrollView and bounded mode. Query/path cells now grow fully; default URL/header/auth singleline unchanged. Release/signature/diff and independent source review passed. Native335pt light/dark checks verified long unbroken wraps, END_MARKER visible through outer scrolling, shortening names/values shrinks row and URL sync remains. No new/rerun tests for presentation simplification; previous173functional checks remain initial implementation evidence. App closed, no sensitive user data accessed. Changes uncommitted; .vscode preserved. Copy as cURL remains next.

## 2026-10-19 — T85 complete locally
Request/collection header tables now opt into auto wrapping; inherited/derived auth rows wrap, query/path/header rows top-align, fixed22pt spacer rails preserve compact entry rows. Existing masking/reveal/reset/source logic unchanged. Release/signature/diff and independent source review passed. Native335pt dark/light verified query/path topalignment, inherited/auth name/value wrapping, editableheader full END_HEADER then shrink/highlight, source jump to collectionHeaders and wrappedcollectionediting. No realcredentials/decrypt, no Core/storage/response changes, no new/rerun tests for presentation-only changes. Isolatedapp closed. Changes uncommitted, unrelated.vscode preserved. Copy as cURL remains next.

## 2026-10-19 — User verification and check-in policy
User confirmed T84/T85 work and requested local check-in. From now on, user verification authorizes committing the verified changes locally without asking again. Do not push unless explicitly requested. Policy recorded in docs/overview.md. This check-in includes auto-growing query/path/header cells, top alignment, inherited/auth presentation and verified documentation. Unrelated untracked .vscode excluded; release signature and diff checks passed.

## 2026-10-19 — T86 code complete, deployment pending
User requested code/config first and ownsdeployment. Terraform infra/distribution provides privateS3+CloudFrontOAC, tagrepoOIDC release role (immutableprefixinputsupported), GitHub vars and existingAWSSecretsManager -> GitHubsecret mapping (SPARKLE_PRIVATE_KEY/TF_GITHUB_TOKEN mandatory; sixApple optional). Externalstate/deployrole/bootstrap/manualinitialapply remain userowned; secrets plaintext retainedinTFstate documented. Actions infrachangesmain validate/plan/apply; vMAJOR.MINOR.PATCH mainhistory tagrelease tests/universalbuild/optionalApplecertificate+notary/Sparklesign/archivebeforefeed. RootMakefile embeds+insideoutsignsSparkle/license, version/feed/keychain/arch inputs. PinnedSparkle2.10.0+lock. Settings/appmenu updater gatedvalidHTTPSfeed+publickey, localdefault disabled.
Validation:173app/coretests;5releasechecks32assertions actualSparkletools+publicRFC8032keys+AWS/make stubs (first/subsequent/duplicateolder/resume/mismatch); TFbackendlessinit/validate/fmt, YAML/embeddedBash/Rubysyntax, independentreview, host/universalarm64+x86_64 builds+strictnested signatures. Fixed reviewfindings archiveflags, paths, Rubycompare, actualfeedXMLschema, cleanresumeartifactcache, mismatchedkeys andverifiedarchivebeforewrite. No AWS/GitHub calls/applies or realcredentials inspected. NativeCUA cgWindowNotFound, optionalunlockquestionunanswered; UI controls, realOIDC/publication/notarization/install unverified. Defaultdist restored nofeed; isolatedappterminated. Logs /Volumes/Data/tmp/postie-sparkle-{build,tests,universal-build,final-build}.log; releaseharness logs /Volumes/Data/tmp/postie-release-test/run-20261019-17616-*. Docs distribution.md+infraREADME. No commit pendinguserverification perpolicy; .vscode untrackedunrelatedpreserved. CopycURL/snapshots stillselected next, deploymentuserowned.

## 2026-10-19 — Release tooling languages
User requested Bash/Swift/Make only. Removed Ruby helpers/harness, preserved five release behavior cases with actual Sparkle tools and local Bash stubs. `make release-test` passed all five; namespace-aware RSS validation tested against valid and malformed fixtures. Runtime prerequisite list and workflow updated. No deployments or real secret access.

## 2026-10-19 — T87 bootstrap boundary decision

User approved defining deployment trust in this repository while looking up the existing GitHub OIDC provider. Selected manual `infra/bootstrap` and automatic `infra/distribution` separation. AWS CloudFront OAC creation has no resource/name/tag restriction; OAC belongs to manual bootstrap. CloudFront tag-on-create authorization cannot establish exclusive ownership of a previously unknown distribution ARN, so initial creation/replacement uses operator credentials; bootstrap binds the resulting exact ID for automatic updates. This is a deliberate fail-closed constraint, not permission to broaden automatic deployment. Implementation and offline review are in progress; no deployment or real credential access authorized.

Implementation refinement: bootstrap owns both deployment and release roles, trust, tags and boundaries. Distribution reads the fixed release role, checks its expected boundary/owner tag and manages only its publishing inline policy. This removes automatic IAM creation, trust, tagging and boundary administration. Exact grants and the boundary are separate documents; boundary explicit denies restrict actions/resources/services, including session-principal resource-policy grants. The initial combined document exceeded IAM's 6,144-character limit; compact deny-based ceiling preserves those restrictions and strips authorization-neutral Sids from emitted JSON. Independent synthetic checks measured 5,371 characters for eight secrets, a secret CMK, separate state CMK and bound CloudFront; larger allowlists fail a size precondition rather than broadening access. Static independent review found no remaining concrete defect. Live AWS authorization remains unverified.

Resolved the executor's final missing-prefix concern against AWS's condition-operator reference: a missing key satisfies negated matching conditions, so `StringNotEquals` on `s3:prefix` keeps the explicit state-list deny effective when no prefix is supplied. No policy change was needed. Source: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html.

## 2026-10-19 — T88 configuration simplification

User approved removing unnecessary Terraform inputs and custom KMS/Apple credential configuration, with region default `ap-southeast-2` and profile/state bucket/key retained. Fixed repository, issuer, IAM names, tags and secret paths are locals; release bucket derives from account/region. Exact OIDC subject prefix remains an explicit input because GitHub's provider cannot derive the owner ID without fetching unnecessary profile fields. No such lookup or PII read was performed.

Removed CloudFront ID binding: boundaries scope account distributions by existing Application=Postie tag and protect tag ownership. Release inline policy still references the actual distribution ARN. Moved OAC to distribution, eliminating its cross-root ID input; initial operator apply creates hosting, workflow gets only account-scoped OAC refresh reads. Bootstrap owns only IAM trust/roles/boundaries. This removes the second bootstrap apply and generated-ID copy steps. AWS provider 6.69.1 source confirms OAC refresh uses GetOriginAccessControl. No state migration executed; existing external deployments would need an explicit ownership migration before this layout.

Both roots have local backend examples with profile/bucket/key, default backend/provider region, and separate bootstrap/distribution keys. Resource variables still carry distribution state location for IAM scope and CI init; Terraform backend blocks cannot reference resource variables. Generated CI config excludes local profile. No custom KMS grants remain. Apple certificate/notary automation was removed; ad-hoc app and Sparkle archive signing retain five existing functional publication checks, all passing with synthetic keys/stub AWS under the approved test escalation. Main-package signing options remain available as general build inputs. Independent static review is clear; final offline snapshot verification is pending. No AWS/GitHub deployment, credentials/env/real-secret reads, or push.

Final T88 gate passed independently on disposable copies: both roots fmt/init-backendless/validate, 3+3 mocked tests, three workflow YAML parses, 14 embedded Bash blocks and shell scripts. JSON policy lengths: infrastructure boundary 4,163; inline 2,830; release boundary 1,825. No live authorization/backend proof. Backend/tfvars copies are ignored by Git; examples remain reviewable. No app tests rerun for this configuration-only change. No commit pending user verification; unrelated .vscode preserved.

## 2026-10-19 — T89 local-first operations

User chose local Terraform deployment and local release publication now, retaining future automation. Consolidated hosting into AWS-only infra/distribution; removed known bootstrap source/docs/examples/lockfile, GitHub provider/synchronization, workflows and IAM/OIDC/boundary setup. Actual ignored state, local backend/tfvars and cached bootstrap artifacts were not inspected or deleted. Terraform now has only optional provider profile and region (default ap-southeast-2); state profile/bucket/key are backend init settings. Signing keys are no longer read into Terraform state.

Make targets infra-init/plan/apply/check and release are reusable entry points. Saved Terraform plans are reviewed before make infra-apply. Local release checks stable tag, clean matching HEAD and main ancestry, without Git mutation/fetch. Wrapper obtains hosting outputs, accepts session credentials or named profile, defaults Sydney region, and reads runtime Sparkle private key from environment/file/default Secrets Manager name. Publisher uses RELEASE_TEMP_ROOT rather than GitHub RUNNER_TEMP and requires increasing Sparkle build numbers for new releases, preserving archive-only resume. The monotonic check is necessary because CFBundleVersion controls Sparkle update ordering; a new marketing version alone is insufficient. Six synthetic cases pass (five prior cases plus wrapper with key/profile/region/log checks), using real Sparkle tools and stubbed AWS/build/Git/Terraform; approved escalation was needed for Foundation fixture writes. No real key, AWS publication or deployment was used.

Corrected an existing hosting assertion: CloudFront default certificates force AWS's TLSv1 viewer policy regardless of minimum_protocol_version. Removed the ignored setting and false TLS1.2-minimum claim; tests verify HTTPS redirection and signed OAC instead. Custom domain/certificate is deferred rather than silently provisioned. Primary source: https://docs.aws.amazon.com/cloudfront/latest/APIReference/API_ViewerCertificate.html. Future automation is T90: thin CI invoking the same Make interfaces, scoped OIDC/runtime key access, serialized publication, full tag/main history and build-number continuity. No dormant CI roles or duplicate release logic retained. Final independent gate is pending; no commit until user verification.

Final T89 gate passed: independent AWS-only Terraform root fmt/init-backendless-readonly-lock/validate/mocktests3, including complete insecure-transport deny contract. Independent fake-command wrapper checks reject four unsafe Git states before any Terraform/AWS call and accept origin/main fallback when local main is absent. Worker Make release-test reports six passing cases, with monotonic-build rejection and wrapper profile/region/key/log behavior. Parent Make-invalid-tag check exits before Git/AWS and proves exported tag wiring. Bash syntax, dry runs, Git ignored-config paths and diff checks passed. Key-file mode/cleanup reviewed in source, not separately runtime-asserted. No live AWS/GitHub/state/key access or Git mutation. Code complete locally, uncommitted until user verifies.

## 2026-10-19 — OTA deferred by user

User requested skipping T94 release-test execution after approval rejection. Permission question is closed; runtime result remains unverified rather than blocking further roadmap discussion. Shared update hosting/domain for multiple apps was discussed, explicitly no implementation now. Next selected product slices remain Copy as cURL and native saved snapshots; parameter/header polish already complete.

T94 implementation: explicit CloudFront cache policies (default60s, feed0TTL/no compression, ZIP1yr), immutableZIP uploadmetadata, updater signedfeed/pre-extraction flags, explicit appcast signing and verification before upload. Independent review found/fixed privatekeyfile verifier requirement and legacyarchive resume signing gap. Terraform isolated fmt/init/validate/mock1 passed; Bashsyntax/testSwiftcompile passed. Syntheticrelease suite execution pending user environment-read exception after auto-review rejection; no unsafe retry. Runtime results unclaimed, no AWS/deploy/commit. docs/distribution.md documents unchanged default20dayfeedvalidationfallback.

T92 approved retention implemented: current plus four noncurrent per object, one-day minimum before older noncurrent expiry; lifecycle depends on enabled versioning and has no current expiration. Backendless disposable init/validate, one temporary mock test, independent source review and fmt/diff checks passed. No AWS reads/deploy/commit. Subsequent requested online design review recorded in docs/distribution-review.md against official AWS/Sparkle/Apple docs; public signing/notarization and real installation remain gaps, caching/feed-signing improvements unimplemented. OTA stays deferred.

T91 DNS completion: user confirmed existing public cloud.axatol.xyz hosted zone. Terraform now looks it up and manages postie.cloud.axatol.xyz A/AAAA aliases to CloudFront with target health checks disabled. Two focused mocked plan tests, disposable backendless init/validate, formatting/diff checks and independent source review passed. No AWS/state/backend access, deployment, release or commit. User verification remains pending.

T91 subsequent approved preparation: custom CloudFront domain postie.cloud.axatol.xyz, existing certificate ARN from us-east-1 SSM /infrastructure/acm/cloud.axatol.xyz/certificate_arn (decryption disabled), SNI/TLSv1.2_2021 and custom release/feed outputs implemented. Backendless disposable-copy init/validate and one mocked plan test passed; formatting/diff checks passed. No AWS access, deployment, publication or commit. DNS aliases await user confirmation of public Route 53 hosted zone cloud.axatol.xyz versus axatol.xyz. OTA publication remains deferred.

After asking about pending check-in, user explicitly said to hold off on OTA updates; local build is sufficient. Pending T86–T89 distribution/Sparkle code remains uncommitted and preserved, with no source deletion, deployment or publication. Prior local UI fixes are already committed at f2fec33. Treat earlier distribution code-complete records as historical implementation evidence, not accepted/active shipping scope. No new local-only implementation is waiting for check-in. Resume distribution only on renewed direction; normal user-verification-before-commit and local-only/no-push policy remain.

## 2026-10-19 — T95 layout switching and T31 native snapshots

User narrowed the selected slice to layout switching and snapshots. Added a remembered shared side-by-side/stacked preference and toolbar control. Snapshots freeze send-time source labels, templates, effective referenced inputs, selected auth and submitted/observed transport. All resolved request transport/input/auth/redirect data is encrypted with the existing app key; templates, labels and original response headers/body remain plaintext. SnapshotStore stages pretty JSON and a file-backed body copy, atomically publishes the directory, preserves unknown fields/ciphertext on rename, and reports malformed/unsupported entries without rewriting them. Execution leases and synchronously registered save tasks protect source bodies through reruns/discard/termination. Snapshot ciphertext or uncertain storage blocks replacement-key creation even after live sources are deleted. Read-only detail never resolves against live values or sends requests; source-independent sidebar grouping and rename/delete are implemented. Only selected decrypted snapshot context remains cached.

Independent source review drove fixes for uncertain lstat failures, per-snapshot view identity, standard sensitive-header masking when the key is unavailable, hidden live-history entries, stale workspace-load overwrite after snapshot mutations, and visible renamed sidebar labels. All 18 final focused tests passed: six snapshot storage/capture/lease tests, seven preparation tests, two app lifecycle/key-gating tests and three history tests. Log /Volumes/Data/tmp/postie-T95-T31-final-sources.log. Final independent review found no actionable issue. Release app packaging/signature checks and diff whitespace check passed; dist/Postie.app refreshed.

Native synthetic checks exercised loopback send, live orientation change, save/open/rename, delete confirmation/cancel and persisted capture reopening. They exposed historical-source grouping during startup and offscreen snapshot sizing during orientation changes. Final source publishes snapshot metadata synchronously after restored collections and uses native hosting split controllers with sizingOptions disabled; focused tests/build/review passed afterwards. Final native recheck remains pending because macOS CUA attach repeatedly returned AppleEvent -1712/timeouts. No claim of native verification for these fixes. Synthetic key/data are separate from actual user workspace; no real runtime config/credentials read. No release suite, deployment, commit or push. User verifies before local check-in; cURL, HAR, multi-request tabs and drag/drop stay deferred.

## 2026-10-20 — Snapshot selection and resolved JSON copying

User explicitly deferred T99 data sync because no Apple Developer account is available. Preserved native iCloud research and completed manual key transfer; no alternative sync implementation selected. Roadmap returns to drag ordering T96, MCP T97, then future CLI T98. Docs-only update, no tests needed or code/cloud/deployment/commit/push performed.

User confirmed manual key import/export is working. Local T100 commit 661e149 contains9verified source/test/encryption/storage doc files. Staged only encryption insertion in mixed HTTPSettingsEditor, keeping updater/distribution changes uncommitted. No push/deployment. T100 complete; T99 data-sync backend/provisioning design remains next, separate from completed manual local-Keychain onboarding.

T100 manual key-transfer implementation completed locally: Settings Encryption Key import Base64/raw/Base64 file, export reveal/copy/private0600 exclusivecreate file. SecretVault accepts only32bytes, validates all supplied ciphertext before persistence, samekey idempotent, stored/cached differentkey conflict, no generation on export. AppModel unions current and durable known encrypted data with snapshot encryptedContext, rejects uncertain/read-only storage, refreshes selected missing-key snapshot; scan permits only realempty staging parent without mutating it. Parent/reviewer fixed cached-key external deletion edge and restored envelope validation before Keychain access. Export UI dismissal guards, explicitcopywhenhidden and failure cleanup prevent late redisplay/partial-new-file leaks. Independent final source/scope review clear.19 focused synthetic cases passed (9vault+6snapshot+4app/file); initial app fixture whitespaceBearer failure corrected only in test data, productionvalidatorunchanged. Log /Volumes/Data/tmp/postie-key-transfer-tests.log. Release app and nested signatures/diffcheck passed; dist refreshed. NativeKeychain/sheet interaction awaitsuser; noactualkey/cloud/runtimeconfigaccess, no newfixtureprocess/worktree, no commit/push. Preserve deferred distribution/UIhunks and unrelated .vscode/newpackagingimage. Percollectionkeys/externalstorage recorded deferred.

Latest user priority changed to sync first. User prefers native Apple SDK and all durable config-folder user data, explicitly including encryption-key portability/snapshots. Research note docs/icloud-sync-research.md compares CKSyncEngine private CloudKit with iCloud document sync, cites Apple's own-persistence recommendation and actual app examples. Source inspection confirms existing generic-password key client lacks kSecAttrSynchronizable; synchronizable-key migration cannot be reduced to toggling an attribute. CloudKit provisioning requires membership/signing capability (verified public Apple HTML checkmarks), current ad-hoc app is not sufficient. Large native CKAsset limit remains unverified; old WebServices50MB is not asserted as native guarantee. T99 research/design now precedes T96/T97/T98. No runtime config/key/cloud-account access, tests/build/source implementation or deployment. Confirm developer membership path before implementation.

Latest MCP refinement explicitly adds Location to metadata-only headers for final and redirect responses, superseding earlier exclusion. Apply known frozen-secret re-templating, strip URL userinfo, preserve relative/absolute form and omit malformed values instead of raw fallback. Other header/body restrictions unchanged. Recorded only, not implemented.

Subsequent roadmap refinements: user approved MCP response-viewing inheritance with global default Block, but requested metadata and known-safe response headers even when blocked, including intermediate redirects. Recorded conservative parsed/normalised RFC9110/RFC9111 metadata allowlist and identical hop/final/snapshot policy. Known-secret filtering still applies; arbitrary encoded/new secrets cannot be guaranteed detectable. Block mode excludes URLs/Location, body, opaque identifiers and sensitive headers. Intermediate scope is captured redirect metadata, not all interim wire responses or per-hop bodies/timings. User requested CLI parity as future T98, skipping MCP redaction/view restrictions; direct secret-variable reads not added. These are planning records, no implementation or tests claimed.

User subsequently confirmed the snapshot changes look good. Committed verified layout/snapshot source, tests and snapshot-specific docs locally as b066227 (22 files); no push, deferred distribution changes excluded. Next requested features are drag ordering of requests/collections and MCP create/edit/start requests, variable listing/nonsecret reads, snapshot create/rename/delete. T96/T97 are planning only pending concrete scope/security confirmation; no new feature code. MCP credential-use versus disclosure boundary needs explicit agreement because arbitrary authenticated sends/echoed responses can reveal secrets despite no variable-secret read tool.

User requested Copy as JSON and selectable fields, declined new per-field copy/Finder actions, then clarified that variables and secrets must be replaced with actual values. Added SnapshotJSONExporter and one snapshot header action: pretty sorted JSON uses frozen submitted/observed request transport, actual captured inputs/auth resolvedSecret, source metadata and response details. It omits original templates rather than presenting unresolved tokens as the request. Missing encrypted context reports unavailable and omits placeholder URLs/local paths. Response body clipboard preview is bounded at 1 MiB, text or Base64, with original/preview byte counts and truncation flag. Encoding/body reading run detached; preparation failure leaves clipboard unchanged and shows an error. Persisted snapshots/encryption unchanged. Snapshot display text and shared header names/source now selectable; existing secret reveal/copy controls preserved.

Independent source review found omitted literal Basic password; resolvedSecret export plus focused assertion fixed it. Final review clear. Nine focused tests (SnapshotTests6+SnapshotJSONTests3) passed, log /Volumes/Data/tmp/postie-snapshot-copy-tests.log. Initial XCBuild manifest sandbox EPERM resolved by scoped cache escalation, no ACL changes. Release make app and nested signatures passed, refreshing dist/Postie.app. Native clipboard/selection gestures await user verification; no claim of native runtime validation. No new runtime data/keys read, no release-suite run/deployment/commit/push. Preserve unrelated pending distribution work; commit verified scope only after user confirms.
