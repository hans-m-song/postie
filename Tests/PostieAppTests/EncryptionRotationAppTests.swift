import Foundation
import XCTest
@testable import PostieCore
import PostieAutomation
@testable import PostieApp

@MainActor
final class EncryptionRotationAppTests: XCTestCase {
    func testFailureAfterCompletionReloadsBeforeAllowingFurtherSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("data")
        let vault = SecretVault(keyStore: RotationAppKeys())
        let coordinator = WorkspaceKeyRotation(rootURL: dataRoot, vault: vault) { checkpoint in
            if checkpoint == .rotationCompleted { throw RotationCompletionFailure() }
        }
        let model = AppModel(
            arguments: [
                "PostieTests", "--data-directory", dataRoot.path,
                "--body-directory", root.appendingPathComponent("bodies").path,
            ], secretVault: vault, legacyMCPKeyStore: RotationAppKeys(), keyRotationCoordinator: coordinator)
        for _ in 0..<200 {
            if model.canEditVariables(.global) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await model.setVariable(name: "credential", value: "synthetic", isSecret: true, owner: .global)
        do {
            try await model.rotateEncryptionKey()
            XCTFail("The post-completion interruption must be surfaced")
        } catch is RotationCompletionFailure {}
        XCTAssertTrue(model.canEditVariables(.global))
        let value = try XCTUnwrap(model.globalVariables["credential"])
        guard case let .encrypted(envelope) = value else { return XCTFail("Expected encrypted value") }
        XCTAssertEqual(envelope.version, 2)
        try model.setPlainVariable(name: "unrelated", value: "retained", owner: .global)
        try await model.flushPendingSaves()
        let diskEnvelopes = try EncryptedDocument.envelopes(
            in: Data(contentsOf: dataRoot.appendingPathComponent("globals.json")), kind: .globals)
        XCTAssertEqual(diskEnvelopes, [envelope])
        let plaintext = try await vault.decrypt(envelope)
        XCTAssertEqual(plaintext, "synthetic")
        let stopped = await model.prepareForTermination()
        XCTAssertTrue(stopped)
    }

    func testRotationFlushesAndReloadsSecretsWithoutChangingMCPToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = RotationAppKeys()
        let vault = SecretVault(keyStore: keys)
        let model = AppModel(
            arguments: [
                "PostieTests", "--data-directory", root.appendingPathComponent("data").path,
                "--body-directory", root.appendingPathComponent("bodies").path,
            ], secretVault: vault, legacyMCPKeyStore: RotationAppKeys())
        for _ in 0..<200 {
            if model.canEditVariables(.global) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canRotateEncryptionKey)
        await model.createCollection(name: "Rotation fixture")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let identity = try XCTUnwrap(model.selectedIdentity)
        try await model.setVariable(name: "credential", value: "synthetic credential", isSecret: true, owner: .global)
        try await model.setVariable(name: "local", value: "synthetic local", isSecret: true, owner: .request(identity))
        let oldKey = try await model.exportEncryptionKey()
        let token = try await model.mcpBearerToken()
        let reachedKeyCreation = expectation(description: "Rotation reached key creation")
        let releaseKeyCreation = DispatchSemaphore(value: 0)
        keys.setCreationGate {
            reachedKeyCreation.fulfill()
            _ = releaseKeyCreation.wait(timeout: .now() + 5)
        }
        let rotation = Task { try await model.rotateEncryptionKey() }
        await fulfillment(of: [reachedKeyCreation], timeout: 5)
        XCTAssertTrue(model.isRotatingEncryptionKey)
        XCTAssertFalse(model.canEdit(identity))
        XCTAssertFalse(model.canEditVariables(.global))
        XCTAssertFalse(model.canSaveSnapshot(for: identity))
        let reply = await model.automationReply(AutomationCommand(operation: .collectionsList), channel: .mcp)
        XCTAssertEqual(reply.error?.code, .unavailable)
        await model.createCollection(name: "Blocked during rotation")
        XCTAssertEqual(model.collections.count, 1)
        do {
            try model.setPlainVariable(name: "blocked", value: "must not save", owner: .global)
            XCTFail("Edits must be unavailable during rotation")
        } catch {}
        releaseKeyCreation.signal()
        try await rotation.value
        let newKey = try await model.exportEncryptionKey()
        let newToken = try await model.mcpBearerToken()
        XCTAssertNotEqual(oldKey, newKey)
        XCTAssertEqual(token, newToken)
        XCTAssertEqual(model.selectedIdentity, identity)
        XCTAssertFalse(model.isRotatingEncryptionKey)
        XCTAssertTrue(model.canEdit(identity))
        let global = try XCTUnwrap(model.globalVariables["credential"])
        guard case let .encrypted(globalEnvelope) = global else { return XCTFail("Expected encrypted value") }
        XCTAssertEqual(globalEnvelope.version, 2)
        let plaintext = try await vault.decrypt(globalEnvelope)
        XCTAssertEqual(plaintext, "synthetic credential")
        let local = try XCTUnwrap(model.drafts[identity]?.variables["local"])
        guard case let .encrypted(localEnvelope) = local else { return XCTFail("Expected encrypted draft") }
        XCTAssertEqual(localEnvelope.keyID, globalEnvelope.keyID)

        let copiedRoot = root.appendingPathComponent("copied-data")
        try FileManager.default.copyItem(at: root.appendingPathComponent("data"), to: copiedRoot)
        let destinationVault = SecretVault(keyStore: RotationAppKeys())
        let reopened = AppModel(
            arguments: [
                "PostieTests", "--data-directory", copiedRoot.path,
                "--body-directory", root.appendingPathComponent("copied-bodies").path,
            ], secretVault: destinationVault, legacyMCPKeyStore: RotationAppKeys())
        for _ in 0..<200 {
            if reopened.canEditVariables(.global) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(reopened.startupError)
        let imported = try await reopened.importEncryptionKey(newKey)
        XCTAssertEqual(imported, .imported)
        let reopenedValue = try XCTUnwrap(reopened.globalVariables["credential"])
        guard case let .encrypted(reopenedEnvelope) = reopenedValue else {
            return XCTFail("Expected persisted encrypted value")
        }
        let reopenedPlaintext = try await destinationVault.decrypt(reopenedEnvelope)
        XCTAssertEqual(reopenedPlaintext, "synthetic credential")
        let reopenedToken = try await reopened.mcpBearerToken()
        XCTAssertEqual(reopenedToken, token)
        let destinationStopped = await reopened.prepareForTermination()
        XCTAssertTrue(destinationStopped)
        let stopped = await model.prepareForTermination()
        XCTAssertTrue(stopped)
    }
}

private struct RotationCompletionFailure: Error {}

private final class RotationAppKeys: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var legacy: Data?
    private var keyed: [UUID: Data] = [:]
    private var creationGate: (@Sendable () -> Void)?

    func setCreationGate(_ gate: @escaping @Sendable () -> Void) {
        lock.withLock { creationGate = gate }
    }

    func loadKey() throws -> Data? { lock.withLock { legacy } }
    func createKey(_ proposedKey: Data) throws -> Data {
        lock.withLock {
            if let legacy { return legacy }
            legacy = proposedKey
            return proposedKey
        }
    }
    func loadKey(id: UUID) throws -> Data? { lock.withLock { keyed[id] } }
    func createKey(_ proposedKey: Data, id: UUID) throws -> Data {
        let gate = lock.withLock { creationGate }
        gate?()
        return lock.withLock {
            if let existing = keyed[id] { return existing }
            keyed[id] = proposedKey
            return proposedKey
        }
    }
}
