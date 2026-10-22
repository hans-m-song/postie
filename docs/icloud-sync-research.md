# Native iCloud sync research

Checked 2026-10-20. Planning evidence only: no sync implementation, Apple account access, runtime configuration or Keychain inspection.

## Native choices

| Approach | Fit for Postie |
|---|---|
| CloudKit private database with CKSyncEngine | Recommended candidate: retain app-owned local JSON persistence, map stable identities to cloud records, use assets for snapshot bodies. |
| iCloud Documents/Drive | Native file syncing, but requires coordinated file access, download-state handling and conflict resolution. Moving the current multi-file workspace is not sufficient. |
| Core Data/SwiftData CloudKit integration | Higher-level persistence alternatives, but adopting them would change Postie's existing storage rather than add sync around it. No migration proposed. |

Apple recommends CKSyncEngine when bringing your own local persistence, and describes its use in Freeform. Its scheduler handles when transfers occur; app code still supplies records, stores incoming changes and handles application-specific decisions. This supports the recommendation, not a claim that merging/conflicts are automatic. [Apple WWDC23: Sync to iCloud with CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/).

The CKSyncEngine overview requires CloudKit and Remote notifications entitlements and persistence of its opaque serialized state across launches. That state belongs to the local sync machinery, not the user-data payload to mirror between Macs. [Apple CKSyncEngine overview](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9?language=objc).

iCloud document APIs use NSFileCoordinator/NSFilePresenter and file-version conflict handling. Postie currently has multi-file create/delete operations and a local process lock; that lock cannot serialise writers on different Macs. This is why direct relocation of the active directory is not the recommended starting design. [Apple: Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html); local source: Sources/PostieCore/CollectionStore.swift.

First-party examples show both patterns: Bear documents CloudKit-backed sync troubleshooting, while OmniOutliner supports document syncing through iCloud Drive. These are examples, not evidence of parity with Postie's data model. [Bear](https://bear.app/faq/sync-troubleshooting/), [OmniOutliner](https://support.omnigroup.com/documentation/omnioutliner/universal/6.3.1/en/connect/).

## Encryption key

Apple supports synchronizable Keychain items through kSecAttrSynchronizable. The default false/omitted setting does not return synchronizable items; query/update/migration design must account for that. Synchronizable macOS items use access-group rather than traditional SecAccess ACL behaviour, and ThisDeviceOnly accessibility settings are incompatible. [Apple Security: kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable).

Current source SystemKeychainItemClient uses generic-password service/account lookups without kSecAttrSynchronizable. Existing encryption envelopes and snapshots depend on that existing key. Proposed migration must preserve it, never place a plaintext key in the synced folder, and validate existing encrypted data before changing the active key source. Do not overwrite a synchronised key when a second Mac already has a different local key. Safe adoption/re-encryption or explicit separate-workspace handling remains a design decision. Source: Sources/PostieCore/SecretVault.swift; SnapshotStore.swift.

Cloud data and Keychain sync are separate mechanisms; do not assume arrival order. The proposed new-device state waits for a matching key, retaining ciphertext rather than generating a replacement. First-device bootstrap, simultaneous offline bootstrap, missing/denied keys and account changes require explicit tests. These are engineering requirements inferred from the existing single-key encryption contract, not an Apple-provided transaction guarantee.

## Provisioning prerequisite

Apple's supported macOS capability table lists CloudKit for Apple Developer Program/Developer ID provisioning, not the free Apple Developer column. The public page's text extraction omits checkmarks; the retrieved HTML CloudKit row has check icons in the first two capability columns and an empty third column. A properly provisioned, consistently signed build is a prerequisite; the current ad-hoc bundle is not live CloudKit validation. No App Store release is implied. [Apple: Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos), [Create an iCloud container](https://developer.apple.com/help/account/identifiers/create-an-icloud-container).

## Selected data and remaining gates

User wants essentially all durable config-folder data: global execution settings/variables, collections/requests/shared headers/auth, encrypted values and saved snapshots including full body sidecars. Exclude implementation locks, abandoned staging, active-run temporary files and local sync state. Appearance/layout preferences currently live separately in UserDefaults; their synchronisation has not been requested explicitly. Future local MCP listener enablement/token should remain device-specific unless separately approved.

Before code: approve backend/provisioning path; define conflicts and deletion tombstones; define existing-key adoption/new-Mac onboarding; define account-switch isolation and opt-out behaviour; validate large snapshot transfers and quota handling. A May 2026 accepted Apple Frameworks Engineer answer states that native CKAsset supports up to 50 GB per asset subject to remaining iCloud storage, with CKError.quotaExceeded handling required. This is current staff forum guidance rather than a limit specified in the public class reference. It supports using assets for Postie's potential 1 GiB responses without speculative chunking, subject to real multi-Mac verification. Do not apply the archived Web Services 50 MB limit to native CKAsset or promise unlimited body syncing. [Apple staff answer](https://developer.apple.com/forums/thread/827897), [Apple CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset), [archived Web Services limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html).

Next sequence: T99 sync ahead of T96 ordering, T97 MCP and T98 CLI. Real multi-Mac/iCloud/Keychain acceptance is required; local mocks cannot establish cloud delivery or signing continuity.
