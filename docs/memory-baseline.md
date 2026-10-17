# Memory assessment — 2026-10-17

User clarified this is feature-related footprint growth between builds, not an observed session leak. Assessment only. User explicitly deferred memory changes on2026-10-17; retain these findings as a constraint for future work, without starting the proposed changes.

## Measurement

Current release code at8e0a6eb, isolated ad-hoc validation bundle, fresh synthetic workspace and loopback Swift fixture. Read only PID/RSS/elapsed counters with BSD ps; no process memory dumps, environment or user request/configuration inspection. RSS is resident memory and is not directly comparable to Activity Monitor's Memory column. No comparable older-build measurement or allocation profile was taken.

| Scenario, in sequence | RSS, KiB | RSS, MiB |
| --- | ---: | ---: |
| Empty workspace, initial | 116064 | 113.3 |
| Empty workspace, subsequent idle sample | 101376 | 99.0 |
| One empty native request editor | 145680 | 142.3 |
| 477-byte JSON response | 166208 | 162.3 |
| 8 MiB text response, 1 MiB raw preview | 220752 | 215.6 |
| 32 MiB text response, same preview cap | 214752 | 209.7 |
| Navigate to global variables afterward | 216720 | 211.6 |

These are single sequential observations, not peaks or controlled allocation attribution. The unchanged preview cap and similar RSS for8/32MiB support file-backed transfer behavior. UI construction/display added visible resident cost; exact allocation ownership is unproven. Navigating away did not immediately reduce RSS, which alone neither proves nor excludes retention problems. No leak claim. Synthetic app and fixture were closed after measurement.

## Source findings

- HTTPExecutionManager uses URLSession.downloadTask and moves completed files, with newest128 event buffering per active run. Full response bodies are not assembled as Data by app code. The default1GiB response cap is configurable and limits body transfer/storage, not application RAM.
- ResponseBodyReader reads at most1MiB plus one byte. AppModel.latestResponses keeps one latest response/preview per request identity; replacement/delete removes the previous state. There is no aggregate preview budget across visited requests.
- JSONPresentation caps pretty input/output at5MiB; parsing/validation/output/text layout can hold additional temporary representations.
- SyntaxHighlighting stops above1MiB input and caches at most12 results at estimated6MiB cost. The estimate omits collection overhead and variable-context sets; it is not a strict RSS bound.
- GrowingBodyEditor uses a dedicated UndoManager without an explicit levelsOfUndo bound. Text/layout and workspace request strings are not size-capped by the highlighting limit.
- Distinct request identities can execute concurrently without an app-wide concurrency ceiling. Search and initial drafts scale with workspace size.

Independent read-only core/model and native-editor/cache audits agreed on these capacity gaps. No source code, tests or app behavior changed during this assessment.

## Recommended first slice, pending approval

1. Keep a response's bounded text preview only while its request is selected. Release/cancel obsolete preview state on navigation and reload from the existing complete body file on return. Preserve response metadata and body files. This avoids an LRU/cache framework and makes retained preview text independent of the number of visited requests.
2. Bound request-body undo history to100 edit groups, preserving normal undo/redo. This is an operation-count bound, not a byte bound for arbitrarily large pastes.
3. Repeat the same synthetic RSS scenarios plus a focused preview-eviction functional check and native undo check. Keep display/transfer limits unchanged initially; measure before adding pagination or changing preview size.

These measures bound identifiable app-owned state; they cannot enforce a fixed process RSS ceiling for AppKit/SwiftUI/URLSession allocations or arbitrarily large user configurations. A historical build-by-build comparison would require matched build type, workspace and actions.
