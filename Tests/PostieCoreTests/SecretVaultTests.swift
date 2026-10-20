import Foundation
import XCTest
@testable import PostieCore

final class SecretVaultTests: XCTestCase {
    func testRoundTripUsesFreshCiphertextForEachEncryption() async throws {
        let keyStore = FakeApplicationKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)

        async let firstEncryption = vault.encrypt("synthetic secret")
        async let secondEncryption = vault.encrypt("synthetic secret")
        let (first, second) = try await (firstEncryption, secondEncryption)
        let firstPlaintext = try await vault.decrypt(first)
        let secondPlaintext = try await vault.decrypt(second)

        XCTAssertEqual(first.version, 1)
        XCTAssertNotEqual(first.combined, second.combined)
        XCTAssertEqual(keyStore.createCount, 1)
        XCTAssertEqual(firstPlaintext, "synthetic secret")
        XCTAssertEqual(secondPlaintext, "synthetic secret")
    }

    func testImportedKeyOpensExistingEnvelopeAndRepeatedImportIsIdempotent() async throws {
        let key = Data(repeating: 0x2a, count: 32)
        let sourceVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: key))
        let envelope = try await sourceVault.encrypt("synthetic imported secret")
        let originalEnvelope = envelope
        let exportedKey = try await sourceVault.exportKey()

        let targetKeyStore = FakeApplicationKeyStore()
        let targetVault = SecretVault(keyStore: targetKeyStore)
        let firstImport = try await targetVault.importKey(exportedKey, validating: [envelope])
        let firstDecryption = try await targetVault.decrypt(envelope)
        let secondImport = try await targetVault.importKey(exportedKey, validating: [envelope])

        XCTAssertEqual(exportedKey, key)
        XCTAssertEqual(firstImport, .imported)
        XCTAssertEqual(secondImport, .alreadyPresent)
        XCTAssertEqual(firstDecryption, "synthetic imported secret")
        XCTAssertEqual(envelope, originalEnvelope)
        XCTAssertEqual(targetKeyStore.createCount, 1)
    }

    func testImportRejectsWrongCandidateBeforeWriting() async throws {
        let sourceVault = SecretVault(
            keyStore: FakeApplicationKeyStore(existingKey: Data(repeating: 0x2a, count: 32))
        )
        let envelope = try await sourceVault.encrypt("synthetic secret")
        let targetKeyStore = FakeApplicationKeyStore()
        let targetVault = SecretVault(keyStore: targetKeyStore)
        let wrongKey = Data(repeating: 0x5b, count: 32)

        do {
            _ = try await targetVault.importKey(Data([0x2a]), validating: [envelope])
            XCTFail("An imported key must contain exactly 32 bytes")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .invalidKeyLength)
        }

        do {
            _ = try await targetVault.importKey(wrongKey, validating: [envelope])
            XCTFail("An unrelated key must not be imported")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
        }

        XCTAssertEqual(targetKeyStore.createCount, 0)

        do {
            _ = try await targetVault.exportKey()
            XCTFail("A rejected import must leave the key store empty")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .missingKey)
        }
    }

    func testImportRejectsDifferentExistingKeyAndPreservesCachedKey() async throws {
        let existingKey = Data(repeating: 0x2a, count: 32)
        let candidateKey = Data(repeating: 0x5b, count: 32)
        let existingVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: existingKey))
        let candidateVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: candidateKey))
        let existingEnvelope = try await existingVault.encrypt("existing synthetic secret")
        let candidateEnvelope = try await candidateVault.encrypt("candidate synthetic secret")
        let existingKeyStore = FakeApplicationKeyStore(existingKey: existingKey)
        let vault = SecretVault(keyStore: existingKeyStore)

        _ = try await vault.decrypt(existingEnvelope)

        do {
            _ = try await vault.importKey(candidateKey, validating: [candidateEnvelope])
            XCTFail("A different stored key must be preserved")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }

        let idempotentImport = try await vault.importKey(existingKey, validating: [existingEnvelope])
        existingKeyStore.replaceStoredKey(nil)

        do {
            _ = try await vault.importKey(candidateKey, validating: [candidateEnvelope])
            XCTFail("A different key must not replace the cached key after external deletion")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }

        let plaintext = try await vault.decrypt(existingEnvelope)

        XCTAssertEqual(existingKeyStore.createCount, 0)
        XCTAssertEqual(plaintext, "existing synthetic secret")
        XCTAssertEqual(idempotentImport, .alreadyPresent)
    }

    func testExportNeverCreatesMissingKeyWhenCreationIsDisabled() async throws {
        let missingKeyStore = FakeApplicationKeyStore()
        let missingKeyVault = SecretVault(keyStore: missingKeyStore)

        do {
            _ = try await missingKeyVault.exportKey()
            XCTFail("Export must not create a missing key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .missingKey)
        }

        XCTAssertEqual(missingKeyStore.createCount, 0)

        let existingKey = Data(repeating: 0x2a, count: 32)
        let existingKeyStore = FakeApplicationKeyStore(existingKey: existingKey)
        let existingKeyVault = SecretVault(keyStore: existingKeyStore)
        let exportedKey = try await existingKeyVault.exportKey()

        XCTAssertEqual(exportedKey, existingKey)
        XCTAssertEqual(existingKeyStore.createCount, 0)

        let envelopeSource = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: existingKey))
        let envelope = try await envelopeSource.encrypt("synthetic cached secret")
        _ = try await existingKeyVault.decrypt(envelope)
        existingKeyStore.replaceStoredKey(Data(repeating: 0x5b, count: 32))

        do {
            _ = try await existingKeyVault.exportKey()
            XCTFail("Export must reject a stored key that differs from the cached key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }
    }

    func testImportDuplicateRaceDoesNotCacheCandidateKey() async throws {
        let candidateKey = Data(repeating: 0x2a, count: 32)
        let racedKey = Data(repeating: 0x5b, count: 32)
        let candidateVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: candidateKey))
        let racedVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: racedKey))
        let candidateEnvelope = try await candidateVault.encrypt("candidate synthetic secret")
        let racedEnvelope = try await racedVault.encrypt("raced synthetic secret")
        let keyStore = FakeApplicationKeyStore(createResult: racedKey)
        let vault = SecretVault(keyStore: keyStore)

        do {
            _ = try await vault.importKey(candidateKey, validating: [candidateEnvelope])
            XCTFail("A duplicate race that finds a different key must be rejected")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyConflict)
        }

        let plaintext = try await vault.decrypt(racedEnvelope)

        XCTAssertEqual(keyStore.createCount, 1)
        XCTAssertEqual(plaintext, "raced synthetic secret")
    }

    func testTamperedAndUnknownEnvelopesAreRejected() async throws {
        let vault = SecretVault(keyStore: FakeApplicationKeyStore(), allowsKeyCreation: true)
        let envelope = try await vault.encrypt("synthetic secret")
        var combined = try XCTUnwrap(Data(base64Encoded: envelope.combined))
        combined[12] ^= 1

        do {
            _ = try await vault.decrypt(SecretEnvelope(combined: combined.base64EncodedString()))
            XCTFail("Tampered ciphertext must be rejected")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
        }

        do {
            _ = try await vault.decrypt(SecretEnvelope(combined: "not-base64"))
            XCTFail("Malformed ciphertext must be rejected")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .malformedEnvelope)
        }

        do {
            _ = try await vault.decrypt(SecretEnvelope(version: 2, combined: envelope.combined))
            XCTFail("Unknown envelope versions must be rejected")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .unsupportedEnvelopeVersion)
        }

        let wrongKeyLengthVault = SecretVault(keyStore: FakeApplicationKeyStore(existingKey: Data([1])))
        do {
            _ = try await wrongKeyLengthVault.decrypt(envelope)
            XCTFail("A wrong-length key must be rejected")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .invalidKeyLength)
        }
    }

    func testMissingKeyAndDeniedCreationNeverCreateDuringDecrypt() async throws {
        let sourceVault = SecretVault(keyStore: FakeApplicationKeyStore(), allowsKeyCreation: true)
        let envelope = try await sourceVault.encrypt("synthetic secret")
        let missingKeyStore = FakeApplicationKeyStore()
        let vault = SecretVault(keyStore: missingKeyStore)

        do {
            _ = try await vault.decrypt(SecretEnvelope(combined: "not-base64"))
            XCTFail("Malformed envelopes must be rejected before key lookup")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .malformedEnvelope)
        }

        do {
            _ = try await vault.decrypt(SecretEnvelope(version: 2, combined: "not-base64"))
            XCTFail("Unsupported versions must be rejected before key lookup")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .unsupportedEnvelopeVersion)
        }

        do {
            _ = try await vault.decrypt(envelope)
            XCTFail("Decryption must not create a missing key")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .missingKey)
        }

        do {
            _ = try await vault.encrypt("another synthetic secret")
            XCTFail("Key creation must be denied by default")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
        }

        XCTAssertEqual(missingKeyStore.createCount, 0)
    }

    func testKeychainStoreReturnsExistingKeyAfterDuplicateAdd() throws {
        let existingKey = Data(repeating: 0x2a, count: 32)
        let proposedKey = Data(repeating: 0x5b, count: 32)
        let client = FakeKeychainItemClient(existingKey: existingKey)
        let keyStore = KeychainApplicationKeyStore(service: "synthetic-postie-test", client: client)

        let returnedKey = try keyStore.createKey(proposedKey)

        XCTAssertEqual(returnedKey, existingKey)
        XCTAssertEqual(client.loadCount, 1)
    }
}

private final class FakeApplicationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var storedCreateCount = 0
    private let createResult: Data?

    init(existingKey: Data? = nil, createResult: Data? = nil) {
        storedKey = existingKey
        self.createResult = createResult
    }

    var createCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateCount
    }

    func replaceStoredKey(_ key: Data?) {
        lock.lock()
        defer { lock.unlock() }
        storedKey = key
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedKey
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        storedCreateCount += 1
        if let createResult {
            storedKey = createResult
            return createResult
        }
        if let storedKey {
            return storedKey
        }
        storedKey = proposedKey
        return proposedKey
    }
}

private final class FakeKeychainItemClient: KeychainItemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var storedLoadCount = 0

    init(existingKey: Data?) {
        storedKey = existingKey
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    func load(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        return storedKey
    }

    func add(_ data: Data, service: String, account: String) throws -> KeychainAddResult {
        lock.lock()
        defer { lock.unlock() }
        guard storedKey == nil else {
            return .duplicate
        }
        storedKey = data
        return .inserted
    }
}
