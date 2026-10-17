# Postie overview

Status: M1–M4 implemented and locally verified on 2026-10-17; see implementation-m3-m4.md for current decisions, audit results and limits. M5 remains deferred.

## Goal

A lightweight native macOS HTTP client for personal use. Make requests, save them in flat collections, reuse variables, and inspect responses. No account or hosted service is required.

## Product scope (M1–M5)

- HTTP and HTTPS requests: method, URL, ordered query parameters and headers, literal :name path-segment parameters, text and JSON bodies.
- Flat collections containing named requests; create, rename, duplicate requests, and delete.
- Global, collection, and request variables. Precedence: request overrides collection, which overrides global.
- Collection settings page for Variables/Headers/Auth, opened from the collection name or right-click menu. Shared headers use request overrides/disabled-row suppression; new requests inherit collection auth, existing explicit auth is preserved. Current follow-up verification: collection-settings.md.
- Literal `{{variable}}` substitution in URLs, query values, header values, authentication fields, and text bodies. Values are not recursively expanded. Missing references prevent sending and cURL copying.
- None, Basic, and Bearer authentication.
- Response status, elapsed time, headers, raw body, and formatted JSON where valid.
- Initial layout: request editor left, response right, with a resizable divider. Top/bottom layout switching is deferred.
- Request tabs are Request, Auth, Variables and Settings. Request stacks query/path parameters, headers and a growing body editor; Settings holds redirect, timeout and size options. The response column stacks exchange disclosures: redirect hops and header groups collapsed initially, final response expanded. Each pane owns one vertical scroll area. Raw and unsupported response text wraps to the pane; successful Pretty JSON retains horizontal scrolling for long lines. No separate response Body/Headers/Redirects tabs.
- Request and response body syntax selectors support None and JSON initially. None disables language colouring but preserves request-template token/missing-variable cues. JSON enables JSON highlighting. Fresh JSON/+json responses default to Pretty once a nonbinary preview is available; Raw stays selectable. Invalid/oversized JSON falls back to wrapped raw preview with an explanation. Presentation never changes source bytes or Content-Type. XML/other syntax modes are deferred.
- Concurrent execution across request identities, with one in-flight execution per request. Visible running state, elapsed time and per-run cancellation remain available across navigation.
- Ongoing Requests view listing active executions with Cancel and Open Request navigation actions.
- Saved Follow redirects setting, a manual one-hop follow action from captured requests, and expandable per-hop headers exposed by the networking API; intermediate bodies are deferred. See execution.md.
- File-backed large responses with configurable defaults: 5-minute inactivity timeout, 30-minute overall deadline and 1 GiB transfer cap. Display thresholds: 1 MiB preview and 5 MiB full JSON formatting. User approved these recommendations; disabled-limit platform semantics still need verification.
- JSON and template highlighting in request bodies; template highlighting in URL/header values; JSON highlighting in responses. Incomplete JSON remains editable.
- Automatic local saving and restoration using a versioned application-owned JSON format in ~/.config/postie. Existing stores are not migrated automatically; explicit directory overrides remain supported.
- Encrypted authentication secrets and marked-secret variables in JSON, with one application encryption key in Keychain. See encryption.md and implementation-m3-m4.md. Ordinary literal values remain plaintext.
- Copy a prepared HTTP request as cURL.
- Paste a supported cURL command into a previewable request draft without executing it; see curl-import.md.
- Command-palette-style navigation searching saved requests across collections by name or stored URL/path; opening a result does not send it. See navigation.md.
- Explicit immutable request/response snapshots: send-time templates plus frozen encrypted inputs reconstruct the submitted request; the original response remains plaintext. See snapshots.md and encryption.md.
- Sidebar snapshots sit beneath their originating request. Physical snapshot storage stays separate for source-deletion independence; the user allowed whichever disk arrangement is simpler.

Shared variables means reuse within the app, not live collaboration. Collections do not contain folders. macOS is the only planned platform.

## Deferred

gRPC, WebSockets, OpenAPI import, existing collection specifications, Git integration, named environments, live collaboration, scripts, recursive templates, dynamic values including UUIDs/timestamps, OAuth flows, automatic request history, additional syntax languages, and cross-platform support. Manual saved snapshots are in scope; automatic response persistence is not.

iCloud sync is deferred for later exploration. The proposed local layout uses one collection directory containing collection metadata with an ordered request-ID index and one JSON file per request; globals are separate. See storage.md for identity, writes and recovery boundaries.

General configuration export/import is deferred by user agreement. Copy as cURL and Paste cURL are in scope; neither implies collection portability or full curl compatibility.

## Architecture and technology

SwiftUI app with AppKit split/text controls, Foundation URLSession, CryptoKit authenticated encryption, Keychain Services and versioned JSON persistence. The dependency-free SwiftPM package contains a core library, native executable and focused test targets. A database and general protocol framework are unnecessary.

```text
UI -> request preparation -> HTTP execution
              |          -> cURL generation
              + variable resolution / authentication / validation

Persistence -> saved configuration
Keychain    -> application encryption key
```

Request preparation is shared by execution and cURL generation. Equivalent request intent is the objective; identical network bytes across URLSession and cURL are not promised. Original response data remains available independently of display formatting.

Keep each request's latest completed exchange during the session: send-time templates/inputs in memory with a file-backed body, so later saving cannot capture changed editor values. Each concurrent run has independent identity, cancellation and file ownership. Saved snapshots use metadata plus a body sidecar and never consult mutable live variables/credentials. See execution.md and snapshots.md.

Encryption protection applies to structured authentication secrets and variables explicitly marked secret. Ordinary literal URLs, headers, bodies, responses and non-secret variables may contain sensitive plaintext. Keychain holds the encryption key; JSON holds ciphertext. No automatic secret detection is promised. Protected values must never enter plaintext autosave, including when Keychain access fails. Copying files without the key cannot recover encrypted values.

User clarification, 2026-10-17: sensitive values may be accessible to the local user. Keychain is storage protection, not a restriction on viewing, editing, inspecting resolved values, or deliberately copying an executable cURL command with credentials. Do not impose mandatory redaction or additional app-level approval prompts for these deliberate actions. Exact reveal/masking controls remain a UI detail. This product policy does not authorise development agents to read the user's runtime secrets.

## Workflow and decisions still required

Follow the vertical slices in roadmap.md. M1/M2 are implemented; see implementation.md for evidence and limitations. User subsequently authorised M3/M4 on 2026-10-17; implementation-m3-m4.md tracks that work. M5 remains unimplemented.

Before M1, verify the primary-Mac deployment/signing target and approved execution defaults, and settle cache behaviour, duplicate headers/query representation, disabled-limit semantics, non-text handling and temporary-file lifecycle. Redirect following is configurable; automatic cookie storage is deferred. Concurrent requests with one in-flight run per identity and accessible cancellation are required. Late callbacks must not overwrite/misattribute results or another run's files. Before M2, settle literal-field persistence boundaries and save failure/recovery. Before M3, settle header/auth conflicts, template parsing/encoding and basic at-rest key lifecycle. Before M5, settle snapshot sidecar publication/reconstruction and explicit secret copying behaviour. Body types beyond text remain deferred unless specifically approved. These are unresolved design details, not implemented capabilities.

The local build requires macOS 27.0+, uses an ad-hoc signature and was exercised on the available macOS 27.0.1 host. Distribution/notarisation and older macOS support are unverified. Headers reflect URLSession-exposed values rather than raw wire bytes. Null overall deadlines and byte caps disable their corresponding app-level limits; a finite positive inactivity timeout remains required. No signing identities, Keychain or runtime user configuration were inspected. The debug bundle occupies approximately 4 MiB on disk; memory/CPU and release-size benchmarks have not been measured. Earlier prerequisite wording above is historical for M1/M2; implementation.md records the settled choices.
