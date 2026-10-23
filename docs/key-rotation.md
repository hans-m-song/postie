# Workspace-key rotation — T119

Approved 2026-10-23. This is the first selected slice of the expanded backlog. Implemented locally; the user reported rotation working on 2026-10-23. No user workspace or Keychain item was modified by development tools.

Settings → Encryption Key → Rotate Key starts the operation after confirmation. It is unavailable during active/preparing requests or protected saves. The app pauses edits/automation, flushes accepted work, rotates, then reloads durable values. A failed pending migration blocks editing; quit and reopen to retry recovery. Missing keys or damaged storage are preserved rather than replaced. Import/export are unavailable during pending migration. Include `workspace-encryption.json` when copying/backing up a rotated workspace, then import the new exported key on the destination.

## Contract

Rotate every marked-secret variable, structured authentication secret, saved snapshot context and encrypted MCP token. Preserve plaintext configuration, snapshot response bodies and unknown JSON metadata. Old backups keep requiring their original key; rotation does not revoke previously exported keys or erase historical copies.

The legacy Keychain key is application-scoped and may serve several workspace roots. Never overwrite/delete it. New envelopes carry a key ID and use independent Keychain entries. A workspace-local metadata document selects its active key. Key import/export routes to that ID after completed rotation; legacy workspaces retain the existing behaviour.

## Recovery sequence

```text
quiesce → flush → authenticate inventory → create/read back new key
    → publish pending metadata → rewrite each owned ciphertext slot
    → authenticate full rescan → mark complete → reload → unlock editing
```

Each document replacement is atomic; the set of files is not one atomic transaction. Mixed old/new envelopes remain decryptable. Startup resumes a pending rotation before normal workspace/automation access. Missing/denied keys or damaged storage preserve data and block writes until recovery. Keys never appear in metadata, logs or temporary plaintext files.

Require no active/preparing runs and settle existing accepted mutations/autosaves/snapshot saves before inventory. Reject damaged, unsupported, ambiguous, staged or unindexed storage. New edits, snapshot saves and automation operations must be excluded while rotating. Reload durable state before releasing the barrier so old cached ciphertext cannot be saved back.

## Ownership and verification

Final local build: release app and strict signatures pass; `dist/Postie.app` refreshed without launch. The user subsequently reported rotation working. Final full suite includes the post-completion-error regression: a later unrelated save cannot restore old ciphertext after completed publication reports an error. Development verification used synthetic keys and checkpoint interruptions; no process-kill test was performed.

- Vault: keyed AES-GCM envelopes, immutable key creation, per-ID caching and manual transfer routing.
- Document transform: explicit schema paths only; never recursively detect envelopes in arbitrary body/response JSON.
- Coordinator: inventory, metadata, resumable replacements and final rescan.
- App: maintenance barrier, startup recovery, reload and explicit Settings action.

Tests must cover legacy/v2 round trips, all ciphertext owners, unknown-field preservation, unavailable/wrong keys, partial rewrites/restart recovery, stale state exclusion and manual transfer. Native Keychain behaviour and user acceptance remain separate from fake-backed tests.

Verification, 2026-10-23: 35 focused tests pass. Full regression suite: 492 cases, 490 passed, two pre-existing case-sensitive-filesystem skips, zero failures/warnings. Strict lint passes. Independent source review closed recovery-temp, maintenance-gate and snapshot-integrity findings; a blind test audit strengthened preservation/value assertions and transfer coverage. Synthetic checkpoints model interruption, not an actual killed native process. Logs: `/Volumes/Data/tmp/postie-key-rotation-{focused,full,lint}.log`. Release build and native/user verification are tracked in the handoff.

Apple documents Keychain item updates through [SecItemUpdate](https://developer.apple.com/documentation/security/secitemupdate(_:_:)); this design avoids replacing the legacy key because it is shared across roots. Crypto operations continue to use [CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm).
