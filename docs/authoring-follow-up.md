# Authoring and response privacy follow-up

Authorised 2026-10-18. Completed locally. No memory-budget implementation or drag-and-drop reordering. Existing request context menu already has Move up/Move down.

## Checklist

- [x] T-58 JSON-body delimiter pairing with native undo, escape/string awareness and unchanged paste/IME/None behavior.
- [x] T-59 reproduce and repair focused URL variable/path highlighting.
- [x] T-60 metadata-only variable completion in applicable template fields and body.
- [x] T-61 send-time sensitivity metadata and default response-pane header masking with explicit Reveal/Copy, including redirects.
- [x] T-62 read-only referenced-variable table in Variables tab, preserving value actions and dismissal protection.
- [x] T-63 one-line secret editor controls, preserving save/cancel/conversion behavior.
- [x] Independent source review, focused functional verification, native synthetic checks, documentation and local check-in.

## Boundaries and choices

Single-pass variables remain literal values, so variable definition inputs do not suggest nested variables. Query/header names and values, path values, URL, body and supported auth inputs receive scope-aware metadata. Masked auth fields remain SecureField; suggestions are available after explicit Show. No values are decrypted for completion.

Core captures lowercase sensitive request-header names from effective secret-dependent fields plus Authorization, Proxy-Authorization and cookies. Final responses, automatic redirects and manual continuation preserve that metadata. UI masks these fields and standard response cookie fields, with explicit Reveal/Copy. Actual sent bytes and captured header values remain unchanged; this is display masking, not response-body redaction. Live variable edits cannot reclassify an old exchange.

Native editing worker owns HighlightedTextField/GrowingBodyEditor and bounded shared helpers; core worker owns preparation/HTTP metadata propagation; secret UI worker owns variable/auth layouts. Main owns caller wiring, response masking, reference table, integration and durable documents. All use synthetic data only, no user config/environment/PII/Keychain reads. Builds coordinated after worker freeze. Tests cover main functional changes, not a comprehensive UI suite.

## Verification — 2026-10-18

Independent functional verification passed 93 tests (Core61/App32), zero failures. Independent source reviews and final scope audit found no remaining blockers after focus/auth metadata fixes. Release build passed. Native isolated checks passed JSON pairing, closer skipping, undo, literal paste, unchanged None, focused URL colors without typing and keyboard refocus, field/body/auth completion, referenced-variable viewing/dismissal, and one-line secret editing. Compact saved-secret icons fit a 335pt pane.

Header checks covered standard auth, inherited secret values, secret-derived names, masked Copy, Reveal, navigation reset, intermediate redirects and manual continuation. Core tests cover automatic redirects and send-time metadata retention after scope changes. Synthetic app and loopback fixture are closed.

Limits: IME, light appearance and large-input latency were not exercised natively. Response bodies are not redacted; Copy places plaintext on the clipboard. Ad-hoc signing/Keychain continuity remains unresolved. Memory work, drag-and-drop and M5 remain deferred.
