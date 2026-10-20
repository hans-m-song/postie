import AppKit
import SwiftUI
import XCTest
@testable import PostieCore
@testable import PostieApp

@MainActor
final class SnapshotNavigationTests: XCTestCase {
    func testStaleSnapshotDetailTaskCannotReclaimNavigationOrHistory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let keyStore = SnapshotNavigationKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let snapshot = try await makeSyntheticSnapshot(root: root, vault: vault)
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.snapshots.contains(where: { $0.id == snapshot.id }) }

        await model.createCollection(name: "Synthetic collection")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Synthetic request")
        let requestIdentity = try XCTUnwrap(model.selectedIdentity)

        model.selectSnapshot(snapshot.id)
        try await waitUntil { model.openedSnapshots[snapshot.id] != nil }
        model.showCollection(collection.id)

        XCTAssertNil(model.selectedSnapshotID)
        XCTAssertEqual(model.selectedCollectionID, collection.id)
        XCTAssertTrue(model.openedSnapshots.isEmpty)

        let appeared = expectation(description: "stale snapshot detail is hosted")
        let hostingController = NSHostingController(
            rootView: SnapshotDetailView(snapshotID: snapshot.id, layout: .sideBySide)
                .environmentObject(model)
                .onAppear { appeared.fulfill() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        defer { window.close() }
        window.contentViewController = hostingController
        window.orderFrontRegardless()
        hostingController.view.layoutSubtreeIfNeeded()
        await fulfillment(of: [appeared], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(model.selectedSnapshotID)
        XCTAssertEqual(model.selectedCollectionID, collection.id)
        XCTAssertTrue(model.openedSnapshots.isEmpty)

        model.navigateBack()
        XCTAssertEqual(model.selectedSnapshotID, snapshot.id)
        model.navigateBack()
        XCTAssertEqual(model.selectedIdentity, requestIdentity)
        XCTAssertNil(model.selectedSnapshotID)

        model.navigateForward()
        XCTAssertEqual(model.selectedSnapshotID, snapshot.id)
        model.navigateForward()
        XCTAssertEqual(model.selectedCollectionID, collection.id)
        XCTAssertNil(model.selectedSnapshotID)

        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    private func makeSyntheticSnapshot(root: URL, vault: SecretVault) async throws -> SavedSnapshot {
        let request = HTTPRequestConfiguration(
            name: "Captured request",
            method: "GET",
            url: "https://snapshot.example.invalid/"
        )
        let prepared = try await RequestPreparer.prepare(request, context: .init(), decryptor: nil)
        let bodyURL = root.appendingPathComponent("snapshot-body")
        let body = Data("synthetic response".utf8)
        try body.write(to: bodyURL)

        let runID = UUID()
        let response = HTTPResponseRecord(
            runID: runID,
            request: request,
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
        let store = SnapshotStore(
            rootURL: root.appendingPathComponent("data/snapshots", isDirectory: true),
            vault: vault
        )
        return try await store.save(
            response: response,
            source: SnapshotSource(
                identity: RequestIdentity(collectionID: UUID(), requestID: request.id),
                collectionName: "Historical collection",
                requestName: request.name
            ),
            name: "Synthetic snapshot",
            bodyLease: HTTPBodyLease(token: UUID(), runID: runID, bodyURL: bodyURL)
        )
    }

    private func makeModel(root: URL, keyStore: SnapshotNavigationKeyStore) -> AppModel {
        AppModel(
            arguments: [
                "PostieSnapshotNavigationTests",
                "--data-directory", root.appendingPathComponent("data", isDirectory: true).path,
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path
            ],
            secretVault: SecretVault(keyStore: keyStore)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieSnapshotNavigationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the model to reach the expected state.")
    }
}

private final class SnapshotNavigationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let key = Data(repeating: 0x6d, count: 32)

    func loadKey() throws -> Data? { key }
    func createKey(_ proposedKey: Data) throws -> Data { key }
}
