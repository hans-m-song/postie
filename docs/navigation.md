# Workspace navigation

User accepted the current integrated navigation/history/palette build on 2026-10-22 (“seems to work well”). Earlier pending native/user-verification statements describe their checkpoint; no exhaustive native/VoiceOver check is implied. A proposed Command-Shift-P shortcut for `>` commands is not implemented yet.

## T-115 — Workspace switcher (implemented locally, 2026-10-22)

User selected one searchable collection/request/snapshot switcher in place of standalone request search. The centered control shows the current destination's breadcrumb; its unfiltered list includes every collection and request in saved order. Collections open their initial Requests tab; explicit variable/header/auth/settings links retain their target tab. Snapshot matching uses only the snapshot name, including retained captures with deleted sources. Collection/request labels remain display context for snapshots, not search fields. Results retain stable identities. No body, secret-value resolution or network search is involved. Command-P opens the toolbar palette; Command-F opens its requests-only mode. Request/snapshot selection navigates without sending; collection settings remain an explicit action.

## T-117 — Palette commands and variables

Implemented locally on 2026-10-22; native/user acceptance pending. Command-P opens without a prefix, searching every supported kind: requests, collections, snapshots, commands and variables. Command-F prefills `@` for requests only. `#` filters collections, `>` commands and `$` variable names; all prefixed options are also available unprefixed. Each explicit opening/mode switch places the caret after the prefill without selecting it; ordinary editing preserves selection. A native AppKit field implements focus and UTF-16 caret placement, arrow/Return/Escape handling, and input-method deferral.

`>` lists Settings, Request History, Global Variables, Create Collection, and each collection's Settings/Create Request commands. Space-separated command terms match across collection and action names. Creation uses the existing naming sheet after the popover closes; readonly/stale destinations are guarded. The centered breadcrumb has additional horizontal padding.

`$` searches variable names by case-insensitive substring across global, collection and request scopes. Each definition remains a separate result, including shadowed names; request drafts take precedence over saved request variables. Plain values get bounded single-line previews. Encrypted values expose only names, scope and a Secret marker; they are neither decrypted nor matched by value. Selecting a result opens its exact owner's Variables page/tab. Duplicate collection/request names get identity suffixes where needed.

History list rows use normal row selection throughout their method/URL text. Read-only inspector fields remain selectable. Native row hit-testing, keyboard focus, and popover-to-naming-sheet interaction await user verification.

Local verification: all 311 package tests passed without warnings (Core 140, Control 19, Automation 28, App 124), including eight palette catalog tests and two model-navigation tests. Strict formatting/whitespace and syntax checks passed. Independent source and blind-test reviews closed their scoped findings. Log: /Volumes/Data/tmp/postie-palette-tests.log. No automated native shortcut or pointer interaction is claimed.

Refinement verification: 23 focused tests passed without warnings, including unified/type-exclusive result composition, bare prefixes, actual AppKit automatic focus/caret and inserted text, already-open query replacement, selection preservation, UTF-16 offsets, key modifiers and marked-text deferral. Lint/syntax passed. Log: /Volumes/Data/tmp/postie-palette-revision-tests.log. This refinement did not rerun the full 311-test baseline. Whole-app shortcut/menu/popover interaction remains user verification.

The refinement's clean release build and strict signatures passed; dist/Postie.app contains the unified palette/caret changes. Build log: /Volumes/Data/tmp/postie-palette-revision-build.log. Reopen this bundle for user verification.

Clean release build and strict signatures passed; dist/Postie.app refreshed. Build log: /Volumes/Data/tmp/postie-palette-build.log. Quit and reopen the rebuilt app for native verification; changes remain uncommitted until user acceptance.

The sidebar stays available for ordering and management, starts hidden, and remembers visibility. While hidden, history/global-variable/settings actions appear as toolbar icons with tooltips. All toolbar action buttons use icons. Request/response layout moves to global Settings → Appearance, retaining its existing preference. Typing searches the entire workspace; an empty query lists every collection and its requests. Duplicate visible labels gain collision-aware identity suffixes, also exposed to accessibility. Original request-search behavior below is a historical baseline.

Focused gates: draft-name/literal-URL matching; collection/snapshot-name-only matching; retained/moved snapshot context; duplicate identities/order; complete unfiltered listing and no-result states; collection initial/explicit-tab navigation; keyboard opening/dismissal, current-destination state, stale-result guards, restored focus and sidebar preference. Native look/focus and restart visibility need user verification; automated matching tests do not establish these interactions.

Verification on 2026-10-22: ten focused search/collection/navigation tests passed after the refinements. The final combined suite passed all 301 tests, strict formatting/whitespace and syntax checks; clean release build and strict signatures passed, refreshing dist/Postie.app. Independent reviews closed duplicate-label, accessibility, narrow-control and test-reliability findings. Logs: `/Volumes/Data/tmp/postie-session-history-full-tests.log` and `postie-session-history-build.log`. Native interaction/user acceptance remains pending. No real endpoint access, runtime secret reads or new persisted search index.

## Historical request search palette

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

Superseded locally on 2026-10-22 by Request History (Command-2): one row per execution, selected frozen request/response details beside the list, active cancellation and a separate Open Request action. No history is saved across app restarts. Retention is 10 completed runs or 100 MB additional logical capture/body data, active runs exempt. See [session-history-plan.md](session-history-plan.md) for ownership, limits and verification. The paragraphs below describe the earlier navigation baseline.

Collection navigation: click its name to open the collection Variables/Headers/Auth page, use the disclosure arrow to expand/collapse requests, and right-click for settings/new request/rename/delete actions. There is no collection ellipsis control. Selecting a request or a search result leaves collection settings and opens that exact request without sending.

Implemented 2026-10-18: inherited headers appear read-only in the request Headers table; their source action opens collection Headers. Clicking inside a complete variable token in a single-line template input opens its value inspector above the token. Go to definition opens the effective scope's Variables page/tab without sending. Incomplete tokens retain keyboard autocomplete. See inherited-headers-and-editing.md for validation and limits.

A separate Ongoing Requests view lists active runs across collections with Cancel and Open Request actions; see execution.md. Opening a configuration does not create a new run. The command palette remains request search, not a duplicate activity log. User requested visual concepts for these views on 2026-10-17; mockups are proposals, not accepted UI or implemented functionality.

## Session Back/Forward

Implemented 2026-10-18: toolbar Back/Forward and Command-[ / Command-] restore request, collection, global-variable and ongoing-request destinations, including request/collection sections and definition jumps. History retains at most 100 destinations, skips deleted targets and clears Forward after new navigation. It preserves configuration drafts without executing requests. History, caret and scroll positions are not persisted. See navigation-and-editor-polish.md for verification.

T-78, 2026-10-18: Request/Auth/Variables/Settings section tabs are restored. Query/Path/Headers/Body stay in initially expanded accordions on Request; manual collapse survives tab/request navigation. History restores the selected section tab, and variable definition jumps select Variables. Future multi-request tabs must activate the destination request tab during Back/Forward; tab lifetime/persistence is not specified yet. See request-tabs-restoration.md.
