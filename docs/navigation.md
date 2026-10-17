# Request search palette

Recorded 2026-10-17. M4 implementation adds native Command-K/menu/sidebar search by draft or saved name and literal URL/path. Current verification is tracked in implementation-m3-m4.md.

## Initial interaction

```text
Command-K
+--------------------------------------------------+
| Search requests by name or URL/path...            |
|                                                  |
| GET   List orders     Shop API                    |
|       {{base_url}}/orders                         |
| POST  Create order    Shop API                    |
|       {{base_url}}/orders                         |
+--------------------------------------------------+
 Up/Down: select    Enter: open    Escape: dismiss
```

Search across all collections. Results show request name, HTTP method, stored URL and collection name to distinguish duplicates. Selection opens the existing request; it never sends it. Provide a menu action so the palette is accessible without knowing the shortcut. Escape restores focus without changing the current request.

If these labels are identical, show an abbreviated request ID as a disambiguator. Extend the identifier as needed, up to the full collection/request identity, so ID-prefix collisions and duplicate collection names cannot leave distinct results indistinguishable. Display names remain unrestricted.

Initial matching is case-insensitive substring matching against request display name and stored URL (including path). Trim the search query; an empty query lists saved requests in collection-name order and collection request order. Preserve that deterministic order among matches. Search collection names, fuzzy ranking, action commands, recent history and matching resolved template values are not required initially.

Search does not resolve templates or fetch Keychain values. For `{{base_url}}/orders`, `/orders` and `base_url` match; the value behind `base_url` does not. A literal URL may itself contain sensitive text and remains visible under the local-user access policy.

Maintain selection by identity, not result row number. Opening a request must preserve edits to the previous request in app state and must not conceal a failed save. No request can open from a stale/deleted result. Do not persist palette query/selection or introduce a separate disk search index.

## T-30 acceptance

- Find a request by mixed-case name, full stored URL and partial path across collections.
- Distinguish duplicate names and open the selected identity through keyboard or pointer interaction.
- Distinguish requests with identical name/method/URL/collection labels, including abbreviated-ID collisions.
- Verify empty/no-match states, Up/Down, Enter, Escape, focus restoration and menu invocation.
- Verify changes to request name/URL and create/delete are reflected without restarting.
- Verify templates remain literal in search, missing variables do not prevent navigation, selecting a result never sends it, and unsaved edits are preserved.

Implementation stays within native SwiftUI/AppKit. No external search service or generic command registry is needed. Detailed palette appearance remains a UI design choice.

## Ongoing requests navigation

Collection navigation: click its name to open the collection Variables/Headers/Auth page, use the disclosure arrow to expand/collapse requests, and right-click for settings/new request/rename/delete actions. There is no collection ellipsis control. Selecting a request or a search result leaves collection settings and opens that exact request without sending.

A separate Ongoing Requests view lists active runs across collections with Cancel and Open Request actions; see execution.md. Opening a configuration does not create a new run. The command palette remains request search, not a duplicate activity log. User requested visual concepts for these views on 2026-10-17; mockups are proposals, not accepted UI or implemented functionality.
