# Body formats and file support

Recorded 2026-10-22. T-111 is the next user-selected slice: HTML/XML Pretty source views with syntax highlighting. Native PDF viewing, rendered HTML and uploads are separate slices. This is a plan, not an implementation or verification claim.

| ID | Deliverable | Scope / status |
|---|---|---|
| T-111 | HTML/XML Pretty source views | First slice requested; markup formatting plus embedded CSS/JS/JSON highlighting. Implementation plan pending confirmation. |
| T-112 | Native PDF preview | PDFKit approach accepted for response/snapshot viewing. |
| T-113 | Rendered HTML preview | Native WebKit proposed; external requests blocked by default, opt-in resource loading. JavaScript execution explicitly out of scope. |
| T-114 | Arbitrary file uploads | Requested future capability; raw file and multipart form-data proposed as separate steps. Storage and automation file-access contracts undecided. |

## T-111 proposed contract

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

Ownership: main agent owns integration/docs/compiler lock; bounded workers own distinct Core, highlighting and UI/automation surfaces. Freeze shared interfaces before parallel edits. Independent source review and meaningful focused tests precede release builds/signatures and user UI verification. Commit after user acceptance. Implementation remains gated on plan confirmation.

## Preview proposals

PDFKit is native: PDFView supplies navigation, zoom, selection and copy. Proposed viewing uses the downloaded file on demand in live responses/snapshots, releasing viewer state on navigation. Invalid, password-protected and oversized file behavior needs a policy before implementation. See [Apple PDFView](https://developer.apple.com/documentation/pdfkit/pdfview).

Rendered HTML would use WKWebView for the captured body, not re-fetch the main page. External requests remain blocked unless explicitly enabled for the preview; resolve relative resources against the captured final URL. JavaScript execution stays disabled even with external resources enabled. Stylesheets/images/fonts are intended opt-in resources. Use a nonpersistent website data store separate from request cookies/auth; do not forward Postie authentication headers to resource fetches. Verify blocking with a loopback request counter, beyond navigation delegate callbacks. Resource opt-in scope/persistence remains undecided. No renderer or zero-network guarantee is claimed yet.

References: [WebKit content rules](https://developer.apple.com/documentation/webkit/wkcontentrulelist), [JavaScript execution control](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript), [website data stores](https://developer.apple.com/documentation/webkit/wkwebsitedatastore).

## Upload questions

Raw file bodies send selected file bytes as the body. Multipart form-data combines text and file parts. Both need streamed/bounded I/O, MIME/filename handling, cancellation/redirect behavior, file lifetime and snapshot/export semantics. Decide managed copies versus external references and an explicit automation file-access contract before coding. Do not silently make MCP paths unrestricted filesystem access.

## Formatting references

[HTML script types](https://html.spec.whatwg.org/multipage/scripting.html) distinguish scripts from JSON/non-script data. [XML whitespace](https://www.w3.org/TR/xml/#sec-white-space) requires care with mixed content and xml:space; indentation is not inherently semantics-neutral.
