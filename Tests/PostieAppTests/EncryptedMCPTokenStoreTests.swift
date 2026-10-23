import Darwin
import Foundation
import XCTest
@testable import PostieApp
import PostieCore

final class EncryptedMCPTokenStoreTests: XCTestCase {
    func testAbsentFileDoesNotReadEitherKeyStore() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKeyStore = TestKeyStore(existingKey: nil)
        let vaultKeyStore = TestKeyStore(existingKey: nil)
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: vaultKeyStore),
            legacyKeyStore: legacyKeyStore
        )

        let envelope = try await store.storedEnvelope()

        XCTAssertNil(envelope)
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(vaultKeyStore.loadCount, 0)
        XCTAssertEqual(vaultKeyStore.createCount, 0)
    }

    func testMigratesLegacyTokenAndPersistsOnlyEncryptedData() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKey = Data(repeating: 0x4D, count: 32)
        let vaultKey = Data(repeating: 0xB6, count: 32)
        let legacyKeyStore = TestKeyStore(existingKey: legacyKey)
        let vaultKeyStore = TestKeyStore(existingKey: vaultKey)
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: vaultKeyStore, allowsKeyCreation: true),
            legacyKeyStore: legacyKeyStore
        )

        let token = try await store.token()
        let storedEnvelope = try await store.storedEnvelope()
        let envelope = try XCTUnwrap(storedEnvelope)
        let persistedData = try Data(contentsOf: root.appendingPathComponent("automation.json"))
        let persistedText = try XCTUnwrap(String(data: persistedData, encoding: .utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("automation.json").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(token, legacyKey.base64EncodedString())
        XCTAssertNotEqual(envelope.combined, token)
        XCTAssertFalse(persistedText.contains(token))
        XCTAssertEqual(permissions.intValue, 0o600)
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
        XCTAssertEqual(vaultKeyStore.createCount, 0)

        let restartedStore = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: vaultKey)),
            legacyKeyStore: legacyKeyStore
        )
        let restartedToken = try await restartedStore.token()

        XCTAssertEqual(restartedToken, token)
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testSubsequentCallReloadsAndRejectsCorruptFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x3D, count: 32))
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x6E, count: 32))),
            legacyKeyStore: legacyKeyStore
        )

        _ = try await store.token()
        try writePrivate(Data("{".utf8), rootURL: root)

        do {
            _ = try await store.token()
            XCTFail("A subsequent call must reload the authoritative file.")
        } catch {}
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testGeneratesTokenWhenLegacyCredentialIsAbsentWithoutCreatingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKeyStore = TestKeyStore(existingKey: nil)
        let vaultKeyStore = TestKeyStore(existingKey: nil)
        let vault = SecretVault(keyStore: vaultKeyStore, allowsKeyCreation: true)
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: vault,
            legacyKeyStore: legacyKeyStore
        )

        let token = try await store.token()
        let decodedToken = try XCTUnwrap(Data(base64Encoded: token))
        let storedEnvelope = try await store.storedEnvelope()
        let envelope = try XCTUnwrap(storedEnvelope)
        let decryptedToken = try await vault.decrypt(envelope)

        XCTAssertEqual(decodedToken.count, 32)
        XCTAssertEqual(decryptedToken, token)
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
        XCTAssertEqual(vaultKeyStore.createCount, 1)
    }

    func testStoredFileIsAuthoritativeWhenVaultKeyIsMissing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultKey = Data(repeating: 0x39, count: 32)
        let writer = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: vaultKey), allowsKeyCreation: true),
            legacyKeyStore: TestKeyStore(existingKey: Data(repeating: 0x21, count: 32))
        )
        _ = try await writer.token()

        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x21, count: 32))
        let vaultKeyStore = TestKeyStore(existingKey: nil)
        let reader = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: vaultKeyStore),
            legacyKeyStore: legacyKeyStore
        )
        let envelope = try await reader.storedEnvelope()

        XCTAssertNotNil(envelope)
        XCTAssertEqual(vaultKeyStore.loadCount, 0)
        XCTAssertEqual(vaultKeyStore.createCount, 0)
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        do {
            _ = try await reader.token()
            XCTFail("An encrypted file without its key must fail closed.")
        } catch let error as SecretVaultError {
            XCTAssertEqual(error, .missingKey)
        }
        XCTAssertEqual(vaultKeyStore.loadCount, 1)
        XCTAssertEqual(vaultKeyStore.createCount, 0)
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testStoredFileIsAuthoritativeWhenVaultKeyIsWrong() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x51, count: 32))),
            legacyKeyStore: TestKeyStore(existingKey: Data(repeating: 0x71, count: 32))
        )
        _ = try await writer.token()

        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x71, count: 32))
        let reader = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x52, count: 32))),
            legacyKeyStore: legacyKeyStore
        )

        do {
            _ = try await reader.token()
            XCTFail("A ciphertext authentication failure must not rotate to the legacy token.")
        } catch let error as SecretVaultError {
            XCTAssertEqual(error, .authenticationFailed)
        }
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testDecryptedNonCanonicalTokenIsRejectedWithoutLegacyFallback() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x67, count: 32)))
        let invalidEnvelope = try await vault.encrypt("not-a-32-byte-base64-token")
        let document = TokenFileFixture(formatVersion: 1, token: invalidEnvelope)
        try writePrivate(try JSONEncoder().encode(document), rootURL: root)
        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x17, count: 32))
        let store = EncryptedMCPTokenStore(rootURL: root, vault: vault, legacyKeyStore: legacyKeyStore)

        do {
            _ = try await store.token()
            XCTFail("Decrypted token plaintext must be canonical Base64 for exactly 32 bytes.")
        } catch {}
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testMalformedAndUnsupportedFilesFailWithoutLegacyFallback() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x63, count: 32))
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x24, count: 32))),
            legacyKeyStore: legacyKeyStore
        )

        try writePrivate(Data("{".utf8), rootURL: root)
        do {
            _ = try await store.storedEnvelope()
            XCTFail("Malformed JSON must be rejected.")
        } catch {}
        do {
            _ = try await store.token()
            XCTFail("Malformed JSON must not fall back to the legacy token.")
        } catch {}

        let unsupportedDocument = TokenFileFixture(
            formatVersion: 2,
            token: SecretEnvelope(combined: Data(repeating: 0xA3, count: 32).base64EncodedString())
        )
        try writePrivate(try JSONEncoder().encode(unsupportedDocument), rootURL: root)
        do {
            _ = try await store.storedEnvelope()
            XCTFail("Unsupported file versions must be rejected.")
        } catch {}
        do {
            _ = try await store.token()
            XCTFail("Unsupported file versions must not fall back to the legacy token.")
        } catch {}

        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testSymlinkAndOversizedFileAreRejected() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let target = container.appendingPathComponent("target.json")
        let vault = SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x44, count: 32)))
        let targetToken = Data(repeating: 0x33, count: 32).base64EncodedString()
        let targetEnvelope = try await vault.encrypt(targetToken)
        let decryptedTargetToken = try await vault.decrypt(targetEnvelope)
        XCTAssertEqual(decryptedTargetToken, targetToken)
        let targetData = try JSONEncoder().encode(TokenFileFixture(formatVersion: 1, token: targetEnvelope))
        try writePrivate(targetData, at: target)
        let originalTargetData = try Data(contentsOf: target)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let targetPermissions = try XCTUnwrap(targetAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(targetPermissions.intValue, 0o600)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("automation.json"),
            withDestinationURL: target
        )
        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x32, count: 32))
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: vault,
            legacyKeyStore: legacyKeyStore
        )

        do {
            _ = try await store.token()
            XCTFail("Symlinks must not be followed.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), originalTargetData)

        try FileManager.default.removeItem(at: root.appendingPathComponent("automation.json"))
        var oversizedData = targetData
        oversizedData.append(contentsOf: [UInt8](repeating: 0x20, count: 4097 - targetData.count))
        let canonicalFile = root.appendingPathComponent("automation.json")
        try writePrivate(oversizedData, at: canonicalFile)
        do {
            _ = try await store.token()
            XCTFail("Files larger than 4 KiB must be rejected.")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: canonicalFile), oversizedData)

        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testFIFOIsRejectedWithoutBlocking() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("automation.json").path
        let result = path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0)

        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x2A, count: 32))
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x2B, count: 32))),
            legacyKeyStore: legacyKeyStore
        )

        do {
            _ = try await store.token()
            XCTFail("A FIFO at the canonical path must be rejected.")
        } catch {}
        XCTAssertEqual(legacyKeyStore.loadCount, 0)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testSymlinkRootIsResolvedBeforeFileAccess() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let realRoot = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let linkedRoot = container.appendingPathComponent("linked-workspace", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let store = EncryptedMCPTokenStore(
            rootURL: linkedRoot,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x5B, count: 32))),
            legacyKeyStore: TestKeyStore(existingKey: Data(repeating: 0x1D, count: 32))
        )

        _ = try await store.token()

        XCTAssertTrue(FileManager.default.fileExists(atPath: realRoot.appendingPathComponent("automation.json").path))
    }

    func testPublicationFailureCanBeRetried() async throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let legacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x48, count: 32))
        let vaultKeyStore = TestKeyStore(existingKey: Data(repeating: 0x18, count: 32))
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: vaultKeyStore, allowsKeyCreation: true),
            legacyKeyStore: legacyKeyStore
        )

        do {
            _ = try await store.token()
            XCTFail("A read-only directory must reject publication.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("automation.json").path))
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let token = try await store.token()

        XCTAssertEqual(token, Data(repeating: 0x48, count: 32).base64EncodedString())
        XCTAssertEqual(legacyKeyStore.loadCount, 2)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testConcurrentTokenCallsReturnSamePersistedToken() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyKey = Data(repeating: 0x5C, count: 32)
        let legacyKeyStore = TestKeyStore(existingKey: legacyKey)
        let store = EncryptedMCPTokenStore(
            rootURL: root,
            vault: SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x7D, count: 32))),
            legacyKeyStore: legacyKeyStore
        )

        async let firstWaiter = store.token()
        async let secondWaiter = store.token()
        let (firstResult, secondResult) = try await (firstWaiter, secondWaiter)

        XCTAssertEqual(firstResult, legacyKey.base64EncodedString())
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(legacyKeyStore.loadCount, 1)
        XCTAssertEqual(legacyKeyStore.createCount, 0)
    }

    func testConcurrentInstancesUseTheWinningPublishedEnvelope() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = SecretVault(keyStore: TestKeyStore(existingKey: Data(repeating: 0x68, count: 32)))
        let firstLegacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x19, count: 32))
        let secondLegacyKeyStore = TestKeyStore(existingKey: Data(repeating: 0x29, count: 32))
        let firstStore = EncryptedMCPTokenStore(
            rootURL: root,
            vault: vault,
            legacyKeyStore: firstLegacyKeyStore
        )
        let secondStore = EncryptedMCPTokenStore(
            rootURL: root,
            vault: vault,
            legacyKeyStore: secondLegacyKeyStore
        )

        async let firstToken = firstStore.token()
        async let secondToken = secondStore.token()
        let (firstResult, secondResult) = try await (firstToken, secondToken)
        let storedEnvelope = try await firstStore.storedEnvelope()
        let persistedEnvelope = try XCTUnwrap(storedEnvelope)
        let persistedToken = try await vault.decrypt(persistedEnvelope)

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult, persistedToken)
        XCTAssertEqual(firstLegacyKeyStore.createCount, 0)
        XCTAssertEqual(secondLegacyKeyStore.createCount, 0)
    }
}

private struct TokenFileFixture: Encodable {
    let formatVersion: Int
    let token: SecretEnvelope
}

private final class TestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var loads = 0
    private var creates = 0

    init(existingKey: Data?) {
        key = existingKey
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var createCount: Int {
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
        if let key { return key }
        key = proposedKey
        return proposedKey
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("postie-encrypted-token-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func writePrivate(_ data: Data, rootURL: URL) throws {
    try writePrivate(data, at: rootURL.appendingPathComponent("automation.json"))
}

private func writePrivate(_ data: Data, at url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
