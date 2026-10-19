# Encryption

Updated 2026-10-19. User authorised the straightforward M3 at-rest design; implementation and verification are tracked in implementation-m3-m4.md. No existing-data migration is performed. Snapshot encryption is implemented locally; see snapshot-implementation.md for its versioned contract. See review.md for earlier design history.

## Purpose and limits

Keep marked secrets and captured snapshot inputs encrypted in local JSON, with one application encryption key in macOS Keychain. Allow the local user to reveal, edit and deliberately copy values. Protect against disclosure from configuration files alone; do not claim protection from a process with access to app memory/Keychain or a user deliberately revealing secrets.

Request templates, ordinary variables, literal headers/bodies, snapshot response data and metadata remain plaintext. A literal secret or a server-echoed secret can therefore remain readable. No automatic secret detection, response scrubbing, whole-file confidentiality, malicious-metadata protection or rollback prevention is promised. No encryption scheme can preserve frozen values while also making them track later credential changes.

## Mechanism

- Use CryptoKit AES-256-GCM with a randomly generated 256-bit symmetric key. No asymmetric keypair or custom cipher.
- Generate a fresh nonce through CryptoKit for each encryption. Persist its sealed-box representation (nonce, ciphertext and authentication tag) as Base64, never deriving a nonce from timestamps, IDs or values.
- Use a small versioned envelope containing sealed-box bytes; version 1 fixes the algorithm and single app-key lookup. Unknown formats are errors, with no plaintext fallback. A key registry or rotation framework is unnecessary initially.
- No owner/field additional-authentication binding is required for the initial at-rest scope. Renaming or duplicating records need not re-encrypt unchanged ciphertext. Copy encrypted values by value, never as mutable shared records. AES-GCM authenticates the encrypted payload; it does not authenticate its placement or the surrounding document.
- Serialize encrypted forms only. Decrypted values may exist in transient execution/editor state, never in generic persisted previews, diagnostic logs, temporary plaintext files or fallback saves.

## Live variables and authentication

Ordinary variables keep plaintext values. A marked-secret variable stores an envelope in the same globals/collection/request JSON that owns it. Authentication secret fields use encrypted envelopes; templates in those fields may also be encrypted. No keychain item is required for each secret.

Variable resolution still follows request > collection > global. Decrypt only the effective referenced values needed for preparation or explicit user access. Marking a value secret must encrypt before replacing its plaintext representation atomically; changing it back to ordinary is an explicit user action. Editing/deleting one value never rotates/deletes the application key.

The variable table uses a reversible Secret checkbox. Conversion succeeds before the model changes; failures retain the old value/type and show an error. Failed conversion alone does not block quitting because the original value remains intact. Explicit failed secret-value Save still retains its draft/error until retry or Cancel; leaving the scope discards that transient edit. Collection structured auth uses the same encrypted fields/key and conservative missing-key gate as request auth. Inactive or overridden credentials are not unlocked during execution.

## Snapshot captures

Retain send-time templates and an independent map of effective values for referenced variable names; encrypt the entire captured-input map, including ordinary referenced values and structured auth inputs, as one snapshot-owned payload. Live secret values and snapshot captures use the same encryption service, not mutable shared value references. Snapshot request literals/templates and the original response remain plaintext.

The retained exchange captures URL, ordered query/header and body templates, effective input values, preparation format version and response together at send time. Include separate query-editor entries, duplicate keys and empty values; do not assume all query data is in the URL template. Version 1 stores submitted and observed request transport plus redirect URLs inside the encrypted context, alongside captured inputs and auth. It opens this recorded transport without resolving historical templates against current scopes. No plaintext resolved request duplicate is written. A restored snapshot is view-only; no replay engine is required.

## Key lifecycle and failures

- One app-level key initially, found using stable, narrowly scoped service/account identifiers. Exact accessibility attributes, entitlements and signing setup must be validated in T-32 on macOS. iCloud Keychain synchronisation is not enabled in this scope.
- Current service is the bundle identifier plus `.workspace-encryption`, account `workspace-key-v1`; the SecItem implementation uses the default macOS generic-password Keychain access policy. The app has an ad-hoc signature. Rebuild continuity must be verified; do not infer it from fake-backed round trips or weaken ACLs to make it pass.
- Provision and verify the key in Keychain before writing dependent encrypted data. Serialize first-use creation; handle duplicate-item races by retrieving the existing item, not overwriting it.
- Distinguish a locked/denied/unavailable Keychain from an absent key. Never replace an inaccessible key. If ciphertext exists but the app key is missing, preserve records, report the failure and block operations requiring decryption. Never silently generate a replacement or erase ciphertext.
- Authentication/decryption errors preserve original encrypted data and block affected send/copy/save operations. Unaffected ordinary requests and search can remain usable. Decide precise read-only editor behaviour before implementation; unknown fields must not disappear during unrelated saves.
- Individual record/snapshot deletion removes its ciphertext only. There are no per-snapshot Keychain entries to clean up. App-key deletion/reset and key rotation are deferred; no automatic key deletion occurs when the last secret is removed.
- Losing the key makes encrypted values unrecoverable. Copying JSON alone is not a usable backup of secrets. The initial version has no key export/recovery flow; communicate this limitation before users rely on encrypted data. Preserve old keys if a future rotation is introduced. Cross-Mac sync/export is not implied.

## T-32 verification and implementation gate

Verify AES-GCM round trips, fresh ciphertext for repeated equal inputs, modified ciphertext/tag rejection, unknown envelope formats, missing/denied Keychain, first-run races, save failures and absence of plaintext duplicates in saved artifacts. Verify renaming/duplicating values preserves independent live/snapshot behaviour without context-dependent re-encryption. Test captured inputs survive live edits/deletion without consulting live state. Check built-app Keychain access survives the intended rebuild/update process.

Do not treat successful round-trip tests as proof of a security audit. The proposal does not authenticate owner identity, templates, responses or other plaintext metadata. Record-substitution resistance, rotation and stronger document integrity are deferred; they are not requirements for the agreed at-rest protection.

## Primary API references

Checked 2026-10-17: Apple's [AES.GCM documentation](https://developer.apple.com/documentation/cryptokit/aes/gcm) provides authenticated encryption and additional authenticated data. Apple's [Storing CryptoKit Keys in the Keychain](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain) describes storing symmetric key representations through Keychain Services. API availability does not verify this application's key lifecycle or build configuration.
