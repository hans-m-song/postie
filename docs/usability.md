# Approved usability follow-up

Approved 2026-10-17 after local M1/M2 testing. T-36–T-41 and T-43–T-46 are implemented; final direct test-bundle verification passed (45 tests); SwiftPM runner completion remains unverified. This document distinguishes intended behaviour from completion evidence in implementation.md.

```text
Sidebar | Request name / collection
        | Method | URL spanning both panes                 | Send / Cancel
        |-------------------------------------------------------------
        | Request configuration            | Response
        | Follow redirects                 | > Request headers
        | Query parameters + empty row     | > Response headers
        | Path parameters                  |   Body
        | Headers + empty row              |
        | Body                             |
        | > Timeouts and response limit    |
```

- T-36: query/header tables always end in an editable empty row. Nonempty input creates an ordinary saved row and another empty row. The empty placeholder is presentation state, not persistent configuration. Typing must retain focus.
- T-37: disclosure text, spacer and surrounding heading padding toggle the section along with its arrow, using a single accessible control. Final response starts expanded; redirect hops, request headers and response headers start collapsed.
- T-38: a stopped, supported redirect offers Follow redirect in the response view. Follow the captured next request as one new run under the same request identity. Do not resend the original request or mutate its saved settings. Continue observed header history; keep HTTP(S), method/body, cross-origin credential and 10-hop policies. Invalid/unsupported destinations do not offer the action. Reference: [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html#name-redirection-3xx).
- T-39: default configuration becomes ~/.config/postie, derived using Foundation's current-user home directory. Explicit --data-directory and --body-directory keep their meaning. No environment-variable reads, implicit migration, merging or runtime-data inspection. Existing Application Support/test stores remain where they are.
- T-40: whole path segments of the form :name become parameters, with ASCII names matching [A-Za-z_][A-Za-z0-9_]*. Display referenced names with values in a path table. Raw values are encoded as one segment; slash/percent/question/hash cannot become URL structure. Missing, empty or ambiguous enabled values block sending. Disabled and unused rows do not substitute. These are distinct from later {{variable}} templates.
- T-41: method, URL and Send/Cancel span the entire detail area above the split panes. Request-specific options remain left. Preserve request identity, activity navigation and autosave behaviour.

User reported clipping in the validation window during this slice. T-41 also includes reducing competing root/sidebar/pane minimum widths and constraining long URL/header content so the layout fits compact windows (target 900×600 minimum; verify 1000×700 and 1120×720). Keep side-by-side layout and accessible Send/Cancel; no layout toggle is introduced.

T-42 remains deferred: session-only request log with expandable request headers, response headers and response body. This does not introduce persistent history, snapshots or additional retention yet.

Latest approved steering during validation: T-43 adds Request and Settings tabs in the request pane; Follow redirects, inactivity/overall timeouts and response-size limits move to Settings. Request retains stacked query/path/header/body editors. Keep live execution state and cancellation discoverable regardless of tab. T-44 investigates and fixes the unused band at the response pane's right edge, preserving ordinary content padding and scrollbar room; container layout must fill its assigned width.

T-45/T-46: response and request bodies expand vertically into their respective pane's outer scroll area, avoiding nested vertical scrollbars. Raw response lines may still scroll horizontally; preview reads remain bounded to 1 MiB. The growing request editor must preserve text, cursor/selection, undo, disabled state and autosave while avoiding a second vertical scroll view. No syntax or formatting feature is added.

Verification boundary: isolated synthetic files and loopback services only. Focused tests verify preparation, persistence and redirect behaviour; real native UI checks verify first-keystroke focus, tab entry, disclosure hit regions/defaults, path editing, one-hop follow and toolbar width. Do not inspect an existing user app window or configuration to perform those checks.

T-50, verified2026-10-17: query/header headings, saved rows and trailing empty rows share padding/control-rail widths and matching flexible columns. Protocol inputs (method, URL, parameter/header names and values) and numeric settings use monospace. Default response-size input has enough width for its grouped value. Native alignment and continuous keyboard entry checked in a synthetic900×652 window; no storage behavior changed.
