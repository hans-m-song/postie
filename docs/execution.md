# HTTP execution and response lifecycle

Recorded 2026-10-17. M1/M2 HTTP execution and the approved usability follow-up are implemented. See implementation.md for verified behavior and limitations; later secret/snapshot requirements below remain design requirements, not shipped capabilities. Historical independent documentation reviews are recorded in review.md.

## Concurrent execution

Different request configurations may execute concurrently. Allow at most one in-flight execution per stable request identity (collection ID plus request ID), across all views/windows. Acquire that slot before asynchronous preparation so repeated Send actions cannot race. Unsaved requests need an in-memory identity. A duplicated request has a new identity and may run independently.

Each execution has a separate run ID, immutable submitted configuration/variable values, cancellation handle, state, elapsed time, redirect chain and response-file ownership. Editing while running affects the next execution only. Navigation does not cancel execution, hide its state or start a second copy. Completion never steals focus from the current request.

Show an in-flight indicator on the request row and in its editor, elapsed time, received byte count/progress where available, and an accessible Cancel action for that specific execution. Do not invent a percentage when total size is unknown. Disable Send for that request until its run has terminated; other requests remain usable. Cancel is available while waiting for headers, following redirects and receiving data. Show Cancelling until terminal acknowledgement, then Cancelled; stale callbacks cannot overwrite later runs or their files. No automatic retries, batch runner, user-defined parallelism scheduler or global single-flight lock is required.

Provide an Ongoing Requests view with a live active count and a row for each in-flight execution: request name, collection, method/URL, state, elapsed time, bytes/progress where known, Cancel and Open Request. Open Request navigates to the existing configuration by stable identity, without sending or cancelling it. Keep rows in Cancelling until terminal acknowledgement; remove completed rows without creating persisted history. The empty state says no requests are running. Provide an app navigation entry so this view is reachable regardless of the selected request. Do not reuse row indices as run identities.

Retain at most the latest completed exchange per request for inspection/snapshot saving during the session, not one global exchange. Keep its paired templates/inputs and body-file reference, without keeping the entire body in memory. Replacing/deleting a result releases its temporary file when no viewer or snapshot-save operation needs it. Navigation alone does not discard another request's completed result. Request/collection deletion must cancel and settle affected executions before removing their configuration and temporary results. Snapshot files remain independent. This is transient latest-result state, not automatic persisted history.

## Redirects and headers

Save a Follow redirects boolean in each request. Off is the proposed default. When on, preserve each observed hop in order, including original URL/method, status, response headers, next URL and prepared next request information where available. Use expandable sections for initial/intermediate/final exchanges with request and response header groups. Opening a section does not send anything. Intermediate bodies are deferred; the final response body is retained.

Show the entire header set exposed by the networking API, including generated auth fields available to the app, rather than a selected subset. Distinguish prepared request headers from response headers; do not claim raw wire capture, exact header casing/order, duplicate-header fidelity or visibility of every framework-generated header. Verify the concrete URLSession representation before UI implementation. User approved stopping after at most 10 followed redirects and not automatically forwarding authentication to a different origin. Preserve observed headers when the hop limit stops execution. Preserve platform method-change behaviour and record the effective next method. Concrete error and sensitive-header handling still need fixture verification.

UI clarification: response inspection is one stacked view, not separate Body/Headers/Redirects tabs. Start every redirect disclosure collapsed and the final response expanded, with its available headers and body visible together. Individual hops can be expanded to inspect their headers. Request configuration uses Request/Auth/Variables/Settings section tabs (T-78, 2026-10-18). Request stacks Query/Path/Headers/Body accordions, initially expanded. Side-by-side request/response columns can scroll independently. Body syntax selection offers None/JSON and does not alter the captured/transmitted bytes.

Snapshots should preserve this observed chain as plaintext metadata; intermediate headers may themselves contain sensitive values, consistent with the local plaintext-response policy. App-constructed protected auth values must not be duplicated into persistent plaintext request-header views; reconstruct those from the frozen encrypted inputs. Exact representation remains part of T-31's capture schema.

## Long-running and large responses

Provide configurable inactivity timeout, overall deadline and maximum response bytes. Support relaxing/disabling an application-level cap without treating a zero value as a platform API guarantee. Continue to offer explicit cancellation regardless of limits. Automatic cookie storage is deferred; manually supplied Cookie headers remain ordinary request configuration. Cache behaviour remains to be finalised.

User approved recommended defaults on 2026-10-17: 5-minute inactivity timeout, 30-minute overall deadline and 1 GiB download cap, all configurable. Display thresholds remain the recommended 1 MiB text/highlighting preview and 5 MiB full JSON formatting threshold. Per-request overrides of app defaults are proposed. Confirm disabled-limit semantics before implementation; approval of values does not verify platform behaviour.

Use file-backed response bodies from M1. Evaluate native URLSession download tasks before building a custom writer; verify all supported methods/bodies, cancellation, redirect reporting and response-byte semantics with a bounded local fixture. Small internal buffers remain; never accumulate the full response merely to store or display it. Temporary storage is transient execution data, not automatic saved history.

The text renderer reads a bounded preview and clearly labels it as partial. Preview limits never truncate the stored body. Pretty-print only a complete body below the formatting threshold; do not parse the whole large file in memory. Non-text responses use a bounded preview/metadata policy to be selected. Show received bytes and unknown-length progress. Apply any transfer cap while receiving, independently of preview limits. A cancelled/limited/failed write remains incomplete and is ineligible for a complete snapshot.

Temporary files are app-owned; handle disk-full/write failures and clean up abandoned transient files on startup without touching saved snapshots. Each run owns its own file. A snapshot save must hold the completed body alive until copying/staging finishes, even if another run replaces the visible result. Snapshot persistence uses metadata plus a body sidecar, not a giant JSON/Base64 payload. Limits apply per execution; aggregate concurrent disk use is an implementation policy to settle before T-33.

## Acceptance

- Run two request identities concurrently; prevent a second run of either identity through repeated Send or another view.
- Verify Ongoing Requests lists all active runs, updates counts/status, cancels the selected identity, opens its configuration without sending, and handles completion while its row is being selected.
- Cancel A while B continues; navigate away and back without losing indicators or misattributing completion.
- Edit during execution, cancel then rerun, and force late callbacks; verify identity, result and file ownership remain correct.
- Follow a redirect chain and inspect each available header set; turn following off and observe the initial 3xx. Include method changes, loops and cross-origin behaviour in the agreed fixture boundaries.
- Test delayed headers, unknown content length, a response larger than preview thresholds, cancellation during transfer and disk-write failure. Verify stored bytes are complete while previews remain bounded.
- Save result A while another run replaces it; snapshot retains A's request/response, redirect chain and body.

Detailed integration-test depth remains subject to user confirmation. No claims of measured memory use, runnable UI or platform support are made by this document.
