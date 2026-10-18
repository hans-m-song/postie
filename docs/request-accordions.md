# Request accordions and inherited value inspection

Approved 2026-10-18. Completed locally; T-78 subsequently supersedes the all-accordion layout/defaults described below. Current layout: request-tabs-restoration.md. T-75 inherited popups remain.

- [x] T-74: replace request tabs with stacked Query parameters, Path parameters, Headers, Body, Authentication, Variables and Settings accordions in the existing request pane. Full headings toggle disclosure. Counts describe rows; headers distinguish local and inherited rows. Auth/settings use summaries.
- [x] Empty sections start collapsed. Configured local content starts expanded; inherited-only headers/auth start collapsed. New query/path entries expand their section. Preserve manual choices during the session, with explicit definition/history navigation opening its destination.
- [x] T-75: inherited header names/values use the existing token-anchored inspector, effective request/collection/global scope, explicit secret Reveal/Hide and Go to definition. Rows remain read-only.
- [x] Focused functional checks, independent source review, native validation, release/signature and local commit.

No change to HTTP execution or persistence format. Preserve one outer vertical scroll, drafts, secret dismissal guards and Back/Forward. Bulk editing and request tabs are deferred, not part of this implementation.

## Verification — 2026-10-18

Independent final exact-source tests passed 119 tests (Core61/App58), zero failures or compiler warnings. Focused additions cover expansion defaults/manual collapse, query/path additions, definition reopening, ordinary navigation versus explicit history restoration, and operation-matched failed-secret-save cleanup. Independent source review found no remaining substantiated defect after correcting restoration/scroll behavior and stale secret callbacks.

Native synthetic checks confirmed empty/inherited-only collapsed defaults, configured section counts, whole-heading interaction, automatic expansion for a newly typed URL path parameter, collapse persistence across ordinary request switches, Back restoring Authentication, and Settings content under one outer scroll. Inherited value popups displayed collection values and request overrides correctly; encrypted values stayed masked. No requests were sent and no Keychain item was accessed.

An initial automation attempt did not expose inherited popup buttons; the final rebuilt app exposed them and the checks were repeated successfully. Final native checks passed middle truncation/no column bleed, clicking a truncated header-name token, collection and request variable definition navigation, opening/scrolling a collapsed Variables accordion, and explicit Reveal showing the deliberately malformed-envelope error with resized popup. Successful secret decryption was not repeated in this slice; the shared inspector passed that check in the preceding slice. Delayed Keychain fault injection, IME, light appearance and performance profiling were not exercised. Logs: `/Volumes/Data/tmp/postie-m34/accordion-tests.log` and `accordion-release.log`.

Variables retain ordinary row drafts while collapsed; secret buffers clear. Authorized saves continue, and failure cleanup checks the save's operation ID before discarding model errors so an old completion cannot clear a newer edit. Headers and Authentication unmount on collapse. The request inspection owner is injected explicitly across the native split hosting boundary.

Future T-76: bulk key/value text editing for query parameters and headers, with reversible switching to table editing. Parsing, duplicate keys, disabled rows and multiline values need a concrete specification before implementation.

Future T-77: request tabs. Back/Forward must activate the relevant open request tab as it restores a request destination; opening/restoring a request must preserve its draft and never send it. Tab lifetime, closing behavior and session persistence remain undecided. This is separate from the editor-section tabs restored by T-78.

Final release packaging and strict signature verification passed. The isolated app was closed and the temporary keep-awake assertion stopped. No new Keychain item was created.
