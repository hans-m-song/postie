# Postie roadmap

Updated 2026-10-22. This opening status is canonical; the task records below preserve decisions and historical checkpoints. IDs are stable and are not renumbered. Local Markdown remains the agreed tracker; TaskView migration is deferred until tracking is requested again.

Local check-ins on 2026-10-22: 9fb17f6 formatting/Linux CI, 5973276 ordering/MCP/CLI foundation, 85fa94c accepted MCP discovery, db42d35 documentation. Deferred distribution work is preserved on deferred/ota-updates at 88ebb7a, outside main; no push/deployment. Local settings/state remain untracked and locally ignored. The isolated foundation passed279 tests and discovery passed27 focused tests after separation. Historical uncommitted-status statements below describe their dated checkpoint.

## Selected next work

User confirmed PDF/HTML sizing and external opening on 2026-10-22 and requested check-in of the current body-support work. Fresh full baseline: 393 tests passed (Core164/Control19/Automation32/App178), strict lint and whitespace checks passed. This supersedes the remaining preview acceptance caveats below; large/password-protected PDFs and real upload workflows are not claimed individually user-tested. Embedded CSS/JS formatting remains deferred. Next selected work is T104–T110; user chose one main window for T108.

Current formatter direction (2026-10-22): user deferred embedded CSS/JavaScript formatting after the native evaluation. No formatter dependency or integration is selected. Retain existing highlighting, wrapping and JSON formatting. Earlier formatter proposals below are historical and superseded.

Implemented locally: default-on Wrap text for Raw/Pretty source previews, with horizontal scrolling when disabled; shared across responses/history/snapshots. All 14 focused tests, lint/syntax, release build and strict signatures passed; dist/Postie.app refreshed. The user positively received wrapping. The [earlier embedded formatter evaluation](embedded-formatter-evaluation.md) records the now-rejected Prettier/JavaScriptCore proposal. Native formatter evaluation replaces that proposal; no formatter dependency has been added, and inline CSS/JS formatting remains unimplemented.

Implemented locally: user verified HTML/embedded highlighting and approved filling the remaining pane with PDF/rendered previews plus external captured-file opening in Preview/default HTTPS browser. No Expand/pop-out window; external HTML browser permissions explicitly accepted. All 392 tests, lint/syntax, release build and strict signatures passed; dist/Postie.app updated. Follow-up awaits user verification; T111–T114 remains uncommitted.

T111–T114 are implemented locally as of 2026-10-22 and awaiting user acceptance. The full 379-test suite passed, including native hosted PDF, HTML loopback resource restrictions, MCP/CLI upload dispatch and automatic/manual mixed-method redirect regressions. Formatting/lint, syntax, release build and strict signatures passed; dist/Postie.app is updated. Three independent source findings were fixed and rechecked: snapshot hosting environment, encoded XML whitespace protection, and upload restoration after body-dropping redirects. Original-file references/local-path automation, no upload spool, metadata-only file snapshots with retained text parts, transient HTML resource opt-in and 25 MB PDF threshold are implemented. See [body-format-plan.md](body-format-plan.md). No commit until user verifies this build.

User accepted the integrated T115–T117 build on 2026-10-22 (“seems to work well”), checked in locally as 0476bf1 without push; this supersedes historical pending-acceptance notes below. User explicitly confirmed the Command-Shift-P follow-up on 2026-10-22: it prefills `>` command mode, preserving Command-P unified search and Command-F @ requests. The verified shortcut is being checked in separately; T111 HTML/XML remains next.

T117 refinement implemented locally: unprefixed palette includes every navigation, command and variable result; `@` narrows to requests, `#` to collections, `>` to commands and `$` to variable names. Command-P opens blank, Command-F prefills `@`. Native field-editor caret placement leaves prefixes unselected after opening/mode switching and preserves ordinary editing. All 23 focused refinement tests, lint and syntax passed; whole-app native/user acceptance and commit remain pending.

Earlier T117 baseline (superseded shortcuts/modes above): page/creation commands and `$` name-only variable lookup, breadcrumb padding and history-row selection fix. That baseline passed all 311 tests, lint and syntax checks; independent source and test reviews were clear. No secret decryption/value search or request execution was added. Native/user acceptance and check-in remain pending.

T-115 navigation chrome is implemented locally, selected by the user's subsequent UI feedback: sidebar retained but hidden initially with remembered visibility; icon-only toolbar actions; request/response layout moves to global Settings; a single searchable collection/request/snapshot switcher replaces standalone search. Snapshots match only their own names, with request/collection context displayed. Eight focused tests, formatting/syntax, release build and strict signatures passed; source/test review clear. User/native verification and check-in pending. This slice precedes the pending HTML/XML implementation; no rendered HTML/PDF/upload work is included.

T-115 refinements and [T-116 session request history](session-history-plan.md) are implemented locally: centered full breadcrumb, all collection/request rows without drill-in, Requests as the initial collection tab, and per-execution history with a side-by-side inspector. Explicit definition/configuration jumps retain their target tab. History retains at most 10 completed runs or 100 MB combined additional logical capture/body cache, oldest completed first; active runs remain visible. All 301 package tests, strict formatting and syntax checks passed. Native/user acceptance and check-in remain pending.

User selected T-111 HTML/XML Pretty source views and syntax highlighting next, including CSS/JS/JSON blocks in HTML. Native PDF preview T-112, rendered HTML T-113 (external requests off by default, opt-in resources; JavaScript execution out of scope), and arbitrary uploads T-114 are separate slices in the [body-format plan](body-format-plan.md). No new format implementation yet; plan confirmation pending. This user selection supersedes the previous next-task order; review fixes remain queued.

## Immediate follow-ups

Selected 2026-10-22: user authorized T104–T110 after checking in accepted body-support work. Current-source re-review is in progress before fixes; T108 window behaviour requires an explicit choice. Security/reliability/UI findings below remain unverified until reproduced or checked against the changed code.

The user requested all review findings be queued as immediate follow-ups, with MCP request discovery first, then approved its proposed plan. [Immediate follow-up specifications](immediate-follow-ups.md) records T-103 search/name-based collection selectors (user-accepted 2026-10-22; 27 focused tests and live discovery/schema checks pass), T-104 snapshot header masking, T-105 IPC budgets, T-106 move recovery, T-107 test repairs, T-108 window ownership, T-109 autocomplete accessibility and T-110 elapsed-time presentation. The remaining items are queued, not implemented. This sequence takes priority over the general next-feature candidates below.

## Current status

| Scope | Status |
|---|---|
| M1–M4 request execution, persistence, variables/auth and editing | Implemented; extensive local/user verification recorded in the feature guides |
| T-31 snapshots and T-95 layout | User-verified, committed `b066227`; navigation fix `983c27d`, collapsing/counts `2234b28` |
| T-100 manual encryption-key import/export | User-verified, committed `661e149` |
| T-96 collection/request ordering and cross-collection moves | Implemented; basic ordering/moves user-confirmed. Restart/cancellation feedback acceptance remains; intermittent insertion report unreproduced and deferred |
| T-97 opt-in authenticated local MCP | Implemented; real Codex discovery/start/result, request exclusion and three response modes verified. Inherited unused-secret redaction user-accepted |
| T-98 existing-instance CLI | Implemented; live read/send/result/cancel and temporary snapshot lifecycle verified; app-closed diagnostic corrected and rechecked |
| T-99 iCloud data sync | Deferred: no Apple Developer account; no sync backend implemented |
| Distribution T-86–T-94 | Local configuration exists; OTA/deployment deferred, no deployment claimed |
| T-101 documentation and Linux CI cleanup | Implemented locally: refreshed docs/logo, normalized Swift formatting, Linux format/syntax/workflow/whitespace checks. All279 existing package tests and local checks/builds/signatures passed; user review and hosted CI remain |
| T-102 module and blind test review | Completed source/test-only review using swiftui-pro and delegated module ownership; findings and proposed fixes in review-2026-10-21.md. Functional fixes await a scoped follow-up decision |

The ordering/MCP/CLI baseline is committed as 5973276; `3cca2f1` contains the earlier frozen unused-secret capture. Distribution work is isolated on deferred/ota-updates. Keep commits local; do not push without an explicit request.

## Current contracts

- Requests moved between collections keep their own templates/overrides, adopt destination inheritance, and carry snapshot grouping without rewriting captures. Active requests reject moves.
- MCP is opt-in and remembers enabled state. Collection exclusion blocks children; retained excluded snapshots stay excluded after source deletion.
- Global, collection and request response policies support Block, redacted body, and explicit unredacted response body/headers/URLs including redirects. The nearest override wins; global default is Block.
- Redaction uses frozen send-time effective secrets. New sends include unused effective encrypted values in a separate bounded payload; new snapshots encrypt it. Legacy snapshots retain only their recorded inputs.
- CLI requires a running Postie instance and intentionally bypasses MCP response/access policies. Direct secret-variable reads remain unavailable.
- Local builds remain sufficient. No deployment, Apple signing/notarization, sync, HAR or headless CLI is implied.

See [automation contracts and verification](automation-implementation.md), [user guide](automation.md), [snapshots](snapshots.md), [CI](ci.md), and [grouped deferred features](deferred-features.md).

## Remaining baseline verification

- New snapshot read through MCP demonstrates unused-secret redaction end to end.
- Collection exclusion blocks children/snapshots in the real connected client.
- Ordering and MCP enabled state persist after restarting.
- MCP request creation/editing and snapshot mutations; shared operations already passed through CLI.
- User acceptance of remaining settings/drag feedback, then scoped baseline check-in.

Latest cleanup gate: all279 existing package tests passed with zero failures/warnings, plus app/CLI builds/signatures, Linux formatting/parser and local workflow/whitespace checks. Earlier91,154 and38 gates are separate runs, not additive coverage. Real inherited-redaction and CLI app-closed rechecks passed after fixes. [Independent review](review-2026-10-21.md) identified correctness and test-confidence follow-ups that passing tests do not close; prioritize those before committing the remaining baseline.

## Next feature candidates

After closing this baseline: Copy as cURL, request tabs with history integration, then bulk query/header editing. These are priorities to select, not newly authorized implementation. Sync, HAR/OpenAPI/collection interchange, named environments, expanded body modes/protocols, automatic history/replay, memory profiling and distribution remain in the deferred inventory.

## Historical milestone and task records

The following dated sections retain original decisions and verification evidence. Statements such as “pending”, “current”, or “deferred” describe that checkpoint; the status above and linked feature guides supersede them.

## Current distribution decision — 2026-10-19

User explicitly deferred OTA updates and distribution work; local app builds are sufficient for now. T-86 through T-89 remain uncommitted, preserved as deferred work rather than an accepted baseline. T-90 automation remains deferred. Do not publish, deploy, or commit the pending distribution scope without renewed user direction/verification. The last verified local UI changes are already committed as f2fec33. Earlier completion statements below describe local implementation/checks, not current approval to ship this work.

## Current selected product scope — layout switching and snapshots

Completed and user-verified, 2026-10-20: snapshot field labels/names/values support selection and one Copy as JSON action exports actual resolved variable/path/secret values using frozen captured transport rather than current workspace values. No new per-field copy buttons or Finder action. Response-body clipboard preview is limited to 1 MiB with explicit byte counts/truncation, and Base64 for binary content. Nine focused tests passed; independent source review is clear. Local commit b066227 contains this follow-up and the underlying layout/snapshot slice. Historical independent native restart/resize recheck remains unperformed; user acceptance authorises this local check-in.

User selected layout switching and native snapshots on 2026-10-19; request tabs, drag-and-drop ordering and Copy as cURL are deferred from this slice. T-95 implements a remembered global side-by-side/stacked layout preference. T-31 implements explicit completed-exchange snapshots with frozen send-time request inputs, staged file-backed body storage, read-only viewing, rename/delete and source-independent sidebar grouping. No automatic history, HAR, replay or memory optimization expansion.

- [x] T-95 implementation: remembered layout preference/control and live native orientation check (final snapshot resize gate remains below).
- [x] T-31: capture/storage contracts and focused recovery/ownership checks.
- [x] T-31: save/view/rename/delete UI and independent source/test verification.
- [x] User verification and local check-in b066227. Independent native restart/resize automation remains an unclaimed check, not an active implementation task.

Verification on 2026-10-19: 18 focused tests passed (six snapshot storage/capture/lease cases, seven preparation cases, two app lifecycle/key-gating cases, three navigation cases). Independent final source review found no actionable issue. Isolated native checks exercised sending a loopback fixture, live layout switching, save/open/rename, delete confirmation/cancel and persisted snapshot reopening. Restart grouping and snapshot resizing defects found in those checks were fixed and rebuilt; their final native recheck remains pending while macOS automation times out. No release suite, deployment or commit is part of this slice.
- [x] User verified runnable changes; checked in locally as b066227, no push.

## T-94 — Cache policies and signed feeds (implemented; release suite skipped by user)

Approved 2026-10-19: implement the three improvements from the distribution review. Replace legacy CloudFront forwarding/TTL configuration with cache policies; disable caching for `releases/appcast.xml` and cache immutable ZIP archives for up to one year. Upload ZIPs with matching immutable cache headers. Updater-enabled bundles require signed feeds and pre-extraction archive verification; publication verifies feed signatures before uploading unchanged signed bytes. Ordinary local builds remain updater-disabled. Preserve Sparkle's existing signed-feed failure fallback defaults. No deployment, publication or unrelated signing/CI changes.

- [x] Implement cache policies and immutable archive metadata.
- [x] Enable signed feeds; add focused synthetic tampering, legacy resume and packaging checks.
- [ ] Execute focused release suite — skipped at user request; runtime result unverified.

Terraform fmt, isolated backendless init/validate and one temporary mock test passed. Bash syntax, release-test Swift compilation and independent final source review passed. Release execution remains unverified: default Foundation temp writes hit sandbox restrictions; automatic approval review rejected escalation because the harness reads synthetic environment variables. User subsequently requested skipping the test; permission is no longer pending and no execution retry is authorized. No deployment, publication or commit. Shared update hostname/hosting is a future consideration only; user explicitly requested no changes now.

## T-92 — Bounded object version history (verified locally; user verification/deployment pending)

Approved 2026-10-19: retain the current object version and four noncurrent versions. Configure a bucket-wide lifecycle rule to expire additional noncurrent versions once they meet the one-day minimum age. Current objects and uniquely named release archives remain untouched; this is per-object history, not a five-release limit. Depends on bucket versioning. Acceptance: backendless validation and one isolated mock test verify the enabled rule, count, age and absence of current-object expiry. No deployment or commit before user verification.

- [x] Add retention rule and document its semantics.
- [x] Verify Terraform locally without AWS access.

Disposable-copy backendless initialization, validation and one temporary mock test passed. Formatting/diff checks and independent source review passed. No repository tests added, AWS access, deployment or commit. The subsequent online guidance review is recorded in the deferred local distribution-review.md document; it does not authorize the suggested follow-up changes.

## T-91 — Custom distribution domain (verified locally; user verification/deployment pending)

Approved 2026-10-19: configure `postie.cloud.axatol.xyz` in Terraform, using the existing certificate ARN from SSM `/infrastructure/acm/cloud.axatol.xyz/certificate_arn` in `us-east-1`. Scope includes CloudFront alias, SNI certificate with TLS 1.2 minimum, custom release/feed URLs and Route 53 A/AAAA aliases. User confirmed the existing public `cloud.axatol.xyz` hosted zone. Certificate issuance/validation remains externally managed. Verify with backendless validation and focused mock-provider tests; no AWS reads, deployment or publication. OTA releases and CI automation remain deferred. Commit only after user verification.

- [x] Configure domain, certificate lookup and DNS aliases.
- [x] Verify local Terraform contracts and record results.

Backendless disposable-copy initialization, validation and two mocked plan tests passed. Formatting/diff checks and independent static review passed. Live hosted-zone and certificate availability remain unverified; no deployment or commit.

## T-89 — Local deployment and releases (code complete locally; deployment pending)

Approved 2026-10-19: deploy Terraform and publish updates locally for now, with future automation retained as a roadmap item. Consolidate hosting into one Terraform root; remove unused GitHub workflows, synchronization, OIDC roles and permission boundaries. Keep reusable Bash/Swift release tooling behind Make targets, so future CI can call the same checked commands. Retain Sparkle integration, AWS profile/backend configuration, default Sydney region, keypair validation and archive-before-feed publication. No real deployment, release, secret access or Git mutation.

- [x] Consolidate local hosting configuration and remove unused CI/IAM setup.
- [x] Add local Make deployment/release commands and focused verification.
- [x] Record future automation scope and update operator documentation.

Verified 2026-10-19: AWS-only root fmt/backendless init/validate and three mock hosting contracts pass independently. Six synthetic release cases pass through Make with actual Sparkle tools and stubbed remote/build commands; increasing-build rejection is included. Independent disposable wrapper checks reject four unsafe Git states before Terraform/AWS calls and accept the fetched-origin/main fallback. Make dry runs, Bash syntax, ignored config/plan paths and diff checks pass. Corrected the previously ineffective viewer TLS minimum for CloudFront's default certificate; no custom domain/certificate added. No production defect remains from review. No app tests rerun, live deployment, publication, credentials/key access or state migration. Uncommitted until user verification; T90 retains future automation.

## T-90 — Automate deployment and releases (deferred)

Goal: run the verified local Make interfaces from CI when automation is requested. Scope: thin workflow calling `infra-init`/`infra-plan`/`infra-apply` and `release`, short-lived OIDC AWS access, scoped runtime signing-key access, appropriate plan/release approvals and serialized publication. Constraint: one implementation of packaging/signing/publication, shared by local and CI entry points; preserve increasing build numbers across both paths; do not provision unused credentials or roles now. Dependencies: T-89 local command verification and operator deployment/install validation. Acceptance: a synthetic CI dry run proves the same commands, full tag/main history checks, build ordering and archive-before-feed contract, then an explicitly authorized end-to-end release. Owner: future implementation task; no active blockers or work assigned.

## T-88 — Distribution configuration simplification (code complete locally; deployment pending)

Approved 2026-10-19: fixed project identity, OIDC issuer and resource naming become locals or derived metadata. Default region to `ap-southeast-2`; retain local profile and state bucket/key settings, with OIDC credentials in CI. Remove the CloudFront ID handoff in favor of account-local distributions with `Application=Postie` ownership checks. Remove custom KMS and deferred Apple signing/notarization inputs. Automatically publish generated workflow configuration to GitHub variables; preserve secrets for signing keys/tokens. No deployment or real-secret access.

- [x] Simplify Terraform inputs and bootstrap/distribution dependency flow.
- [x] Remove unused Apple release tooling and custom KMS scope.
- [x] Verify focused mock and release behavior tests and update setup documentation.

Verified 2026-10-19: both roots pass formatting, backendless initialization with locked providers, validation and three focused mock tests each. Five existing release-publication scenarios pass after Apple removal. Independent static review found no remaining concrete defect; independent syntax checks passed all three workflow YAML files, 14 embedded shell blocks and release scripts. Boundary/inline/release policy JSON lengths are 4,163 / 2,830 / 1,825 characters, within their limits. Backend/tfvars paths are confirmed ignored. No app tests rerun, live policy simulation, backend access, AWS/GitHub deployment or real credential/secret inspection. Changes remain uncommitted until user verification. T-88 supersedes T-87's ID binding and bootstrap OAC ownership; migration is required if that earlier layout was externally deployed.

## T-87 — Bounded infrastructure bootstrap (code complete locally; deployment pending)

Approved 2026-10-19: define the GitHub deployment role in this repository, look up the existing OIDC provider, and separate manually applied `infra/bootstrap` from automatically applied `infra/distribution`. Restrict deployment to exact Postie resources, ownership tags and a mandatory release-role permissions boundary. Bootstrap owns both roles, their trust/tags/boundaries and origin access control; distribution manages only the release publishing policy. Initial CloudFront creation is manual; bootstrap then binds its exact ID for automatic updates. No deployment, credential inspection or live AWS/GitHub calls.

- [x] Implement bootstrap roles, boundaries, OIDC lookup and scoped backend/secret access.
- [x] Wire distribution inputs and validation-only bootstrap workflow.
- [x] Run focused offline checks and independent security review.
- [x] Document manual initialization, automatic updates and replacement limits.

Verified 2026-10-19: both roots passed formatting, backendless initialization with locked providers and validation. Six focused mocked Terraform tests passed (three bootstrap configurations and three distribution role-contract cases). Independent static security review found no remaining concrete defect; separate synthetic checks confirmed explicit deny preservation and managed/inline size limits, including eight secret references and optional distinct/shared KMS keys. Largest representative infrastructure boundary: 5,371 / 6,144 characters. No live authorization simulation, AWS/GitHub deployment, environment inspection or real-secret access. T-86/T-87 remain uncommitted pending user verification.

## T-86 — Distribution configuration and Sparkle (code complete locally; deployment pending)

Approved 2026-10-19: code/configuration only for Terraform-managed S3/CloudFront, GitHub OIDC release access, AWS Secrets Manager to GitHub secret synchronization, infrastructure-change and tag-release workflows, and Sparkle integration. Assume an AWS account and compatible macOS runner exist. User handles deployment, backend/bootstrap, key creation and real credentials. Support ad-hoc app signing plus Sparkle archive signing without Apple membership; optional Developer ID/notarization when configured. No AWS/GitHub mutations, live secret access or deployment during implementation. Secret synchronization stores secret values in Terraform state; document this explicitly.

Verified: 173 app/core tests, five release-pipeline tests using actual Sparkle tools with synthetic keys and mocked AWS/build commands, backendless Terraform init/validate/fmt, workflow/script syntax, independent source review, native and universal release builds plus nested signature checks. Release tooling and its harness now use Bash/Swift/Make only, per the 2026-10-19 correction; the five cases passed through `make release-test`. Default local build restored without a live feed. Native UI automation was unavailable; live OIDC, hosting, notarization and actual update installation remain deployment checks. See distribution.md and infra/distribution/README.md. No commit until user verification.

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
Native embedded formatter research completed on 2026-10-22: [evaluation](native-formatter-evaluation.md). Oxfmt standalone is the proposed CSS/JS candidate; no dependency or integration approved. Packaging/runtime checks and user approval remain pending. Inline CSS/JS formatting is not yet implemented.
