# Postie roadmap

Recorded 2026-10-17. M1–M4 are complete locally. M5 remains not started. IDs are stable; do not reuse deleted IDs. Paste cURL is deferred beyond this implementation slice. See implementation-m3-m4.md for decisions, audit dispositions, verification and limits.

This document records the approved high-level breakdown. User agreed on 2026-10-17 to keep local planning for now; TaskView records have not been created. Revisit TaskView migration only when project tracking is requested again.

Latest scope, 2026-10-18: parameter polish, Copy as cURL and native snapshots are selected for the next implementation slices. Snapshots support Rename and Delete; HAR export and Paste cURL remain deferred. See [grouped deferred features](deferred-features.md) for the consolidated backlog and explicit non-goals. Older M5-deferred wording below records prior scope, not cancellation of these selected slices.

## Shared task contract

## T-85 — Header wrapping and top-aligned rows (complete locally)

Approved 2026-10-19: extend automatic wrapping and vertical growth to request headers, including inherited/auth rows. Align names and values at the top of query, path and header rows. Preserve masking, explicit Reveal/Hide, variable inspection/completion and source navigation. No response, storage or credential behavior changes. Verify narrow-pane long headers and mixed-height rows.

Verified: release/signature/diff checks and independent source review passed. Isolated native 335-point dark/light checks covered long inherited/auth header names, wrapped inherited/editable values, top-aligned query/path/header rows, editable header shrink/highlighting and collection header source navigation/editing. Credentials remained masked; no successful secret decryption exercised. No new/rerun tests for this presentation-only change.

## T-84 — Long parameter cells (complete locally)

Revised 2026-10-19: query names/values and path names/values wrap automatically and grow vertically to fit all content. Remove the three-line cap, expand controls and popovers from the initial 2026-10-18 implementation. Keep short rows compact, path names read-only, template colours and variable completion, existing query URL synchronization and exact parameter bytes. Header/auth/URL editors retain their existing layout. The request pane owns scrolling.

The initial implementation passed 173 existing functional tests. The 2026-10-19 refinement passed release/signature/diff checks, independent source review and isolated native long-input wrapping, growth/shrink, URL synchronization, outer scrolling and light/dark checks. See parameter-polish.md.

## T-83 — Inherited authentication summary and navigation (complete locally)

Request Auth now displays inherited collection authentication type, relevant public fields and a masked derived header with explicit Reveal/Hide. Both source actions open collection Auth directly. Preview uses request-scoped variables and retains identity, configuration and navigation stale-result checks. Verified on 2026-10-18: 173 existing functional tests, release build, strict signature/diff checks, and isolated 335-point native summary, destination, Back navigation and safe malformed-credential reveal checks. Successful credential reveal was not exercised against a real Keychain item.

## T-82 — Unified derived headers and captured sources (complete locally)

Approved 2026-10-18: Request Headers includes collection and selected auth rows (including request-level auth) as read-only rows with source/status, explicit Reveal/Hide for auth and source navigation. Captured request headers in final/redirect responses use matching Name/Value table presentation and immutable send-time source labels, never live configuration inference. Preserve manual request-header precedence, explicit secret access and stale-result cleanup. Query checkboxes unchanged; the empty entry row intentionally has none, as clarified by the user.

Verified: 173 functional tests, independent review, warning-free release, strict signature/diff checks and isolated narrow-pane native source-navigation/masking/capture checks. See header-tables.md for evidence and limits.

## T-81 — API key authentication and header precedence (complete locally)

Approved 2026-10-18: collection/request API key auth with literal header name and encrypted, template-capable value sent verbatim. Enabled manual request headers take precedence over selected request auth, inherited collection auth and collection headers, case-insensitively; explicit Inherit/None remains. Shadowed auth inputs are not decrypted/resolved. Custom auth header names join masking and cross-origin stripping. Reuse secret editor/lifecycle and existing at-rest encryption; no query-string API keys or new credential storage system. Focused preparation/persistence/loopback and synthetic native gates; no real credentials/configuration accessed.

Verified: combined 165 functional tests plus focused 35 preparation tests covering three late additions (168 distinct tests). Independent source review clear; release warning-free and signature/diff checks passed. Native collection/request auth controls, 335-point layout and secret draft discard checked. See api-key-authentication.md for evidence and limits.

## T-79 — Bidirectional query editing (complete locally)

Approved 2026-10-18: URL and query table synchronize additions, edits, deletion and enabled state. Disabled rows stay in table and are excluded from URL/execution. Preserve duplicate keys, ordering, empty values, templates, fragments and percent encoding; retain partial URL typing and avoid double appending legacy URL/query inputs. Main owns integration and documentation; bounded core/app executors and independent focused verification. No bulk editing or unrelated parameter layout work.

Verified with T-80: 155 functional tests, independent source review, isolated native checks and release/signature validation. See query-and-global-settings.md for decisions, evidence and limits.

## T-80 — Global execution defaults and size units (complete locally)

Approved 2026-10-18: global Settings page for redirects, timeouts and response-size limit; decimal KB/MB entry. Each unset request value inherits, with the inherited numeric value shown as placeholder. Clearing an override restores inheritance; redirects have a Use global choice and limits retain explicit Unlimited. Existing concrete settings remain explicit, new requests inherit. Functional gates cover persistence, effective execution options and unit conversion.

## T-78 — Restore request section tabs (complete locally)

Requested 2026-10-18: restore Request/Auth/Variables/Settings tabs. Request keeps Query/Path/Headers/Body accordions, all expanded initially. Preserve session collapse choices, inherited variable popups, secret lifecycle and navigation. See request-tabs-restoration.md. This supersedes the relevant T-74 layout choice; multi-request tabs T-77 remain deferred.

## T-74–T-75 — Request accordions and inherited value inspection (complete locally)

Approved 2026-10-18: one request pane with counted accordions instead of section tabs, configured-content defaults and automatic query/path expansion, plus inherited-header variable popups. See request-accordions.md for scope and gates. T-76 bulk key/value editing and T-77 request tabs are deferred; future Back/Forward must activate the destination request tab. No M5 or memory-budget expansion.

## T-70–T-73 — Navigation and editor consistency (complete locally)

Approved 2026-10-18: Back/Forward navigation, inherited header highlighting, table gutter/font consistency, one-line growing body authoring, and closed partial-name autocomplete. See navigation-and-editor-polish.md. Verified with 115 functional tests, independent review/scope audit, native checks and release/signature validation; no M5 or memory-budget changes.

## T-68–T-69 — Compact variable popovers and autocomplete values (complete locally)

Approved 2026-10-18: ordinary-value previews in autocomplete and compact native value/source inspector, with an eye action for secrets. Preserve input focus, effective scope, explicit-only decryption and existing navigation. See variable-popover-polish.md.

## T-64–T-67 — Inherited headers, variable inspection and JSON editing (complete locally)

Approved 2026-10-18: one headers table with read-only inherited rows/source navigation, JSON newline indentation and selected-text wrapping, token-anchored variable inspection/value/reveal/definition navigation, and the subsequently reported revealed-secret column alignment repair (T-67). See inherited-headers-and-editing.md. No M5 or memory-budget expansion.

Verified 2026-10-18: 106 functional tests (Core61/App45), independent reviews, final release/signature and isolated native checks passed. The secret alignment repair covers collection/request shared editing. See inherited-headers-and-editing.md for exact evidence and limits.

## T-58–T-63 — Authoring and response privacy follow-up (complete locally)

Authorised2026-10-18: JSON delimiter pairing, focused URL highlighting, broader variable autocomplete, send-time response-header masking with Reveal/Copy, referenced-variable table in Variables, and inline secret-edit controls. See authoring-follow-up.md for ownership/checklist/choices. Existing Move up/Move down remains; drag-and-drop and memory-budget changes deferred. Depends on current native editor/M3-M4 behavior; no M5 expansion.

Verified 2026-10-18: independent 93 functional tests passed (Core61/App32), source reviews closed, release build and isolated native checks passed. See authoring-follow-up.md for evidence and limits.

## T-57 — Response presentation defaults and wrapping (complete locally)

Authorised2026-10-18: default supported JSON/+json responses to Pretty; other text and invalid/oversized JSON fallback use wrapped raw text. Keep Raw selectable, binary presentation unchanged, existing1MiB preview/5MiB formatting limits, and one vertical scroll owner. Executor owns ResponseView/HighlightedResponseText; main integrates and checks isolated native JSON/plain/fallback/resize behavior; independent review/test gate. Memory-budget changes remain explicitly deferred.

Verified2026-10-18: independent82 existing tests passed, no new automated tests. Release build and source review passed. Native synthetic checks passed JSON/+json defaults, manual Raw, invalid/6MiB JSON fallback explanations, JSON-labeled binary Raw/no formatter error, and unbroken plain text wrapping. Raw reflow was verified at335pt and464pt split widths by toggling the sidebar; the failed divider-drag attempt is not resize evidence. One outer vertical scrollbar reaches the body end. Fixture /presentation provides controlled valid/invalid/oversized/binary cases. No source-byte or limit change; isolated app and fixture closed. Light appearance/IME and new memory profiling were not exercised.

## T-56 — Referenced variable value actions (complete locally)

Authorised2026-10-17: View full ordinary values, Reveal/Hide secrets and Copy full values directly from the referenced-variable summary. Decrypt only on explicit Reveal/Copy; clear revealed buffers on dismissal/navigation and reject stale async results. Reuse existing variable resolution and Keychain-backed decryption. Main owns integration/docs; referenced_value_actions owns the row/view; independent review and isolated synthetic native check. No comprehensive tests or deferred feature expansion.

Verified2026-10-17: release build and82 existing functional tests passed; independent review closed a captured-tab-state timing gap using a live activity binding. Native synthetic checks passed full-value viewing, full ordinary Copy, secret Copy without Reveal, Reveal/Hide and tab dismissal. Narrow-pane label wrapping corrected. Async stale-result guards are source-reviewed, without delayed-Keychain fault injection. No new automated tests. Copy intentionally places plaintext on the system clipboard; hiding the popover does not clear the clipboard.

## Approved collection settings follow-up — complete locally

T-52 Collection Variables/Headers/Auth page and shared defaults; T-53 variable tables/trailing rows/reversible Secret checkbox; T-54 URL variable autocomplete; T-55 collection context menu without overflow icon and tighter request-method inset. Authorised2026-10-17. Inheritance, compatibility, ownership and acceptance: collection-settings.md. Depends on M3/M4. No M5 expansion.

Verified2026-10-17: independent82 functional tests, release build, source reviews and isolated native collection/table/completion/inheritance/secret/restart checks passed. Existing request auth remains explicit; new requests inherit. Review repairs and residual limits are recorded in collection-settings.md. Local check-in only; no push.

## T-50 — Table alignment and input typography (complete locally)

Align query/header headings, saved rows and trailing entry rows using matching rail widths/padding. Use monospace for method, URL, parameter/header names and values, and numeric settings inputs. Preserve focus/promotion and current storage behavior. Bounded presentation-only change; release build and isolated native visual/editing check, no new automated tests. Main owns verification/docs; table_alignment_typography owns RequestEditorView.swift.

Verified 2026-10-17: release build and strict signature check passed; native 900×652 window shows aligned query/header/path dividers and monospaced inputs. Continuous Tab entry promoted two query and header rows without losing focus. Widened response-limit field to120pt so the default grouped byte count fits. Independent scoped source review found no findings. No automated tests added or rerun for presentation-only changes.

## Initial Git baseline — complete locally, 2026-10-17

T-47: independent security, architecture/performance and UI/specification reviews; correct substantiated findings, verify main functional requirements, audit repository contents and publish the initial baseline to configured origin. See baseline-review.md for roles, findings and verification checklist. No comprehensive test expansion or deferred product work.

T-48 (complete): explicit Rename request… sidebar context-menu action, reusing the existing name dialog and autosave. Native rename/Cancel and persistence after restart passed. Depends on existing M2 saving; bounded UI-only change.

T-49 (complete): removed project Python dependency per user clarification. Makefile packages/signs the app; a dependency-free Swift loopback fixture replaces the Python test server. Independent source review, all 46 existing functional tests, release packaging/signature and isolated launch gates passed. No comprehensive test expansion. Git history/upstream record publication state for T-47.

T-47 Git outcome: local baseline `a3aa26b` on main. User explicitly chose to keep commits local; no push is authorised or pending.

## Approved usability follow-up — complete locally, 2026-10-17

User approved this bounded slice after M1/M2: T-36 trailing empty query/header rows with focus retained; T-37 whole-heading disclosure hit targets and response headers collapsed by default; T-38 one-hop manual redirect from captured exchange without mutating saved settings; T-39 default configuration at ~/.config/postie without silently migrating/merging existing stores; T-40 literal :name path-segment parameters, encoded substitution and missing-value diagnostics; T-41 full-width method/URL/Send toolbar above both panes. Existing directory overrides remain. Verification uses synthetic isolated paths only. Main owns integration and durable docs; bounded workers own core path/storage, HTTP/model continuation and native views. Independent test/review required before completion.

T-42 is deferred: session request log with expandable request headers, response headers and body. It does not authorise persisted history. M3/M4 were subsequently authorised; M5 remains deferred.

Additional user steering during validation: T-43 (complete) Request/Settings tabs, moving redirect/time/size options to Settings; T-44 (complete) remove unexplained response right-side unused band by fixing container width. T-41 also addresses compact-window clipping. No deferred feature expansion.

T-45/T-46 (complete): expand response/request bodies vertically under each pane's single outer vertical scrollbar, retaining bounded response previews and normal request editing/undo.

Each task inherits its milestone goal, constraints, acceptance gate, and dependencies below. Main agent owns integration/handoff; bounded executors implement and independent tester/reviewer verify. User authorised M1/M2 on 2026-10-17 and delegated remaining implementation decisions. See implementation.md for concrete boundaries, ownership and evidence checklist. No M3–M5 work is authorised by this slice.

## M1 — Make an HTTP request (complete)

Goal: enter a URL, send a request, inspect its result.

| ID | Deliverable | Dependency |
|---|---|---|
| T-01 | macOS shell with side-by-side request-left/response-right panes | Minimum macOS version decision |
| T-02 | HTTP model and request preparation interface | None |
| T-03 | Method, URL, query and header editors | T-01, T-02 |
| T-04 | Text/JSON request bodies | T-02, T-03 |
| T-05 | Concurrent per-request execution, cancellation, configurable timeouts/redirects, errors | T-02 |
| T-06 | Visible running state, duration/progress, expandable per-hop headers and raw response | T-01, T-05 |
| T-33 | File-backed response bodies, bounded previews and per-run cleanup | T-02, T-05 |
| T-34 | Ongoing Requests view with live state/count, per-run Cancel and Open Request | T-01, T-05 |

Gate: GET and POST to a local fixture; run different request identities concurrently, reject repeated sends of the same identity and cancel one without affecting another. Indicators/cancel remain accessible across navigation. Associate results/files with immutable run IDs; verify edits, repeated sends and late cancellation callbacks cannot overwrite/misattribute results. Verify Follow redirects on/off and expandable observed hop headers. Resolve cache, redirect loops/cross-origin handling and duplicate parameter/header representation; automatic cookie storage is deferred. Establish relaxed configurable time/transfer limits and bounded previews over file-backed bodies; numerical defaults are approved below, while disabled-limit semantics remain to be verified. Verify delayed/large/unknown-length responses, disk failures and cleanup. Agree fixture depth before implementation. See execution.md. UI and execution may proceed separately after T-02's interface is agreed; M1 completes only after T-33.

## M2 — Save and organise requests (complete)

Goal: resume saved work after restart. Depends on M1.

| ID | Deliverable | Dependency |
|---|---|---|
| T-07 | Versioned JSON storage format (current default ~/.config/postie) | T-02 |
| T-08 | Collection creation, rename and deletion | T-07 |
| T-09 | Named request creation, duplication and deletion | T-08 |
| T-10 | Automatic save and restore | T-07, T-09 |
| T-11 | Visible save/read failure handling; no silent overwrite | T-10 |
| T-29 | Ordered collection index, per-request files and partial-operation recovery | T-07, T-09, T-10, T-11 |

Gate: create multiple collections/requests, restart, and recover saved configuration. Verify malformed-file and failed-write handling. No folders, Git integration, automatic history, or response persistence in M2; explicit snapshots arrive in M5. Agree format, literal-field plaintext boundaries and deletion/recovery behaviour before parallel persistence/UI work. A version newer than supported must not be silently rewritten. M2 does not provide structured authentication/secret variables; ordinary literal configuration is persisted as entered.

Storage proposal: one directory per collection, collection.json with ordered request IDs, one file per request identified by UUID filename, and separate globals.json. T-29 owns recovery between multi-file writes; see storage.md. Physical collection directories do not introduce product folders. Resolve multiple-app-instance writes and safe collection deletion before implementation.

## M3 — Variables and authentication (complete locally)

Goal: reuse configuration with predictable substitution. Depends on M2.

| ID | Deliverable | Dependency |
|---|---|---|
| T-12 | Global, collection, request variable editors | T-07 |
| T-13 | Request > collection > global resolution | T-12 |
| T-14 | Substitution in URL/query/header/auth/text body | T-13 |
| T-15 | Missing-reference diagnostics and resolved-value source | T-14 |
| T-16 | None, Basic and Bearer authentication | T-14 |
| T-17 | Encrypted auth/secret variables and Keychain-held key integration | T-07, T-16, T-32 |
| T-32 | Simple at-rest encryption envelope, app key and failure handling | T-07 |

Gate: override a name at all three scopes and inspect outgoing values; unresolved variables block sending/copying once cURL exists; encrypted values survive restart using the Keychain-held application key. No recursion or dynamic values. Resolve parsing, encoding, literal delimiters, secret visibility and Authorization conflict rules before implementation. Structured auth/secret saving must ship with encryption, never through a temporary plaintext path. Cover missing/denied Keychain, literal-to-secret conversion and independent duplicate/delete behaviour without app-key removal. No record/field binding or rename-dependent re-encryption is required initially. T-32 covers modified ciphertext rejection, unknown envelopes, no plaintext fallback and actual built-app Keychain access; see encryption.md.

## M4 — Highlighting and editing (complete locally)

Goal: comfortable editing and response inspection. Depends on M3; editor feasibility can be investigated earlier.

| ID | Deliverable | Dependency |
|---|---|---|
| T-18 | Validate AppKit/SwiftUI editor approach | T-01 |
| T-19 | None/JSON body syntax selector with independent template cues | T-18, T-14 |
| T-20 | URL/header template and missing-reference highlighting | T-15 |
| T-21 | Stacked response headers/body, collapsed redirect hops, None/JSON and Raw/Pretty | T-06, T-18 |
| T-22 | Stable selection, cursor, undo and responsive editing | T-19, T-21 |
| T-23 | Essential shortcuts and loading/error states | T-01 through T-22 as relevant |
| T-30 | Native request search palette: name and stored URL/path across collections | T-09, T-10, T-29 |
| T-51 | URL variable and whole-segment path parameter highlighting, missing cues | T-14, T-20, T-40 |

Gate: edit incomplete JSON containing templates without cursor disruption; inspect JSON/non-JSON; preserve original response data. Apply bounded reads/highlighting and full-body formatting thresholds over M1's file-backed bodies without blocking UI. Clearly mark partial previews without truncating stored bodies. Native editor feasibility is established for the checked flows; IME and large-input latency remain unverified.

T-30 gate: Command-K/menu invocation, case-insensitive name/URL/path matching, duplicate-name context, keyboard/pointer selection, empty/no-match handling and preserved edits on navigation. Search updates with saved-request changes, uses stable identities and opens without sending. No template resolution, persistent search index or generic command framework. See navigation.md. Can proceed independently of highlighting once persistence interfaces are stable.

## M5 — cURL, saved snapshots and personal-use release

Goal: routine personal use. Depends on M4.

| ID | Deliverable | Dependency |
|---|---|---|
| T-24 | cURL generation from shared prepared request | T-02, T-16 |
| T-25 | Shell quoting, bodies, headers and auth | T-24 |
| T-26 | User-accessible credentials in deliberate cURL copying | T-17, T-25 |
| T-27 | Focused verification of representative workflows | T-01 through T-26 |
| T-28 | Locally installable build and storage/recovery documentation | T-27 |
| T-31 | Explicit immutable request/response snapshots, view and deletion | T-05, T-06, T-11, T-17, T-21 |
| T-35 | Paste cURL: bounded parser, request preview, edit and save without execution | T-02, T-09, T-17, T-25 |

Gate: compare app/cURL request intent using an approved local fixture, including quotes, Unicode, JSON and authentication; restart and verify encrypted storage/Keychain access. Agree target shell and credential-copy interaction. Signing/distribution requirements are unresolved; no App Store release is assumed.

Credential policy clarified 2026-10-17: allow the local user to view/edit sensitive values and deliberately copy executable commands containing them. Proposed ciphertext lives in JSON with the key in Keychain. No mandatory redaction or extra app-level approval flow is required; reveal/masking presentation remains a UI choice.

T-27 also depends on T-29 through T-33 and verifies persistence recovery, search, encrypted values, concurrent result/cancellation ownership, redirect headers and large-response snapshots. New tasks are appended as stable IDs rather than renumbering T-01–T-28.

T-27 also depends on T-34. Verify live activity navigation returns to the correct request without sending, cancellation is isolated, completion during row selection is safe, and the empty state/count are accurate.

T-31 gate: manually save a completed exchange, restart and reconstruct request intent/view the original response despite source edits/deletion and live credential changes. Use metadata plus full body sidecar, staged before publication; retain the source body through concurrent save/rerun. Support non-2xx and non-text responses; no automatic history. Capture send-time templates, frozen encrypted inputs/settings and observed redirect chain. Resolve preparation compatibility and publication/recovery before implementation. See snapshots.md/encryption.md/execution.md. T-31 also depends on T-33; snapshot work can proceed separately from cURL after interfaces are agreed.

## Verification and completion

Latest M3/M4 gates, 2026-10-17: independent core/security/UI reviews, fixes and final functional verification complete; `make test` passes66 (Core53/App13). Release build/strict signature and isolated native syntax/undo/focus/search/secret restart checks passed. Ad-hoc rebuilds prompted for Keychain access, user approved; unattended continuity remains unverified. See implementation-m3-m4.md. Earlier milestone counts below are historical.

M1/M2 completion, 2026-10-17: T-01–T-11, T-29, T-33 and T-34 are complete locally. Independent verification passed 36 tests with zero failures; final source review found no blocking findings. The final app bundle was rebuilt/signature-verified and real UI flows checked, including concurrency, redirects, cancellation and restart persistence. See implementation.md for precise evidence and residual gaps. T-04 supports text/JSON bytes in a raw editor; T-19 owns syntax selection/highlighting. T-28 remains later release readiness despite the current local bundle.

Decisions approved 2026-10-17: target the primary Mac initially (its intended OS/signing identity still needs verification); configurable 5-minute inactivity/30-minute overall/1 GiB transfer defaults; 10 followed redirects maximum without automatic cross-origin authentication; dimmed source placeholders preserve snapshot navigation after source deletion; general configuration import/export deferred but Paste cURL is in scope. Local roadmap remains the tracker. These decisions supersede older pending/default wording above. A host version check reported macOS 27.0.1; do not equate that observation with verified primary-Mac compatibility or signing setup.

T-35 gate: supported quoted/multiline curl input becomes a previewable draft, never shell execution, automatic file access or network sending. Preserve documented supported flag semantics and reject unsupported constructs visibly. Verify supported cURL export/import round trips, raw body preservation, auth encryption and no original-command persistence. See curl-import.md. T-27 also depends on T-35.

Latest UI clarification, 2026-10-18: T-78 restores Request/Auth/Variables/Settings tabs. Query/Path/Headers/Body remain initially expanded accordions on Request; see request-tabs-restoration.md. T-06/T-21 stack response exchange sections with redirect hops initially collapsed and final response expanded. No separate response Body/Headers/Redirects tabs. T-19/T-21 offer only None/JSON syntax; switching changes presentation, not bytes or Content-Type, and None preserves template cues. Verify defaults, independent scrolling and explicit formatting; XML/other languages remain deferred.

UI clarification, 2026-10-17: side-by-side request/response initially; layout toggle deferred. T-31 groups snapshots beneath originating requests in the sidebar and must preserve discoverability after source deletion. Physical snapshot storage stays separate for simpler deletion independence. Current visual concepts and exact image-generation prompts are in docs/mockups/README.md; concepts are not an implemented or approved interface.

Focused checks: resolver precedence/errors, prepared-request construction, JSON round trips/failure recovery, shell quoting. Manually assess the runnable editor and primary workflow. Add no broad UI suite without an agreed purpose. Each completed task requires evidence, an updated status, and any remaining limitations. M2 is the first useful stopping point; M5 completes the current initial scope.
