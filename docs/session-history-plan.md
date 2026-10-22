# T-116 — Session request history

Recorded 2026-10-22. Implemented locally; user accepted the integrated rebuilt navigation/history/palette on 2026-10-22 (“seems to work well”). Detailed automated versus native verification boundaries remain recorded below.

```text
Request history               Selected execution
--------------------------    ---------------------------
GET Stats       200            Frozen request / response
GET Stats       cancelled     Headers and redirects
POST Refresh    running       Available body or explanation
```

## Requested behavior

- One entry per accepted execution, including preparation, running, success, failure and cancellation. Repeated sends of the same request are separate entries; manual redirect-follow is another attempt.
- Newest-started first, stable token identity. Selecting a row opens read-only snapshot-style details alongside it; list remains visible. New executions/completions do not replace the user's selected row.
- Cancel active runs from the list/inspector; opening the editable source is a separate action. Retain frozen source labels even if the original request is moved, renamed or deleted; disable unavailable source links.
- Show only data actually captured. Failed/cancelled attempts must not borrow another run's completed response or invent a body.
- No automatic saved snapshots, history files or configuration writes. Existing temporary response-body storage is distinct from durable saved history. Session data disappears on application exit.

## Approved retention

Retain at most 10 completed runs or 100,000,000 bytes of combined additional history capture/body data, whichever limit is reached first. Evict oldest completed entries first; active runs remain visible. An oversized detail must have an explicit unavailable explanation rather than showing another execution's response. These limits govern history retention, not total process memory or existing latest-response caches. Bodies remain file-backed.

## Verified current boundaries

- AppModel.ActiveRun.token exists before preparation; Core runID arrives later. Use the token as row identity.
- AppModel.replaceLatestResponse discards the prior body's ownership for that request. A separate session archive is required to keep older results reliable.
- Core body leases delay deletion, but pending-discard bodies reject new leases. A permanent history lease alone cannot provide future inspector reads; retention must coordinate ownership before discard or add explicit sharing semantics.
- Failure/cancellation cleanup deletes incomplete body files. Preserve available configuration, progress, redirects and error reason, without promising partial bodies.
- Existing source moves rewrite latest-response grouping; freeze historical identity/labels separately from the live source link.
- MCP run outcomes remain latest-per-request under their existing cap/expiry. History does not implicitly broaden MCP/CLI APIs or retention.

Evidence: AppModel.swift ActiveRun/startRequest, settleRun/replaceLatestResponse, source move/delete and termination; HTTPExecutionManager.swift body leases/terminal cleanup; ResponseView.swift latest-per-request presentation. Source inspection only, not a runtime test.

## Module and integration boundary

An app-only SessionExecutionStore owns begin/update/finish/inspection/clear, terminal rows, optional retained payloads and eviction. AppModel remains the sole execution/workspace writer and forwards lifecycle events. A SessionHistoryView owns the selected token and split list/inspector. Share presentation values/components with snapshot details, not SnapshotStore or OpenedSnapshot persistence. Do not use request-keyed ResponseView for historical entries.

SessionHistoryDetailView presents frozen fields; SessionHistoryResponseBodyView performs lease-scoped reads. Raw previews and request-body display are limited to1MiB; JSON Pretty uses the existing5MiB bound. Credential headers, captured secret inputs and auth secrets require reveal; local response bodies are visible by default. Count/byte limits measure additional logical retained UTF8 capture content plus file-backed body length, not process RSS. Active runs are exempt while active. Internal ongoing-request navigation aliases remain for compatibility; visible commands use Request History and Command-2.

Preview/Pretty operations use exact-run identity/generation and operation leases. Disappearance/cancellation releases resources; shutdown drains leases before deleting transient files. Body retention changes, if selected, are isolated in Core ownership rather than bypassing cleanup in AppModel.

## Verification gates

Focused synthetic tests: repeated sends, preparation failure/cancellation, stale callbacks, exact-run lookup, replacement/eviction during inspection, move/delete after capture, shutdown cleanup, unchanged MCP semantics and no snapshot/config writes. Independent source review of Core lease/state integration and test-only meaningfulness review. User verifies list/inspector behavior, active cancellation, missing-data messaging and session reset after restart. No real requests, runtime config or credentials are needed for implementation checks.

Verification2026-10-22: all301 package tests passed (Core140, Control19, Automation28, App114), including10 history tests using temporary workspaces, fake keys and a synthetic loopback HTTP fixture. Strict formatting/whitespace and syntax checks passed. Source review found no remaining ownership/lifecycle defect; blind test review strengthened stale cancellation, combined budgets, bounded waits and cleanup. Log: /Volumes/Data/tmp/postie-session-history-full-tests.log. Native layout/focus/VoiceOver and user acceptance remain unverified.

Clean release build and strict signature checks passed; dist/Postie.app refreshed. Build log: /Volumes/Data/tmp/postie-session-history-build.log. Reopen that bundle for native verification. Changes remain uncommitted until user acceptance.

## Roles and sequencing

Main agent freezes retention/API, owns docs/build lock and integration; one worker owns the history store/lifecycle bridge, another owns list/detail presentation after interfaces settle. Core ownership changes, if required, have a separate serialized owner. Avoid concurrent AppModel edits. Existing uncommitted T-115 work must be preserved. T-111 HTML/XML and all PDF/rendered HTML/upload/OTA work remain out of scope.
