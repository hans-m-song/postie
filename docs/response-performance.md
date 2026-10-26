# Response text performance — T128

## Current trial — 2026-10-26

The user accepted the trial on 2026-10-26, reporting that performance is much better and the appearance looks good. Automated gates are complete locally. A separate native long-line layout limit remains unresolved; acceptance does not establish that pathological case as fixed.

```text
Source revision → off-main input guard → off-main tokenizer → small UI batches
Scroll/resize   → delay unfinished batches; retain installed colours
```

## Module boundaries

| Module | Responsibility |
|---|---|
| `BodySourceTextDisplay` / `HighlightedResponseText` | Shared live-response, snapshot and history display input |
| `ResponseTextViewport` | Native bridge, off-main preparation, revision cancellation and teardown |
| `ResponseTextInputPolicy` | Bounded, cancellable input inspection before tokenization |
| `ResponseTextViewportHostView` | Native scroll/wrap geometry and interaction notifications |
| `ResponseTextHighlightingState` | Stable source-order foreground attributes and yielding application/clear batches |

TextKit 2 owns viewport layout. The response path makes no explicit whole-document layout or measurement request and never accesses the legacy `layoutManager`. The previous custom visible-range mapper, interval index and scroll-time colour eviction have been removed. Shared request editors and `SyntaxHighlighting` remain unchanged.

Tokenization retains complete lexical context within the existing 1 MiB input ceiling, including embedded HTML languages. Response preparation also pauses highlighting when any logical line exceeds 20,000 UTF-16 units. The scalar scan runs off-main, returns promptly once a limit is known, and checks cancellation. Unlike Monaco’s per-line tokenization policy, Postie conservatively leaves the entire response plain rather than losing multiline lexer context. The content remains readable, selectable and copyable. A reason-specific label explains the pause. [Monaco line limit](https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IGlobalEditorOptions.html#maxTokenizationLineLength).

## Deferred styling

Each batch performs at most 128 attribute writes and checks a 4 ms elapsed-time target. Batches suspend for 8 ms, allowing other main-thread work to run. A scroll or resize delays pending work until 120 ms after the last interaction. Sustained interaction may keep highlighting deferred; it does not remove installed colours.

The 4 ms target cannot preempt an individual AppKit mutation or `endEditing()`. It is a scheduling policy, not a hard frame-time guarantee. Generation checks stop obsolete preparation and application. New source is installed with fresh monospaced font and dynamic base foreground attributes, avoiding inherited token colours. Syntax-only changes clear installed colours in batches.

## Automated verification

- Focused guard and renderer gate: **13 cases, zero failures**.
- Tests cover actual target-glyph raster colours after settlement and return scrolling, offscreen colour persistence, source replacement and syntax-only clearing, stale-batch cancellation, post-interaction progress, wrapping/geometry, astral UTF-16 offsets, exact private-pasteboard copy/selection, teardown, byte ceiling and long-line boundary/recovery.
- Independent source review: no remaining substantiated findings.
- Full suite: **548 cases, 546 passed, two existing case-sensitive-filesystem skips, zero failures**. No compiler warnings.
- Strict formatting/whitespace lint, release build and strict code-signature verification pass. `dist/Postie.app` was refreshed without launching or restarting Postie. Previous bundle: `/Volumes/Data/tmp/postie-before-stable-highlighting-q1pnknjf/Postie.app`.
- The user confirmed improved performance and appearance on 2026-10-26. Accessibility and every compositor/input-device path were not individually verified by that confirmation.

## Performance evidence

All measurements are single debug-build samples using an 800 × 700 production-shaped response viewport. These are not statistical frame-time guarantees or release-build end-to-end timings. Windows run inside the test runner and close after each case; no standalone sample applications were launched.

The previously authorized OpenObserve request supplied an anonymized structure-preserving fixture only. Its raw form is 402,829 bytes and Pretty output is 569,930 bytes; original response data was not read or printed in this iteration. Tokenization is measured separately off-main before mounting, warming the existing lexer cache. Ready time includes mounting and the deferred policy/styling path; it excludes request execution and Pretty formatting. For plain fallback, ready means the pause state is visible. For styled cases, ready means the final token has its expected foreground attribute.

| Shape | Bytes | Mount + first layout/display request | Ready | Largest main-actor sample gap | Result |
|---|---:|---:|---:|---:|---|
| Anonymized minified JSON | 402,829 | 126 ms | 176 ms | 40 ms | Plain long-line fallback |
| Anonymized Pretty JSON | 569,930 | 48 ms | 2,122 ms | 11 ms | Progressive colours |
| Synthetic single long string | 950,014 | 5,281 ms | 5,456 ms | 175 ms | Plain; native initial-layout cliff |
| Synthetic many-token JSON | 868,892 | 62 ms | 4,711 ms | 27 ms | 64,000 spans applied progressively |

The sample gap is the maximum observed interval between 2 ms main-actor sleeps after mounting. It includes scheduling and native work and is not an isolated attribute-batch measurement. Initial mount cost is reported separately so a slow first layout is not hidden by the sampler.

Before the long-line safeguard, minified fixture colouring failed to complete within 20 seconds and produced a 280 ms maximum sample gap. That rejected variant is not the delivered policy. Pretty colouring completed in roughly 2.1 seconds in both variants.

## Unresolved limit

The 950 kB single-line case still takes about 5.3 seconds for initial native layout even with syntax highlighting disabled. The highlighting safeguard prevents repeated colouring stalls but cannot fix TextKit’s initial paragraph layout. Do not claim T128 is a complete large-file solution. A bounded display preview or a different renderer would require a separate agreed design and measured comparison; neither was added in this trial.

The earlier viewport-only benchmark figures described an implementation whose settled colouring was incorrect. They remain in historical logs and must not be used as proof of the final renderer’s paint correctness or overall speed.

## Evidence and continuation

- `/Volumes/Data/tmp/postie-t128-guard-focused.log`: 13 focused checks.
- `/Volumes/Data/tmp/postie-stable-benchmark.log`: rejected unguarded minified case.
- `/Volumes/Data/tmp/postie-stable-benchmark-guarded.log`: four final shapes in two temporary benchmark cases.
- `/Volumes/Data/tmp/postie-stable-full-tests.log`: full suite.
- `/Volumes/Data/tmp/postie-stable-lint.log`, `/Volumes/Data/tmp/postie-stable-build.log`: lint/release evidence.
- `/Volumes/Data/tmp/StableResponseBenchmark.swift`: archived temporary benchmark; removed from `Tests` before the full suite.
- `/Volumes/Data/tmp/postie-stable-highlighting-baseline-asbx32ro`: source/test snapshot before this iteration.

All eight earlier standalone diagnostic probe processes were terminated; no further standalone probes were launched. The accepted rendering scope is checked in separately from the remaining HAR/audit work. See [research comparison](response-rendering-research.md) for primary-source alternatives and the pre-implementation decision record.
