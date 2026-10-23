import Foundation
import XCTest
@testable import PostieCore

final class KeyedSecretVaultTests: XCTestCase {
    func testRotationKeyCreationDoesNotChangeActiveDestination() async throws {
        let legacyKey = Data(repeating: 0x2a, count: 32)
        let keyStore = KeyedFakeApplicationKeyStore(legacyKey: legacyKey)
        let vault = SecretVault(keyStore: keyStore)
        let original = try await vault.encrypt("synthetic legacy secret")

        let rotationKeyID = try await vault.createRotationKey()
        let stillLegacy = try await vault.encrypt("another synthetic legacy secret")

        XCTAssertEqual(original.version, 1)
        XCTAssertNil(original.keyID)
        XCTAssertEqual(stillLegacy.version, 1)
        XCTAssertNil(stillLegacy.keyID)
        let exportedLegacyKey = try await vault.exportKey()
        XCTAssertEqual(exportedLegacyKey, legacyKey)
        XCTAssertNotNil(keyStore.loadKeyValue(id: rotationKeyID))

        await vault.configure(activeKeyID: rotationKeyID)
        let rotated = try await vault.encrypt("synthetic rotated secret")

        XCTAssertEqual(rotated.version, 2)
        XCTAssertEqual(rotated.keyID, rotationKeyID)
        let exportedRotationKey = try await vault.exportKey()
        XCTAssertEqual(exportedRotationKey, keyStore.loadKeyValue(id: rotationKeyID))
    }

    func testDecryptUsesEnvelopeKeyAfterActiveDestinationChanges() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstKey = Data(repeating: 0x2a, count: 32)
        let secondKey = Data(repeating: 0x5b, count: 32)
        let keyStore = KeyedFakeApplicationKeyStore(identifiedKeys: [firstID: firstKey, secondID: secondKey])
        let vault = SecretVault(keyStore: keyStore)
        await vault.configure(activeKeyID: firstID)
        let firstEnvelope = try await vault.encrypt("synthetic first key value")

        await vault.configure(activeKeyID: secondID)
        let secondEnvelope = try await vault.encrypt("synthetic second key value")
        let firstPlaintext = try await vault.decrypt(firstEnvelope)

        XCTAssertEqual(firstEnvelope.version, 2)
        XCTAssertEqual(firstEnvelope.keyID, firstID)
        XCTAssertEqual(secondEnvelope.keyID, secondID)
        XCTAssertEqual(firstPlaintext, "synthetic first key value")
        XCTAssertEqual(keyStore.identifiedLoadIDs, [firstID, secondID])
    }

    func testReencryptUsesActiveKeyAndAuthenticatesAlreadyTargetedEnvelope() async throws {
        let oldID = UUID()
        let activeID = UUID()
        let keyStore = KeyedFakeApplicationKeyStore(
            identifiedKeys: [
                oldID: Data(repeating: 0x2a, count: 32),
                activeID: Data(repeating: 0x5b, count: 32),
            ]
        )
        let vault = SecretVault(keyStore: keyStore)
        await vault.configure(activeKeyID: oldID)
        let oldEnvelope = try await vault.encrypt("synthetic value for re-encryption")

        await vault.configure(activeKeyID: activeID)
        let updatedEnvelope = try await vault.reencrypt(oldEnvelope)
        let unchangedEnvelope = try await vault.reencrypt(updatedEnvelope)
        let plaintext = try await vault.decrypt(updatedEnvelope)
        var combined = try XCTUnwrap(Data(base64Encoded: updatedEnvelope.combined))
        combined[12] ^= 1

        do {
            _ = try await vault.reencrypt(
                SecretEnvelope(version: 2, combined: combined.base64EncodedString(), keyID: activeID)
            )
            XCTFail("Re-encryption must authenticate even when the envelope already targets the active key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
        }

        XCTAssertEqual(updatedEnvelope.version, 2)
        XCTAssertEqual(updatedEnvelope.keyID, activeID)
        XCTAssertEqual(unchangedEnvelope, updatedEnvelope)
        XCTAssertEqual(plaintext, "synthetic value for re-encryption")
    }

    func testImportRequiresActiveKeyEnvelopesAndValidatesBeforeCreating() async throws {
        let firstID = UUID()
        let activeID = UUID()
        let firstKey = Data(repeating: 0x2a, count: 32)
        let activeKey = Data(repeating: 0x5b, count: 32)
        let sourceStore = KeyedFakeApplicationKeyStore(identifiedKeys: [firstID: firstKey, activeID: activeKey])
        let sourceVault = SecretVault(keyStore: sourceStore)
        await sourceVault.configure(activeKeyID: firstID)
        let firstEnvelope = try await sourceVault.encrypt("synthetic first-key data")
        await sourceVault.configure(activeKeyID: activeID)
        let activeEnvelope = try await sourceVault.encrypt("synthetic active-key data")

        let targetStore = KeyedFakeApplicationKeyStore()
        let targetVault = SecretVault(keyStore: targetStore)
        await targetVault.configure(activeKeyID: activeID)
        let result = try await targetVault.importKey(activeKey, validating: [activeEnvelope])
        let recovered = try await targetVault.decrypt(activeEnvelope)

        XCTAssertEqual(result, .imported)
        XCTAssertEqual(recovered, "synthetic active-key data")
        XCTAssertEqual(targetStore.identifiedCreateIDs, [activeID])
        XCTAssertNil(targetStore.loadKeyValue(id: firstID))

        let mismatchedStore = KeyedFakeApplicationKeyStore()
        let mismatchedVault = SecretVault(keyStore: mismatchedStore)
        await mismatchedVault.configure(activeKeyID: activeID)

        do {
            _ = try await mismatchedVault.importKey(activeKey, validating: [firstEnvelope, activeEnvelope])
            XCTFail("Import must reject ciphertext outside the configured active key identifier")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }

        XCTAssertTrue(mismatchedStore.identifiedCreateIDs.isEmpty)
        XCTAssertNil(mismatchedStore.loadKeyValue(id: activeID))

        let rejectedStore = KeyedFakeApplicationKeyStore()
        let rejectedVault = SecretVault(keyStore: rejectedStore)
        await rejectedVault.configure(activeKeyID: activeID)

        do {
            _ = try await rejectedVault.importKey(firstKey, validating: [activeEnvelope])
            XCTFail("A candidate that cannot open active-key data must be rejected before storage")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
        }

        XCTAssertTrue(rejectedStore.identifiedCreateIDs.isEmpty)
        XCTAssertNil(rejectedStore.loadKeyValue(id: activeID))

        let conflictStore = KeyedFakeApplicationKeyStore(identifiedKeys: [activeID: firstKey])
        let conflictVault = SecretVault(keyStore: conflictStore)
        await conflictVault.configure(activeKeyID: activeID)

        do {
            _ = try await conflictVault.importKey(activeKey, validating: [activeEnvelope])
            XCTFail("Import must not replace a different key stored for the active identifier")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }

        XCTAssertEqual(conflictStore.loadKeyValue(id: activeID), firstKey)
        XCTAssertTrue(conflictStore.identifiedCreateIDs.isEmpty)
    }

    func testKeyedExportRetainsCachedConflictCheck() async throws {
        let keyID = UUID()
        let originalKey = Data(repeating: 0x2a, count: 32)
        let replacementKey = Data(repeating: 0x5b, count: 32)
        let keyStore = KeyedFakeApplicationKeyStore(identifiedKeys: [keyID: originalKey])
        let vault = SecretVault(keyStore: keyStore)
        await vault.configure(activeKeyID: keyID)

        _ = try await vault.encrypt("synthetic cached key value")
        keyStore.replaceKey(replacementKey, id: keyID)

        do {
            _ = try await vault.exportKey()
            XCTFail("Export must reject a stored key that differs from the cached active key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }
    }

    func testLegacyOnlyStoreDoesNotFallBackForIdentifiedKey() async throws {
        let keyID = UUID()
        let store = LegacyOnlyApplicationKeyStore(key: Data(repeating: 0x2a, count: 32))
        let vault = SecretVault(keyStore: store, allowsKeyCreation: true)
        await vault.configure(activeKeyID: keyID)

        do {
            _ = try await vault.encrypt("synthetic identified value")
            XCTFail("An identified key lookup must not fall back to the legacy key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .unsupportedKeyIdentifier)
        }

        XCTAssertEqual(store.legacyLoadCount, 0)
        XCTAssertEqual(store.legacyCreateCount, 0)

        do {
            _ = try store.createKey(Data(repeating: 0x5b, count: 32), id: keyID)
            XCTFail("The default identified-key create method must be unsupported")
        } catch {
            XCTAssertEqual(error as? ApplicationKeyStoreError, .unsupportedKeyIdentifier)
        }

        XCTAssertEqual(store.legacyLoadCount, 0)
        XCTAssertEqual(store.legacyCreateCount, 0)
    }

    func testMissingActiveIdentifierIsNotAutomaticallyCreated() async throws {
        let keyID = UUID()
        let keyStore = KeyedFakeApplicationKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        await vault.configure(activeKeyID: keyID)

        do {
            _ = try await vault.encrypt("synthetic identified value")
            XCTFail("An absent active identifier must not silently create a replacement key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .missingKey)
        }

        XCTAssertTrue(keyStore.identifiedCreateIDs.isEmpty)
    }

    func testEnvelopeVersionsRequireTheirMatchingKeyIdentifierShape() async throws {
        let keyID = UUID()
        let keyStore = KeyedFakeApplicationKeyStore(legacyKey: Data(repeating: 0x2a, count: 32))
        let vault = SecretVault(keyStore: keyStore)
        let legacyEnvelope = try await vault.encrypt("synthetic legacy data")

        do {
            _ = try await vault.decrypt(
                SecretEnvelope(version: 1, combined: legacyEnvelope.combined, keyID: keyID)
            )
            XCTFail("Version 1 envelopes must not carry a key identifier")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .malformedEnvelope)
        }

        let oldEnvelopeJSON = Data(
            "{\"version\":1,\"combined\":\"\(legacyEnvelope.combined)\"}".utf8
        )
        let decodedLegacyEnvelope = try JSONDecoder().decode(SecretEnvelope.self, from: oldEnvelopeJSON)

        XCTAssertNil(decodedLegacyEnvelope.keyID)
        XCTAssertEqual(decodedLegacyEnvelope, legacyEnvelope)
    }

    func testKeychainStoreUsesCanonicalIdentifierAccountAndPreservesLegacyAccount() throws {
        let keyID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let legacyKey = Data(repeating: 0x2a, count: 32)
        let identifiedKey = Data(repeating: 0x5b, count: 32)
        let client = FakeKeychainItemClient(
            accounts: ["workspace-key-v1": legacyKey]
        )
        let keyStore = KeychainApplicationKeyStore(service: "synthetic-postie-test", client: client)

        let createdKey = try keyStore.createKey(identifiedKey, id: keyID)
        let duplicateCreateResult = try keyStore.createKey(Data(repeating: 0x7c, count: 32), id: keyID)
        let loadedKey = try keyStore.loadKey(id: keyID)
        let unchangedLegacyKey = try keyStore.loadKey()

        XCTAssertEqual(createdKey, identifiedKey)
        XCTAssertEqual(duplicateCreateResult, identifiedKey)
        XCTAssertEqual(loadedKey, identifiedKey)
        XCTAssertEqual(unchangedLegacyKey, legacyKey)
        XCTAssertEqual(
            Set(client.accountsForService("synthetic-postie-test")),
            Set(["workspace-key-v1", "workspace-key-00112233-4455-6677-8899-aabbccddeeff"])
        )
    }
}

private final class KeyedFakeApplicationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var legacyKey: Data?
    private var identifiedKeys: [UUID: Data]
    private var loadIDs: [UUID] = []
    private var createIDs: [UUID] = []

    init(legacyKey: Data? = nil, identifiedKeys: [UUID: Data] = [:]) {
        self.legacyKey = legacyKey
        self.identifiedKeys = identifiedKeys
    }

    var identifiedLoadIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return loadIDs
    }

    var identifiedCreateIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return createIDs
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return legacyKey
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let legacyKey {
            return legacyKey
        }
        legacyKey = proposedKey
        return proposedKey
    }

    func loadKey(id: UUID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loadIDs.append(id)
        return identifiedKeys[id]
    }

    func createKey(_ proposedKey: Data, id: UUID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        createIDs.append(id)
        if let existingKey = identifiedKeys[id] {
            return existingKey
        }
        identifiedKeys[id] = proposedKey
        return proposedKey
    }

    func loadKeyValue(id: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return identifiedKeys[id]
    }

    func replaceKey(_ key: Data, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        identifiedKeys[id] = key
    }
}

private final class LegacyOnlyApplicationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private let key: Data
    private var loads = 0
    private var creates = 0

    init(key: Data) {
        self.key = key
    }

    var legacyLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var legacyCreateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return creates
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        return key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        creates += 1
        return key
    }
}

private final class FakeKeychainItemClient: KeychainItemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var valuesByAccount: [String: Data]
    private let service: String?

    init(accounts: [String: Data], service: String? = nil) {
        valuesByAccount = accounts
        self.service = service
    }

    func load(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let expectedService = self.service, expectedService != service {
            return nil
        }
        return valuesByAccount[account]
    }

    func add(_ data: Data, service: String, account: String) throws -> KeychainAddResult {
        lock.lock()
        defer { lock.unlock() }
        if let expectedService = self.service, expectedService != service {
            return .duplicate
        }
        guard valuesByAccount[account] == nil else {
            return .duplicate
        }
        valuesByAccount[account] = data
        return .inserted
    }

    func accountsForService(_ service: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard self.service == nil || self.service == service else { return [] }
        return valuesByAccount.keys.sorted()
    }
}
