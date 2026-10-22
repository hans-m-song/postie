import AppKit
import CoreGraphics
import PDFKit
import SwiftUI
import XCTest
@testable import PostieCore
@testable import PostieApp

@MainActor
final class SnapshotNavigationTests: XCTestCase {
    func testOpenedPDFSnapshotLoadsInsideNativeSplitHost() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("fixture.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(pdfURL as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let keyStore = SnapshotNavigationKeyStore()
        let snapshot = try await makeSyntheticSnapshot(
            root: root, vault: SecretVault(keyStore: keyStore, allowsKeyCreation: true),
            body: Data(contentsOf: pdfURL), isPDF: true)
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.snapshots.contains(where: { $0.id == snapshot.id }) }
        model.selectSnapshot(snapshot.id)
        try await waitUntil { model.openedSnapshots[snapshot.id] != nil }
        let host = NSHostingController(
            rootView: SnapshotDetailView(snapshotID: snapshot.id, layout: .sideBySide).environmentObject(model))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        defer { window.close() }
        window.contentViewController = host
        host.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.orderFrontRegardless()
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        scrollToBottom(in: host.view)
        try await waitUntil { self.loadedPDFView(in: host.view) != nil }
        XCTAssertEqual(loadedPDFView(in: host.view)?.document?.pageCount, 1)
        let initialHeight = try XCTUnwrap(loadedPDFView(in: host.view)).bounds.height
        window.setContentSize(NSSize(width: 1000, height: 1200))
        host.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 1200)
        host.view.layoutSubtreeIfNeeded()
        try await waitUntil {
            (self.loadedPDFView(in: host.view)?.bounds.height ?? 0) > initialHeight + 250
        }
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
        XCTAssertNil(loadedPDFView(in: host.view))
    }

    private func loadedPDFView(in view: NSView) -> PDFView? {
        if let pdf = view as? PDFView, pdf.document != nil { return pdf }
        for child in view.subviews {
            if let pdf = loadedPDFView(in: child) { return pdf }
        }
        return nil
    }

    private func scrollToBottom(in view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            scroll.contentView.scroll(
                to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { scrollToBottom(in: child) }
    }

    func testDeletingSnapshotInvalidatesVisibleResourceBeforeRemovingBody() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = SnapshotNavigationKeyStore()
        let snapshot = try await makeSyntheticSnapshot(
            root: root, vault: SecretVault(keyStore: keyStore, allowsKeyCreation: true))
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.snapshots.contains(where: { $0.id == snapshot.id }) }
        model.selectSnapshot(snapshot.id)
        try await waitUntil { model.openedSnapshots[snapshot.id] != nil }
        let response = try XCTUnwrap(model.openedSnapshots[snapshot.id]?.response)
        let resource = try await model.acquireBodyResource(from: .snapshot(snapshot.id, response))
        var bodyExistedWhenConsumerCleared = false
        _ = resource.registerInvalidation {
            bodyExistedWhenConsumerCleared = FileManager.default.fileExists(atPath: resource.url.path)
        }

        await model.deleteSnapshot(id: snapshot.id)

        XCTAssertFalse(resource.isValid)
        XCTAssertTrue(bodyExistedWhenConsumerCleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        do {
            _ = try await model.acquireBodyResource(from: .snapshot(snapshot.id, response))
            XCTFail("Deleted snapshot resource was reacquired")
        } catch {}
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testTerminationInvalidatesVisibleSnapshotResource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = SnapshotNavigationKeyStore()
        let snapshot = try await makeSyntheticSnapshot(
            root: root, vault: SecretVault(keyStore: keyStore, allowsKeyCreation: true))
        let model = makeModel(root: root, keyStore: keyStore)
        try await waitUntil { model.snapshots.contains(where: { $0.id == snapshot.id }) }
        model.selectSnapshot(snapshot.id)
        try await waitUntil { model.openedSnapshots[snapshot.id] != nil }
        let response = try XCTUnwrap(model.openedSnapshots[snapshot.id]?.response)
        let resource = try await model.acquireBodyResource(from: .snapshot(snapshot.id, response))
        var cleared = false
        _ = resource.registerInvalidation { cleared = true }

        let terminated = await model.prepareForTermination()

        XCTAssertTrue(terminated)
        XCTAssertTrue(cleared)
        XCTAssertFalse(resource.isValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
    }

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

    private func makeSyntheticSnapshot(
        root: URL, vault: SecretVault, body suppliedBody: Data? = nil, isPDF: Bool = false
    ) async throws -> SavedSnapshot {
        let request = HTTPRequestConfiguration(
            name: "Captured request",
            method: "GET",
            url: "https://snapshot.example.invalid/"
        )
        let prepared = try await RequestPreparer.prepare(request, context: .init(), decryptor: nil)
        let bodyURL = root.appendingPathComponent("snapshot-body")
        let body = suppliedBody ?? Data("synthetic response".utf8)
        try body.write(to: bodyURL)

        let runID = UUID()
        let response = HTTPResponseRecord(
            runID: runID,
            request: request,
            finalURL: try XCTUnwrap(prepared.request.url),
            statusCode: 200,
            requestHeaders: [],
            responseHeaders: isPDF ? [HTTPField(name: "Content-Type", value: "application/pdf")] : [],
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
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path,
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
