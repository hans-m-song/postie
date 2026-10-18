# Long parameter cells — T-84

Approved revision, 19 October 2026: query names and values, plus path names and values, wrap automatically and grow vertically to fit their complete content. Short cells stay compact. The request pane owns scrolling. Path names remain read-only and derive from the URL.

This replaces the 18 October trial of three-line cells with expand controls and popovers, which the user found visually cluttered.

## Boundaries

- Preserve exact strings and bidirectional query URL/table bindings.
- Preserve variable syntax colouring, autocomplete and inspection; do not resolve or decrypt secrets automatically.
- Use the shared adaptive blue for path names.
- Keep header, auth and URL input layouts unchanged.
- Remove the line cap, expand controls and parameter popovers.

## Verification

On 19 October 2026, the release build, strict signature/diff checks and independent source review passed. Isolated native checks at a 335-point request pane verified long unbroken input wrapping beyond three lines, visible end marker through outer-pane scrolling, shrinking after shortening names/values, live URL updates and light/dark layout. No expand controls or cell-local scroll areas remain. The shared read-only path-name/value binding and completion wiring are preserved.

The initial implementation passed 173 existing functional tests and native autocomplete/Tab checks on 18 October; those tests were not rerun for this presentation-only simplification. No new tests were added. IME and very large input performance were not profiled.

## Header and alignment follow-up — T-85

Approved 19 October 2026: extend wrapping to request and collection header tables, including inherited/auth rows, and top-align query/path/header names and values. This supersedes the earlier header-layout boundary; auth configuration inputs and the URL bar retain their existing layout.

Release/signature/diff checks and independent source review passed. Isolated native 335-point dark/light checks verified long inherited/auth names, long inherited and editable values, top alignment, shrinking after editing a header, template highlighting and source navigation to collection Headers. Mask/reveal reset and source action logic were unchanged. No real credentials were decrypted; no automated tests added or rerun for this presentation change.
