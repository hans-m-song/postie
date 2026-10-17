import Darwin
import Dispatch
import Foundation
import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class AppModelTests: XCTestCase {
    func testFlushPersistsLatestEditAndNavigationRetainsOtherDrafts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "First")
        await model.createRequest(in: collection.id, name: "Second")
        let requests = try XCTUnwrap(model.collections.first?.requests)
        let first = identity(collection.id, try XCTUnwrap(requests.first { $0.name == "First" }))
        let second = identity(collection.id, try XCTUnwrap(requests.first { $0.name == "Second" }))

        model.updateDraft(first) { request in
            request.url = "http://example.test/edited"
            request.body = "last edit before flush"
            request.bodyEnabled = true
        }
        model.select(second)
        XCTAssertEqual(model.request(for: first)?.body, "last edit before flush")
        XCTAssertEqual(model.selectedIdentity, second)

        try await model.flushPendingSaves()

        let stored = try readRequest(root: root, identity: first)
        XCTAssertEqual(stored["url"] as? String, "http://example.test/edited")
        XCTAssertEqual(stored["body"] as? String, "last edit before flush")
        XCTAssertEqual(stored["bodyEnabled"] as? Bool, true)
        XCTAssertNil(model.autosaveErrors[first])
    }

    func testOverlappingCollectionMutationsPreserveEveryCreatedRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Before")
        let collectionID = try XCTUnwrap(model.collections.first?.id)

        let rename = Task { @MainActor in await model.renameCollection(id: collectionID, name: "After") }
        let createTasks = (0..<6).map { index in
            Task { @MainActor in await model.createRequest(in: collectionID, name: "Request \(index)") }
        }
        await rename.value
        for task in createTasks { await task.value }

        let collection = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        XCTAssertEqual(collection.name, "After")
        XCTAssertEqual(collection.requests.count, 6)
        XCTAssertEqual(Set(collection.requests.map(\.id)).count, 6)

        let reversedIDs = collection.requests.map(\.id).reversed()
        await model.reorderRequests(Array(reversedIDs), in: collectionID)
        let reordered = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        XCTAssertEqual(reordered.requests.map(\.id), Array(reversedIDs))
        try await model.flushPendingSaves()
    }

    func testSaveFailureKeepsDraftAndBlocksTermination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Protected")
        let request = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, request)
        let requestURL = requestFileURL(root: root, identity: requestIdentity)
        try setImmutable(requestURL, enabled: true)
        defer { try? setImmutable(requestURL, enabled: false) }

        model.updateDraft(requestIdentity) { $0.name = "Unsaved latest edit" }

        do {
            try await model.flushPendingSaves()
            XCTFail("An immutable request file must report a failed save.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not save pending changes"))
        }
        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved latest edit")
        XCTAssertNotNil(model.autosaveErrors[requestIdentity])
        let canTerminate = await model.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertFalse(model.isTerminating)
        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved latest edit")
    }

    func testDeletingRequestGatesEditingAndWaitsForActiveRunSettlement() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Slow request")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let slowURL = try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "2")])
        model.updateDraft(requestIdentity) { $0.url = slowURL }
        try await model.flushPendingSaves()

        model.startRequest(requestIdentity)
        try await waitUntil { model.activeRuns[requestIdentity]?.runID != nil }
        let deletion = Task { @MainActor in await model.deleteRequest(requestIdentity) }
        await Task.yield()
        XCTAssertTrue(model.deletingRequests.contains(requestIdentity))
        XCTAssertFalse(model.canEdit(requestIdentity))
        XCTAssertNotNil(model.activeRuns[requestIdentity])

        await deletion.value

        XCTAssertNil(model.activeRuns[requestIdentity])
        XCTAssertNil(model.request(for: requestIdentity))
        XCTAssertFalse(model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
    }

    func testPartialDeletionOrphanCannotBeEditedOrStartedFromStaleDraft() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Orphan candidate")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        model.updateDraft(requestIdentity) { $0.url = fixture.baseURL + "/echo" }
        try await model.flushPendingSaves()

        let requestURL = requestFileURL(root: root, identity: requestIdentity)
        try setImmutable(requestURL, enabled: true)
        defer { try? setImmutable(requestURL, enabled: false) }
        await model.deleteRequest(requestIdentity)

        XCTAssertFalse(model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
        XCTAssertTrue(model.storageIssues.contains { $0.requestID == configuration.id && $0.canRecover })
        XCTAssertFalse(model.canEdit(requestIdentity))

        model.startRequest(requestIdentity)
        XCTAssertNil(model.activeRuns[requestIdentity], "An unindexed orphan must not be sent through its stale draft.")
        if model.activeRuns[requestIdentity] != nil {
            await model.cancelAndWait(for: requestIdentity)
        }
    }

    func testMutationReloadPreservesDirtyDraftWhenCollectionMembershipIsUnknown() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Draft owner")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let slowURL = try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "2")])
        model.updateDraft(requestIdentity) {
            $0.name = "Unsaved edit retained"
            $0.url = slowURL
        }

        let metadataURL = root.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(collectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("collection.json")
        try Data("{ malformed collection metadata".utf8).write(to: metadataURL, options: .atomic)
        await model.renameCollection(id: collectionID, name: "Cannot be saved")

        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved edit retained")
        XCTAssertTrue(model.collections.first { $0.id == collectionID }?.isReadOnly == true)
        XCTAssertFalse(model.canEdit(requestIdentity))
        XCTAssertTrue(model.storageIssues.contains {
            $0.collectionID == collectionID && $0.requestID == nil && $0.id.hasPrefix("store:collection-metadata-malformed:")
        })

        model.startRequest(requestIdentity)
        XCTAssertNil(model.activeRuns[requestIdentity], "Unknown collection membership must keep a retained draft from being sent.")
        if model.activeRuns[requestIdentity] != nil {
            await model.cancelAndWait(for: requestIdentity)
        }
    }

    func testDeletingCollectionClearsRetainedMalformedDraftAfterOrphanRecovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Malformed request")
        await model.createRequest(in: collectionID, name: "Orphan request")
        let collection = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        let malformedRequest = try XCTUnwrap(collection.requests.first { $0.name == "Malformed request" })
        let orphanRequest = try XCTUnwrap(collection.requests.first { $0.name == "Orphan request" })
        let malformedIdentity = identity(collectionID, malformedRequest)
        let orphanIdentity = identity(collectionID, orphanRequest)
        let malformedURL = requestFileURL(root: root, identity: malformedIdentity)
        let orphanURL = requestFileURL(root: root, identity: orphanIdentity)

        model.updateDraft(malformedIdentity) { $0.name = "Unsaved malformed draft" }
        try Data("{ malformed request".utf8).write(to: malformedURL, options: .atomic)
        try setImmutable(orphanURL, enabled: true)
        defer {
            if FileManager.default.fileExists(atPath: orphanURL.path) {
                try? setImmutable(orphanURL, enabled: false)
            }
        }

        await model.deleteRequest(orphanIdentity)
        let orphanIssue = try XCTUnwrap(model.storageIssues.first {
            $0.requestID == orphanIdentity.requestID && $0.canRecover
        })
        await model.recover(orphanIssue)
        try await waitUntil { model.autosaveErrors[malformedIdentity] != nil }
        XCTAssertEqual(model.request(for: malformedIdentity)?.name, "Unsaved malformed draft")

        try setImmutable(orphanURL, enabled: false)
        await model.deleteCollection(id: collectionID)

        XCTAssertFalse(model.collections.contains { $0.id == collectionID })
        XCTAssertNil(model.request(for: malformedIdentity))
        XCTAssertNil(model.autosaveErrors[malformedIdentity])
        XCTAssertFalse(model.drafts.keys.contains { $0.collectionID == collectionID })

        let canTerminate = await model.prepareForTermination()
        XCTAssertTrue(canTerminate)
    }

    func testManualRedirectUsesCapturedHopAndPreservesEditedDraft() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Redirected request")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let redirectURL = try fixture.url(path: "/redirect", query: [
            URLQueryItem(name: "to", value: "/echo"),
            URLQueryItem(name: "status", value: "302")
        ])
        model.updateDraft(requestIdentity) {
            $0.method = "POST"
            $0.url = redirectURL
            $0.body = "submitted body"
            $0.bodyEnabled = true
        }
        try await model.flushPendingSaves()

        model.startRequest(requestIdentity)
        try await waitUntil {
            model.activeRuns[requestIdentity] == nil && model.latestResponses[requestIdentity]?.response.statusCode == 302
        }
        XCTAssertTrue(model.canFollowRedirect(requestIdentity))

        let editedURL = try fixture.url(path: "/echo", query: [URLQueryItem(name: "draft", value: "preserved")])
        model.updateDraft(requestIdentity) {
            $0.method = "PUT"
            $0.url = editedURL
            $0.body = "later edit"
            $0.options.followRedirects = true
        }
        try await model.flushPendingSaves()

        model.followRedirect(requestIdentity)
        let active = try XCTUnwrap(model.activeRuns[requestIdentity])
        XCTAssertEqual(active.request.method, "GET")
        XCTAssertEqual(active.request.url, fixture.baseURL + "/echo")
        XCTAssertEqual(active.redirects.count, 1)
        XCTAssertFalse(model.canFollowRedirect(requestIdentity))

        try await waitUntil {
            model.activeRuns[requestIdentity] == nil && model.latestResponses[requestIdentity]?.response.statusCode == 200
        }
        let finalResponse = try XCTUnwrap(model.latestResponses[requestIdentity]?.response)
        XCTAssertEqual(finalResponse.finalURL.path, "/echo")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: finalResponse.bodyFileURL)) as? [String: Any])
        XCTAssertEqual(payload["method"] as? String, "GET")
        XCTAssertEqual(payload["path"] as? String, "/echo")
        XCTAssertEqual(payload["query"] as? String, "")
        XCTAssertEqual(payload["body"] as? String, "")

        let currentDraft = try XCTUnwrap(model.request(for: requestIdentity))
        XCTAssertEqual(currentDraft.method, "PUT")
        XCTAssertEqual(currentDraft.url, editedURL)
        XCTAssertEqual(currentDraft.body, "later edit")
        XCTAssertTrue(currentDraft.options.followRedirects)
        try await model.flushPendingSaves()
        let stored = try readRequest(root: root, identity: requestIdentity)
        XCTAssertEqual(stored["method"] as? String, "PUT")
        XCTAssertEqual(stored["url"] as? String, editedURL)
        XCTAssertEqual(stored["body"] as? String, "later edit")
        let storedOptions = try XCTUnwrap(stored["options"] as? [String: Any])
        XCTAssertEqual(storedOptions["followRedirects"] as? Bool, true)

        _ = await model.prepareForTermination()
    }

    private func makeModel(root: URL) throws -> AppModel {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        return AppModel(arguments: [
            "PostieTests",
            "--data-directory", dataDirectory.path,
            "--body-directory", bodyDirectory.path
        ])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieAppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func identity(_ collectionID: UUID, _ request: HTTPRequestConfiguration) -> RequestIdentity {
        RequestIdentity(collectionID: collectionID, requestID: request.id)
    }

    private func requestFileURL(root: URL, identity: RequestIdentity) -> URL {
        root.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(identity.collectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("\(identity.requestID.uuidString.lowercased()).json")
    }

    private func readRequest(root: URL, identity: RequestIdentity) throws -> [String: Any] {
        let data = try Data(contentsOf: requestFileURL(root: root, identity: identity))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func setImmutable(_ url: URL, enabled: Bool) throws {
        let flags = enabled ? UInt32(UF_IMMUTABLE) : 0
        let result = url.path.withCString { Darwin.chflags($0, flags) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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

private final class AppHTTPFixture {
    private let process: Process
    private let termination: DispatchSemaphore
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fixtureExecutable = Bundle(for: AppModelTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PostieHTTPFixture")
        let output = Pipe()
        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = fixtureExecutable
        process.arguments = ["--port", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { @Sendable _ in termination.signal() }
        self.process = process
        self.termination = termination
        try process.run()

        do {
            let line = try Self.readLine(from: output.fileHandleForReading)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int])
            self.port = try XCTUnwrap(value["port"])
        } catch {
            Self.stop(process: process, termination: termination)
            throw error
        }
    }

    deinit {
        Self.stop(process: process, termination: termination)
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> String {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = query.isEmpty ? nil : query
        return try XCTUnwrap(components?.url?.absoluteString)
    }

    private static func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            guard let byte = chunk.first else { throw FixtureError.didNotStart }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func stop(process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }

        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        XCTFail("The HTTP fixture process did not terminate after SIGKILL.")
    }

    private enum FixtureError: Error {
        case didNotStart
    }
}
