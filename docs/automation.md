# Local automation

Implemented locally on 2026-10-21. The normalized source passed all 279 existing package tests, app/CLI builds and strict signatures. The real Codex connection passed live MCP list/start/get, block/raw/redacted response modes and cached-ID exclusion checks; the inherited redaction flow was user-accepted. CLI list/read/send/get, cancel and snapshot CRUD passed. The app-closed CLI message was fixed and verified. Basic ordering and cross-collection moves are user-verified; intermittent insertion behavior remains unreproduced. MCP mutation coverage, collection-level parent exclusion, restart/persistence and live verification of new snapshot redaction remain pending. See the [independent review](review-2026-10-21.md) for newly identified follow-up issues; passing checks do not close them.

Postie owns the workspace and execution lifecycle. Both automation adapters require the app to be running; they do not open another workspace writer. Independent/headless CLI operation is deferred.

## CLI

Build with `make cli`. The executable is `dist/postie`; the Swift package product is `PostieCLI` to avoid a case-insensitive filename collision with the app executable.

```sh
./dist/postie collections.list
./dist/postie requests.list --arguments '{"collectionID":"COLLECTION-UUID"}'
./dist/postie requests.start --arguments '{"collectionID":"COLLECTION-UUID","requestID":"REQUEST-UUID"}'
./dist/postie runs.get --arguments '{"runID":"RUN-UUID"}'
./dist/postie runs.cancel --arguments '{"runID":"RUN-UUID"}'
```

Use `--stdin` instead of `--arguments` when supplying sensitive values. Input is one JSON object, bounded to 1 MiB. The response is a JSON envelope containing its command ID and either a result or an error. A disconnected/timed-out command is not retried automatically because a mutation may already have been accepted.

The CLI uses a private same-user Unix socket. It intentionally bypasses MCP access and response-view policies and returns bounded resolved response previews without MCP redaction. Direct secret-variable reads remain unavailable. Do not share CLI output without inspecting it.

## MCP

Enable the MCP server in Settings → Automation. It defaults off and remembers its enabled state. The local port defaults to 49157 and can be changed. The listener binds only to `127.0.0.1`; authentication is mandatory. “Copy Codex configuration” copies the URL and bearer header, including the access token, for the user to install in their Codex configuration. Postie does not modify Codex files.

The bearer token is separate from the workspace encryption key and stored in a separate Keychain service ending `.mcp-access`, account `bearer-token-v1`. Enabling/configuring MCP may prompt for Keychain access.

MCP lists/creates/edits/starts requests; lists and cancels ongoing runs; lists variables and reads nonsecret values; and lists/reads/creates/renames/deletes snapshots. Command schemas reject unsupported mutation fields. MCP cannot change its own access settings or export encryption keys. Live verification covers list/start/get and cached-ID exclusion behavior; do not infer broader live acceptance from implementation or selected checks.

Collection selectors in MCP schemas use `collectionName`. Names are matched case-insensitively after trimming surrounding whitespace. Duplicate accessible names return a conflict; excluded collections do not participate in matching. Internal identities remain UUIDs. The dispatcher still accepts legacy `collectionID` selectors for CLI and cached clients, but rejects supplying both selectors.

`requests.list` accepts optional `collectionName` and `query` arguments:

```json
{"collectionName":"buildsight","query":"qbcc"}
```

The query matches a case-insensitive substring of the request name or URL template path, preserving sidebar order. Loaded edits are included, consistent with ordinary request listing; search does not wait for disk persistence. A missing or blank query lists all accessible requests in scope. Paths retain literal percent escapes and templates; hosts, query strings and fragments are excluded. Variables are never resolved for search. Collection/request exclusions apply before results are returned. Request, run and snapshot handles remain ID-based.

Discovery was user-accepted on 2026-10-22 after live name/path matching, ordering, error and compatibility checks. A fresh Codex session exposes the updated schemas. No request was sent or edited during discovery verification. Duplicate/exclusion edge cases for the new selectors were verified with synthetic tests.

Collection/request settings can exclude resources. Collection exclusion also blocks all children and snapshots. Excluded snapshots remain excluded when their source is deleted. Moving a request follows destination inheritance and access settings. Request templates and explicit overrides remain intact.

Response viewing defaults to **Block body; show safe metadata** globally. Collection/request settings inherit or override it:

- **Block body; show safe metadata** returns status, bounded typed metadata, parsed safe headers, observed redirect hops and sanitised Location, without bodies.
- **Show body with secrets redacted** returns bounded text previews and headers after replacing known frozen secrets. Missing decryption context withholds unsafe output. Re-templating covers known captured secrets and supported encodings; it cannot identify arbitrary new or transformed server secrets. This retains the saved `allow` policy's behavior.
- **Show response unredacted** explicitly permits actual response body content, headers and URLs, including redirects. Preview limits still apply. It does not enable direct secret-variable reads or override resource exclusions. The mode is saved as `unredacted`; existing settings do not opt into it automatically.

The three response modes and inherited redaction flow were user-verified on 2026-10-21. These settings apply to live results and saved snapshot response reads, and redirect metadata while a request is ongoing.

New snapshot redaction is not yet live-verified. Redaction follow-up, 2026-10-21: new runs freeze effective encrypted variables from request, collection and global scope, including unused variables, separately from request-referenced inputs. This data is retained only for redaction and is encrypted with a newly saved snapshot's existing context; it is not added to the outgoing request. Unavailable or over-limit capture withholds redacted output conservatively, while explicit unredacted mode remains raw. Capture is bounded to 128 secret attempts and 1 MiB of names/values. Older snapshots without this payload keep their recorded referenced-only redaction inputs; opening them does not read current secret values.

If Postie is closed, the CLI exits unsuccessfully with guidance to open Postie. Unsafe socket paths or permissions remain a separate error; commands are never retried automatically.

The transport is stateless Streamable HTTP: POST JSON-RPC with JSON or a request-local final-message SSE response. There are no sessions, replay streams or unsolicited updates; poll run handles for progress. No claim is made for unobserved interim HTTP responses or per-hop bodies/timings.

## Request edits and handles

Create/update accepts a `request` object with name, method, URL, query/path/header rows, body, syntax, request option overrides and authentication. Rows contain `name`, `value` and optional `isEnabled`. Authentication accepts kind, username, header name and newly supplied password/token/API-key values; credentials are encrypted before persistence. Omitted fields retain existing values. URL queries are parsed into the table; an explicitly supplied query array replaces those rows.

Body syntax accepts `none`, `json`, `html` and `xml`. Uploads use `bodyKind` (`text`, `rawFile`, `multipart`), `rawFile` (`path`, optional `filename`/`contentType`, or null to clear), and `multipartParts` (ordered `name`, `kind` text/file, `text` or `file`, optional `isEnabled`). Paths must be absolute local paths; configuration does not read the file. Sending reads the original, without a temporary copy. Missing or detectably changed sources fail explicitly. Multipart text values support variables; paths and file bytes are literal. The same fields apply to MCP and CLI. Response viewing and resource exclusions continue to apply.

```json
{"bodyEnabled":true,"bodyKind":"multipart","multipartParts":[{"name":"description","kind":"text","text":"{{description}}"},{"name":"document","kind":"file","file":{"path":"/absolute/path/document.pdf","contentType":"application/pdf"}}]}
```

Run IDs identify the exact preparation/execution attempt. A stale cancellation handle does not cancel a later run. Snapshot creation targets an exact completed run, never whichever newer result happens to be visible. Results are retained according to the app's existing latest-per-request lifecycle rather than an unbounded run history.
