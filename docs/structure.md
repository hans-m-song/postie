# Postie structure

Verified 2026-10-17. M1/M2 now exist in one dependency-free SwiftPM package; remaining responsibilities below describe later product scope.

## Current documents

```text
docs/
  overview.md      Product scope, architecture, open decisions
  structure.md     Responsibility and ownership boundaries
  roadmap.md       Proposed milestones and stable task IDs
  review.md        Independent adversarial findings and disposition
  storage.md       File layout, identity, write ordering and recovery
  navigation.md    Request search palette and acceptance
  snapshots.md     Explicit saved request/response captures
  encryption.md    Proposed encrypted values and Keychain key lifecycle
  execution.md     Concurrent runs, redirects, progress and file-backed bodies
  curl-import.md   Supported cURL parsing, preview and import boundaries
.agents/
  log.md          Verified decisions and lessons
  handoff.md      Current status and resumption context
```

## Responsibility boundaries

| Responsibility | Owns | Does not own |
|---|---|---|
| UI | Editing, navigation, selection, display, keyboard actions | Networking and persistence formats |
| Models | Saved collections, requests, variables, format version, encrypted envelopes | UI state and decrypted protected values |
| Preparation | Template resolution, encoding, auth, validation, prepared request | Network execution |
| HTTP execution | Per-request run identity, URLSession, redirects, progress, cancellation, results/errors | Editing and durable configuration |
| Response body storage | Run-owned temporary files, bounded reads, lifetimes and snapshot copying | Network policy and JSON formatting |
| cURL generation | Shell representation of a prepared request | Independent variable/auth resolution |
| cURL import | Parse a supported command into a previewable request draft | Shell execution, local file reads, network sends |
| Persistence | Load/save configuration and failures | Automatic response history or structured secret values |
| Encryption/key storage | At-rest CryptoKit envelopes and Keychain application key | Record/field binding, rotation framework, collection navigation |
| Response presentation | Raw/pretty rendering and highlighting | Modifying original response data |
| Request search | In-memory matching and stable request identities | Sending requests, resolving secrets, disk search index |
| Saved snapshots | Immutable exchange records and snapshot-file lifecycle | Automatic history, replay, mutation of live requests |

The package separates PostieCore from the PostieApp executable and has two focused test targets. A separate Swift loopback fixture supports tests and is not bundled with the app. Deferred features do not yet have implementation modules.

```text
Sources/PostieCore/
  Models.swift                  Shared values and run events
  RequestPreparer.swift         Validation and URLRequest construction
  HTTPExecutionManager.swift    URLSession, redirects, cancellation, body ownership
  ResponseBodyReader.swift      Bounded text/binary previews
  CollectionStore.swift         JSON, index, atomic writes, lock and recovery
Sources/PostieApp/
  PostieApp.swift               Entry and coordinated termination
  AppModel.swift                Drafts, autosave, CRUD and per-request runs
  ContentView.swift             Sidebar/actions and split layout
  RequestEditorView.swift       Stacked query/header/body and options
  RequestResponseSplit.swift    Native split allocation and persistent hosted panes
  GrowingBodyEditor.swift       Non-scrolling native editor, height, binding and undo
  PaddedDisclosureGroupStyle.swift Whole-heading accessible disclosure control
  ResponseView.swift            Redirect/final exchanges and preview
  OngoingRequestsView.swift     Active runs, Cancel and Open Request
Tests/PostieCoreTests/          HTTP, preparation, bodies and storage
Tests/PostieAppTests/           AppModel save, CRUD and recovery
Sources/PostieHTTPFixture/      Synthetic Swift loopback fixture executable
Makefile                       App packaging, functional tests and fixture targets
packaging/Info.plist            Static app bundle metadata
dist/Postie.app                 Generated local verification bundle
docs/implementation.md          M1/M2 decisions, evidence and limits
docs/interfaces.md              Concrete actor/UI contracts
```

Runtime data defaults to ~/.config/postie; temporary response bodies use isolated locked sessions beneath temporary-directory/Postie. Explicit directory arguments support isolated verification. Existing stores are not automatically moved. Runtime configuration is not repository content.

Ordinary literal configuration and responses can contain sensitive text; it is not automatically classified as a secret. Proposed encrypted fields protect marked variables/auth values through a Keychain-held key. Preparation/editor state may hold decrypted secrets transiently; saved models and error diagnostics must not receive those decrypted values.

The main agent owns product decisions, integration, and .agents/log.md and .agents/handoff.md. Bounded executors may own agreed source surfaces; independent reviewers remain read-only. Runtime user configuration is not repository content.
