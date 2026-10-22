import Foundation
import XCTest
@testable import PostieCore
@testable import PostieApp

@MainActor
final class OrderingAppTests: XCTestCase {
    func testCrossCollectionMovePreservesRequestAndSnapshotSourceAcrossRestart() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = OrderingTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        var firstModel: AppModel? = makeModel(root: root, secretVault: vault)
        let firstModelReference = WeakAppModelReference(firstModel)

        await firstModel?.createCollection(name: "Source")
        await firstModel?.createCollection(name: "Destination")
        await firstModel?.createCollection(name: "Other")
        let sourceCollection = try XCTUnwrap(firstModel?.collections.first { $0.name == "Source" })
        let destinationCollection = try XCTUnwrap(firstModel?.collections.first { $0.name == "Destination" })
        let otherCollection = try XCTUnwrap(firstModel?.collections.first { $0.name == "Other" })
        await firstModel?.createRequest(in: sourceCollection.id, name: "Move me")
        let identity = try XCTUnwrap(firstModel?.selectedIdentity)
        try firstModel?.setPlainVariable(name: "host", value: "source.example", owner: .collection(sourceCollection.id))
        try firstModel?.setPlainVariable(
            name: "host", value: "destination.example", owner: .collection(destinationCollection.id))
        firstModel?.updateDraft(identity) {
            $0.url = "https://{{host}}.invalid/{{sourceOnly}}"
        }
        await firstModel?.reorderCollections([destinationCollection.id, otherCollection.id, sourceCollection.id])
        try await firstModel?.flushPendingSaves()

        let requestURL = requestFileURL(root: root, identity: identity)
        let requestBytes = try Data(contentsOf: requestURL)
        let request = try XCTUnwrap(firstModel?.request(for: identity))
        var snapshotConfiguration = request
        snapshotConfiguration.url = "https://source.example.invalid/"
        let prepared = try await RequestPreparer.prepare(snapshotConfiguration, context: .init(), decryptor: nil)
        let source = SnapshotSource(
            identity: identity,
            collectionName: sourceCollection.name,
            requestName: request.name
        )
        let bodyURL = root.appendingPathComponent("snapshot-body", isDirectory: false).standardizedFileURL
        try Data("synthetic response".utf8).write(to: bodyURL)
        let runID = UUID()
        let response = HTTPResponseRecord(
            runID: runID,
            request: snapshotConfiguration,
            finalURL: try XCTUnwrap(prepared.request.url),
            statusCode: 200,
            requestHeaders: [],
            responseHeaders: [],
            redirects: [],
            bodyFileURL: bodyURL,
            bodyByteCount: Int64(try Data(contentsOf: bodyURL).count),
            duration: 0,
            snapshotCapture: prepared.snapshotCapture
        )
        let snapshotStore = SnapshotStore(
            rootURL: root.appendingPathComponent("data/snapshots", isDirectory: true),
            vault: vault
        )
        let snapshot = try await snapshotStore.save(
            response: response,
            source: source,
            name: "Original capture",
            bodyLease: HTTPBodyLease(token: UUID(), runID: runID, bodyURL: bodyURL)
        )

        let firstTerminated = await firstModel?.prepareForTermination()
        XCTAssertEqual(firstTerminated, true)
        firstModel = nil
        try await waitUntil { firstModelReference.value == nil }

        var model: AppModel? = makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        let modelReference = WeakAppModelReference(model)
        try await waitUntil { model?.snapshots.contains(where: { $0.id == snapshot.id }) == true }
        let reloadedRequest = RequestIdentity(collectionID: sourceCollection.id, requestID: identity.requestID)
        model?.select(reloadedRequest)
        await model?.moveRequest(reloadedRequest, toCollectionID: destinationCollection.id)

        let movedIdentity = RequestIdentity(collectionID: destinationCollection.id, requestID: identity.requestID)
        XCTAssertEqual(model?.selectedIdentity, movedIdentity)
        XCTAssertEqual(
            model?.collections.map(\.id), [destinationCollection.id, otherCollection.id, sourceCollection.id])
        XCTAssertNil(model?.request(for: reloadedRequest))
        let movedRequest = try XCTUnwrap(model?.request(for: movedIdentity))
        XCTAssertEqual(movedRequest.url, "https://{{host}}.invalid/{{sourceOnly}}")
        XCTAssertEqual(try Data(contentsOf: requestFileURL(root: root, identity: movedIdentity)), requestBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))
        XCTAssertEqual(model?.variableContext(for: movedIdentity).collection["host"], .plain("destination.example"))
        var resolvableRequest = movedRequest
        resolvableRequest.url = "https://{{host}}.invalid/"
        let destinationPrepared = try await RequestPreparer.prepare(
            resolvableRequest,
            context: try XCTUnwrap(model?.variableContext(for: movedIdentity)),
            decryptor: nil
        )
        XCTAssertEqual(destinationPrepared.request.url?.host, "destination.example.invalid")
        do {
            _ = try await RequestPreparer.prepare(
                movedRequest,
                context: try XCTUnwrap(model?.variableContext(for: movedIdentity)),
                decryptor: nil
            )
            XCTFail("A source-only reference should remain unresolved after the move.")
        } catch {}

        let movedSnapshot = try XCTUnwrap(model?.snapshots.first { $0.id == snapshot.id })
        XCTAssertEqual(movedSnapshot.source, source)
        XCTAssertEqual(model?.snapshotGrouping(for: movedSnapshot).identity, movedIdentity)
        XCTAssertEqual(model?.snapshots(for: movedIdentity).map(\.id), [snapshot.id])
        model?.selectSnapshot(snapshot.id)
        try await waitUntil { model?.openedSnapshots[snapshot.id] != nil }
        XCTAssertEqual(model?.openedSnapshots[snapshot.id]?.summary.source, source)

        let terminated = await model?.prepareForTermination()
        XCTAssertEqual(terminated, true)
        model = nil
        try await waitUntil { modelReference.value == nil }

        let restarted = makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { restarted.snapshots.contains(where: { $0.id == snapshot.id }) }
        XCTAssertEqual(
            restarted.collections.map(\.id), [destinationCollection.id, otherCollection.id, sourceCollection.id])
        XCTAssertEqual(
            restarted.snapshotGrouping(for: try XCTUnwrap(restarted.snapshots.first { $0.id == snapshot.id })).identity,
            movedIdentity)
        XCTAssertEqual(try Data(contentsOf: requestFileURL(root: root, identity: movedIdentity)), requestBytes)
        let restartedTerminated = await restarted.prepareForTermination()
        XCTAssertTrue(restartedTerminated)
    }

    func testMoveRefusesRequestWhileItIsPreparingToRun() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        await model.createCollection(name: "Source")
        await model.createCollection(name: "Destination")
        let source = try XCTUnwrap(model.collections.first { $0.name == "Source" })
        let destination = try XCTUnwrap(model.collections.first { $0.name == "Destination" })
        await model.createRequest(in: source.id, name: "Running request")
        let identity = try XCTUnwrap(model.selectedIdentity)
        model.updateDraft(identity) { $0.url = "http://127.0.0.1:1/" }
        try await model.flushPendingSaves()

        model.startRequest(identity)
        XCTAssertEqual(model.activeRuns[identity]?.phase, .preparing)
        await model.moveRequest(identity, toCollectionID: destination.id)

        XCTAssertEqual(model.operationError, "Stop the request before moving it to another collection.")
        XCTAssertNotNil(model.request(for: identity))
        XCTAssertNil(model.request(for: RequestIdentity(collectionID: destination.id, requestID: identity.requestID)))
        await model.cancelAndWait(for: identity)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testExcludedRequestDeletionRetainsSnapshotMCPExclusionUntilSnapshotDelete() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = OrderingTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        var sourceModel: AppModel? = makeModel(root: root, secretVault: vault)
        let sourceModelReference = WeakAppModelReference(sourceModel)

        await sourceModel?.createCollection(name: "Zulu")
        await sourceModel?.createCollection(name: "Excluded source")
        await sourceModel?.createCollection(name: "Alpha")
        let zulu = try XCTUnwrap(sourceModel?.collections.first { $0.name == "Zulu" })
        let collection = try XCTUnwrap(sourceModel?.collections.first { $0.name == "Excluded source" })
        let alpha = try XCTUnwrap(sourceModel?.collections.first { $0.name == "Alpha" })
        await sourceModel?.createRequest(in: collection.id, name: "Excluded request")
        let identity = try XCTUnwrap(sourceModel?.selectedIdentity)
        sourceModel?.updateDraft(identity) { $0.mcpPolicy.excluded = true }
        try await sourceModel?.flushPendingSaves()
        let request = try XCTUnwrap(sourceModel?.request(for: identity))

        let sourceTerminated = await sourceModel?.prepareForTermination()
        XCTAssertEqual(sourceTerminated, true)
        sourceModel = nil
        try await waitUntil { sourceModelReference.value == nil }

        let snapshot = try await makeSyntheticSnapshot(
            root: root,
            vault: vault,
            request: request,
            source: SnapshotSource(identity: identity, collectionName: collection.name, requestName: request.name)
        )
        var model: AppModel? = makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        let modelReference = WeakAppModelReference(model)
        try await waitUntil { model?.snapshots.contains(where: { $0.id == snapshot.id }) == true }

        XCTAssertTrue(try XCTUnwrap(model).snapshotIsMCPExcluded(snapshot))
        await model?.deleteRequest(identity)

        XCTAssertNil(model?.request(for: identity))
        XCTAssertTrue(model?.workspaceIndex.mcpExcludedSnapshotIDs.contains(snapshot.id) == true)
        XCTAssertTrue(try XCTUnwrap(model).snapshotIsMCPExcluded(snapshot))

        let modelTerminated = await model?.prepareForTermination()
        XCTAssertEqual(modelTerminated, true)
        model = nil
        try await waitUntil { modelReference.value == nil }

        let restarted = makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { restarted.snapshots.contains(where: { $0.id == snapshot.id }) }
        XCTAssertEqual(restarted.collections.map(\.id), [zulu.id, collection.id, alpha.id])
        XCTAssertTrue(restarted.snapshotIsMCPExcluded(snapshot))

        await restarted.deleteSnapshot(id: snapshot.id)
        XCTAssertFalse(restarted.workspaceIndex.mcpExcludedSnapshotIDs.contains(snapshot.id))
        let restartedTerminated = await restarted.prepareForTermination()
        XCTAssertTrue(restartedTerminated)
    }

    func testNavigationHistoryRemapsRequestAndVariableLocations() {
        var history = NavigationHistory()
        let oldIdentity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let newIdentity = RequestIdentity(collectionID: UUID(), requestID: oldIdentity.requestID)
        history.visit(.request(oldIdentity, section: .request))
        history.visit(.requestVariableDefinition(oldIdentity, name: "host"))

        history.remapRequest(from: oldIdentity, to: newIdentity)

        XCTAssertEqual(
            history.locations,
            [
                .request(newIdentity, section: .request),
                .requestVariableDefinition(newIdentity, name: "host"),
            ])
    }

    private func makeModel(root: URL, secretVault: SecretVault? = nil) -> AppModel {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        return AppModel(
            arguments: [
                "PostieOrderingTests",
                "--data-directory", dataDirectory.path,
                "--body-directory", bodyDirectory.path,
            ], secretVault: secretVault)
    }

    private func makeSyntheticSnapshot(
        root: URL,
        vault: SecretVault,
        request: HTTPRequestConfiguration,
        source: SnapshotSource
    ) async throws -> SavedSnapshot {
        var snapshotRequest = request
        snapshotRequest.url = "https://snapshot.example.invalid/"
        let prepared = try await RequestPreparer.prepare(snapshotRequest, context: .init(), decryptor: nil)
        let bodyURL = root.appendingPathComponent("snapshot-body-\(UUID().uuidString)")
        try Data("synthetic response".utf8).write(to: bodyURL)
        let runID = UUID()
        let body = try Data(contentsOf: bodyURL)
        let response = HTTPResponseRecord(
            runID: runID,
            request: snapshotRequest,
            finalURL: try XCTUnwrap(prepared.request.url),
            statusCode: 200,
            requestHeaders: [],
            responseHeaders: [],
            redirects: [],
            bodyFileURL: bodyURL,
            bodyByteCount: Int64(body.count),
            duration: 0,
            snapshotCapture: prepared.snapshotCapture
        )
        let snapshotStore = SnapshotStore(
            rootURL: root.appendingPathComponent("data/snapshots", isDirectory: true),
            vault: vault
        )
        return try await snapshotStore.save(
            response: response,
            source: source,
            name: "Synthetic capture",
            bodyLease: HTTPBodyLease(token: UUID(), runID: runID, bodyURL: bodyURL)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieOrderingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func requestFileURL(root: URL, identity: RequestIdentity) -> URL {
        root.appendingPathComponent(
            "data/collections/\(identity.collectionID.uuidString.lowercased())/\(identity.requestID.uuidString.lowercased()).json"
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the app model to reach the expected state.")
    }
}

@MainActor
private final class WeakAppModelReference {
    weak var value: AppModel?

    init(_ value: AppModel?) {
        self.value = value
    }
}

private final class OrderingTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: Data?

    func loadKey() throws -> Data? {
        lock.withLock { storedKey }
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.withLock {
            if let storedKey { return storedKey }
            storedKey = proposedKey
            return proposedKey
        }
    }
}
