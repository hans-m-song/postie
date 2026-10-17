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

    init(existingKey: Data? = nil) {
        storedKey = existingKey
    }

    var createCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateCount
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
