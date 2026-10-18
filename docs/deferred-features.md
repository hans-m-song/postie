# Deferred features

Reconciled 18 October 2026 from the roadmap, product scope, execution, encryption, snapshot and memory documents. This is a grouped inventory, not approval to implement everything listed. Existing task IDs are retained where assigned; other items have no scheduled milestone.

## Current selected work

Parameter polish (long-cell wrapping/expansion and path-name highlighting), Copy as cURL, and native saved snapshots are selected for the next slices. Snapshots include Rename and Delete; capture content stays fixed while its display name can change. HAR is deferred. Bidirectional query editing, global/request settings inheritance, KB/MB entry, request reset and app branding are already implemented locally.

## Deferred backlog

| Higher-level feature | Deferred capabilities | Existing task/reference |
|---|---|---|
| Workspace and navigation | Multiple open request tabs, with Back/Forward activating the destination tab; decisions on tab lifetime and session restoration; drag-and-drop request reordering (Move up/down already exists); switching between side-by-side and stacked request/response layouts | T-77; request-accordions.md, overview.md |
| Authoring and variables | Bulk query/header text editing; syntax languages beyond None/JSON, including XML; named environments; dynamic values such as UUIDs and timestamps; scripts/functions and recursive template expansion; request-body modes beyond the current text/JSON editor, including multipart/file-backed uploads | T-76; overview.md, curl-import.md |
| Protocols and HTTP capabilities | gRPC; WebSockets; OAuth flows; automatic cookie storage; retaining intermediate redirect response bodies | overview.md, execution.md |
| Import, export and portability | Paste cURL with preview and a bounded nonexecuting parser; HAR export for snapshots; general collection/configuration import/export and existing collection formats; OpenAPI import to generate requests | T-35; curl-import.md; HAR deferred by user on 18 October 2026 |
| History and snapshot extensions | Session request log with request/response headers and body; automatic persisted history; capture of cancelled, failed or size-limited exchanges; snapshot comparison, replay, scheduling and snapshot search | T-42; snapshots.md, execution.md |
| Sync and collaboration | iCloud cross-Mac synchronization; associated encrypted-key portability/recovery design; live/shared editing | overview.md, encryption.md |
| Memory and large-workspace efficiency | Selected-request-only preview retention; bounded body-editor undo history; repeatable allocation/memory profiling and matched build comparisons before further optimization | Explicitly paused by user; memory-baseline.md |
| Security and recovery extensions | Encryption-key export/recovery, rotation/reset; whole-document encryption/integrity or stronger record binding; automatic secret detection and response scrubbing | encryption.md; current at-rest scope does not promise these capabilities |

## Explicit non-goals and uncommitted possibilities

Git integration, nested collection folders and cross-platform support were excluded from the initial personal macOS product. They are not committed future features. Likewise automatic retries, batch/collection runners, user-defined concurrency scheduling and raw wire capture are outside the current design, rather than agreed backlog tasks. No App Store/public release is assumed.

The initial Paste cURL parser will not imply arbitrary shell/cURL compatibility: shell execution/expansion, local-file/stdin/config operands and multiple transfers remain excluded unless separately specified. These are parser boundaries, not an implicit promise of future support.

## Required verification, not optional feature work

Stable signing/Keychain access across intended updates, focused workflow verification and storage/recovery documentation remain release-readiness work (T-27/T-28). Snapshot capture/reconstruction, staged publication and source-body ownership must be settled in its implementation spec. They should not be hidden in the deferred backlog.

Supporting specs: [roadmap](roadmap.md), [overview](overview.md), [snapshots](snapshots.md), [execution](execution.md), [encryption](encryption.md), [Paste cURL](curl-import.md), [memory assessment](memory-baseline.md).
