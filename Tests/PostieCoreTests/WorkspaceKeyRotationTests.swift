import Foundation
import XCTest
@testable import PostieCore

final class WorkspaceKeyRotationTests: XCTestCase {
    func testRotationRewritesEveryOwnerAndPreservesUnknownMetadataAndBodies() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        try await assertFixtureLoads(fixture, vault: vault)
        let legacyBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
        let legacyKey = try keyStore.key(for: nil)

        let rotation = WorkspaceKeyRotation(rootURL: root, vault: vault)
        try await rotation.rotate()

        let rotationIsPending = try await rotation.isPending()
        XCTAssertFalse(rotationIsPending)
        let metadata = try readObject(at: fixture.metadataURL)
        let activeKeyID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(metadata["activeKeyID"] as? String)))
        XCTAssertEqual(metadata["pendingRotation"] as? Bool, false)

        let expectedOwners: [(URL, EncryptedDocument.Kind)] = [
            (fixture.globalsURL, .globals),
            (fixture.collectionURL, .collection),
            (fixture.requestURL, .request),
            (fixture.snapshotURL, .snapshot),
            (fixture.automationURL, .automation),
        ]
        for (ownerIndex, (url, kind)) in expectedOwners.enumerated() {
            let data = try Data(contentsOf: url)
            let envelopes = try EncryptedDocument.envelopes(in: data, kind: kind)
            let expectedPlaintexts = try XCTUnwrap(fixture.expectedPlaintextsByPath[url.path])
            XCTAssertEqual(envelopes.count, expectedPlaintexts.count)
            XCTAssertTrue(envelopes.allSatisfy { $0.version == 2 && $0.keyID == activeKeyID })
            for (envelope, expectedPlaintext) in zip(envelopes, expectedPlaintexts) {
                let plaintext = try await vault.decrypt(envelope)
                XCTAssertEqual(plaintext, expectedPlaintext)
            }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-value"))
            XCTAssertNotEqual(data, legacyBytes[ownerIndex])
        }

        let globals = try readObject(at: fixture.globalsURL)
        let futureRootField = try XCTUnwrap(globals["futureRootField"] as? [String: Any])
        XCTAssertEqual(futureRootField["retained"] as? Bool, true)
        let globalsVariables = try XCTUnwrap(globals["variables"] as? [String: Any])
        let globalEnvelope = try XCTUnwrap(globalsVariables["globalSecret"] as? [String: Any])
        let futureEnvelopeField = try XCTUnwrap(globalEnvelope["futureEnvelopeField"] as? [String: Any])
        XCTAssertEqual(futureEnvelopeField["retained"] as? Bool, true)

        let collection = try readObject(at: fixture.collectionURL)
        XCTAssertEqual(collection["futureCollectionField"] as? String, "retained")
        let request = try readObject(at: fixture.requestURL)
        let futureRequestField = try XCTUnwrap(request["futureRequestField"] as? [String: Any])
        XCTAssertEqual(futureRequestField["retained"] as? Bool, true)
        let snapshot = try readObject(at: fixture.snapshotURL)
        let futureSnapshotField = try XCTUnwrap(snapshot["futureSnapshotField"] as? [String: Any])
        XCTAssertEqual(futureSnapshotField["retained"] as? Bool, true)
        let automation = try readObject(at: fixture.automationURL)
        XCTAssertEqual(automation["futureAutomationField"] as? Bool, true)

        XCTAssertEqual(try Data(contentsOf: fixture.responseBodyURL), fixture.responseBody)
        let newKey = try keyStore.key(for: activeKeyID)
        let metadataBytes = try Data(contentsOf: fixture.metadataURL)
        XCTAssertFalse(metadataBytes.range(of: legacyKey) != nil)
        XCTAssertFalse(metadataBytes.range(of: newKey) != nil)
        XCTAssertFalse(String(decoding: metadataBytes, as: UTF8.self).contains(legacyKey.base64EncodedString()))
        XCTAssertFalse(String(decoding: metadataBytes, as: UTF8.self).contains(newKey.base64EncodedString()))
        let stagingURL = root.appendingPathComponent(".key-rotation-staging", isDirectory: true)
        for entry in try FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: entry)
            XCTAssertFalse(bytes.range(of: legacyKey) != nil)
            XCTAssertFalse(bytes.range(of: newKey) != nil)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(legacyKey.base64EncodedString()))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(newKey.base64EncodedString()))
        }
        try await assertFixtureLoads(fixture, vault: vault)

        let importKey = newKey
        let importingVault = SecretVault(keyStore: RotationTestKeyStore(legacyKey: legacyKey))
        let recoveringCoordinator = WorkspaceKeyRotation(rootURL: root, vault: importingVault)
        try await recoveringCoordinator.prepareWorkspace()
        await importingVault.configure(activeKeyID: activeKeyID)
        _ = try await importingVault.importKey(
            importKey,
            validating: expectedOwners.flatMap {
                try EncryptedDocument.envelopes(in: Data(contentsOf: $0.0), kind: $0.1)
            })
    }

    func testPendingRotationResumesAfterOneDocumentWasRewritten() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        let interrupted = WorkspaceKeyRotation(
            rootURL: root, vault: vault,
            checkpoint: { checkpoint in
                if checkpoint == .documentRewritten(1) { throw SimulatedRotationInterruption() }
            })

        do {
            try await interrupted.rotate()
            XCTFail("The injected interruption should stop the first rotation attempt.")
        } catch is SimulatedRotationInterruption {
        }
        let interruptedIsPending = try await interrupted.isPending()
        XCTAssertTrue(interruptedIsPending)
        XCTAssertTrue(
            try EncryptedDocument.envelopes(in: Data(contentsOf: fixture.globalsURL), kind: .globals)
                .allSatisfy { $0.version == 2 })
        XCTAssertTrue(
            try EncryptedDocument.envelopes(in: Data(contentsOf: fixture.requestURL), kind: .request)
                .allSatisfy { $0.version == 1 })

        let restarted = WorkspaceKeyRotation(rootURL: root, vault: SecretVault(keyStore: keyStore))
        try await restarted.prepareWorkspace()
        let restartedIsPending = try await restarted.isPending()
        XCTAssertFalse(restartedIsPending)
        try await assertFixtureLoads(fixture, vault: SecretVault(keyStore: keyStore))
    }

    func testMissingTargetKeyKeepsPendingMetadataAndDoesNotRewriteDocuments() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        let originalBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
        let interrupted = WorkspaceKeyRotation(
            rootURL: root, vault: vault,
            checkpoint: { checkpoint in
                if checkpoint == .pendingPublished { throw SimulatedRotationInterruption() }
            })

        do {
            try await interrupted.rotate()
            XCTFail("The injected interruption should stop after publishing pending metadata.")
        } catch is SimulatedRotationInterruption {
        }
        let interruptedIsPending = try await interrupted.isPending()
        XCTAssertTrue(interruptedIsPending)
        let legacyKey = try keyStore.key(for: nil)
        let missingTargetStore = RotationTestKeyStore(legacyKey: legacyKey)
        let restarted = WorkspaceKeyRotation(
            rootURL: root,
            vault: SecretVault(keyStore: missingTargetStore)
        )

        do {
            try await restarted.prepareWorkspace()
            XCTFail("A missing active key must leave rotation pending.")
        } catch SecretVaultError.missingKey {
        }
        let restartedIsPending = try await restarted.isPending()
        XCTAssertTrue(restartedIsPending)
        XCTAssertEqual(try fixture.documentURLs.map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testPreCommitInterruptionLeavesRecoverableTempOutsideSnapshotAndResumes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        let interrupted = WorkspaceKeyRotation(
            rootURL: root, vault: vault,
            checkpoint: { checkpoint in
                if checkpoint == .documentTemporaryWritten(4) { throw SimulatedRotationInterruption() }
            })

        do {
            try await interrupted.rotate()
            XCTFail("The injected interruption should leave a staged snapshot replacement.")
        } catch is SimulatedRotationInterruption {
        }
        let interruptedIsPending = try await interrupted.isPending()
        XCTAssertTrue(interruptedIsPending)
        let stagingURL = root.appendingPathComponent(".key-rotation-staging", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingURL.path).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshotURL.path))
        let pendingMetadata = try readObject(at: fixture.metadataURL)
        let activeKeyID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(pendingMetadata["activeKeyID"] as? String)))
        let keyMaterial = [try keyStore.key(for: nil), try keyStore.key(for: activeKeyID)]
        let stagedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil).first
        )
        let stagedBytes = try Data(contentsOf: stagedFile)
        let stagedText = String(decoding: stagedBytes, as: UTF8.self)
        for key in keyMaterial {
            XCTAssertFalse(stagedBytes.range(of: key) != nil)
            XCTAssertFalse(stagedText.contains(key.base64EncodedString()))
        }

        let restarted = WorkspaceKeyRotation(rootURL: root, vault: SecretVault(keyStore: keyStore))
        try await restarted.prepareWorkspace()
        let restartedIsPending = try await restarted.isPending()
        XCTAssertFalse(restartedIsPending)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stagingURL.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.responseBodyURL), fixture.responseBody)
        try await assertFixtureLoads(fixture, vault: SecretVault(keyStore: keyStore))
    }

    func testPreflightAuthenticatesEveryEnvelopeBeforeCreatingKeyOrRewriting() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        let interrupted = WorkspaceKeyRotation(
            rootURL: root, vault: vault,
            checkpoint: { checkpoint in
                if checkpoint == .pendingPublished { throw SimulatedRotationInterruption() }
            })
        do {
            try await interrupted.rotate()
            XCTFail("The first attempt should publish pending metadata and stop.")
        } catch is SimulatedRotationInterruption {
        }

        let unavailableKeyStore = RotationTestKeyStore()
        let unavailableVault = SecretVault(keyStore: unavailableKeyStore, allowsKeyCreation: true)
        let unavailableID = try await unavailableVault.createRotationKey()
        await unavailableVault.configure(activeKeyID: unavailableID)
        let unavailableEnvelope = try await unavailableVault.encrypt("other-key")
        var automation = try readObject(at: fixture.automationURL)
        automation["token"] = try envelopeObject(unavailableEnvelope)
        try writeJSON(automation, to: fixture.automationURL)

        let originalBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
        let rotation = WorkspaceKeyRotation(rootURL: root, vault: SecretVault(keyStore: keyStore))
        do {
            try await rotation.prepareWorkspace()
            XCTFail("The unavailable envelope key must fail preflight.")
        } catch SecretVaultError.missingKey {
        }

        XCTAssertEqual(keyStore.identifiedKeyCount, 1)
        let stillPending = try await rotation.isPending()
        XCTAssertTrue(stillPending)
        XCTAssertEqual(try fixture.documentURLs.map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testInitialPreflightAuthenticationFailureDoesNotAllocateKeyOrRewrite() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        var automation = try readObject(at: fixture.automationURL)
        var envelope = try XCTUnwrap(automation["token"] as? [String: Any])
        var combined = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["combined"] as? String)))
        combined[combined.count - 1] ^= 1
        envelope["combined"] = combined.base64EncodedString()
        automation["token"] = envelope
        try writeJSON(automation, to: fixture.automationURL)

        let originalBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
        let rotation = WorkspaceKeyRotation(rootURL: root, vault: vault)
        do {
            try await rotation.rotate()
            XCTFail("Unauthenticated ciphertext must fail before key allocation.")
        } catch SecretVaultError.authenticationFailed {
        }

        XCTAssertEqual(keyStore.identifiedKeyCount, 0)
        XCTAssertEqual(try fixture.documentURLs.map { try Data(contentsOf: $0) }, originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.metadataURL.path))
    }

    func testMissingMetadataRejectsIdentifiedEnvelopesBeforeWorkspaceAccess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let activeKeyID = try await vault.createRotationKey()
        await vault.configure(activeKeyID: activeKeyID)
        let envelope = try await vault.encrypt("identified-secret")
        let globalsURL = root.appendingPathComponent("globals.json")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("collections", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeJSON(
            [
                "formatVersion": 1,
                "variables": ["secret": try envelopeObject(envelope)],
            ], to: globalsURL)

        let rotation = WorkspaceKeyRotation(rootURL: root, vault: vault)
        do {
            try await rotation.prepareWorkspace()
            XCTFail("Identified envelopes require workspace key metadata.")
        } catch WorkspaceKeyRotationError.metadataRequiredForIdentifiedEnvelope {
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace-encryption.json").path))
    }

    func testMalformedOrUnindexedRequestBlocksRotationBeforeAnyRewrite() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = RotationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let fixture = try await makeWorkspace(at: root, vault: vault)
        let originalBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
        let extraID = UUID()
        let requestObject = try readObject(at: fixture.requestURL)
        try writeJSON(
            requestObject,
            to: fixture.requestURL.deletingLastPathComponent()
                .appendingPathComponent("\(extraID.uuidString).json"))

        let rotation = WorkspaceKeyRotation(rootURL: root, vault: vault)
        do {
            try await rotation.rotate()
            XCTFail("Unindexed request documents must block rotation.")
        } catch WorkspaceKeyRotationError.unindexedRequest {
        }
        XCTAssertEqual(keyStore.identifiedKeyCount, 0)
        XCTAssertEqual(try fixture.documentURLs.map { try Data(contentsOf: $0) }, originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.metadataURL.path))
    }

    func testPendingRotationDoesNotClearWhenSnapshotBodyIsMissingOrTruncated() async throws {
        for removeBody in [true, false] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }

            let keyStore = RotationTestKeyStore()
            let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
            let fixture = try await makeWorkspace(at: root, vault: vault)
            let originalBytes = try fixture.documentURLs.map { try Data(contentsOf: $0) }
            let interrupted = WorkspaceKeyRotation(
                rootURL: root, vault: vault,
                checkpoint: { checkpoint in
                    if checkpoint == .pendingPublished { throw SimulatedRotationInterruption() }
                })
            do {
                try await interrupted.rotate()
                XCTFail("The injected interruption should leave a pending rotation.")
            } catch is SimulatedRotationInterruption {
            }

            if removeBody {
                try FileManager.default.removeItem(at: fixture.responseBodyURL)
            } else {
                try Data([1]).write(to: fixture.responseBodyURL)
            }
            let restarted = WorkspaceKeyRotation(rootURL: root, vault: SecretVault(keyStore: keyStore))
            do {
                try await restarted.prepareWorkspace()
                XCTFail("A damaged snapshot body must keep rotation pending.")
            } catch WorkspaceKeyRotationError.invalidWorkspace {
            }
            let stillPending = try await restarted.isPending()
            XCTAssertTrue(stillPending)
            XCTAssertEqual(try fixture.documentURLs.map { try Data(contentsOf: $0) }, originalBytes)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieWorkspaceKeyRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeWorkspace(at root: URL, vault: SecretVault) async throws -> WorkspaceFixture {
        let collectionsURL = root.appendingPathComponent("collections", isDirectory: true)
        let collectionID = UUID()
        let requestID = UUID()
        let collectionDirectory = collectionsURL.appendingPathComponent(collectionID.uuidString, isDirectory: true)
        let snapshotsDirectory = root.appendingPathComponent("snapshots", isDirectory: true)
        let snapshotID = UUID()
        let snapshotDirectory = snapshotsDirectory.appendingPathComponent(snapshotID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: collectionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let globalEnvelope = try await vault.encrypt("secret-value-global")
        let collectionEnvelope = try await vault.encrypt("secret-value-collection")
        let collectionPassword = try await vault.encrypt("secret-value-collection-auth")
        let requestEnvelope = try await vault.encrypt("secret-value-request")
        let requestToken = try await vault.encrypt("secret-value-request-auth")
        let snapshotEnvelope = try await vault.encrypt("secret-value-snapshot")
        let automationEnvelope = try await vault.encrypt("secret-value-automation")

        var globalEnvelopeObject = try envelopeObject(globalEnvelope)
        globalEnvelopeObject["futureEnvelopeField"] = ["retained": true]
        let globalsURL = root.appendingPathComponent("globals.json")
        try writeJSON(
            [
                "formatVersion": 1,
                "variables": ["globalSecret": globalEnvelopeObject],
                "httpOptions": try jsonObject(HTTPOptions()),
                "futureRootField": ["retained": true],
            ], to: globalsURL)

        let collectionURL = collectionDirectory.appendingPathComponent("collection.json")
        let collectionVariables: VariableValues = ["collectionSecret": .encrypted(collectionEnvelope)]
        try writeJSON(
            [
                "formatVersion": 1,
                "name": "Fixture",
                "variables": try jsonObject(collectionVariables),
                "authentication": try jsonObject(
                    RequestAuthentication(
                        kind: .basic,
                        username: "fixture-user",
                        password: collectionPassword
                    )),
                "requests": [requestID.uuidString],
                "futureCollectionField": "retained",
            ], to: collectionURL)

        var requestConfiguration = HTTPRequestConfiguration(
            id: requestID,
            name: "Fixture request",
            method: "GET",
            url: "https://example.invalid/",
            variables: ["requestSecret": .encrypted(requestEnvelope)],
            authentication: RequestAuthentication(kind: .bearer, token: requestToken)
        )
        requestConfiguration.bodySyntax = .none
        var requestObject = try jsonObject(requestConfiguration)
        requestObject.removeValue(forKey: "id")
        requestObject["formatVersion"] = 1
        requestObject["futureRequestField"] = ["retained": true]
        let requestURL = collectionDirectory.appendingPathComponent("\(requestID.uuidString).json")
        try writeJSON(requestObject, to: requestURL)

        let automationURL = root.appendingPathComponent("automation.json")
        try writeJSON(
            [
                "formatVersion": 1,
                "token": try envelopeObject(automationEnvelope),
                "futureAutomationField": true,
            ], to: automationURL)

        let responseBody = Data([0, 255, 1, 128, 42])
        let responseBodyURL = snapshotDirectory.appendingPathComponent("response.body")
        try responseBody.write(to: responseBodyURL)
        let snapshotURL = snapshotDirectory.appendingPathComponent("snapshot.json")
        let template = SnapshotRequestTemplate(configuration: requestConfiguration)
        let source = SnapshotSource(
            identity: RequestIdentity(collectionID: collectionID, requestID: requestID),
            collectionName: "Fixture",
            requestName: "Fixture request"
        )
        try writeJSON(
            [
                "version": 1,
                "name": "Fixture snapshot",
                "capturedAt": try jsonValue(Date()),
                "source": try jsonObject(source),
                "originalRunID": UUID().uuidString,
                "template": try jsonObject(template),
                "preparationVersion": 1,
                "encryptedContext": try envelopeObject(snapshotEnvelope),
                "response": [
                    "statusCode": 200,
                    "headers": [],
                    "bodyByteCount": responseBody.count,
                    "duration": 0.1,
                    "redirectLimitReached": false,
                    "effectiveMethod": "GET",
                    "redirects": [],
                ],
                "futureSnapshotField": ["retained": true],
            ], to: snapshotURL)

        return WorkspaceFixture(
            rootURL: root,
            globalsURL: globalsURL,
            collectionURL: collectionURL,
            requestURL: requestURL,
            snapshotURL: snapshotURL,
            responseBodyURL: responseBodyURL,
            automationURL: automationURL,
            metadataURL: root.appendingPathComponent("workspace-encryption.json"),
            responseBody: responseBody,
            expectedPlaintextsByPath: [
                globalsURL.path: ["secret-value-global"],
                collectionURL.path: ["secret-value-collection", "secret-value-collection-auth"],
                requestURL.path: ["secret-value-request", "secret-value-request-auth"],
                snapshotURL.path: ["secret-value-snapshot"],
                automationURL.path: ["secret-value-automation"],
            ]
        )
    }

    private func assertFixtureLoads(_ fixture: WorkspaceFixture, vault: SecretVault) async throws {
        let collectionStore = try CollectionStore(rootURL: fixture.rootURL)
        let workspace = try await collectionStore.load()
        XCTAssertTrue(workspace.issues.isEmpty)
        XCTAssertEqual(workspace.collections.count, 1)
        let snapshots = try await SnapshotStore(
            rootURL: fixture.rootURL.appendingPathComponent("snapshots", isDirectory: true),
            vault: vault
        ).load()
        XCTAssertTrue(snapshots.issues.isEmpty)
        XCTAssertEqual(snapshots.snapshots.count, 1)
    }

    private func envelopeObject(_ envelope: SecretEnvelope) throws -> [String: Any] {
        try jsonObject(envelope)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        guard let object = try jsonValue(value) as? [String: Any] else {
            throw WorkspaceKeyRotationTestsError.invalidFixture
        }
        return object
    }

    private func jsonValue<Value: Encodable>(_ value: Value) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw WorkspaceKeyRotationTestsError.invalidFixture
        }
        return object
    }
}

private struct WorkspaceFixture {
    let rootURL: URL
    let globalsURL: URL
    let collectionURL: URL
    let requestURL: URL
    let snapshotURL: URL
    let responseBodyURL: URL
    let automationURL: URL
    let metadataURL: URL
    let responseBody: Data
    let expectedPlaintextsByPath: [String: [String]]

    var documentURLs: [URL] {
        [globalsURL, collectionURL, requestURL, snapshotURL, automationURL]
    }
}

private struct SimulatedRotationInterruption: Error {}

private enum WorkspaceKeyRotationTestsError: Error {
    case invalidFixture
}

private final class RotationTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var legacyKey: Data?
    private var identifiedKeys: [UUID: Data] = [:]

    init(legacyKey: Data? = nil) {
        self.legacyKey = legacyKey
    }

    var identifiedKeyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return identifiedKeys.count
    }

    func key(for id: UUID?) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let key = id.flatMap({ identifiedKeys[$0] }) ?? legacyKey else {
            throw SecretVaultError.missingKey
        }
        return key
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return legacyKey
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let legacyKey { return legacyKey }
        legacyKey = proposedKey
        return proposedKey
    }

    func loadKey(id: UUID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return identifiedKeys[id]
    }

    func createKey(_ proposedKey: Data, id: UUID) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let stored = identifiedKeys[id] { return stored }
        identifiedKeys[id] = proposedKey
        return proposedKey
    }
}
