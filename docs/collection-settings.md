# Collection settings and editing follow-up

Authorised 2026-10-17 after M3/M4. User approved the inheritance proposal and requested right-click collection actions without an ellipsis control. No cURL/snapshots/protocol/sync expansion. Keep commits local.

## Checklist

- [x] Inspect current source; approve concrete inheritance and editing rules.
- [x] Collection header/auth persistence and effective preparation, focused tests.
- [x] Collection detail page, selection/context menu and request inheritance controls.
- [x] Variable tables with stable trailing entry rows and reversible Secret checkboxes.
- [x] URL variable autocomplete, native keyboard/focus behavior.
- [x] Independent review/testing, isolated native validation, documentation and local check-in.

## Rules

- Clicking a collection name opens its Variables/Headers/Auth page; the disclosure arrow only expands/collapses requests. Right-click offers the collection actions. No ellipsis/menu chevron remains. Remove extra left padding before request methods.
- Global/collection/request variables share a Name/Value/Secret table and trailing empty row. No temporary plaintext persistence for a checked-secret row. Checking seals before model update, unchecking unlocks and saves plain only after success; failures preserve the old type/value. Names are the existing ASCII identifiers, unique within scope. Stable row UI identity survives promotion/rename. Ordinary valid edits update model synchronously; disk debounce belongs to AppModel. Secret text edits may use explicit Save/Cancel, but the checkbox itself commits conversion.
- Collection headers are inherited. Request header names override inherited names case-insensitively after name template substitution; any named request row, including disabled, suppresses matching inherited headers. Disabled request values and shadowed collection values never resolve/decrypt. Preserve duplicate active request headers and existing URLSession representation.
- Request auth has Inherit/None/Basic/Bearer. Existing requests retain current explicit auth; new requests inherit by default. Collections have None/Basic/Bearer. Inherited headers/auth resolve against the active request > collection > global variables. Structured auth still conflicts with an effective Authorization header. No automatic merge of Basic/Bearer credentials.
- URL autocomplete triggers inside an unescaped {{identifier prefix, includes scope/secret metadata only, and never unlocks values. Arrows choose, Return/Tab accept, Escape dismisses without clearing edits; normal Tab and Command-Return work when not accepting. Replaces the token/prefix without duplicated closing braces. Bound results and work; preserve native selection/undo/IME and current highlighting.

## Frozen interfaces and ownership

Core worker owns ConfigurationValues.swift, Models.swift, CollectionStore.swift, RequestPreparer.swift and adjacent core tests. Add CollectionRequestDefaults(headers: [HTTPField] = [], authentication: RequestAuthentication = .init()), RequestCollection.headers/authentication and HTTPRequestConfiguration.inheritsCollectionAuthentication defaultfalse (legacy safe). Async prepare adds collection: CollectionRequestDefaults = .init() after decryptor. saveCollectionConfiguration(_ defaults: CollectionRequestDefaults, variables: VariableValues, in: UUID) atomically replaces owned vars/headers/auth while preserving name/index/unknown metadata.

Main owns AppModel, collection navigation/page, collection-aware auth UI, shared FieldTable extraction, request inherited-header presentation, durable docs/integration. Variable worker owns VariableEditorView and variable UI state helpers only, using existing APIs plus Main-provided setVariableSecret(_:named:owner:) async throws for atomic reversible conversion. Autocomplete worker owns HighlightedTextField and new completion helper/tests, with optional completionVariables: [VariableCompletion] default[] (name/scope/isSecret metadata). Main supplies URL metadata. All workers preserve others' changes; no builds until coordinated freeze.

Verification uses fake keys, synthetic directories, loopback and exact new validation Keychain services only. Never inspect existing runtime config/environment/PII/keys. Only main functional regressions, no comprehensive suite. macOS permission dialogs requiring user clicks cannot be automated or bypassed.

## Progress and review

Independent final make test passes82 tests (Core58/App24), zero failures. Release builds pass. Independent inheritance/AppModel source review found no substantiated bug; a focused collection-only ciphertext/missing-key regression verifies conservative creation gating. UI review identified completion consuming another token/path, discarded new-secret errors blocking Quit, and trailing-variable rows moving between distinct SwiftUI structures. Those paths were repaired and independently rechecked, including failure followed by rename/retry or conversion to plain. Final source review found no substantiated blocker. Repository audit found no unrelated feature or runtime artifact in the change set.

Isolated native validation passed collection right-click actions without an ellipsis, collection page selection, variable name typing across row promotion and Tab/value entry, collection header entry, request-scope inheritance, header override/disabled suppression, autocomplete scope labels/Down/Tab/Escape/distinct undo and dismissal across request selection. Checking then unchecking Secret round-tripped a synthetic value using a new dedicated Keychain service. Shared Bearer authentication executed against loopback and decrypted after same-binary restart; a legacy request retained explicit None. Validation app and fixture were closed afterward. Existing user configuration and keys were not inspected.

Residual limits: IME and light-mode runtime behavior were not exercised. Completion matching scans at most16Ki UTF-16 units, inspects4096 supplied metadata entries and shows20 suggestions; AppModel still constructs/sorts the effective name list from configured scopes. Metadata precedence is source-reviewed but has no separate direct AppModel test. Failed-secret retry/navigation cleanup is independently source-reviewed, not a native fault-injection test. No comprehensive test expansion or performance benchmark. Stable distribution signing/Keychain continuity across changed app binaries remains future work.
