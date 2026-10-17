# Local storage design

Recorded 2026-10-17. Collection index/per-request layout, three variable scopes and encrypted authentication are implemented. Snapshots remain M5 design; that subtree below is not created by the current app. Default root is ~/.config/postie without implicit migration/merge. iCloud sync remains deferred.

## Layout and identity

```text
~/.config/postie/
  globals.json
  snapshots/
    <snapshot-id>/
      snapshot.json
      response.body
  collections/
    <collection-id>/
      collection.json
      <request-id>.json
      <request-id>.json
```

Collection and request IDs are UUIDs. A collection's directory name and a request's filename stem supply identity; JSON does not duplicate those IDs. Display names live in JSON, may repeat, and can change without renaming files. Explicit directory arguments override the default root.

`globals.json` contains its format version and global variables. Each `collection.json` contains its format version, display name, collection variables, and an ordered `requests` array of request IDs. Each request file contains its format version, display name, method, URL, ordered query/header/path entries, body, authentication configuration, and request variables. Variable maps encode ordinary values as strings and secrets as `{ "version": 1, "combined": "Base64 sealed box" }`. Auth contains kind/username and optional encrypted password/token envelopes. Only the application key is in Keychain. See encryption.md.

Collection settings add ordered `headers` and `authentication` fields, defaulting to empty/None when absent. Request `inheritsCollectionAuthentication` defaultsfalse when reading older files; AppModel explicitly sets it true for newly created requests. Existing explicit auth does not silently change. Collection variables/headers/auth save together in one atomic metadata replacement, preserving current name/index and unrelated metadata. See collection-settings.md for override and disabled-row suppression rules.

Absent additive request/collection variable/auth fields default empty/None. Malformed globals load read-only with an issue while unrelated collections remain usable; malformed collection variables make that collection read-only. Owned maps replace deleted/renamed keys rather than recursively resurrecting them. Unrelated unknown metadata is preserved. Marking a variable secret seals it before updating the model and atomically replaces its plaintext representation at save.

Illustrative collection metadata:

```json
{
  "formatVersion": 1,
  "name": "My API",
  "variables": {},
  "requests": [
    "85d138ca-cfb8-4394-8975-7d27976fe70b",
    "5bfb64ac-031f-4dc7-b2d8-02f935d49e04"
  ]
}
```

The index is authoritative for membership and request order. Directory enumeration discovers collections and detects unindexed request files. No root collection index or custom collection ordering is initially required; collections sort by display name with ID as tie-breaker. JSON folders are a storage detail, not nested folders in the product.

Explicit exchange snapshots live separately from request configuration and survive source deletion. See snapshots.md for capture identity, immutable values and Keychain questions. They are excluded from request search.

Responses for active/latest completed runs live in app-owned temporary storage, separately from durable configuration/snapshots. Each run owns a distinct file; do not persist execution state as automatic history. Snapshot saves stage/copy a completed body alongside metadata before publishing the snapshot directory. See execution.md for cancellation, concurrency, preview bounds and cleanup.

## Writes and recovery

- Replace individual files atomically. This does not make two-file operations transactional.
- Create/duplicate: write a new request file, then add its new ID to the collection index. Do not report full success if either step fails.
- Edit: replace only the affected request file; renaming does not change its ID.
- Reorder: replace collection metadata only.
- Delete request: remove its ID from the index, then delete its file. A failed cleanup must be reported.
- Indexed file missing or malformed: flag that request and load unaffected entries. Do not silently remove its index entry or overwrite its file.
- Unindexed request file: preserve it, keep it out of normal membership/search, and offer explicit recovery. It may be an interrupted creation or deletion; never automatically resurrect it.
- Malformed/unsupported collection metadata: preserve all files and disable writes to that collection until explicitly recovered. Do not rebuild membership/order silently from directory contents.
- Unsupported future versions must not be rewritten. Validate index IDs as UUIDs and reject duplicate IDs; IDs never serve as arbitrary paths.

Keep one serialised writer in the app. No multi-process writers, filesystem watcher, automatic merge, sync engine, or transaction journal is required initially. Before T-07 implementation, choose how simultaneous app instances are prevented from overwriting each other's work, define globals-file failure behaviour, and specify safe collection deletion. These remain design decisions.

## Search integration

Search uses the loaded in-memory saved-request summaries, keyed by collection ID and request ID. There is no additional persisted search index or per-keystroke filesystem scan. Request creation, editing, deletion and recovery update the summaries. Broken/unindexed requests are reported through recovery UI rather than hidden normal search results.

## Verification gate

T-29 verifies ordering, stable identities across renames, duplicate display names, invalid/duplicate IDs, missing/malformed files and unsupported versions. Inject failures between each create/delete write step; restart and verify partial work is preserved, diagnosed and never silently resurrected. Atomic file replacement is a requirement, not a claim of crash-proof multi-file transactions.
