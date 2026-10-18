# Navigation and editor consistency

Approved 2026-10-18. T-70–T-73 are complete locally, together with T-68–T-69.

- [x] T-70: bounded session-only Back/Forward history, toolbar actions and Command-[ / Command-]. Cover request/collection/global/activity destinations and definition jumps, retaining drafts and section context without sending.
- [x] T-71: inherited header template highlighting, consistent query/path/header control gutters, and matching monospace name/value sizing in editable/referenced variable tables. Keep metadata smaller.
- [x] T-72: body editor starts at one text line plus padding and grows with newlines/wrapping; one outer vertical scroll owner.
- [x] T-73: closed-but-incomplete names such as `{{var_}}` continue autocomplete for `var_foo`. Exact defined names use the inspector; accepting a suggestion replaces the whole token once.
- [x] Focused functional tests, independent source review/scope audit, native checks, release/signature and local commit.

History stores identities and section metadata, not duplicate configurations or responses. It is bounded to 100 destinations and skips deleted targets. New navigation clears Forward; restoring a destination does not execute a request. No persisted history, scroll/caret restoration, M5, scripts, import or memory-budget expansion.

Table highlighting reuses the existing bounded asynchronous template highlighter without resolving/decrypting values. Body minimum height derives from the actual native font/insets rather than a fixed pixel minimum. Inspector routing requires an exact defined variable, allowing unknown partial names to reach completion even when braces are closed.

## Verification — 2026-10-18

Independent exact-source tests passed 115 tests (Core61/App54), zero failures and compiler warnings. Independent navigation/editor review and scope audit found no remaining blockers. Release build and strict signature verification passed.

Isolated native checks confirmed Command-[ / Command-] preserve an edited URL, a definition jump opens Variables and returns to Request in one Back step, inherited tokens are highlighted, table gutters align, and empty body height grows for multiline JSON then shrinks after deletion. Closed partial `{{var_}}` offered `var_foo` with its ordinary value; Return produced `{{var_foo}}/items` without duplicated braces or sending. Keyboard navigation reached the eighth collection completion. Compact ordinary and secret inspectors rendered correctly; explicit Reveal/Hide passed with a synthetic encrypted value.

No network requests or user configuration were accessed. Pointer selection after manual completion scrolling, error-line resizing, IME, light appearance and performance profiling were not exercised in this slice. Session history is not persisted. Logs: `/Volumes/Data/tmp/postie-m34/navigation-polish-tests.log` and `navigation-polish-release.log`.
