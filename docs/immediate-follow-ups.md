# Immediate follow-ups

Recorded 2026-10-22 at the user's request. These tasks precede the general feature backlog. IDs are stable. T-103 is implemented, checked live and user-accepted. The remaining review fixes are queued separately.

## Queue

| ID | Outcome | Scope and acceptance | Dependencies / status |
|---|---|---|---|
| T-103 | Search MCP requests and select collections by name | Extend requests.list with optional query matching a request name or saved URL path; use collection names for MCP collection selectors. No secret resolution, sends or mutations during discovery. Preserve exclusions. | User-accepted 2026-10-22; 27 focused tests and live discovery/schema checks pass |
| T-104 | Preserve snapshot credential-header masking | Carry frozen sensitive/secret header names into snapshot template projection. A synthetic custom API-key override is masked in Block/redacted mode; explicit unredacted response behavior remains unchanged. | Reproduce static finding before fixing; App/Automation ownership |
| T-105 | Make IPC size failures explicit | Shared command/reply wire budgets; validate serialized command envelopes and return bounded correlated errors for oversized results. Below/above-boundary cases must distinguish size failure from unavailable app. | Reproduce static finding; Control/CLI ownership |
| T-106 | Recover moves with supported directory casing | Use consistent UUID-to-directory resolution for ordinary access and committed recovery. Mixed-case collections move/recover on case-sensitive storage without permanently blocking structural writes. | Case-sensitive synthetic reproduction required; Core/storage ownership |
| T-107 | Strengthen misleading or unreliable tests | Repair the reviewed failure-path, concurrency, timeout and vacuous assertions; demonstrate the intended behavior can fail. Prefer gates and bounded waits over sleeps. No comprehensive coverage expansion. | May run alongside fixes with nonoverlapping test ownership; test-only reviewer rechecks meaningfulness |
| T-108 | Make window navigation ownership explicit | Decide single window versus independent scene navigation. The previous recommendation was one window; no choice is confirmed yet. Verify no cross-window selection/search interference under the selected design. | Product decision pending; SwiftUI/App ownership |
| T-109 | Make variable suggestions accessible | Expose suggestion name/scope/selection and selection changes through native accessibility semantics. Verify keyboard behavior remains intact and VoiceOver can navigate/announce suggestions. | Native accessibility verification required; AppKit/UI ownership |
| T-110 | Confine elapsed-time presentation updates | Remove the idle workspace-wide published clock; update active elapsed-time displays locally. Verify elapsed time/cancellation and inspect idle invalidation before/after. No memory-leak claim or broad performance refactor. | Establish a measurable invalidation check; SwiftUI/App ownership |

## T-103 approved discovery contract

Goal: let an MCP caller find a saved request from familiar collection names and partial request names/routes, without first copying collection UUIDs.

- Extend the existing requests.list tool rather than add another overlapping tool.
- Optional `collectionName` scopes discovery; omitting it searches all MCP-accessible collections.
- Optional `query` uses case-insensitive substring matching against the request display name or saved URL path. This is not a regex, fuzzy ranking, network lookup or resolved-secret search.
- Search saved templates only. A leading origin template is treated as an authority; its hostname/port suffix is excluded. Path templates and percent escapes remain literal. Query strings and fragments are excluded. Do not resolve variables or match credentials in query values.
- Search uses the current loaded configuration, including pending edits, like ordinary request listing. “Saved templates” distinguishes authored templates from resolved outgoing values; it does not require waiting for disk persistence.
- Collection selectors across MCP schemas use names. Storage identities remain UUIDs; the dispatcher retains legacy ID-based calls for CLI and cached clients. Supplying both selectors is invalid. Names are trimmed and matched case-insensitively.
- Preserve collection/request exclusions and deterministic saved ordering. Matching must not send, select or edit requests.
- Duplicate collection names remain supported by storage. Ambiguous accessible names return an explicit error rather than selecting the first match. No global rename or uniqueness migration is required.

Functional acceptance: name-only match, path-only match, mixed case, collection scope, no matches, empty-query behavior, duplicate collection names, excluded resources and no variable/secret resolution. Keep assertions focused on returned identities/results and specific errors. Shared command behavior should remain consistent with CLI compatibility.

Ownership: main agent freezes the contract, owns integration/docs and build lock; a bounded executor owns schema/name resolution/filtering; an independent reviewer checks policy boundaries; a tester checks functional results. Dependencies: current automation baseline and its pending check-in boundaries. No new framework or storage migration is required by the proposed design.

Verification, 2026-10-22: all 27 focused AppAutomationTests, AutomationContractTests and MCPTransportTests passed without warnings; strict formatting and whitespace checks passed. App/CLI release builds and strict signatures passed. Independent source review found no unresolved defect, and a test-only audit confirmed interior-substring assertions after identifying that gap. Logs: `/Volumes/Data/tmp/postie-discovery-tests-final.log` and `/Volumes/Data/tmp/postie-discovery-build.log`. No live MCP acceptance or real HTTP send is claimed.

Live checks after restart, 2026-10-22: interior name/path substrings, trimmed mixed-case collection name, no matches, origin exclusion, blank-query ordering, legacy ID compatibility, invalid dual selectors and missing collection passed through MCP. No requests were sent or edited. This Codex session still advertises the prior schema despite accepting the new arguments; refreshed client metadata remains unverified. Duplicate/exclusion boundaries retain synthetic verification. User acceptance is pending.

Subsequent fresh-session verification, 2026-10-22: updated collectionName/query schemas are visible; live `bcc sta` search returned only get qbcc stats. User accepted the feature. This supersedes the schema-cache and acceptance caveats above. Separately checked in as 85fa94c after automation foundation 5973276, excluding deferred distribution work. Isolated foundation passed279 tests; discovery passed27 focused tests; release app/CLI builds and signatures passed.

## T-107 test repairs

- Restore a valid response body before the snapshot encryption-failure scenario; assert the intended error.
- Gate concurrent HTTP responses and shutdown start instead of assuming sleeps/yield counts prove ordering.
- Bound fixture startup and transport-continuation waits with guaranteed cleanup.
- Make stale-cancellation testing require a valid newer live run.
- Require both reused-ID MCP dispatches to overlap and complete in reverse order.
- Supply the plaintext sentinel and source-only variable through the relevant paths, or remove assertions that cannot establish the claimed behavior.

These items come from reviewers who read tests without production implementation context. They are confidence gaps, not proof of production failures.

## Shared execution and verification gates

The three correctness findings remain static until reproduced. For each fix: isolate a synthetic failing case, make the narrow correction, rerun the focused checks, then independent source/test review. Separate workers by source/test ownership; AppModel and shared persistence edits must be serialized. Keep one workspace writer and existing policy/crypto boundaries.

Preserve unrelated automation/distribution/editor changes. No runtime config, Keychain contents, credentials, deployments or real HTTP sends are needed for these fixes. Use Swift/Bash/Make and the pinned formatter. Update roadmap/handoff with verified facts. User confirmation precedes local check-in; no push. Existing live-acceptance gaps remain listed in roadmap.md rather than being hidden by this queue.

Evidence: [module and blind test review](review-2026-10-21.md), [automation contracts](automation-implementation.md), [roadmap](roadmap.md).
