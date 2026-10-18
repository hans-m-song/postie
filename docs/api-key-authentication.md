# API key authentication

Completed locally 18 October 2026 (T-81).

Collection and request Auth offer API Key with an ordinary literal header name and encrypted value. Selecting the mode proposes `X-API-Key`; the name remains editable. Values support the existing nonrecursive variable templates and are sent verbatim, without adding a prefix. The existing Keychain-held app key, encrypted envelope and Save/Reveal/Replace editor are reused. No query-string API keys or new key storage mechanism is introduced.

## Header precedence

For a matching header name, case-insensitively:

1. Enabled manually configured request header.
2. Selected request authentication.
3. Inherited collection authentication.
4. Collection header.

Request auth is still an explicit choice: Inherit selects collection authentication; None disables it. There is no implicit fallback from None to collection auth. Disabled manual request rows do not override selected authentication, but retain their existing suppression of matching collection header rows. Basic and Bearer follow the same new manual-request-header precedence as API Key.

Shadowed authentication does not resolve its username/secret templates or decrypt its credential. Selected authentication suppresses matching collection header values before template/value preparation. Saved header rows are not mutated. Header names use existing HTTP-token validation; values must be nonempty and contain no invalid control characters.

## Privacy and persistence

The configured API header name is marked sensitive/secret for captured request-header masking, including when a manual request header wins. Reveal/Copy remains an explicit local action. Custom credential names are removed on cross-origin redirects, both automatic and manual; same-origin redirects retain them. Manual continuation uses internally retained sensitivity metadata. Response bodies retain the existing plaintext policy and are not scrubbed.

Old authentication documents decode without the optional API fields. Request/collection ciphertext checks include API-key envelopes, so ciphertext prevents accidental replacement-key creation. Unknown fields are preserved through the existing auth merge. Navigation and auth-section changes discard transient revealed/edit buffers and invalidate pending callbacks.

## Verification

Combined functional verification passed 165 tests (Core 101/App 64). A focused PreparationTests run passed all 35 tests including three added after the combined build, for 168 distinct passing tests. Coverage includes encrypted request/collection persistence and reload, API-key-only missing-key protection, verbatim templating, masking names, manual/disabled header precedence, Basic credential suppression, None versus Inherit, same-origin preservation and automatic/manual cross-origin stripping. Independent read-only review found no actionable defect. Release build passed without warnings; strict signature and diff checks passed.

Native checks in the isolated `.build/query-settings-validation` app confirmed API Key in request and collection menus, editable header-name controls, secret editor availability, readable layout at 335-point request width and unsaved synthetic key draft discard on leaving Auth. No native encryption Save/Reveal was performed; synthetic in-process key-store tests cover encryption and persistence. No real credentials, user configuration, environment values or existing Keychain items were accessed. No new Keychain item or native network request was needed; loopback tests exercised execution. The validation app was closed afterward. Delayed Keychain prompts, light mode and IME remain unverified.

Initial tester commands under the default sandbox hit build-artifact/manifest permission errors. An elevated workspace-local build under `.build/api-key-check` succeeded; no permission/ACL weakening was performed. Logs: `/Volumes/Data/tmp/postie-api-key-main-tests.log`, `/Volumes/Data/tmp/postie-api-key-preparation-tests.log`, `/Volumes/Data/tmp/postie-api-key-release.log`. Output: `dist/Postie.app`. Changes remain local and uncommitted.
