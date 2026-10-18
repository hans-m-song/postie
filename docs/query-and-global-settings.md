# Query editing and global HTTP settings

Completed locally 18 October 2026. T-79 and T-80 implement this bounded follow-up.

## Query representation

Saved request `url` is the base URL including any fragment, without its query. The ordered `query` rows are canonical. The URL editor renders the base plus enabled rows and parses edits back into the same rows. Disabled rows remain in the table but are absent from the displayed URL and outgoing request. Removing a parameter in the URL removes its enabled row. Duplicate names, order, bare keys, empty values and empty query markers are retained.

Optional row `queryEncoding` metadata retains original encoded components and decoded values. Unchanged components preserve their raw encoding; edited components are encoded once. Template tokens remain authorable; substitution encodes inserted values without interpreting percent-encoded literal braces as variables. Escaped literal tokens preserve their escape semantics after URL editing. A bare value is encoded as explicit JSON null so unknown-field preservation cannot restore a deleted value.

Legacy requests containing both a URL query and table rows are normalized on load in their existing send order: URL query first, then table rows. Normalization is in-memory until an ordinary save; it does not remove files or change formatVersion. Preparation also accepts legacy configurations directly. The URL parser is lexical rather than network-validating, so incomplete typing remains editable; sending retains HTTP validation.

## Global defaults and overrides

The Settings sidebar page and Command-comma open global redirect, inactivity timeout, overall timeout and maximum response-size defaults. Globals are saved as `httpOptions` in the existing `globals.json`, preserving variables and unknown fields. Missing settings use built-in defaults. Malformed stored settings are preserved and made read-only, with fallback defaults and a storage issue.

New requests have per-field optional `optionOverrides`. An absent numeric value inherits the global value, shown as a placeholder. Clearing a field restores inheritance. Redirects offer Use global, Yes and No. Deadline and response limit also support explicit Unlimited, distinct from inheritance. Legacy requests without the overrides object retain their concrete `options` until values are cleared. Effective options are captured when a request starts; later edits do not alter an in-flight run.

Response size uses decimal KB (1,000 bytes) or MB (1,000,000 bytes), defaulting to MB. Unit changes affect presentation, not stored byte counts. Numeric input rejects partial garbage, nonfinite/negative values and overflow; timeouts must be positive. Invalid input restores the persisted value on blur. Explicit zero-byte limits remain valid.

## Scope and checks

155 functional tests passed (93 core, 62 app). Focused additions cover query edits/enabling/deletion, normalization and preparation, encoding/templates, persistence, inheritance and effective redirect execution, plus numeric conversion boundaries. Independent review identified bare-key persistence, escaped-token round-trip and zero-timeout issues; fixes and regressions are included. Initial new restart tests accidentally reused a still-locked body directory; correcting model lifetime and reusing the synthetic key store resolved those fixture failures.

Release build passed without warnings and strict bundle signature verification passed. Native checks in an isolated synthetic workspace confirmed URL-to-table population, checkbox exclusion, encoded value updates, URL deletion with disabled-row retention, inherited placeholders/clearing, MB-to-KB conversion and persistence across restart. A cramped 335-point request Settings layout was corrected with stacked label/control fallback and checked again in the final build. Invalid zero timeout restored its inherited placeholder on blur. Sidebar branding, removed Requests row and compact request accordions were visible. No real requests were sent during native checks; functional tests used the Swift loopback fixture. No user configuration, environment values or existing Keychain items were read. Native automation attachment stalled about 15 minutes; no product defect was inferred from that tool delay.

Evidence: `/Volumes/Data/tmp/postie-query-settings-tests.log` and `/Volumes/Data/tmp/postie-query-settings-release.log`. Production bundle: `dist/Postie.app`. Validation app/data/bodies: `.build/query-settings-validation`, app identifier `dev.postie.validation.querysettings.20261018`; closed after checks. No new secrets were needed. IME, light appearance, performance and fault-injected persistence remain unverified; memory optimization stays deferred. Changes remain local and uncommitted.

No bulk editor, long-cell layout change, cURL, snapshots, memory-budget changes or user-data migration is included.

## Request reset and sidebar hit areas

Follow-up completed 18 October 2026: Reset to Global Defaults clears the full request override object, including explicit Unlimited choices. Both global and request resets refresh numeric editor state so a focused field immediately shows the reset value or inherited placeholder. Search, Ongoing Requests, Global Variables and Settings sidebar buttons include their full padded row in hit testing.

Release build passed without warnings, strict signature and diff checks passed. Isolated native checks confirmed empty-space clicks on Settings/Global Variables, readable reset placement at 335-point request width, unlimited deadline reset and immediate focused numeric-field clearing. No new automated tests were added for these UI-only changes; existing option-resolution tests cover the underlying empty override semantics.
