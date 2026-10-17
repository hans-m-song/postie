# Core and UI contracts

Shared models are in Sources/PostieCore/Models.swift. Main agent owns those declarations and Package.swift; coordinate interface changes before editing shared files. Everything below is public in PostieCore. No networking or persistence of real user data is allowed in verification.

## HTTP worker

```swift
public actor HTTPExecutionManager {
    public init(bodyDirectory: URL) throws
    public func start(identity: RequestIdentity, configuration: HTTPRequestConfiguration) throws -> HTTPRun
    public func start(identity: RequestIdentity, prepared: PreparedHTTPRequest) throws -> HTTPRun
    public func followRedirect(identity: RequestIdentity, response: HTTPResponseRecord) throws -> HTTPRun
    public func cancel(identity: RequestIdentity, runID expectedRunID: UUID? = nil)
    public func discardBody(at url: URL) throws
    public func shutdown() async
}

public enum RequestPreparer {
    public static func prepare(_ configuration: HTTPRequestConfiguration) throws -> URLRequest
    public static func prepare(_ configuration: HTTPRequestConfiguration, context: VariableContext,
                               decryptor: (any SecretValueDecrypting)?) async throws -> PreparedHTTPRequest
    public static func pathParameterNames(in url: String) -> [String]
}

public enum ResponseBodyReader {
    public static func preview(at url: URL, maximumBytes: Int = 1_048_576) throws -> BodyPreview
}
```

The manager reserves the identity synchronously before starting async work and releases it only at a terminal event. Events stream progress, redirect and exactly one terminal result. A completed result owns an app-managed body file until explicitly discarded; unsuccessful runs remove their body. AppModel ignores stale run IDs and owns latest-result retention. discardBody must refuse to delete files outside the manager's own body directory. Shutdown cancels runs, awaits terminal events and removes its owned session directory; invoke it after consumers finish using retained bodies at termination. Each manager has an isolated locked session directory; startup removes only marked stale sessions, preserving active managers and unrelated files. Errors have safe user-readable descriptions. Responses use API-exposed headers, not a raw wire trace.

Body previews read a bounded prefix. Binary previews set isBinary and preserve truncation metadata but return empty text; the UI displays a binary placeholder without allocating unused hexadecimal strings.

Redirect-cap result clarification: HTTPResponseRecord.redirectLimitReached defaults false. When refusing an additional hop after 10 followed redirects, retain the complete refused 3xx response/observed chain as a completed record with this flag true. UI explicitly labels the stop; do not imply the intended destination was reached. This avoids losing diagnostic headers through a message-only failure event.

Manual-follow records may carry an in-memory redirectRequest and pendingRedirect, captured from URLSession and sanitized before exposure. followRedirect validates manager/identity/body ownership, launches that exact next request, retains prior observed hops and limits the chain to ten followed hops. A pending/refused hop already appears once in redirects; do not duplicate it on continuation. AppModel.canFollowRedirect(_:) and followRedirect(_:) expose the action without mutating drafts or saved follow settings. Unsupported destinations may fail inside Foundation before a redirect callback/HTTP record; never offer a follow action in that path.

HTTPRequestConfiguration.pathParameters defaults to an empty field array, including when decoding older documents. Names identify whole :name path segments; the helper returns unique ordered names for UI. Used values require one enabled nonempty entry, encode as one path segment and reject unresolved templates. Unused rows do not affect preparation. Stored request format version remains unchanged; the added optional field is backward-compatible.

## Persistence worker

```swift
public actor CollectionStore {
    public init(rootURL: URL) throws
    public func load() throws -> WorkspaceLoad
    public func saveGlobalVariables(_ variables: VariableValues) throws
    public func saveCollectionVariables(_ variables: VariableValues, in collectionID: UUID) throws
    public func createCollection(name: String) throws -> RequestCollection
    public func renameCollection(id: UUID, name: String) throws
    public func deleteCollection(id: UUID) throws
    public func createRequest(_ request: HTTPRequestConfiguration, in collectionID: UUID) throws
    public func saveRequest(_ request: HTTPRequestConfiguration, in collectionID: UUID) throws
    public func deleteRequest(id: UUID, in collectionID: UUID) throws
    public func recoverRequest(id: UUID, in collectionID: UUID) throws
    public func reorderRequests(ids: [UUID], in collectionID: UUID) throws
}
```

CollectionStore holds an exclusive OS lock for its lifetime. Unknown/malformed/indexed-missing records stay on disk with issues; unaffected requests still load. Preserve index membership when editing around broken entries; do not silently rebuild/drop them. Recovery explicitly adds a valid orphan to the index. Deletion removes membership first, then cleans the file; report partial failures. Collection deletion stages outside the active directory before cleanup. Filename/directory provides identity; do not duplicate request/collection IDs in stored JSON. Version each document. WorkspaceLoad includes globals and their read-only status; scope writes replace owned maps while preserving unrelated unknown fields.

## M3 preparation and encryption

ConfigurationValues.swift defines VariableValue (plain string/encrypted SecretEnvelope), VariableContext and non-Codable PreparedHTTPRequest. Request > collection > global lookup is single pass, active/referenced inputs only. The async preparer supplements missing context.request entries from configuration.variables, preserving explicit context overrides. Original configuration remains templates/ciphertext; URLRequest/referencedInputs are transient. SecretVault owns AES-GCM and narrowly scoped ApplicationKeyStore access, with conservative explicit creation permission. See implementation-m3-m4.md for parsing/auth/failure rules.

AppModel publishes workspace snapshots only after vault gating and revision checks, updates ordinary values synchronously before debounced disk save, and tracks accepted asynchronous secret commits for termination. Per-target tokens invalidate commits after removal/rename/navigation. Run-specific cancellation prevents obsolete work cancelling a newer run. Secret edit buffers use explicit Save/Cancel; navigation discards unsaved secret edits, tabs within the same request retain them.

## UI worker

AppModel is @MainActor, shared by all windows, and consumes these actor APIs. It owns selected request identity, drafts, autosave ordering/errors, per-identity run state/latest result, and activity navigation. Acquire a visible starting state before awaiting start. Do not overwrite newer edits when older saves complete; do not lose drafts when navigation changes or save fails. Request deletion cancels/waits out its run; no response is persisted automatically. Body reading/formatting must run off the main actor with bounded reads. No hidden placeholder feature actions for M3+.

Collection deletion drains and clears both visible members and tracked unavailable indexed requests belonging to that collection. Request/Settings switches retain the body editor's selection and undo; hidden controls cannot receive input or accessibility focus. Explicit Rename request… reuses the ordinary draft/autosave path.

App arguments: `--data-directory <path>` selects an explicitly isolated store, and `--body-directory <path>` selects transient bodies. Do not read environment variables. Default runtime data uses Foundation's current-user home directory plus .config/postie, with no implicit migration; bodies remain temporary. All automated launches use explicit isolated paths. Request Settings tab owns redirect/time/byte options. The full-width URL toolbar sits above both panes; current layout changes are recorded in usability.md rather than implying exact mockup parity.
