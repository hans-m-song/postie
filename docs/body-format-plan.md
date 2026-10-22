# Body formats and file support

Acceptance update (2026-10-22): user confirmed PDF/HTML viewport sizing and external opening work and requested check-in. Fresh baseline passed all 393 tests and strict lint/whitespace checks. Earlier pending-preview notes below are historical; no separate claim of user verification for every large/password-protected PDF or upload case. Embedded CSS/JS formatting is deferred.

Updated 2026-10-22. T111–T114 and the viewport/external-opening follow-up are implemented locally and awaiting user acceptance. The complete 392-test suite, formatting/lint, syntax, release build and strict signatures passed. Native hosted PDF, HTML resource restrictions and MCP/CLI uploads were exercised using synthetic files and loopback servers. No real endpoints or user files were used. Changes remain uncommitted until user verification.

## Confirmed implementation decisions

Current formatter decision (2026-10-22): the user rejected Prettier because it is implemented in JavaScript. Its evaluation/proposal below is historical; do not add Prettier or the JavaScriptCore helper. Native compiled CSS/JavaScript options are being evaluated without adding a dependency. The existing native JSON formatter remains available; no CSS/JS formatter is integrated yet.

Completed local follow-up (2026-10-22): default-on Wrap text checkbox for Raw/Pretty source views, with horizontal scrolling when off. The preference remains within the view across syntax/Raw/Pretty changes without triggering body reads or formatting. All 14 focused tests, lint/syntax, release build and strict signatures passed; native/user acceptance pending. The [embedded formatter evaluation](embedded-formatter-evaluation.md) is complete; its Prettier/JavaScriptCore helper proposal needs dependency approval before integration. Pretty output remains display-only, unknown/invalid blocks must remain unchanged, and captured/rendered/exported HTML retains original bytes.

Implemented follow-up (2026-10-22): PDF/rendered HTML previews fill remaining pane height across live responses/history/snapshots, retaining a 280-point overall minimum when headers crowd the pane. Native resize/scroll-stability and small-pane tests pass. Captured exports open PDF explicitly in Preview and HTML in the default HTTPS browser. Browser JavaScript/network rules apply externally, explicitly accepted by the user; no additional confirmation dialog. No Expand control or separate Postie window. All 392 regression tests, lint/syntax, release build and strict signatures passed. dist/Postie.app is updated; user acceptance remains pending for this follow-up.

External PDF copies stream in 64 KiB chunks; HTML uses the existing complete UTF-8 5 MiB bound. Exports are independent of run/snapshot files, atomically published in unique private directories under the system temporary directory (0700 folders/0600 files). They are not removed on request rerun, snapshot deletion or app shutdown; the OS may eventually clean temporary files. HTML retains its doctype/source while adding/resolving a captured HTTP(S) base for relative assets; comment/script/template base tags are ignored. Unsupported named character references in an existing relative base produce a clear export error rather than a silently incorrect URL. Tests use injected openers; actual Preview/browser delivery requires user verification.

The 280-point minimum includes HTML resource controls and the document area together. The native WebView may be shorter than 280 points in a small pane so those controls fit; the small-window test checks that child, rather than reducing the overall preview minimum.

- T111: HTML/XML Pretty and highlighting, including embedded CSS/JS/JSON source; existing 1 MiB highlighting/preview and 5 MiB formatting bounds.
- T112: native PDFKit preview, 25 MB preview threshold with explicit Load anyway, password entry never saved.
- T113: captured HTML in native WebKit, JavaScript disabled, external resources blocked initially; resource opt-in applies only to the current preview and resets on reopening.
- T114: reference original files, including local paths configured via MCP/CLI. Direct streaming only: no workspace copies or temporary run spool. Detectable source changes fail or are reported; in-place mutation cannot be guaranteed detectable. Redirect replay must revalidate the source before rereading.
- Upload snapshots retain frozen file metadata (name/type/size/hash where available), not file bytes. They must explicitly distinguish omitted binary payloads from empty/text bodies and cannot imply self-contained upload replay.
- Tests use synthetic temporary files and loopback fixtures, never real user files, runtime configuration or credentials.

Sequence: T111 syntax/formatting → shared ownership and T112 PDF → T113 HTML rendering → T114 raw-file streaming → multipart and automation/snapshot integration. Independent reviews and focused synthetic checks precede user verification and check-in.

| ID | Deliverable | Scope / status |
|---|---|---|
| T-111 | HTML/XML Pretty source views | Implemented; conservative formatting and embedded CSS/JS/JSON highlighting. |
| T-112 | Native PDF preview | Implemented in live responses, history and snapshots, with visible-resource lifetime coordination. |
| T-113 | Rendered HTML preview | Implemented; captured source, disabled JavaScript, transient opt-in for images/stylesheets/fonts. |
| T-114 | Arbitrary file uploads | Implemented; original-file raw/multipart streams, replay validation, metadata-only file snapshots and MCP/CLI configuration. |

## T-111 contract

Goal: inspect readable HTML/XML source without modifying transmitted or captured body bytes.

- Add HTML/XML syntax alongside None/JSON, shared by request source editing, live responses and snapshots. No new markup editing aids implied.
- Share MIME detection: text/html selects HTML; application/xml, text/xml and +xml select XML, including XHTML. Ignore parameters/case; preserve JSON detection.
- Follow the existing supported-type policy: detected textual HTML/XML defaults to Pretty, with Raw available. Invalid, unsupported, oversized or binary content retains a bounded fallback with an explanation.
- Highlight tags, attributes/values, comments, entities, declarations and XML CDATA, preserving template overlays in authored content.
- Highlight CSS inside style blocks; JavaScript inside ordinary/module script blocks; JSON inside recognized JSON data blocks/import maps. Unknown embedded types remain plain. Nothing executes.
- Markup formatting preserves mixed text/protected subtrees, pre/textarea, CDATA, xml:space regions and embedded CSS/JS/JSON source. Embedded-language formatting is outside this slice. This is a conservative source-layout projection, not a standards-complete validator or a DOM-equivalence promise.
- Keep existing 1 MiB highlighting/preview and 5 MiB formatting bounds, cancellation and bounded retention. No new dependency without approval.
- Core owns syntax identities, MIME classification and bounded pure presentation. App owns colored spans and shared presentation lifecycle. Automation publishes matching syntax enum values. Existing JSON editor pairing/indentation remains JSON-only.
- Formatting task identity includes body identity, syntax and Pretty eligibility. Cancel obsolete work and prevent stale output when switching syntax, responses or snapshots.

Acceptance: focused synthetic cases for markup, mixed content, CDATA/entities, quoted delimiters, malformed/truncated input, raw-text regions, embedded language boundaries, template overlays, MIME parity, persisted request/snapshot compatibility, automation schemas, unchanged raw bytes, cancellation and bounds. New syntax saved by the updated app is not promised readable by older app versions. No live requests or credentials are needed.

Ownership: Core owns MIME/scanning/formatting and upload preparation/transport/storage. App owns syntax colors, shared presentation, native adapters and resource invalidation. Automation owns schemas and strict patches. Main agent owns integration/docs/compiler lock. Independent source and blind-test reviews found and prompted fixes for snapshot model injection, encoded XML whitespace and mixed-method upload redirect chains; all three were rechecked at source level. Commit after user acceptance.

## Preview behavior

PDFView supplies native navigation, zoom, selection and copy. Application/pdf defaults to PDF with Text still available. Files above 25,000,000 bytes require Load anyway. Invalid files show an error; locked files accept a transient password, cleared on submit/navigation. Reopening requires the password again. Visible native consumers hold a resource; invalidation clears PDFKit before lease release or snapshot deletion. See [Apple PDFView](https://developer.apple.com/documentation/pdfkit/pdfview).

Rendered HTML uses complete captured UTF-8 source up to 5 MiB and never refetches the main document. Relative resources resolve against the captured final HTTP(S) URL. JavaScript stays disabled. Stylesheets/images/fonts can be enabled for the current preview only; navigation, forms, scripts and frames remain restricted. A nonpersistent web store receives no Postie cookies/auth headers. Content rules and CSP are installed before loading. Loopback tests cover resources, inline-script request attempts, refresh/navigation and resource hints, including accepted TCP connections. These tests do not establish comprehensive DNS isolation or standards-complete browser security confinement.

References: [WebKit content rules](https://developer.apple.com/documentation/webkit/wkcontentrulelist), [JavaScript execution control](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript), [website data stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore).

## Upload behavior

Raw files and ordered multipart text/file parts stream from original absolute paths without a temporary file copy. The file picker and MCP/CLI may configure paths; missing files remain configurable and fail on send. Only multipart text is templated. Content-Type defaults to application/octet-stream for files; multipart boundaries match the wire header, and contradictory header/length values fail explicitly. Reads and redirect retries revalidate file identity, size and timestamps. Detectable changes fail; undetectable concurrent in-place changes remain possible. Hashes describe fully read bytes, not server acknowledgement.

Snapshots omit original paths and file bytes, retain file name/type/size/hash metadata, and distinguish omission from an empty body. Original enabled text templates remain available; resolved multipart text belongs only in encrypted context and resolved JSON export. A redirect that changes to a bodyless method permanently drops the upload for later automatic/manual hops. Upload request documents and snapshots use version 2; legacy text defaults remain version 1. Native UI acceptance remains pending, including large/password-protected PDFs and real user upload workflows.

## Formatting references

[HTML script types](https://html.spec.whatwg.org/multipage/scripting.html) distinguish scripts from JSON/non-script data. [XML whitespace](https://www.w3.org/TR/xml/#sec-white-space) requires care with mixed content and xml:space; indentation is not inherently semantics-neutral.
Native formatter evaluation completed (2026-10-22): [candidate comparison](native-formatter-evaluation.md). Proposed Oxfmt standalone integration is limited to extracted CSS/JS blocks, with existing native JSON formatting retained. This is a research recommendation; dependency approval and packaging/runtime validation remain pending.
Current decision (2026-10-22): embedded CSS/JavaScript formatting is deferred at the user's request. Preserve existing highlighting, wrapping and JSON formatting; do not proceed with formatter packaging or integration.
