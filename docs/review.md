# Independent adversarial documentation review

Applicability note, 2026-10-17: entries below review historical drafts. Later user direction simplified encryption to at-rest protection without record/field binding and added file-backed large responses, redirect inspection and per-request concurrent execution. Current canonical docs describe these revisions; the earlier review conclusions do not independently validate them. No runtime implementation has been tested.

Date: 2026-10-17. Review ID: DOC-REVIEW-01.

## Method and scope

A separate read-only reviewer agent inspected overview.md, structure.md, roadmap.md, .agents/log.md and .agents/handoff.md. It challenged scope, correctness, security boundaries, dependencies and verification against the agreed personal-use product. No application code or runtime tests exist. Findings below refer to the initial draft; task IDs and quoted contracts identify the affected areas after revision.

## Findings and disposition

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| R-01 | Medium | M1 execution precedes M4 response-size/binary policy; a large or endless response could exhaust memory. | Corrected plan: move bounded-transfer, non-text, timeout and failure decisions/verification into M1 T-05/T-06. M4 applies these limits to rendering. Actual policy remains to be selected before implementation. |
| R-02 | Medium | M2 autosave precedes M3 Keychain while model boundaries exclude credentials; literal Authorization headers lack a clear storage contract. | Clarified overview/structure: ordinary literal configuration is persisted verbatim; protection applies to structured auth and explicitly secret variables. M2 must make this boundary visible. M3 gates auth saving on Keychain and verifies failure, conversion, duplication and deletion. No heuristic secret detection was added. |
| R-03 | Medium | Cancellation exists but overlapping sends and edits during execution have no result-ownership contract. Late responses can overwrite/misattribute results. | Corrected M1 gate and overview: associate results with submitted snapshots and prevent stale overwrite/misattribution. Single-flight versus concurrent sends remains a decision before implementation. |

Reviewer readiness conclusion: suitable for bounded implementation planning once these contracts are recorded; not ready for unqualified implementation approval. Minimum macOS version remains a prerequisite. Configuration export/import remains an explicit product question.

## Additional main-agent clarifications

- Unsupported future storage versions must not be silently rewritten.
- M3's missing-variable copying gate applies when cURL arrives in M5.
- Technical choices are proposals, not measured implementation results.

## Remaining decisions

The review changed the timing and clarity of contracts, not the agreed feature scope. See overview.md and each milestone gate for open policy decisions. No application code, tests, TaskView records, Git repository or release artifacts were created during this work.

## Independent follow-up verification

DOC-REVIEW-02, completed 2026-10-17: the same independent reviewer inspected the revised overview, structure, roadmap and review report. It confirmed R-01–R-03 are addressed for planning, found no substantiated residual material gaps, and confirmed the dispositions match the revisions without expanding scope. Documentation inspection only; no runtime checks were performed. The plan is ready for bounded implementation planning, subject to milestone policy choices and implementation approval.

## File layout and palette review — DOC-REVIEW-03

Completed 2026-10-17 by a separate read-only reviewer of storage.md, navigation.md, overview.md, structure.md, roadmap.md and handoff.md. No runtime verification was performed.

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| R-04 | Low | Two palette entries can have identical name, method, URL and collection labels while referring to requests with different bodies/headers. | navigation.md now requires an abbreviated request ID when labels collide, extended through full collection/request identity if necessary. Added collision acceptance checks. |

No other material findings were substantiated for storage/palette. Reviewer found file-first creation/index-first deletion with explicit orphan recovery internally consistent. Simultaneous-instance exclusion, globals-file failure handling and collection deletion remain prerequisites before T-07. Secret-reference lifecycle remains an M3 gate. Storage recovery guarantees are proposed acceptance criteria, not implemented guarantees.

The user's saved-exchange requirement arrived during this review and was reviewed separately below.

## Saved snapshots and palette follow-up — DOC-REVIEW-04

Completed 2026-10-17. The same independent reviewer inspected snapshots.md, storage.md, navigation.md, overview.md, structure.md and roadmap.md. No new material findings were substantiated. It confirmed execution-time request/response pairing, original response bytes, immutable captured values, source-deletion independence and exclusion of incomplete transfers from complete snapshots. It also verified R-04's ID disambiguation and collision acceptance checks.

Snapshot schema, secret substitution representation, snapshot-owned Keychain values, partial-write cleanup, body bounds and UI remain explicit preimplementation decisions. Reviewer requested a bounded unsaved-exchange retention clarification. snapshots.md now proposes at most one completed exchange eligible for saving, paired with the currently retained displayed result; no hidden history or restart recovery. DOC-REVIEW-04A independently confirmed on 2026-10-17 that this addresses the clarification; it remains proposed policy, not approved implementation. No runtime tests were performed.

## Encryption-specific review — ENC-REVIEW-01

Completed 2026-10-17 by a fresh independent read-only reviewer of encryption.md, snapshots.md, storage.md, overview.md, structure.md and roadmap.md. The candidate design supersedes historical per-secret Keychain references: protected values live as AES-GCM ciphertext in JSON, with one app key in Keychain; snapshots retain templates plus frozen encrypted inputs. Earlier review entries describe previous drafts, not the current encryption proposal.

| ID | Severity | Finding | Disposition |
|---|---|---|---|
| R-05 | Medium | Snapshot capture omitted separately edited query entries. A URL `/search` plus query-editor `tag={{term}}` cannot be reconstructed from URL/header/body templates alone. | Corrected snapshots.md/encryption.md to capture ordered query templates, duplicate keys and empty values. Added reconstruction acceptance after source edits/deletion. Reviewer independently verified the correction. |

No remaining material findings were substantiated. Reviewer independently checked Apple's AES-GCM and Keychain API documentation on 2026-10-17. Encryption does not authenticate the entire plaintext document or protect literal/response secrets; these remain explicit boundaries. Context encoding, historical preparation compatibility, Keychain accessibility/signing and failure-state UI remain preimplementation decisions. No runtime tests were run; this is a design review, not an implementation security audit.

## Overall plan review — PLAN-REVIEW-05

Completed 2026-10-17 by a different independent read-only reviewer after ENC-REVIEW-01. It read all seven canonical documents: overview, structure, roadmap, storage, navigation, snapshots and encryption. No substantiated material defects or task-dependency cycles were found. The review confirmed consistency of scope, stable identities, literal-variable precedence, shared preparation, independent snapshots and local-user secret access.

The proposal is ready for concrete design decisions, not implementation approval. Ordered prerequisites:

1. Before M1: minimum macOS version; HTTP redirect/cookie/cache defaults; duplicate parameter/header representation; limits, timeout and non-text handling; overlapping sends and result ownership.
2. Before M2: simultaneous-instance exclusion, globals failure handling and safe collection deletion.
3. Before M3: parsing/encoding, literal delimiters, Authorization conflicts, encryption context encoding and verified built-app Keychain behaviour.
4. Before snapshots/release: historical reconstruction compatibility, retained-result navigation, snapshot UI and cURL target-shell behaviour.

These are already recorded milestone gates, not additional feature requirements. Public API behaviour in this app, performance, executable storage/encryption and runnable UI remain unverified. No runtime tests were performed. Review establishes documentation consistency, not security or implementation correctness.
