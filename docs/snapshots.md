# Saved request/response snapshots

Navigation regression follow-up, 2026-10-20: removed a redundant selection-changing task from the snapshot loading view. A delayed callback from a disappearing snapshot could previously reselect it after a sidebar or history navigation. Selection and history restoration already initiate loading in AppModel; rendering the loading indicator now has no navigation side effect. The actual hosted-view regression failed twice before the fix and passed afterward, together with11 existing snapshot/history checks. User confirmation remains pending.

Updated 2026-10-19. Native snapshots are implemented locally; user acceptance is pending. This document defines Postie's capture contract, without asserting parity with a particular Postman feature. See [implementation contract](snapshot-implementation.md) for concrete types and storage boundaries.

Clarified 2026-10-18: native metadata plus body-sidecar storage is selected; HAR export is deferred to a future feature. Snapshots can be renamed and deleted. Immutable means the captured request/response content stays fixed; the user-facing name is mutable and independent of snapshot identity. Save initially proposes the request name and capture time. See deferred-features.md for grouped future capabilities.

## Capture contract

An explicit Save Snapshot action stores an immutable record of a completed HTTP exchange. Capture send-time request templates, the effective referenced variable/auth inputs and preparation settings from execution state, paired with the received response. Never capture current editor values after the exchange. Store templates/literals and the original response unencrypted; encrypt frozen captured inputs as described in encryption.md. A snapshot includes capture timestamp, source collection/request identities and display names, method, URL template, ordered query entries (including duplicate keys, empty values and enabled state where supported), ordered header templates, body template, preparation format version/settings, encrypted captured inputs, response status/headers/body and duration. Query templates include names and values actually used by preparation, not just the URL editor text. It reconstructs application-level submitted request intent, not a raw packet trace or guaranteed intermediate redirect capture.

Saving is manual. No automatic history, automatic snapshot replacement, comparisons, scheduled capture or replay engine is required. Viewing a snapshot never sends a request. A snapshot can be viewed and explicitly deleted. Editing a request, changing variables or deleting its source request must not change/delete an existing snapshot. The snapshot's original labels are preserved even when source requests/collections are renamed or removed.

Retain at most the latest completed exchange per request during the session, consistent with concurrent execution in execution.md. Navigation does not discard other requests' latest results. No automatic historical queue or restart recovery is promised. Preserve each submitted template/input capture alongside its file-backed body for as long as the result is eligible. A snapshot save holds that result/body until staging finishes, even if a new run replaces the visible result.

Initial capture is for completed HTTP responses, including non-2xx status codes. Transport failures, cancelled exchanges and responses stopped by size limits are not presented as complete snapshots. Their future capture is outside this initial feature. Copy the complete file-backed response body as a sidecar, without JSON/Base64 expansion or full-body memory buffering. Missing request body and zero-length body must remain distinguishable where execution distinguishes them. Retain observed redirect statuses/URLs/headers as specified in execution.md, not intermediate response bodies or a raw wire trace.

## Storage

```text
~/.config/postie/
  snapshots/
    <snapshot-id>/
      snapshot.json
      response.body
```

Snapshots are self-contained directories with versioned metadata and immutable source identities/labels; the directory name supplies snapshot identity. Enumerate metadata without eagerly loading body files. Separate storage lets them outlive source deletion. A malformed, incomplete or unsupported snapshot must not prevent other snapshots from loading or be silently rewritten.

Snapshot captured input values are independent encrypted copies, not references to mutable live variables/credentials. Capture one effective value for each referenced variable name after scope precedence, plus the structured auth inputs needed for reconstruction. Ordinary literal sensitive headers/bodies/responses remain plaintext and user-accessible. Automatic secret detection is not required. There are no per-snapshot Keychain entries: the app-level key decrypts the snapshot's input envelope.

Persist only after encryption succeeds with an established Keychain key. Stage metadata and a copy of the completed body in a separate directory on the same volume, then publish the complete directory; handle failed copies and clean abandoned staging without publishing partial snapshots. Preserve the source temporary body during staging through execution-manager leases. Snapshot deletion removes its directory, never the app key or live values. Resolved submitted/observed request transport and redirect URLs are persisted inside the encrypted context, never as plaintext duplicates. Version 1 opens recorded transport without re-running preparation or consulting live scopes. Unreadable or uncertain snapshot storage blocks replacement-key creation.

## UI and acceptance: T-31

Show snapshots beneath their originating request in sidebar navigation, labelled with their editable name, capture date and status; selection opens a read-only capture using the remembered side-by-side or stacked layout. This is not user-created folder nesting. Keep physical snapshot storage separate to preserve captures after source deletion; source IDs provide UI grouping. Deleted-source navigation follows the approved placeholder policy below.

User approved the recommended deleted-source behaviour on 2026-10-17: retain a dimmed, non-executable source-request entry containing its snapshots until the last snapshot is deleted. If the source collection is also deleted, retain a dimmed historical collection grouping. These are navigation placeholders derived from snapshot metadata, not live request configurations; exclude them from normal request search and Send actions.

Copying follow-up, 2026-10-20: displayed snapshot fields support text selection. Copy as JSON exports pretty, sorted JSON with frozen resolved submitted/observed request fields, actual captured variable/authentication values (including secrets), source metadata and response details. It does not substitute current workspace values or export unresolved templates as an executable request. Missing encrypted context is explicitly unavailable. Response content is capped at a 1 MiB clipboard preview, with original/preview byte counts and a truncation flag; binary content is Base64. Copying does not change the saved files or their encryption. No new per-field copy buttons or Finder action were added.

- Save a completed response with its submitted request through an explicit action.
- View saved snapshots in a small list with capture date, request name and response status; no persisted custom ordering/index is needed.
- Change request/variable values after an exchange but before saving; verify the saved snapshot still reflects that exchange.
- Verify query-editor-only inputs, duplicate query keys and empty query values reconstruct in their original order after source edits/deletion; capture all referenced query inputs alongside URL/header/body/auth inputs.
- Verify a newer result cannot cause Save Snapshot to combine the previous response with the newer request; discarded unsaved exchanges are not advertised as available.
- Restart, view both sides of a snapshot, and verify original response bytes and capture metadata.
- Edit/delete the source request or collection; verify the snapshot remains readable and unchanged.
- Include non-2xx and bounded non-text responses; do not mislabel failed/truncated transfers as complete exchanges.
- Verify live credential changes cannot mutate captured values; reconstruct using frozen encrypted inputs without consulting live scopes. Verify encryption/key failures and deletion leave unrelated data untouched.
- Verify malformed records, unsupported versions, failed writes and explicit deletion without loss of unrelated data.
- Verify large-body snapshot copying does not require loading the entire body, interrupted staging is not published, and saving A remains correct while A's request runs again or B completes.

No snapshot-search extension to the request palette is implemented. Copying a snapshot without its Keychain-held key does not make the captured inputs portable. Missing or unavailable keys leave the original response inspectable while encrypted request details report an error.
