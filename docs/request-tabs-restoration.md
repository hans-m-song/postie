# Request section tabs restored

T-78, requested and completed locally 2026-10-18.

- [x] Restore Request, Auth, Variables and Settings as separate request-pane tabs.
- [x] Keep Query, Path, Headers and Body as accordions on Request, all initially expanded, including empty sections and inherited-only Headers.
- [x] Preserve manual collapse choices during the session, counts, inherited variable inspection, draft values and secret cleanup when leaving a tab.
- [x] Preserve Back/Forward tab restoration and Go to definition selecting Variables.
- [x] Focused functional verification, independent review, isolated native checks, release/signature and local commit.

This supersedes the T-74 decision to put Auth, Variables and Settings in accordions. T-75 inherited popups remain. Future T-77 concerns tabs for multiple requests and is separate from these editor-section tabs. Bulk editing, M5 and memory work remain deferred.

## Verification

Independent final exact-source tests passed 118 tests (Core61/App57), zero failures and compiler warnings. Existing focused tests were updated for all-open defaults, manual collapse across tab/history navigation, and definition/draft behavior; no comprehensive test expansion. Source review and changed-file scope audit found no remaining substantiated issue. Review added a selected-Request guard so queued accordion scrolling cannot target a newly selected tab.

Isolated native checks confirmed Request/Auth/Variables/Settings tabs, all four Request accordions initially open for empty/configured requests (including inherited-only Headers), manual Query/Path collapse preserved across tab navigation, dedicated Auth/Settings content, Back/Forward tab restoration, and inherited Go to definition selecting Variables. Inherited popup and referenced-variable value popup dismissed when leaving their tabs. Edited JSON body text survived a Settings round trip. Each selected tab has one outer vertical scroll.

Header/Auth content unmounts off-tab; Variables and Body remain mounted with explicit activity flags so ordinary drafts/undo state survive while transient secret/popup state clears. Reference scanning now keys on request identity as well as source strings, avoiding stale scans for requests with identical templates. Existing encryption and operation-matched secret failure cleanup are unchanged.

Final release packaging and strict signature verification passed. Output is dist/Postie.app. Logs: `/Volumes/Data/tmp/postie-m34/tab-restoration-tests.log`, `tab-restoration-release.log`, `tab-restoration-dist.log`. Test app closed and temporary keep-awake assertion stopped. No network sends, user configuration or Keychain access. Successful secret decryption, delayed Keychain faults, IME, light appearance and performance profiling were not repeated in this slice.
