# Postie

A native macOS HTTP client for personal use. Current work targets macOS 27.0+ and builds with Swift 6/Xcode 27. M1/M2 are implemented and locally verified as of 2026-10-17; later roadmap features are not implemented.

## Build and run

No third-party dependencies are required. From the repository directory:

```sh
make app
open dist/Postie.app
```

The Makefile builds a release app bundle and applies an ad-hoc signature; it does not inspect signing identities or distribute/notarise the app. Override `SWIFT`, `BUILD_DIR`, `APP_DIR` or `CONFIGURATION` on the make command line when needed. HTTP and HTTPS are allowed for an explicit API client; normal server-certificate validation remains enabled.

For an isolated development workspace, launch with explicit directories:

```sh
open --new dist/Postie.app --args \
  --data-directory /Volumes/Data/tmp/postie-demo/data \
  --body-directory /Volumes/Data/tmp/postie-demo/bodies
```

Otherwise saved collections live in `~/.config/postie`, with one versioned JSON file per request and an ordered collection index. Existing Application Support or test stores are not moved or merged automatically; use `--data-directory` to reopen one explicitly. Response bodies are transient files, not automatic saved history. A second writer to the same workspace is refused. Ordinary literal headers/bodies are stored as entered; encryption and structured authentication are later milestones.

## Local verification

```sh
make test
make fixture
```

The Swift fixture binds only loopback, prints its chosen port and serves synthetic echo, redirect, delay, large/chunked and binary responses. Tests build and launch it automatically in isolated temporary workspaces; `make fixture` starts it for manual checks. It is not bundled with the app. In restricted agent execution, build tools require explicit writable caches and an approved invocation outside the outer tool sandbox; see docs/implementation.md. `--disable-sandbox` avoids unsupported nested SwiftPM manifest/plugin sandboxing for this trusted dependency-free package.

## Scope

Rename a request by right-clicking its sidebar row and choosing **Rename request…**, or edit its name above the URL bar. Changes save automatically. Execution settings are under the request **Settings** tab.

M1/M2 cover a side-by-side request/response editor, stacked query/path/header/body configuration, concurrent request identities with one in-flight execution each, Cancel/Open Request activity navigation, manual redirect following and header inspection, bounded file-backed responses, and saved flat collections. Execution options live in the request Settings tab. Both bodies grow vertically within their pane's outer scroll area; response previews remain bounded.

The initial baseline received independent security, architecture/performance and UI reviews on 2026-10-17. All 46 functional tests pass. See [review findings and verification limits](docs/baseline-review.md).

Scoped variables, structured auth/encryption, syntax highlighting, command palette, snapshots and cURL import/export remain later milestones. Paste cURL is explicitly deferred for the first slice. Runtime evidence and remaining gaps belong in docs/implementation.md and .agents/handoff.md; the roadmap is docs/roadmap.md.
