# Local storage design

Recorded 2026-10-17. M1/M2 implement the collection index/per-request layout and recovery; secret variables and snapshots remain later work. The approved usability follow-up changes the default root to ~/.config/postie without implicit migration/merge. iCloud sync remains deferred.

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

Collection and request IDs are UUIDs. A collection's directory name and a request's filename stem supply identity; JSON does not duplicate those IDs. Display names live in JSON, may repeat, and can change without renaming files. Storage locations are resolved through platform APIs; sandbox packaging may affect the actual Application Support path.

`globals.json` contains its format version and global variables. Each `collection.json` contains its format version, display name, collection variables, and an ordered `requests` array of request IDs. Each request file contains its format version, display name, method, URL, ordered query/header entries, body, authentication configuration, and request variables. Proposed structured secrets are encrypted envelopes in JSON; only the application encryption key is in Keychain. See encryption.md. Details of those field schemas are defined during T-07/T-32.

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
