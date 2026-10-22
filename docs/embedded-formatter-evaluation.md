# Embedded CSS, JavaScript, and JSON formatting evaluation

Evaluation date: 2026-10-22. This records a source review and a small synthetic JavaScriptCore prototype. It does not add a formatter dependency or change the app.

Decision update (2026-10-22): the user declined Prettier because the formatter is implemented in JavaScript. The recommendation below is historical and rejected. Native CSS/JavaScript library evaluation is now selected; no formatter dependency/helper has been authorized or added. Existing Foundation-backed JSON formatting remains available.

## Recommendation

Use the official Prettier 3.9.10 standalone distribution as the candidate for recognized inline CSS and JavaScript blocks, loaded as local app resources in JavaScriptCore. For the current contract, use its Acorn, ESTree, and PostCSS plugins; keep JSON on the existing Foundation-backed `JSONPresentation` path. Do not invoke Prettier's HTML parser for the whole document: keep Postie's conservative markup projection and replace only recognized embedded source ranges.

For untrusted response bodies, put JavaScriptCore in a request-scoped helper process if hard cancellation and crash isolation are required. The helper should receive only bounded source strings over a pipe, expose no native objects, load only the bundled formatter assets, and make no network calls. The app can terminate it on cancellation or timeout and keep the original block. A helper process is a termination boundary, not a complete OS sandbox or a documented memory quota. If a helper cannot be shipped, an in-process adapter can still avoid source execution and enforce input/output size caps, but cancellation remains best-effort while JavaScriptCore is formatting.

This recommendation is conditional on accepting that memory use is not hard-capped by a documented JavaScriptCore API. If hard memory isolation is required, retain the current raw embedded blocks until a supported sandbox/resource boundary is established. The user approved this evaluation only; dependency approval remains separate.

## Existing Postie boundary

`MarkupPresentation` accepts at most 5 MiB of UTF-8 markup, checks cancellation while scanning and projecting, and caps projected output at the same limit. It currently invokes `MarkupScanner` with token collection disabled and preserves protected raw-text regions as source. The formatter does not expose typed embedded-code ranges to `BodyTextFormatting` yet. [MarkupPresentation.swift](../Sources/PostieCore/MarkupPresentation.swift#L3) [MarkupScanner.swift](../Sources/PostieCore/MarkupScanner.swift#L236)

The scanner already distinguishes CSS, JavaScript, and JSON data blocks while collecting syntax-highlight tokens. Its current recognition includes ordinary and module scripts, known JavaScript MIME types, default/`text/css` style blocks, and recognized JSON script types; unknown script types remain unclassified. The formatting path needs to reuse that classification and expose ranges without re-parsing or changing the surrounding markup. [MarkupScanner.swift](../Sources/PostieCore/MarkupScanner.swift#L249)

`BodyTextFormatting` dispatches whole JSON bodies to `JSONPresentation` and HTML/XML to `MarkupPresentation`. The UI runs formatting in a detached Swift task and cancels that task when the presentation identity changes. `JSONPresentation` validates with `JSONSerialization` before formatting, so embedded JSON can reuse this existing path rather than adding another JSON parser. [BodyTextPresentation.swift](../Sources/PostieApp/BodyTextPresentation.swift#L271) [BodyTextPresentation.swift](../Sources/PostieApp/BodyTextPresentation.swift#L303) [JSONPresentation.swift](../Sources/PostieCore/JSONPresentation.swift#L17)

The package currently has no formatter dependency, and the T-111 plan says embedded-language formatting is outside the delivered slice and requires approval for any new dependency. [Package.swift](../Package.swift#L14) [body-format-plan.md](body-format-plan.md#L40)

## Candidate comparison

| Candidate | Fit for this slice | Cost and limitation |
|---|---|---|
| Prettier standalone 3.9.10 with Acorn, ESTree, and PostCSS plugins | Mature parser-and-printer path for JavaScript and CSS; its browser distribution does not require Node. JSON remains on Postie's existing parser-backed formatter. | Adds about 609 KB of raw JavaScript resources before notices; `format()` is promise-based. JavaScriptCore has no documented hard cancellation or memory ceiling in the API surface reviewed here. |
| Existing Swift/Foundation path | `JSONSerialization` already validates JSON and Postie already has a bounded JSON source formatter. | Does not format CSS or JavaScript. JavaScriptCore is an execution environment, not a CSS/JavaScript source formatter. |
| Pure-Swift HTML parsers such as Swift-JustHTML or Kanna | Could parse HTML/XML or produce serialized markup. | Does not provide CSS and JavaScript parser/printer pairs. Replacing the current source-preserving scanner with a DOM serializer also changes this feature's established conservative behavior. |
| New native CSS/JavaScript parsers plus printers | Would avoid a JavaScript runtime. | Requires selecting and maintaining two grammar/printer stacks or writing formatter logic. That is a larger implementation and maintenance surface than the bounded display feature. |

Prettier's standalone browser build explicitly omits Node, config-file and automatic plugin loading; callers must load the required parser plugins. The public `format()` API is asynchronous. The official browser documentation identifies the ESTree plugin as needed for JavaScript-family printing, and the synthetic harness confirmed the Acorn and PostCSS plugins work in JavaScriptCore for the cases below. [Prettier browser documentation](https://prettier.io/docs/browser) [Prettier API documentation](https://prettier.io/docs/api/) [Prettier 3.9.10 release](https://github.com/prettier/prettier/releases/tag/3.9.10)

Swift-JustHTML documents HTML5 parsing and serialization to HTML, plain text, or Markdown; Kanna documents HTML/XML parsing and selection. Those are reasonable markup parser options, but neither supplies the inline CSS/JavaScript formatter this task needs. [Swift-JustHTML](https://github.com/kylehowells/swift-justhtml) [Kanna](https://github.com/tid-kijyun/Kanna)

## Synthetic JavaScriptCore prototype

The official `prettier@3.9.10` npm tarball was downloaded to `/Volumes/Data/tmp/embedded-formatter-evaluation/prettier-3.9.10.tgz`. A standalone Swift harness was compiled against the system JavaScriptCore framework without invoking SwiftPM or installing Node. The prototype source is `/Volumes/Data/tmp/embedded-formatter-evaluation/main.swift`, its executable is `/Volumes/Data/tmp/embedded-formatter-evaluation/prettier-jsc-prototype`, and the captured output is `/Volumes/Data/tmp/embedded-formatter-evaluation/prototype-output.txt`. Extracted package files are under `/Volumes/Data/tmp/embedded-formatter-evaluation/prettier-3.9.10/package`.

The harness loaded `standalone.js`, `plugins/acorn.js`, `plugins/estree.js`, and `plugins/postcss.js` into a fresh `JSContext` and passed source through JavaScriptCore values, not source interpolation. Results:

- CSS input `a{color:red;background:#fff}` formatted as a PostCSS block.
- JavaScript input formatted as an AST-backed `espree` result. It included `globalThis.__sourceExecuted=true;` as source text; the global marker remained `false` after formatting.
- Invalid JavaScript `const = ;` produced a rejected promise. The catch path retained the original string and marked the block as fallback.
- Promise handlers completed within the `evaluateScript` call for these synthetic cases.
- In this JavaScriptCore context, `fetch`, `XMLHttpRequest`, `window`, `require`, and `process` were all `undefined`; no browser or Node globals were supplied.

This proves API/runtime compatibility for those synthetic inputs only. It is not a broad JavaScript/CSS compatibility suite, an adversarial parser test, a sandbox audit, or a characterization of large-input performance.

The parent reran this same three-snippet harness using macOS `/usr/bin/time -l`: one successful run took 0.03 seconds elapsed and reported 21,446,656 bytes maximum resident set size (about 21.4 MB). This is a small synthetic, warm-cache sample, not an app memory increment, worst-case peak or performance guarantee. Output and statistics are in `/Volumes/Data/tmp/embedded-formatter-evaluation/prototype-timing-output.txt` and `prototype-timing.txt`. Reproduce with `/usr/bin/time -l /Volumes/Data/tmp/embedded-formatter-evaluation/prettier-jsc-prototype /Volumes/Data/tmp/embedded-formatter-evaluation/prettier-3.9.10/package` while those temporary artifacts remain available. The statistics required leaving the restricted tool sandbox because its macOS timing-statistics query was blocked; no application or formatter sandbox claim follows from that tool permission.

## Resource, cancellation, and security limits

Keep the existing 5 MiB whole-markup input and output bounds. Proposed initial sub-bounds are 256 KiB of source per inline CSS/JavaScript/JSON block and no formatting call for an over-budget block; on parse error, unsupported syntax, or output-limit overflow, retain that block's original text while formatting other eligible blocks. These sub-bounds are estimates for review and were not performance- or memory-tested. No production wall-clock budget or large/adversarial-input peak-memory behavior has been validated; the small synthetic measurement above is the only timing/RSS evidence.

Prettier parses and prints the supplied source; the prototype does not evaluate the captured JavaScript. In production, pass captured code to a formatter function as a string value and never concatenate it into a script or call `eval`/`Function` on it. Load only local bundled resources. The tested JavaScriptCore context had no network, browser, or Node host globals and no app objects were bridged into it. This limits the formatter's ability to initiate requests; it does not prove JavaScriptCore itself is a security sandbox.

The existing Swift cancellation handler can cancel its detached task, but it cannot interrupt a synchronous `JSContext.evaluateScript` call already in progress. The Apple `JSContext` API documents script evaluation and context access, while the public `JSContextRef.h` reviewed here exposes no execution-time or memory-limit setter. Treat that as a finding about the documented/public surface reviewed, not a claim about private APIs. A request-scoped helper can be terminated to enforce a wall-clock cancellation boundary; its memory use still needs an OS-supported limit or a sufficiently conservative source cap. [Apple JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext) [WebKit JavaScriptCore public header](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRef.h) [Apple Process.terminate](https://developer.apple.com/documentation/foundation/process/terminate())

Formatting stays separate from the HTTP request/capture data path. It only receives already-captured block strings, never a URL, request headers, cookies, or authentication data. A parser failure must not reject the complete HTML view: preserve that exact block and continue, with a visible partial-formatting indication if the UI can expose one.

## Measured artifact footprint and license

The selected raw JavaScript assets and their SHA-256 hashes are:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `standalone.js` | 82,491 | `dce9a9923a5957a8f9a9cdc8902167cd3061431790edcb2bccef55626500002b` |
| `plugins/acorn.js` | 154,070 | `fa635e0d171a6ef76feffc54cfe026d2d05e302778ee071cab49c0a11d342399` |
| `plugins/estree.js` | 212,682 | `7af7b9e59af8113e22d9b25653a760c372fa8d7c04e9adf67d0037c6ebf862b4` |
| `plugins/postcss.js` | 160,107 | `8dd23dad68a8bb34d304e04b2b6493c187150dbaebdfb5b54061007f430e5058` |
| **Selected JavaScript subtotal** | **609,350** | |
| `LICENSE` | 1,065 | |
| `THIRD-PARTY-NOTICES.md` | 362,597 | |
| **Conservative raw-resource total with full notices** | **973,012** | |

The complete npm tarball was 2,801,570 bytes with SHA-256 `9dc72045591793dff972432fb78722f7ab91aaa90a7fa8c1261ede55969246b7`. The app's compressed/install-size delta was not measured. The full Prettier package notice lists several third-party license families; preserve Prettier's MIT notice and audit the applicable third-party notices before shipping a selected subset. Retaining the full notice file is the conservative starting point for attribution. [Prettier license](https://github.com/prettier/prettier/blob/3.9.10/LICENSE) [Prettier third-party notices](https://github.com/prettier/prettier/blob/3.9.10/THIRD-PARTY-NOTICES.md)

Pin the version and selected artifact hashes if adopted. Update those files only through a deliberate dependency review. Do not load from a CDN or fetch plugins at runtime. No package or app resource was added in this evaluation.

## Narrow implementation outline

1. Keep the current 5 MiB markup projection. Extend the existing scanner result with typed source ranges for supported `style`, JavaScript `script`, and JSON data blocks; preserve unknown or non-code types byte-for-byte.
2. Keep JSON on `JSONPresentation` after its existing UTF-8 and `JSONSerialization` validation. Do not add Prettier's Babel plugin solely for JSON.
3. Route bounded CSS/JavaScript block strings to a request-scoped local helper using the vendored Prettier 3.9.10 assets. The helper uses PostCSS for CSS and Acorn plus ESTree for JavaScript. It gets no network-capable native bridge and never evaluates the block source.
4. Return one formatted result or one parse/limit failure per block. Preserve failed blocks exactly; if the helper times out or is cancelled, discard its pending results and preserve the original blocks.
5. Verify content-type classification, script/module parser mode, mixed markup preservation, output-size accounting, cancellation/timeout behavior, and stale-view identity at the app seam before approving the dependency.

The 256 KiB per-block input cap and helper timeout remain proposed values; choose them after bounded synthetic timing and memory measurements. The helper process and its distribution mechanism are also unimplemented and need a packaging review.
