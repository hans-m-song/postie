import Foundation
import XCTest
@testable import PostieCore
@testable import PostieApp

@MainActor
final class KeyTransferTests: XCTestCase {
    func testKeyFilesAcceptRawAndBase64AndSavePrivatelyWithoutOverwrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x4c, count: 32)
        let rawURL = root.appendingPathComponent("raw.key")
        let base64URL = root.appendingPathComponent("base64.key")
        try key.write(to: rawURL)
        try Data((key.base64EncodedString() + "\n").utf8).write(to: base64URL)

        XCTAssertEqual(try EncryptionKeyFile.read(at: rawURL), key)
        XCTAssertEqual(try EncryptionKeyFile.read(at: base64URL), key)
        XCTAssertEqual(try EncryptionKeyFile.decodeBase64(key.base64EncodedString()), key)

        let outputURL = root.appendingPathComponent("exported.key")
        let exported = Data(key.base64EncodedString().utf8)
        try EncryptionKeyFile.writePrivate(exported, to: outputURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: outputURL), exported)
        XCTAssertThrowsError(try EncryptionKeyFile.writePrivate(Data("replacement".utf8), to: outputURL))
        XCTAssertEqual(try Data(contentsOf: outputURL), exported)

        let oversizedURL = root.appendingPathComponent("oversized.key")
        try Data(repeating: 0x41, count: 4097).write(to: oversizedURL)
        XCTAssertThrowsError(try EncryptionKeyFile.read(at: oversizedURL))
    }

    func testImportValidatesAndOpensAnActuallySavedSnapshot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x2a, count: 32)
        let snapshotID = try await createWorkspaceWithSnapshot(root: root, workspaceKey: key)
        let keyStore = TransferTestKeyStore()
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.canEditVariables(.global) }

        model.selectSnapshot(snapshotID)
        try await waitUntil { model.openedSnapshots[snapshotID] != nil }
        let beforeImport = try XCTUnwrap(model.openedSnapshots[snapshotID])
        XCTAssertNil(beforeImport.context)
        XCTAssertTrue(beforeImport.contextError?.contains("encryption key is missing") == true)

        let result = try await model.importEncryptionKey(key)
        let opened = try XCTUnwrap(model.openedSnapshots[snapshotID])

        XCTAssertEqual(result, .imported)
        XCTAssertEqual(keyStore.key, key)
        XCTAssertNotNil(opened.context)
        XCTAssertNil(opened.contextError)
        XCTAssertEqual(opened.context?.preparation.authentication.resolvedSecret, "synthetic-snapshot-token")
        let exportedKey = try await model.exportEncryptionKey()
        XCTAssertEqual(exportedKey, key)
        let repeatedImport = try await model.importEncryptionKey(key)
        XCTAssertEqual(repeatedImport, .alreadyPresent)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testGlobalKeyCandidateIsRejectedWhenSavedSnapshotUsesAnotherKey() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceKey = Data(repeating: 0x2a, count: 32)
        let snapshotKey = Data(repeating: 0x5b, count: 32)
        let snapshotID = try await createWorkspaceWithSnapshot(
            root: root, workspaceKey: workspaceKey, snapshotKey: snapshotKey
        )
        let keyStore = TransferTestKeyStore()
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.canEditVariables(.global) }
        model.selectSnapshot(snapshotID)
        try await waitUntil { model.openedSnapshots[snapshotID] != nil }

        do {
            _ = try await model.importEncryptionKey(workspaceKey)
            XCTFail("The candidate must also validate the saved snapshot context.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
        }

        XCTAssertNil(keyStore.key)
        XCTAssertEqual(keyStore.createCount, 0)
        do {
            _ = try await model.exportEncryptionKey()
            XCTFail("A rejected candidate must not be persisted.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .missingKey)
        }
        XCTAssertNil(model.openedSnapshots[snapshotID]?.context)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testEnvelopeScanRejectsNonemptyStagingWithoutCleaningIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        let staged = snapshots.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let payload = staged.appendingPathComponent("unrecognized-staging-data")
        try Data([1, 2, 3]).write(to: payload)
        let store = SnapshotStore(rootURL: snapshots, vault: SecretVault(keyStore: TransferTestKeyStore()))

        do {
            _ = try await store.encryptionEnvelopes()
            XCTFail("Unrecognized staged data must block key import.")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
    }

    private func createWorkspaceWithSnapshot(
        root: URL,
        workspaceKey: Data,
        snapshotKey: Data? = nil
    ) async throws -> UUID {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let store = try CollectionStore(rootURL: dataDirectory)
        let workspaceVault = SecretVault(keyStore: TransferTestKeyStore(existingKey: workspaceKey))
        let globalEnvelope = try await workspaceVault.encrypt("synthetic global credential")
        try await store.saveGlobalVariables(["credential": .encrypted(globalEnvelope)])

        let snapshotVault = SecretVault(keyStore: TransferTestKeyStore(existingKey: snapshotKey ?? workspaceKey))
        let token = try await snapshotVault.encrypt("synthetic-snapshot-token")
        let request = HTTPRequestConfiguration(
            name: "Synthetic request",
            url: "https://example.invalid/",
            authentication: RequestAuthentication(kind: .bearer, token: token)
        )
        let prepared = try await RequestPreparer.prepare(request, context: .init(), decryptor: snapshotVault)
        let capture = try XCTUnwrap(prepared.snapshotCapture)
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodyDirectory, withIntermediateDirectories: true)
        let body = Data([1, 2, 3])
        let bodyURL = bodyDirectory.appendingPathComponent("response.body")
        try body.write(to: bodyURL)
        let response = HTTPResponseRecord(
            runID: UUID(), request: request, finalURL: capture.submitted.url, statusCode: 200,
            requestHeaders: capture.submitted.headers, responseHeaders: [], redirects: [],
            bodyFileURL: bodyURL, bodyByteCount: Int64(body.count), duration: 0,
            snapshotCapture: capture
        )
        let source = SnapshotSource(
            identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
            collectionName: "Synthetic collection", requestName: request.name
        )
        let lease = HTTPBodyLease(token: UUID(), runID: response.runID, bodyURL: bodyURL)
        let snapshotStore = SnapshotStore(
            rootURL: dataDirectory.appendingPathComponent("snapshots", isDirectory: true), vault: snapshotVault
        )
        let saved = try await snapshotStore.save(
            response: response, source: source, name: "Synthetic saved snapshot", bodyLease: lease
        )
        return saved.id
    }

    private func makeModel(root: URL, keyStore: TransferTestKeyStore) -> AppModel {
        AppModel(
            arguments: [
                "PostieKeyTransferTests",
                "--data-directory", root.appendingPathComponent("data", isDirectory: true).path,
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path,
            ], secretVault: SecretVault(keyStore: keyStore))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieKeyTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The expected app state was not reached.")
    }
}

private final class TransferTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?
    private var storedCreateCount = 0

    init(existingKey: Data? = nil) {
        storedKey = existingKey
    }

    var key: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedKey
    }

    var createCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateCount
    }

    func loadKey() throws -> Data? {
        key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        storedCreateCount += 1
        if let storedKey { return storedKey }
        storedKey = proposedKey
        return proposedKey
    }
}
