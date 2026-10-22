# Deferred features

Reconciled 21 October 2026. This is a grouped inventory, not approval to implement everything listed. Existing task IDs are retained where assigned; other items have no scheduled milestone.

## Current selected work

Layout switching/snapshots and manual key transfer are user-verified in local commits b066227 and 661e149. Parameter/header wrapping, bidirectional query editing, settings inheritance, KB/MB entry and branding are delivered. Drag ordering, opt-in local MCP and existing-instance CLI are implemented. Basic ordering, cross-collection moves, the real Codex connection for MCP list/start/get and block/raw/redacted modes, cached-ID exclusion, inherited redaction, and CLI list/read/send/get/cancel/snapshot CRUD have user verification. Intermittent insertion behavior remains unreproduced; MCP mutation coverage, restart/persistence, collection-level parent exclusion and new snapshot-redaction live checks remain pending. The app-closed CLI guidance was fixed and verified.

## Deferred backlog

| Higher-level feature | Deferred capabilities | Existing task/reference |
|---|---|---|
| Workspace and navigation | Multiple open request tabs, with Back/Forward activating the destination tab; decisions on tab lifetime and session restoration | T-77; request-accordions.md |
| Authoring and variables | Bulk query/header text editing; syntax languages beyond None/JSON, including XML; named environments; dynamic values such as UUIDs and timestamps; scripts/functions and recursive template expansion; request-body modes beyond the current text/JSON editor, including multipart/file-backed uploads | T-76; overview.md, curl-import.md |
| Protocols and HTTP capabilities | gRPC; WebSockets; OAuth flows; automatic cookie storage; retaining intermediate redirect response bodies | overview.md, execution.md |
| Import, export and portability | Copy as cURL; Paste cURL with preview and a bounded nonexecuting parser; HAR export for snapshots; general collection/configuration import/export and existing collection formats; OpenAPI import to generate requests | T-35; curl-import.md; HAR deferred by user on 18 October 2026 |
| History and snapshot extensions | Session request log with request/response headers and body; automatic persisted history; capture of cancelled, failed or size-limited exchanges; snapshot comparison, replay, scheduling and snapshot search | T-42; snapshots.md, execution.md |
| Sync and collaboration | Native iCloud data sync deferred by user on 20 October 2026 because no Apple Developer account is available; preserve research for later. Automatic key sync and live/shared editing remain deferred | T-99; icloud-sync-research.md; encryption.md |
| Memory and large-workspace efficiency | Selected-request-only preview retention; bounded body-editor undo history; repeatable allocation/memory profiling and matched build comparisons before further optimization | Explicitly paused by user; memory-baseline.md |
| Security and recovery extensions | Key rotation/reset and recovery beyond explicit manual transfer; per-collection encryption keys and external collection storage; whole-document encryption/integrity or stronger record binding; automatic secret detection and general response scrubbing | encryption.md |
| Distribution and platform signing | CI deployment/release automation calling the local Make targets, OIDC credentials and serialized publication; deployment of the configured custom domain/hosting; Apple Developer ID signing/notarization when membership is available; real update-installation and signing/Keychain continuity checks | T-90; T-91; distribution.md |

## Explicit non-goals and uncommitted possibilities

Git integration, nested collection folders and cross-platform support were excluded from the initial personal macOS product. They are not committed future features. Likewise automatic retries, batch/collection runners, user-defined concurrency scheduling and raw wire capture are outside the current design, rather than agreed backlog tasks. No App Store/public release is assumed.

The initial Paste cURL parser will not imply arbitrary shell/cURL compatibility: shell execution/expansion, local-file/stdin/config operands and multiple transfers remain excluded unless separately specified. These are parser boundaries, not an implicit promise of future support.

## Required verification, not optional feature work

Stable signing/Keychain access across intended updates, focused workflow verification and storage/recovery documentation remain release-readiness work (T-27/T-28). Snapshot capture/reconstruction, staged publication and source-body ownership must be settled in its implementation spec. They should not be hidden in the deferred backlog.

Supporting specs: [roadmap](roadmap.md), [overview](overview.md), [snapshots](snapshots.md), [execution](execution.md), [encryption](encryption.md), [Paste cURL](curl-import.md), [memory assessment](memory-baseline.md).
