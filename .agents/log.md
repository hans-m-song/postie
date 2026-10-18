# Decision log

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
