import Foundation
import XCTest
@testable import PostieApp
@testable import PostieCore

@MainActor
final class MCPTokenIntegrationTests: XCTestCase {
    func testWorkspaceSecretAndLegacyTokenMigrationShareWorkspaceKey() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceKey = Data(repeating: 0x2b, count: 32)
        let setupVault = SecretVault(keyStore: MCPTokenIntegrationKeyStore(existingKey: workspaceKey))
        let originalSecret = "synthetic workspace credential"
        let secretEnvelope = try await setupVault.encrypt(originalSecret)
        let dataRoot = dataDirectory(root: root)
        do {
            let store = try CollectionStore(rootURL: dataRoot)
            try await store.saveGlobalVariables(["existingCredential": .encrypted(secretEnvelope)])
        }

        let legacyKey = Data(repeating: 0x5c, count: 32)
        let workspaceKeyStore = MCPTokenIntegrationKeyStore(existingKey: workspaceKey)
        let legacyKeyStore = MCPTokenIntegrationKeyStore(existingKey: legacyKey)

        try await withModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }

            let loadedSecret = try await model.revealVariable(named: "existingCredential", owner: .global)
            XCTAssertEqual(loadedSecret, originalSecret)

            let token = try await model.mcpBearerToken()
            XCTAssertEqual(token, legacyKey.base64EncodedString())
            XCTAssertEqual(legacyKeyStore.loadCount, 1)
            XCTAssertEqual(legacyKeyStore.createCount, 0)
            XCTAssertEqual(workspaceKeyStore.loadCount, 1)
            XCTAssertEqual(workspaceKeyStore.createCount, 0)

            let document = try readTokenDocument(root: root)
            XCTAssertEqual(document.formatVersion, 1)
            let tokenFile = try Data(contentsOf: tokenFileURL(root: root))
            XCTAssertNil(tokenFile.range(of: Data(token.utf8)))
            let verifier = SecretVault(keyStore: MCPTokenIntegrationKeyStore(existingKey: workspaceKey))
            let persistedToken = try await verifier.decrypt(document.token)
            XCTAssertEqual(persistedToken, token)

            let exportedKey = try await model.exportEncryptionKey()
            XCTAssertEqual(exportedKey, workspaceKey)

            try await model.setVariable(
                name: "newCredential",
                value: "synthetic new credential",
                isSecret: true,
                owner: .global
            )
            try await model.flushPendingSaves()
            let savedSecret = try await model.revealVariable(named: "newCredential", owner: .global)
            XCTAssertEqual(savedSecret, "synthetic new credential")
            XCTAssertTrue(model.globalVariables["newCredential"]?.isEncrypted == true)
        }
    }

    func testAutomationOnlyCiphertextBlocksReplacementKeyAfterRestart() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalSession = try await seedTokenOnlyWorkspace(root: root)
        try await waitUntil { originalSession.modelReference.model == nil }
        let originalFile = try Data(contentsOf: tokenFileURL(root: root))

        let missingWorkspaceKeyStore = MCPTokenIntegrationKeyStore()
        let unusedLegacyKeyStore = MCPTokenIntegrationKeyStore()
        try await withModel(
            root: root,
            workspaceKeyStore: missingWorkspaceKeyStore,
            legacyKeyStore: unusedLegacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }
            XCTAssertTrue(model.globalVariables.isEmpty)
            XCTAssertTrue(model.collections.isEmpty)
            XCTAssertTrue(model.snapshots.isEmpty)

            do {
                try await model.setVariable(
                    name: "replacementCredential",
                    value: "synthetic replacement credential",
                    isSecret: true,
                    owner: .global
                )
                XCTFail("Automation ciphertext must prevent replacement-key creation.")
            } catch {
                XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
            }
            model.discardVariableSecretEdit(named: "replacementCredential", owner: .global)

            do {
                _ = try await model.mcpBearerToken()
                XCTFail("An automation token encrypted with a missing workspace key must not be replaced.")
            } catch {
                XCTAssertEqual(error as? SecretVaultError, .missingKey)
            }

            XCTAssertEqual(missingWorkspaceKeyStore.createCount, 0)
            XCTAssertEqual(unusedLegacyKeyStore.loadCount, 0)
            XCTAssertEqual(try Data(contentsOf: tokenFileURL(root: root)), originalFile)
        }
    }

    func testTokenEnvelopeValidatesImportAndRestoresTokenWithoutLegacyRead() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalSession = try await seedTokenOnlyWorkspace(root: root)
        try await waitUntil { originalSession.modelReference.model == nil }

        let workspaceKeyStore = MCPTokenIntegrationKeyStore()
        let legacyKeyStore = MCPTokenIntegrationKeyStore()
        try await withModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }
            XCTAssertTrue(model.globalVariables.isEmpty)
            XCTAssertTrue(model.collections.isEmpty)
            XCTAssertTrue(model.snapshots.isEmpty)

            do {
                _ = try await model.importEncryptionKey(Data(repeating: 0x17, count: 32))
                XCTFail("The token envelope must reject a key that cannot decrypt it.")
            } catch {
                XCTAssertEqual(error as? SecretVaultError, .authenticationFailed)
            }
            XCTAssertEqual(workspaceKeyStore.createCount, 0)
            XCTAssertEqual(workspaceKeyStore.loadCount, 0)
            XCTAssertEqual(legacyKeyStore.loadCount, 0)

            let importResult = try await model.importEncryptionKey(originalSession.key)
            XCTAssertEqual(importResult, .imported)
            XCTAssertEqual(workspaceKeyStore.createCount, 1)

            let restoredToken = try await model.mcpBearerToken()
            XCTAssertEqual(restoredToken, originalSession.token)
            XCTAssertEqual(legacyKeyStore.loadCount, 0)
        }
    }

    func testStartupInspectionDoesNotReadEitherKeyStore() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceKeyStore = MCPTokenIntegrationKeyStore()
        let legacyKeyStore = MCPTokenIntegrationKeyStore()

        try await withModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }

            XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFileURL(root: root).path))
            XCTAssertEqual(workspaceKeyStore.loadCount, 0)
            XCTAssertEqual(workspaceKeyStore.createCount, 0)
            XCTAssertEqual(legacyKeyStore.loadCount, 0)
            XCTAssertEqual(legacyKeyStore.createCount, 0)
        }
    }

    func testMalformedAutomationFileBlocksWritesAndImportWithoutChangingBytes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory(root: root), withIntermediateDirectories: true)
        let tokenFile = tokenFileURL(root: root)
        let originalFile = Data(
            #"{"formatVersion":1,"token":{"version":1,"combined":"not-base64"}}"#.utf8
        )
        try originalFile.write(to: tokenFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        let workspaceKeyStore = MCPTokenIntegrationKeyStore()
        let legacyKeyStore = MCPTokenIntegrationKeyStore(existingKey: Data(repeating: 0x38, count: 32))
        try await withModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }

            var tokenReadFailed = false
            do {
                _ = try await model.mcpBearerToken()
                XCTFail("Malformed automation data must not be replaced with a new token.")
            } catch {
                tokenReadFailed = true
            }
            XCTAssertTrue(tokenReadFailed)

            do {
                try await model.setVariable(
                    name: "blockedCredential",
                    value: "synthetic blocked credential",
                    isSecret: true,
                    owner: .global
                )
                XCTFail("Malformed automation data must prevent workspace-key creation.")
            } catch {
                XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
            }
            model.discardVariableSecretEdit(named: "blockedCredential", owner: .global)

            do {
                _ = try await model.importEncryptionKey(Data(repeating: 0x49, count: 32))
                XCTFail("Key import must stop when automation storage is malformed.")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Key import is unavailable while workspace or snapshot storage has unresolved issues."
                )
            }

            XCTAssertEqual(workspaceKeyStore.createCount, 0)
            XCTAssertEqual(legacyKeyStore.loadCount, 0)
            XCTAssertEqual(try Data(contentsOf: tokenFile), originalFile)
        }
    }

    func testSymlinkAutomationFileBlocksWritesAndImportWithoutChangingTargetBytes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: dataDirectory(root: root), withIntermediateDirectories: true)
        let tokenFile = tokenFileURL(root: root)
        let targetURL = root.appendingPathComponent("synthetic-token-target")
        let targetKey = Data(repeating: 0xa3, count: 32)
        let targetVault = SecretVault(keyStore: MCPTokenIntegrationKeyStore(existingKey: targetKey))
        let targetEnvelope = try await targetVault.encrypt("synthetic symlink token")
        let targetBytes = try JSONEncoder().encode(
            MCPTokenIntegrationDocument(formatVersion: 1, token: targetEnvelope)
        )
        try targetBytes.write(to: targetURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        try FileManager.default.createSymbolicLink(at: tokenFile, withDestinationURL: targetURL)

        let workspaceKeyStore = MCPTokenIntegrationKeyStore()
        let legacyKeyStore = MCPTokenIntegrationKeyStore(existingKey: Data(repeating: 0x61, count: 32))
        try await withModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        ) { model in
            try await waitUntil { model.canEditVariables(.global) }

            var tokenReadFailed = false
            do {
                _ = try await model.mcpBearerToken()
                XCTFail("A symlinked automation file must not be read or replaced.")
            } catch {
                tokenReadFailed = true
            }
            XCTAssertTrue(tokenReadFailed)

            do {
                try await model.setVariable(
                    name: "blockedCredential",
                    value: "synthetic blocked credential",
                    isSecret: true,
                    owner: .global
                )
                XCTFail("A symlinked automation file must prevent workspace-key creation.")
            } catch {
                XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
            }
            model.discardVariableSecretEdit(named: "blockedCredential", owner: .global)

            do {
                _ = try await model.importEncryptionKey(targetKey)
                XCTFail("Key import must stop when automation storage is a symlink.")
            } catch {
                XCTAssertEqual(
                    error.localizedDescription,
                    "Key import is unavailable while workspace or snapshot storage has unresolved issues."
                )
            }

            XCTAssertEqual(workspaceKeyStore.createCount, 0)
            XCTAssertEqual(legacyKeyStore.loadCount, 0)
            XCTAssertEqual(try Data(contentsOf: targetURL), targetBytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: tokenFile.path), targetURL.path)
        }
    }

    private func seedTokenOnlyWorkspace(root: URL) async throws -> TokenOnlyWorkspaceFixture {
        let modelReference = MCPTokenIntegrationModelReference()
        let tokenAndKey = try await withModel(
            root: root,
            workspaceKeyStore: MCPTokenIntegrationKeyStore(),
            legacyKeyStore: MCPTokenIntegrationKeyStore()
        ) { model in
            modelReference.model = model
            try await waitUntil { model.canEditVariables(.global) }
            let token = try await model.mcpBearerToken()
            let key = try await model.exportEncryptionKey()
            return (token, key)
        }
        return TokenOnlyWorkspaceFixture(
            token: tokenAndKey.0,
            key: tokenAndKey.1,
            modelReference: modelReference
        )
    }

    private func withModel<Output>(
        root: URL,
        workspaceKeyStore: MCPTokenIntegrationKeyStore,
        legacyKeyStore: MCPTokenIntegrationKeyStore,
        operation: @MainActor (AppModel) async throws -> Output
    ) async throws -> Output {
        let model = makeModel(
            root: root,
            workspaceKeyStore: workspaceKeyStore,
            legacyKeyStore: legacyKeyStore
        )
        do {
            let output = try await operation(model)
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
            return output
        } catch {
            _ = await model.prepareForTermination()
            throw error
        }
    }

    private func makeModel(
        root: URL,
        workspaceKeyStore: MCPTokenIntegrationKeyStore,
        legacyKeyStore: MCPTokenIntegrationKeyStore
    ) -> AppModel {
        AppModel(
            arguments: [
                "PostieMCPTokenIntegrationTests",
                "--data-directory", dataDirectory(root: root).path,
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path,
            ],
            secretVault: SecretVault(keyStore: workspaceKeyStore),
            legacyMCPKeyStore: legacyKeyStore
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the model to reach the expected state.")
    }

    private func readTokenDocument(root: URL) throws -> MCPTokenIntegrationDocument {
        let data = try Data(contentsOf: tokenFileURL(root: root))
        return try JSONDecoder().decode(MCPTokenIntegrationDocument.self, from: data)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieMCPTokenIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func dataDirectory(root: URL) -> URL {
        root.appendingPathComponent("data", isDirectory: true)
    }

    private func tokenFileURL(root: URL) -> URL {
        dataDirectory(root: root).appendingPathComponent("automation.json")
    }
}

private struct MCPTokenIntegrationDocument: Codable {
    let formatVersion: Int
    let token: SecretEnvelope
}

private struct TokenOnlyWorkspaceFixture {
    let token: String
    let key: Data
    let modelReference: MCPTokenIntegrationModelReference
}

@MainActor
private final class MCPTokenIntegrationModelReference {
    weak var model: AppModel?
}

private final class MCPTokenIntegrationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var loads = 0
    private var creations = 0

    init(existingKey: Data? = nil) {
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
        return creations
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
        creations += 1
        if let key { return key }
        key = proposedKey
        return proposedKey
    }
}
