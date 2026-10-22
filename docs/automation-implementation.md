# Ordering and automation implementation

Updated 2026-10-21. T-96 ordering, T-97 MCP and T-98 CLI are implemented locally. This is the current verification record. The automation foundation is checked in separately from deferred distribution work.

## Verified behavior

- User confirmed basic ordering and cross-collection moves. Intermittent incorrect insertion could not be reproduced and was explicitly deferred; no placement fix is claimed.
- Real Codex MCP discovery/start/result passed against the user-authorized QBCC stats GET.
- Block withheld the body; Unredacted returned body/headers/final URL. After correction, inherited redaction replaced freshness with {{test}}; user accepted the result.
- Request exclusion hid the endpoint and cached-ID start returned forbidden without executing it.
- Real CLI help, discovery, request read/start/result, cancellation and temporary snapshot create/read/rename/delete passed. The temporary snapshot was deleted.
- Rebuilt CLI with Postie closed exited1 and correctly instructed the user to open Postie.

## Remaining acceptance

- [ ] New snapshot MCP read verifies unused-secret redaction end to end; synthetic encrypted round-trip/projection checks pass. Old snapshots keep their original context.
- [ ] Collection exclusion blocks child requests/snapshots in the connected client.
- [ ] Ordering and MCP enabled state survive restart.
- [ ] MCP-specific create/edit and snapshot mutations; shared operations passed through CLI.
- [ ] Collection Settings-tab presentation and drag cancellation feedback, unless user testing has already covered them.
- [ ] Remaining baseline accepted, then scoped local commits. No push.

## Verification evidence

Initial selected gate:154 checks on 2026-10-20. Three-mode policy gate:38. Latest secret/CLI gate:91, no failures/warnings. Counts are separate runs, not aggregate coverage. Logs: `/Volumes/Data/tmp/postie-automation-final-tests.log`, `postie-unredacted-tests.log`, `postie-secret-cli-green.log`.

Both latest bugs had synthetic red tests before correction: absent socket classification, and unused secret capture/body/header redaction. Tests cover effective scope precedence, reuse, failure/cancellation, limits, encrypted round-trip and legacy absence.

App/CLI builds and strict signatures passed before cleanup. Outputs: `dist/Postie.app`, `dist/postie`. Cleanup's exact-source recheck belongs in [CI and verification](ci.md).

Independent source review found no remaining blocking issue. Current-policy selection follows all awaits/access checks. Concurrent downgrades have source/sequential-test evidence, not deterministic suspension-injection coverage. Native automation's system connection failed; only the stated user/MCP/CLI checks are live evidence. No runtime credentials/configuration/Keychain files were read.

## Check-in boundaries

- `983c27d`: snapshot navigation.
- `2234b28`: collapsible snapshot groups/counts.
- `3cca2f1`: frozen unused-secret capture, encrypted snapshot support, send opt-in.
- Remaining ordering/MCP/CLI source, sanitizer/UI policies and CLI diagnostic are pending with their automation foundations.
- Distribution/deployment, data sync and headless CLI remain deferred.

## Confirmed product contract

- Drag to reorder collections and requests; requests also move between collections.
- Moving adopts destination collection inheritance while preserving the request's own explicit overrides and literal variable templates, even when references become unresolved.
- Saved snapshots follow moved requests in the sidebar; captured source names/content remain unchanged.
- Embedded MCP for Codex uses opt-in loopback Streamable HTTP/SSE, disabled initially. Remember enabled state across launches. Once enabled, workspace access includes everything by default, with collection/request opt-out controls.
- MCP supports request discovery/create/edit/start; ongoing-run view/cancel including UI starts; variable listing and nonsecret reads; snapshot list/create/read/rename/delete. No key-transfer or direct secret-read tool.
- Response viewing is separate from access. Global default Block; collection/request Inherit, Block, redacted Allow or Unredacted. Block returns typed metadata/allowlisted headers/redirects/sanitised Location, not bodies. Allow re-templates known frozen secrets, including unused effective encrypted variables for new sends; Unredacted intentionally returns raw response body, headers and URLs. Use the detailed policy in roadmap.md; UI resolved Copy as JSON is not an MCP output path.
- CLI shares the application operations but deliberately omits MCP re-templating/redaction and MCP-specific response-view restrictions. Variable read scope remains nonsecret.

## Additional confirmed choices

- CLI requires an existing Postie instance; independent/headless operation is deferred.
- Collection MCP opt-out is a hard deny for all child requests and snapshots; a request cannot opt back into an excluded collection.
- Refuse moves while a request is preparing/running/cancelling; do not cancel it or change the frozen in-flight request.
- Retained snapshots remain MCP-excluded after their excluded request/collection is deleted. Persist per-snapshot exclusion tombstones; a move follows live destination access instead.

## Architecture requirements

- AppModel remains the sole writer and execution owner; transport adapters do not open a second CollectionStore or overwrite files directly.
- External commands use explicit input/output models and returning/throwing operation results, without changing UI selection. Reject unknown mutation fields; never round-trip secret envelopes through automation.
- External MCP edits cannot change MCP visibility/access/listener policy. Do not let an edit reset policy fields omitted from an input model.
- MCP projection is selected by the HTTP adapter, CLI raw projection by separate protected local IPC. No caller-supplied raw/trust/channel flag may bypass MCP policy.
- Public run handles exist during preparation and survive execution; cancellation/snapshot creation target exact handles, not whichever run is currently latest. No automatic historical queue.
- Lease response bodies while reading; bound previews and sanitize before returning any fragments. Treat truncation/encoding boundaries conservatively to prevent partial known-secret leakage.
- Cross-collection persistence needs recovery for source index, destination index, request file and snapshot navigation association. Preserve capture metadata; do not implement naive create/delete as an atomic move.
- Collection order must be respected at both storage and AppModel layers; malformed/unknown metadata remains preserved and diagnosed.
- Stop command admission before termination drains accepted work; do not retry accepted mutations implicitly on disconnect.


## Module boundaries

PostieAutomation owns contracts, patches and projections; PostieControl owns authenticated loopback HTTP/MCP and separate same-user Unix IPC; PostieCLI connects to the running app. The socket directory is owner-only and socket permissions are0600.

MCP bearer material uses a separate Keychain service. Tests use synthetic data/fake keys. Stateless Streamable HTTP returns JSON or request-local final-message SSE, without sessions, replay or unsolicited updates.

Package.swift declares Swift MCP SDK0.12.1 and SwiftNIO. Sparkle integration/publication/deployment remain deferred and uncommitted.
