# Postie visual concepts

Requested 2026-10-17. Static image-generation concepts, not a runnable app or approved UI. Built-in image generation is used. Prompts are saved in prompts.json alongside the final images. Text/layout in generated images may require refinement; canonical behaviour is in the product documents.

Acceptance update, 2026-10-17: user said the v3 editor looks good. Its layout is the accepted visual direction; this is not runtime validation or blanket acceptance of older concept views.

Planned views: request editor and response, ongoing requests with per-run Cancel/Open Request, expandable redirect headers, and request search palette. Synthetic example data only. The ongoing view is a requirement; exact visual styling is proposed.

## Current concepts

- [Current request editor and response](01-request-editor-v3.png): side-by-side columns; query/headers/body stacked under Request with Auth/Variables separate; None/JSON syntax selection; redirects collapsed and final response expanded with headers/body.
- [Ongoing Requests](02-ongoing-requests-v2.png): concurrent runs, elapsed time/received bytes, individual Cancel and Open Request.
- [Earlier expanded redirect study](03-redirect-headers-v2.png): illustrates hop-header contents only; tab strips/default expansion are superseded by the current editor.
- [Request search](04-request-search-v2.png): foreground name/path palette remains the concept; its background tab-based editor is superseded by v3.

Generated using the built-in image_gen tool and visually inspected on 2026-10-17. Revised to the user's side-by-side preference and nested snapshot navigation. Corrected generated out-of-scope labels, unknown-size progress, request-selection mismatch and an extra background response pane. Exact prompts are in prompts.json and edit-prompts.json. Earlier versions/drafts remain for provenance; the four links above are current.

These are raster design concepts, not SwiftUI/AppKit screenshots, a runnable prototype, or proof of native-control parity. Implementation is intended to use SwiftUI with AppKit editing where needed. Layout switching is deferred. Snapshots appear beneath originating requests in the sidebar. Physical files remain separate because source-deletion survival is simpler; user allowed disk co-location only if it simplified the design. Navigation for deleted source requests remains an explicit preimplementation decision.

Latest revision: 01-request-editor-v3.png was generated/visually inspected on 2026-10-17 using the built-in image tool. Exact edit prompt is in stacked-editor-prompt.json. It supersedes earlier request/response tab layouts. None and JSON are the only syntax choices; XML/other modes remain deferred. Syntax is presentation-only and template cues remain independent.
