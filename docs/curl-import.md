# Paste cURL request import

Recorded 2026-10-17. User requested cURL paste/import as an exception to deferring general configuration import/export. Documentation only; no parser exists.

## Interaction

An explicit Paste cURL action opens a text input. Parse one command into an in-memory draft and preview method, URL/query, headers, body, auth and redirect behaviour. Let the user edit/name it and choose a collection before saving. Importing never executes curl, invokes a shell, reads local files or sends the request. Do not persist the original pasted command or include it in diagnostic logs.

## Proposed initial subset

- One `curl` command with one HTTP/HTTPS URL, positional or `--url`.
- POSIX-style single/double quotes, supported backslash escapes and line continuations. No shell evaluation or expansion; report unsupported quote dialects explicitly.
- Explicit method through `--request`/`-X`, HEAD through `--head`/`-I`, and documented GET/POST inference for supported data options. Reject ambiguous combinations until their semantics are implemented.
- Ordered/repeated headers through `--header`/`-H`.
- Inline text body through `--data`/`-d`, `--data-raw`, `--data-binary`, and `--json`. Preserve their distinct method, body-combination and default Content-Type/Accept semantics; do not assume all JSON-looking text implies JSON headers. `--data-raw` treats a leading @ literally; other file-reading forms are unsupported.
- Basic credentials through `--user`/`-u` without interactive password prompts. Unambiguous Basic/Bearer Authorization headers can map to structured auth; conflicting auth definitions must be surfaced, never silently combined.
- Follow redirects through `--location`/`-L`. App redirect-hop and cross-origin policies still apply.

This is a bounded importer, not full curl compatibility. Unknown options and unsupported combinations must be shown before creating a request, never silently discarded. File/stdin operands, multipart uploads, config files, command substitutions, executable shell operators, environment expansion and multiple transfers remain unsupported. Literal shell-looking characters inside properly quoted data are not commands. Pasted `$TOKEN` is not automatically converted into a Postie variable.

Final supported flag forms, repeated-option precedence and handling of browser-added transport/output flags must be frozen with fixtures before T-35. Support short curl aliases in imported text even though agent-run commands use full option names. Avoid promising every browser's Copy as cURL dialect initially.

## Secrets and persistence

Import preview may reveal values to the local user. Structured auth is encrypted before normal persistence using the app Keychain-held key. Ordinary literal headers/bodies retain the existing plaintext policy; users can replace literals with secret variables. Keychain failure must not result in plaintext fallback saves or autosaved original command text.

## T-35 acceptance

- Import representative GET, POST JSON, repeated-header/query and Basic/Bearer examples with quoted strings, escapes and multiline input.
- Preserve request intent, byte-sensitive body content, default headers, method inference and redirect selection for supported options.
- Reject malformed quotes, missing operands, unsupported flags/file references and multi-command/multi-transfer input without side effects.
- Verify quoted shell-looking literals remain data while actual shell expansion/operators are not executed or silently evaluated.
- Verify preview/edit/save and collection choice do not send; structured secrets persist encrypted; source command text is not separately saved.
- Round-trip the app's supported Copy as cURL output through import and compare prepared request intent. This does not promise byte-identical transport or arbitrary curl compatibility.

## Reference

Checked 2026-10-17 against the official [curl manual](https://curl.se/docs/manpage.html), including data-option, JSON-header and method semantics. This is the behavioural reference for supported options, not authorisation to execute pasted commands.
