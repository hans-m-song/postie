# Response rendering alternatives — T128

Research date: 2026-10-26. Scope: primary-source comparison before further implementation. No renderer code, dependency, build or application process was changed or started for this research.

Subsequent approved trial, 2026-10-26: stable deferred styling was implemented and tested. Benchmarks rejected unguarded minified colouring, leading to a response-only 20,000 UTF-16-unit line safeguard, consistent with [Monaco's documented default](https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IGlobalEditorOptions.html#maxTokenizationLineLength). Formatted bodies colour progressively; long-line bodies remain plain. A separate 950 kB single-line native initial-layout cost of about 5.3 seconds remains, so the trial does not establish a complete large-file solution. See [final trial evidence](response-performance.md).

## Decision

Viewport-based rendering is a valid, established design. That does not validate Postie's current implementation of scroll-triggered syntax-attribute removal and reapplication.

Recommended first candidate: retain a bounded native `NSTextView` viewport, compute syntax tokens off-main within the existing 1 MiB highlighting ceiling, and apply stable foreground attributes once for each response/syntax/theme revision. Scrolling should not edit syntax attributes. This is a proposed simplification, not a verified fix or a performance claim.

```text
Response revision ──> background token computation ──> stable styles
                                                         │
Scroll position ──> native viewport layout ──────────────> visible text
```

The proposed separation removes Postie's application-level scroll → attribute mutation → layout feedback path. It does not eliminate native layout work or prove the root cause of the observed failure.

## Evidence and alternatives

### 1. Native TextKit 2, stable document attributes — first candidate

Apple describes TextKit 2 as using noncontiguous viewport layout with an overscroll region. Offscreen geometry may be estimated; asking to ensure offscreen layout can be expensive. The built-in text control provides selection and accessibility services that a custom renderer must otherwise supply. [Apple: Meet TextKit 2](https://developer.apple.com/videos/play/wwdc2021/10061/)

For a response that is static between replacements, styles can be stored with the display text instead of repeatedly changed on scroll. Neon provides a concrete `TextStorageSystemInterface` that batches default and token attributes in `beginEditing` / `endEditing`. This demonstrates a real native integration technique; it does not establish Postie-specific speed or repaint correctness. [Neon native interfaces](https://github.com/slsrepo/Neon/blob/main/Sources/Neon/TextViewSystemInterface.swift)

Tradeoff: initial styling and theme changes may cost more than the present small-window pass. Input size alone does not bound the number of style runs. Minified single-paragraph input remains an important test; viewport layout is not proof that every operation on one enormous paragraph is cheap. These are reasons to benchmark this candidate, not to assume it succeeds.

The existing source has a 1,048,576-byte highlighting ceiling in `Sources/PostieApp/SyntaxHighlighting.swift`. The proposal retains that boundary. It does not add disk streaming or permit unlimited full-response styling.

### 2. TextKit rendering-only attributes — legitimate API, unresolved integration

Apple distinguishes TextKit 1 temporary attributes and TextKit 2 rendering attributes from layout attributes. The same migration guidance warns that accessing an `NSTextView`'s legacy `layoutManager` can switch it to TextKit 1 compatibility mode. [Apple: What's new in TextKit and text views](https://developer.apple.com/videos/play/wwdc2022/10090/)

Neon has separate implementations for TextKit 1 temporary attributes, TextKit 2 rendering attributes and backing-storage attributes. Thus rendering-only styling is not an invalid idea. However, the project also documents difficult TextKit invalidation timing and visible-range integration. That supports caution about lifecycle assumptions; it does not identify the cause of Postie's bug. [Neon design and integration notes](https://github.com/slsrepo/Neon), [interface implementation](https://github.com/slsrepo/Neon/blob/main/Sources/Neon/TextViewSystemInterface.swift)

Assessment: keep as an alternative if the simpler native candidate fails a defined gate. Do not continue adding invalidations without a reliable native-paint reproduction. A TextKit 1 fallback would be deliberate and separately measured, rather than an accidental compatibility switch.

### 3. Existing native editor component — reuse instead of a bespoke renderer

STTextView supplies a TextKit 2-based replacement text view, ordinary range styling and syntax-highlighting integration. Adopting it could reuse editor infrastructure, but would introduce a dependency and still requires evaluating the same large wrapped/minified responses. Feature claims are not comparative benchmarks. [STTextView](https://github.com/krzyzanowskim/STTextView)

CodeEditTextView supplies a native line-oriented renderer. Its layout source uses a visible rectangle plus padding, caches line state, reuses fragment views and adjusts scroll position when measured heights change. Its README expressly limits system-text-view parity, including right-to-left text. The source also iterates a selected line's fragments; it should not be advertised as a guarantee of constant work for a giant wrapped line. [CodeEditTextView scope](https://github.com/CodeEditApp/CodeEditTextView), [layout implementation](https://github.com/CodeEditApp/CodeEditTextView/blob/main/Sources/CodeEditTextView/TextLayoutManager/TextLayoutManager%2BLayout.swift)

Assessment: credible native alternatives if a measured dependency evaluation becomes necessary. Neither is approved for installation or adoption by this research.

### 4. CodeMirror or Monaco in a web view — established virtualization, different integration

CodeMirror explicitly renders visible content plus a margin, tracks estimated and measured document heights, and distinguishes the viewport from actual visible ranges. Its parser has time/viewport budgets; a full syntax tree is not always immediately available. [CodeMirror system guide](https://codemirror.net/docs/guide/), [reference manual](https://codemirror.net/docs/ref/)

VS Code's view layer renders a line-number interval and reuses overlap. Its default background tokenizer retains line state and yields in short work slices. The model remains separate from that rendered interval; this is not equivalent to reading only visible bytes from disk. [VS Code view layer](https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/view/viewLayer.ts), [tokenization](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/textModelTokens.ts), [text model](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/model/textModel.ts)

Assessment: strongest reference designs for virtualization. Embedding one would add a web runtime plus app-to-editor integration, and would require checking selection/copy, accessibility, keyboard commands and theme behavior in Postie. The sources do not establish that this is faster or simpler for Postie's current response sizes.

### 5. Bespoke native line renderer — defer

Inference from the responsibilities visible in the editor implementations: a custom renderer would need line/fragment height tracking, scroll anchoring, wrapping, Unicode handling, hit testing, cross-line selection, copy and accessibility. It offers control at a substantial maintenance cost. The current evidence does not justify taking on that scope first.

## Proposed verification gate before choosing an implementation

1. Agree the first candidate and its boundary before renderer edits. Preserve the existing response-loading and highlighting limits.
2. Use one reusable, isolated verification path with guaranteed window/process cleanup. Do not accumulate application variants.
3. Test the same text for initial display, actual scroll → stop, return scrolling, response replacement, resize and wrap changes. Include dark/light appearance, UTF-16 astral characters, selection and exact plain-text copy.
4. Use both formatted multi-line and minified long-line shapes. Keep lexical context independent of viewport clipping, especially for embedded HTML languages.
5. Verify native glyph appearance, not just cached attributes or manually invoked callbacks. A target must remain visible throughout the settled check; repeated corrective scrolling must not hide movement.
6. Measure layout, tokenization, attribute application and settled repaint separately against the same fixture and build mode. Prior benchmark numbers do not prove this candidate's performance.
7. If the first candidate fails, record the failed gate and choose the next alternative explicitly. Do not chain speculative invalidation changes.

## What remains uncertain

- The exact cause of the prior rendering-attribute painting failure.
- Whether stable backing attributes avoid the observed scroll/layout interaction on the supported macOS version.
- The initial styling cost and memory overhead at the highlighting ceiling, particularly with many short tokens.
- Long single-paragraph wrapping behavior and accessibility in any replacement component.

Research establishes suitable designs and tradeoffs. It cannot replace the native correctness and performance gates above. No further implementation was attempted during this research.
