# Snapshot implementation contract

Selected 2026-10-19: layout switching and manual native snapshots only. Request tabs, reordering, cURL, HAR, automatic history and replay remain deferred. This document specifies the implementation boundary; completion evidence belongs in the roadmap/handoff.

## Capture

Dedicated Codable/Sendable types live in SnapshotModels.swift:

- `SnapshotInput`: value, scope (`VariableScope`), isSecret.
- `SnapshotRequestTemplate`: method, url, ordered pathParameters/query/headers `[HTTPField]`, body, bodyEnabled, bodySyntax, resolved HTTPOptions. Excludes live variables and auth envelopes. Effective header templates include inherited headers after suppression. Preserve original URL/query/encoding representation without renormalizing.
- `SnapshotAuthenticationInput`: kind, username, secretTemplate optional, resolvedSecret optional, apiKeyHeaderName optional. Only capture effective non-overridden auth.
- `SnapshotTransportRequest`: method, url URL, headers, body optional String (preserve absent versus empty), headerSources, sensitiveNames, secretNames.
- `SnapshotPreparationCapture`: preparationVersion (1), template, referencedInputs `[String:SnapshotInput]`, authentication, submitted transport.
- `SnapshotSource`: identity RequestIdentity, collectionName, requestName. Freeze before preparation, never at Save time.

PreparedHTTPRequest and HTTPResponseRecord gain an optional `snapshotCapture`; response gains `completedAt`. RequestPreparer constructs capture while effective inputs/auth/header templates are available. Execution carries it unchanged, including manual redirects. Missing capture makes a result ineligible. Version 1 viewing uses captured transport directly, not current preparation or live scopes.

All resolved request-side transport details and captured inputs are encrypted together. This includes URLs, submitted body, headers, secret header names, source maps, effective auth and observed redirect request data. Original request templates/literals, source labels and original response headers/body remain plaintext. No unused variable values or superseded auth inputs are captured. An encrypted observed transport copy is permitted to preserve historical rendering without plaintext duplication of protected values.

## Storage interface

`SnapshotStore` is an actor initialized with rootURL (the snapshots directory) and SecretVault.

```swift
load() throws -> SnapshotLoad
save(response: HTTPResponseRecord, source: SnapshotSource,
     name: String, bodyLease: HTTPBodyLease) async throws -> SavedSnapshot
open(id: UUID) async throws -> OpenedSnapshot
rename(id: UUID, name: String) throws -> SavedSnapshot
delete(id: UUID) throws
```

`SavedSnapshot` is metadata-only and Identifiable; minimum public fields: id, name, capturedAt, source, statusCode, bodyByteCount. `SnapshotLoad` supplies snapshots, per-entry issues and containsEncryptedData (conservatively true for uncertain published entries). `OpenedSnapshot` supplies summary, template, decrypted frozen context and a view-only HTTPResponseRecord pointing at its durable body. Make initializers/public properties usable by PostieApp. Plaintext response inspection should remain possible if the context cannot unlock: expose the stored response metadata/body separately, with an explicit context error rather than failing the whole list.

Persist `snapshots/<UUID>/snapshot.json` and `response.body`. Version1 metadata contains name/capturedAt/source/originalRunID, template, preparationVersion, encryptedContext, response status/headers/bytecount/duration/redirectLimitReached and redirect statuses/methods/response headers. No temporary body path, URLRequest, or executable redirect continuation. FrozenSnapshotContext contains preparation inputs/auth/submitted transport, observed final URL/method/headers/source/sensitivity maps and observed redirect request details. Public models can nest/reuse these types sensibly.

Encrypt before publishing. Stage under snapshots/.staging/<UUID> on the same volume, copy the complete body without whole-body reads, verify byte count, write pretty JSON and atomically rename the complete directory. Reject symlinked/unsupported/malformed paths; preserve published invalid records and report individually. Clean only recognized abandoned staging directories. Snapshot deletion never touches live request data or keys. Rename updates only name and preserves ciphertext/unknown JSON fields. Snapshot body limits match completed execution; no new arbitrary limit.

## Body lifetime and key safety

HTTPExecutionManager offers `acquireBodyLease(for: HTTPResponseRecord) throws -> HTTPBodyLease` and `releaseBodyLease(_:)`. Lease fields include token/runID/bodyURL. Validate exact retained run/body; defer discard while leased, and make shutdown wait for releases. Keep active/retained snapshot capture through manual redirects.

AppModel registers snapshot saves keyed by run ID before suspension. Prior-body discard waits for registered saves, closing the acquisition race. Release every acquired lease on success/failure. Termination waits for accepted saves before execution shutdown. Freeze source labels per run before preparation and pair them with the exact completed response.

Startup loads snapshot metadata before allowing key creation. Any snapshot ciphertext, malformed/unsupported/unreadable published snapshot or load uncertainty prevents creating a replacement key when live source data has disappeared. Keep snapshot state separate from live collections/drafts/search/send. Initial use of an existing key is through SecretVault; never replace missing historical keys.

## UI

Save Snapshot in the response header, only for a completed eligible exchange (including non-2xx). Keep latest eligible completed result semantics; no failed/cancelled/size-limited snapshot. Default name uses frozen request name and completion time. Group captures beneath live requests. For deleted sources, show dimmed non-executable request/collection placeholders derived from snapshot labels. Rename/Delete through context menus and detail actions, confirming deletion consistently with existing UI.

Snapshot detail is read-only with original templates and recorded submitted request, response headers/status/redirects/body, and a clear captured timestamp. Honor the same global side-by-side/stacked layout preference; no Send action or live scope lookup. Keep bounded body previews and existing None/JSON presentation limits. Secret headers remain masked with explicit Reveal/Copy, matching existing response UI.

Copy as JSON (2026-10-20) uses SnapshotJSONExporter, separate from the encrypted on-disk schema. The primary request is frozen submitted transport with actual resolved values; original templates are omitted. Captured inputs and resolved authentication secrets are deliberately included independently of viewer reveal state. Encoding and body reading run off the main actor; only successful preparation updates the clipboard. Response preview is bounded at 1 MiB with explicit encoding/byte counts/truncation, UTF-8 text or Base64 binary. Unavailable encrypted context is reported instead of exporting fallback URLs. Snapshot labels, names and displayed values support text selection; no new per-field copy action is introduced.

## Focused gates

Use synthetic directories and in-memory key stores, not real workspace/Keychain/credentials. Cover frozen inherited/query/auth inputs, no plaintext secret duplicates in JSON, save/restart/rename/delete/source deletion, body hold during replacement, malformed/unsupported entries, missing key, empty/binary/file-backed body copy and rejected partial writes. Avoid comprehensive UI tests; build and isolated native checks cover layout and Save/View actions. User verifies before commit.
