# Inherited headers, variable inspection and JSON editing

Approved 2026-10-18. T-64–T-67 are complete locally.

- [x] T-64: inherited collection headers share the request Headers table. Rows are read-only, retain templates, explain overrides/suppression and jump to collection Headers.
- [x] T-65: JSON-only newline indentation and selected-text delimiter wrapping. Two-space indentation, inline opener pairs, native undo; paste/IME/None unchanged.
- [x] T-66: complete variable tokens open an inspector above their text range; show ordinary values, explicit secret Reveal and Go to definition. Incomplete tokens retain keyboard autocomplete, anchored to their range.
- [x] T-67: repair revealed-secret Name/Value alignment in collection and request variable tables, retaining single-line controls and readable long names.
- [x] Focused tests, independent source review, isolated native checks, release build and local commit.

Variable inspection in single-line template inputs resolves the effective request/collection/global definition without decrypting until Reveal. The body retains autocomplete. Inspection clears transient revealed state on dismissal or invalidation. Variable values remain literal. Navigation selects the definition's scope/tab; no automatic edits or network sends. Header status does not resolve/decrypt templated names: uncertain matches are labelled explicitly.

Native anchoring uses AppKit's character-range screen rectangle converted into the field coordinates. The preferred edge requests placement above the token; macOS may reposition popovers near screen edges. Sources: [character range rectangle](https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect(forcharacterrange:actualrange:)), [popover positioning](https://developer.apple.com/documentation/appkit/nspopover/show(relativeto:of:preferrededge:)).

Memory budgets, drag-and-drop ordering, M5 and response-body redaction remain outside this slice. No user configuration or existing credentials are used for validation.

## Verification — 2026-10-18

Independent source reviews and scope audit completed. A templated-header case-folding status defect was corrected with focused tests. Functional verification passes 106 cases (Core61/App45), zero failures. Final release build and strict signature check passed.

Native synthetic checks passed: inherited/overridden/suppressed/disabled rows in one table; collection Headers source navigation; ordinary inspector value, explicit secret Reveal/Hide and collection definition navigation; request definition navigation to Variables; initial token click retaining URL focus, typing, undo and caret movement; autocomplete above its token with Return insertion and no send; JSON empty-container newline indentation/undo and nested selected-text brace/bracket/quote wrapping with selection retained.

The reported secret layout was reproduced with admin_authorisation in the collection view and scope in a 335pt request pane. The fixed shared edit layout was checked through Replace/Show with synthetic text in both panes: Name/Value boundaries align and Hide/Cancel/Save stay on one line. Actual secret decryption/Reveal was exercised before the presentation-only host/layout refinements; final controls and guards were source-reviewed.

Inspector presentation is deferred beyond AppKit selection setup, uses a non-focusable host/actions, and repositions open popovers without presenting again. Inspector values are scrollable but not selectable; existing referenced-variable Copy remains available. Body inspection, IME, light appearance, pending-Keychain fault injection, large-input latency and new memory profiling were not exercised. The screen locked during one keyboard attempt; that attempt was discarded and autocomplete was rechecked after the user unlocked. Temporary caffeinate assertion was stopped after checks. Validation app closed; no requests sent, user data read, or security dialogs bypassed. Synthetic validation Keychain items remain untouched.
