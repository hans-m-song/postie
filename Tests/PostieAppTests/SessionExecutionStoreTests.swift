import Darwin
import Dispatch
import Foundation
import XCTest
@testable import PostieCore
@testable import PostieApp

@MainActor
final class SessionExecutionStoreTests: XCTestCase {
    func testTerminalCountLimitKeepsNewestStartedAndExemptsActiveEntries() async throws {
        let history = SessionExecutionStore()
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let oldestActive = active(identity: identity)
        history.begin(identity: identity, active: oldestActive)
        var terminalTokens: [UUID] = []
        for _ in 0..<12 {
            let run = active(identity: identity)
            history.begin(identity: identity, active: run)
            history.finish(token: run.token, phase: .failed, error: "Synthetic failure")
            terminalTokens.insert(run.token, at: 0)
        }
        XCTAssertEqual(history.entries.map(\.token), Array(terminalTokens.prefix(10)) + [oldestActive.token])
        XCTAssertEqual(history.entry(for: oldestActive.token)?.phase, .preparing)
        history.update(active(identity: identity, token: terminalTokens.last!))
        XCTAssertNil(history.entry(for: terminalTokens.last!))
        await history.clear()
    }

    func testPayloadBudgetEvictsOldestCompletedAndOversizedEntryRetainsBoundedSummary() async throws {
        let history = SessionExecutionStore(maximumRetainedBytes: 600)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let first = active(identity: identity, body: String(repeating: "a", count: 350))
        history.begin(identity: identity, active: first)
        history.finish(token: first.token, phase: .cancelled)
        let second = active(identity: identity, body: String(repeating: "b", count: 350))
        history.begin(identity: identity, active: second)
        history.finish(token: second.token, phase: .failed)
        XCTAssertNil(history.entry(for: first.token))
        XCTAssertNotNil(history.entry(for: second.token)?.request)

        let oversized = active(identity: identity, body: String(repeating: "x", count: 601))
        history.begin(identity: identity, active: oversized)
        XCTAssertNotNil(history.entry(for: oversized.token)?.request)
        history.finish(token: oversized.token, phase: .cancelled)
        let entry = try XCTUnwrap(history.entry(for: oversized.token))
        XCTAssertNil(entry.request)
        XCTAssertNil(entry.capture)
        XCTAssertNil(entry.response)
        XCTAssertTrue(entry.redirects.isEmpty)
        XCTAssertNotNil(entry.detailsUnavailableReason)
        XCTAssertEqual(entry.method, "GET")
        XCTAssertEqual(entry.requestName, "Frozen request")
        XCTAssertEqual(entry.source?.collectionName, "Frozen collection")
        await history.clear()
    }

    func testCaptureAndBodyAccountingIncludesResolvedInputsAndSaturates() async throws {
        let history = SessionExecutionStore(maximumRetainedBytes: 500)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        var run = active(identity: identity)
        run.snapshotCapture = SnapshotPreparationCapture(
            template: SnapshotRequestTemplate(configuration: run.request),
            referencedInputs: [
                "value": SnapshotInput(value: String(repeating: "z", count: 600), scope: .global, isSecret: true)
            ],
            authentication: SnapshotAuthenticationInput(kind: .none),
            submitted: SnapshotTransportRequest(
                method: "GET", url: URL(string: "https://example.invalid")!, headers: []))
        history.begin(identity: identity, active: run)
        history.finish(token: run.token, phase: .failed)
        XCTAssertNil(history.entry(for: run.token)?.capture)
        XCTAssertNotNil(history.entry(for: run.token)?.detailsUnavailableReason)

        let large = active(identity: identity)
        history.begin(identity: identity, active: large)
        let response = response(
            request: large.request, bodyURL: URL(fileURLWithPath: "/synthetic-unavailable"), byteCount: Int64.max)
        history.finish(token: large.token, phase: .completed, response: response)
        XCTAssertEqual(history.entry(for: large.token)?.bodyByteCount, Int64.max)
        XCTAssertNil(history.entry(for: large.token)?.response)
        await history.clear()
    }

    func testProgressSourceRemapAndTerminalStateRemainFrozen() async throws {
        let history = SessionExecutionStore()
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        var run = active(identity: identity)
        history.begin(identity: identity, active: run)
        run.phase = .running
        run.progress = HTTPProgress(receivedBytes: 23, expectedBytes: 100)
        run.redirects = [
            HTTPRedirect(
                statusCode: 302, url: URL(string: "https://example.invalid/old")!,
                nextURL: URL(string: "https://example.invalid/new")!, method: "GET", nextMethod: "GET",
                requestHeaders: [], responseHeaders: [])
        ]
        history.update(run)
        history.finish(token: run.token, phase: .cancelled)
        run.progress = HTTPProgress(receivedBytes: 99)
        history.update(run)
        let destination = RequestIdentity(collectionID: UUID(), requestID: identity.requestID)
        history.remapSource(from: identity, to: destination)
        XCTAssertEqual(history.entry(for: run.token)?.liveSourceIdentity, destination)
        XCTAssertEqual(history.entry(for: run.token)?.source?.identity, identity)
        XCTAssertEqual(history.entry(for: run.token)?.progress?.receivedBytes, 23)
        XCTAssertEqual(history.entry(for: run.token)?.redirects.count, 1)
        XCTAssertNil(history.entry(for: run.token)?.response)
        history.removeSource(destination)
        XCTAssertNil(history.entry(for: run.token)?.liveSourceIdentity)
        XCTAssertEqual(history.entry(for: run.token)?.source?.requestName, "Frozen request")
        await history.clear()
    }

    func testExactRunInspectionSurvivesLatestDiscardAndEvictionUntilOperationEnds() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root)
        let history = SessionExecutionStore(maximumCompletedEntries: 1)
        history.connect(to: manager)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let first = active(identity: identity)
        let firstResponse = try await ownedResponse(
            manager: manager, root: root, identity: identity, request: first.request, text: "first exact response")
        history.begin(identity: identity, active: first)
        await history.retainResponse(firstResponse, for: first.token)
        history.finish(token: first.token, phase: .completed, response: firstResponse)
        try await manager.discardBody(at: firstResponse.bodyFileURL)

        let exact = try await history.withRetainedResponse(for: first.token) { response, url in
            XCTAssertEqual(response.runID, firstResponse.runID)
            return try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(exact, "first exact response")

        var inspectorEntered = false
        var releaseInspector = false
        let inspection = Task { @MainActor in
            try await history.withRetainedResponse(for: first.token) { response, url in
                inspectorEntered = true
                try await self.waitUntil { releaseInspector }
                XCTAssertEqual(response.runID, firstResponse.runID)
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        defer {
            releaseInspector = true
            inspection.cancel()
        }
        try await waitUntil { inspectorEntered }
        let second = active(identity: identity)
        let secondResponse = try await ownedResponse(
            manager: manager, root: root, identity: identity, request: second.request, text: "second response")
        history.begin(identity: identity, active: second)
        await history.retainResponse(secondResponse, for: second.token)
        history.finish(token: second.token, phase: .completed, response: secondResponse)
        XCTAssertNil(history.entry(for: first.token))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstResponse.bodyFileURL.path))
        releaseInspector = true
        let inspected = try await inspection.value
        XCTAssertEqual(inspected, "first exact response")
        try await waitUntil { !FileManager.default.fileExists(atPath: firstResponse.bodyFileURL.path) }
        let newest = try await history.withRetainedResponse(for: second.token) { _, url in
            try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(newest, "second response")
        await history.clear()
        await manager.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondResponse.bodyFileURL.path))
    }

    func testLifecycleBridgePreparationFailureCancellationRerunMoveDeleteAndSessionReset() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        weak var previousModel: AppModel?
        do {
            let model = AppModel(
                arguments: [
                    "PostieTests", "--data-directory", root.appendingPathComponent("data").path,
                    "--body-directory", root.appendingPathComponent("bodies").path,
                ],
                secretVault: SecretVault(keyStore: SessionHistoryKeyStore()))
            previousModel = model
            XCTAssertNil(model.startupError)
            await model.createCollection(name: "Frozen collection")
            await model.createCollection(name: "Destination")
            let collection = try XCTUnwrap(model.collections.first { $0.name == "Frozen collection" })
            let destination = try XCTUnwrap(model.collections.first { $0.name == "Destination" })
            await model.createRequest(in: collection.id, name: "Frozen request")
            let identity = try XCTUnwrap(model.selectedIdentity)
            model.updateDraft(identity) { $0.url = "{{missing}}" }
            try await model.flushPendingSaves()
            let requestURL = root.appendingPathComponent(
                "data/collections/\(identity.collectionID.uuidString.lowercased())/\(identity.requestID.uuidString.lowercased()).json"
            )
            let originalBytes = try Data(contentsOf: requestURL)
            model.startRequest(identity)
            let failed = try XCTUnwrap(model.activeRuns[identity]?.token)
            try await waitUntil("preparation failure settlement") { model.activeRuns[identity] == nil }
            XCTAssertEqual(model.sessionHistory.entry(for: failed)?.phase, .failed)
            XCTAssertNotNil(model.sessionHistory.entry(for: failed)?.errorMessage)
            XCTAssertNil(model.sessionHistory.entry(for: failed)?.response)

            model.startRequest(identity)
            let cancelled = try XCTUnwrap(model.activeRuns[identity]?.token)
            model.cancelHistoryRun(token: cancelled)
            XCTAssertEqual(model.sessionHistory.entry(for: cancelled)?.phase, .cancelled)
            model.startRequest(identity)
            let newest = try XCTUnwrap(model.activeRuns[identity]?.token)
            model.cancelHistoryRun(token: cancelled)
            XCTAssertEqual(model.activeRuns[identity]?.token, newest)
            XCTAssertEqual(model.activeRuns[identity]?.cancelRequested, false)
            model.cancelHistoryRun(token: newest)
            XCTAssertEqual(model.sessionHistory.entries.map(\.token), [newest, cancelled, failed])
            XCTAssertEqual(try Data(contentsOf: requestURL), originalBytes)
            XCTAssertTrue(model.snapshots.isEmpty)
            await model.moveRequest(identity, toCollectionID: destination.id)
            let moved = RequestIdentity(collectionID: destination.id, requestID: identity.requestID)
            XCTAssertEqual(model.sessionHistory.entry(for: failed)?.liveSourceIdentity, moved)
            XCTAssertEqual(model.sessionHistory.entry(for: failed)?.source?.collectionName, "Frozen collection")
            model.openHistorySource(token: failed)
            XCTAssertEqual(model.selectedIdentity, moved)
            await model.deleteRequest(moved)
            XCTAssertNil(model.sessionHistory.entry(for: failed)?.liveSourceIdentity)
            XCTAssertEqual(model.sessionHistory.entry(for: failed)?.source?.requestName, "Frozen request")
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
            XCTAssertTrue(model.sessionHistory.entries.isEmpty)
        }
        try await waitUntil("original model release before reopening workspace") { previousModel == nil }
        let restarted = AppModel(
            arguments: [
                "PostieTests", "--data-directory", root.appendingPathComponent("data").path,
                "--body-directory", root.appendingPathComponent("bodies").path,
            ],
            secretVault: SecretVault(keyStore: SessionHistoryKeyStore()))
        XCTAssertNil(restarted.startupError)
        try await waitUntil("restarted workspace loads both collections") { restarted.collections.count == 2 }
        XCTAssertTrue(restarted.sessionHistory.entries.isEmpty)
        let restartedTerminated = await restarted.prepareForTermination()
        XCTAssertTrue(restartedTerminated)
    }

    func testCombinedUnderLimitCapturesAndBodiesEvictOldestEntry() async throws {
        let history = SessionExecutionStore(maximumRetainedBytes: 2_000)
        let captureOnlyHistory = SessionExecutionStore(maximumRetainedBytes: 2_000)
        let bodyOnlyHistory = SessionExecutionStore(maximumRetainedBytes: 2_000)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        var tokens: [UUID] = []
        for _ in 0..<2 {
            var run = active(identity: identity)
            let capture = SnapshotPreparationCapture(
                template: SnapshotRequestTemplate(configuration: run.request),
                referencedInputs: [
                    "input": SnapshotInput(value: String(repeating: "v", count: 200), scope: .request, isSecret: false)
                ],
                authentication: SnapshotAuthenticationInput(kind: .none),
                submitted: SnapshotTransportRequest(
                    method: "GET", url: URL(string: run.request.url)!, headers: []))
            run.snapshotCapture = capture
            let response = HTTPResponseRecord(
                runID: UUID(), request: run.request, finalURL: URL(string: run.request.url)!, statusCode: 200,
                requestHeaders: [], responseHeaders: [], redirects: [],
                bodyFileURL: URL(fileURLWithPath: "/synthetic-unavailable"), bodyByteCount: 500, duration: 0,
                snapshotCapture: capture)
            history.begin(identity: identity, active: run)
            history.finish(token: run.token, phase: .completed, response: response)
            XCTAssertNil(history.entry(for: run.token)?.detailsUnavailableReason)
            XCTAssertNotNil(history.entry(for: run.token)?.capture)
            captureOnlyHistory.begin(identity: identity, active: run)
            let captureOnlyResponse = HTTPResponseRecord(
                runID: UUID(), request: run.request, finalURL: URL(string: run.request.url)!, statusCode: 200,
                requestHeaders: [], responseHeaders: [], redirects: [],
                bodyFileURL: URL(fileURLWithPath: "/synthetic-unavailable"), bodyByteCount: 0, duration: 0,
                snapshotCapture: capture)
            captureOnlyHistory.finish(token: run.token, phase: .completed, response: captureOnlyResponse)
            var bodyOnlyRun = run
            bodyOnlyRun.snapshotCapture = nil
            bodyOnlyHistory.begin(identity: identity, active: bodyOnlyRun)
            let bodyOnlyResponse = self.response(
                request: run.request, bodyURL: URL(fileURLWithPath: "/synthetic-unavailable"), byteCount: 500)
            bodyOnlyHistory.finish(token: run.token, phase: .completed, response: bodyOnlyResponse)
            tokens.append(run.token)
        }
        XCTAssertEqual(captureOnlyHistory.entries.count, 2)
        XCTAssertEqual(bodyOnlyHistory.entries.count, 2)
        for token in tokens {
            XCTAssertNotNil(captureOnlyHistory.entry(for: token)?.capture)
            XCTAssertNil(captureOnlyHistory.entry(for: token)?.detailsUnavailableReason)
            XCTAssertNotNil(bodyOnlyHistory.entry(for: token)?.response)
            XCTAssertEqual(bodyOnlyHistory.entry(for: token)?.bodyByteCount, 500)
            XCTAssertNil(bodyOnlyHistory.entry(for: token)?.detailsUnavailableReason)
        }
        XCTAssertNil(history.entry(for: tokens[0]))
        XCTAssertEqual(history.entries.map(\.token), [tokens[1]])
        await history.clear()
        await captureOnlyHistory.clear()
        await bodyOnlyHistory.clear()
    }

    func testCompletedAppModelRerunPreservesExactOldBodyAndFrozenCapture() async throws {
        let fixture = try SessionHistoryHTTPFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            arguments: [
                "PostieTests", "--data-directory", root.appendingPathComponent("data").path,
                "--body-directory", root.appendingPathComponent("bodies").path,
            ],
            secretVault: SecretVault(keyStore: SessionHistoryKeyStore()))
        await model.createCollection(name: "Run capture")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "First run")
        let identity = try XCTUnwrap(model.selectedIdentity)
        model.updateDraft(identity) {
            $0.url = fixture.baseURL + "/echo"
            $0.method = "POST"
            $0.body = "first captured payload"
            $0.bodyEnabled = true
        }
        try await model.flushPendingSaves()
        model.startRequest(identity)
        let firstToken = try XCTUnwrap(model.activeRuns[identity]?.token)
        try await waitUntil { model.activeRuns[identity] == nil }
        let first = try XCTUnwrap(model.sessionHistory.entry(for: firstToken))
        let firstResponse = try XCTUnwrap(first.response)
        XCTAssertEqual(first.phase, .completed)
        XCTAssertEqual(first.capture?.submitted.body, "first captured payload")
        let firstBody = try await model.withRetainedResponse(for: firstToken) { response, url in
            XCTAssertEqual(response.runID, firstResponse.runID)
            return try Data(contentsOf: url)
        }
        XCTAssertTrue(String(decoding: firstBody, as: UTF8.self).contains("first captured payload"))

        model.updateDraft(identity) {
            $0.name = "Second run"
            $0.body = "second captured payload"
        }
        try await model.flushPendingSaves()
        let requestURL = root.appendingPathComponent(
            "data/collections/\(identity.collectionID.uuidString.lowercased())/\(identity.requestID.uuidString.lowercased()).json"
        )
        let persistedBeforeRerun = try Data(contentsOf: requestURL)
        model.startRequest(identity)
        let secondToken = try XCTUnwrap(model.activeRuns[identity]?.token)
        try await waitUntil { model.activeRuns[identity] == nil }
        let latest = try XCTUnwrap(model.latestResponses[identity]?.response)
        XCTAssertNotEqual(latest.runID, firstResponse.runID)
        XCTAssertEqual(model.sessionHistory.entries.map(\.token), [secondToken, firstToken])
        XCTAssertEqual(model.sessionHistory.entry(for: firstToken)?.requestName, "First run")
        XCTAssertEqual(model.sessionHistory.entry(for: firstToken)?.capture?.submitted.body, "first captured payload")
        let oldBodyAfterRerun = try await model.withRetainedResponse(for: firstToken) { response, url in
            XCTAssertEqual(response.runID, firstResponse.runID)
            XCTAssertEqual(response.request.body, "first captured payload")
            return try Data(contentsOf: url)
        }
        let newBody = try await model.withRetainedResponse(for: secondToken) { response, url in
            XCTAssertEqual(response.runID, latest.runID)
            return try Data(contentsOf: url)
        }
        XCTAssertEqual(oldBodyAfterRerun, firstBody)
        XCTAssertNotEqual(newBody, firstBody)
        XCTAssertTrue(String(decoding: newBody, as: UTF8.self).contains("second captured payload"))
        XCTAssertEqual(try Data(contentsOf: requestURL), persistedBeforeRerun)
        XCTAssertTrue(model.snapshots.isEmpty)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstResponse.bodyFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: latest.bodyFileURL.path))
    }

    func testClearThenShutdownWaitsForSuspendedInspectorOperationLease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root)
        let history = SessionExecutionStore()
        history.connect(to: manager)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let run = active(identity: identity)
        let response = try await ownedResponse(
            manager: manager, root: root, identity: identity, request: run.request, text: "held inspector body")
        history.begin(identity: identity, active: run)
        await history.retainResponse(response, for: run.token)
        history.finish(token: run.token, phase: .completed, response: response)
        try await manager.discardBody(at: response.bodyFileURL)
        var inspectorEntered = false
        var releaseInspector = false
        let inspection = Task { @MainActor in
            try await history.withRetainedResponse(for: run.token) { _, url in
                inspectorEntered = true
                try await self.waitUntil { releaseInspector }
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        defer {
            releaseInspector = true
            inspection.cancel()
        }
        try await waitUntil { inspectorEntered }
        await history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        var shutdownEntered = false
        var shutdownFinished = false
        let shutdown = Task { @MainActor in
            shutdownEntered = true
            await manager.shutdown()
            shutdownFinished = true
        }
        try await waitUntil { shutdownEntered }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(shutdownFinished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
        releaseInspector = true
        let body = try await inspection.value
        XCTAssertEqual(body, "held inspector body")
        try await waitUntil { shutdownFinished }
        await shutdown.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
    }

    func testThrowingAndCancelledInspectorOperationsReleaseLeases() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try HTTPExecutionManager(bodyDirectory: root)
        let history = SessionExecutionStore()
        history.connect(to: manager)
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let run = active(identity: identity)
        let response = try await ownedResponse(
            manager: manager, root: root, identity: identity, request: run.request, text: "operation cleanup")
        history.begin(identity: identity, active: run)
        await history.retainResponse(response, for: run.token)
        history.finish(token: run.token, phase: .completed, response: response)
        do {
            let _: Void = try await history.withRetainedResponse(for: run.token) { _, _ in
                throw SessionHistoryTestError.expected
            }
            XCTFail("The operation error should propagate.")
        } catch SessionHistoryTestError.expected {}

        var inspectorEntered = false
        let inspection = Task { @MainActor in
            try await history.withRetainedResponse(for: run.token) { _, _ in
                inspectorEntered = true
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        defer { inspection.cancel() }
        try await waitUntil { inspectorEntered }
        inspection.cancel()
        do {
            try await inspection.value
            XCTFail("Cancellation should propagate from the operation.")
        } catch is CancellationError {}
        try await manager.discardBody(at: response.bodyFileURL)
        await history.clear()
        var shutdownFinished = false
        let shutdown = Task { @MainActor in
            await manager.shutdown()
            shutdownFinished = true
        }
        try await waitUntil { shutdownFinished }
        await shutdown.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.bodyFileURL.path))
    }

    private func active(identity: RequestIdentity, token: UUID = UUID(), body: String = "") -> AppModel.ActiveRun {
        let request = HTTPRequestConfiguration(name: "Frozen request", url: "https://example.invalid", body: body)
        return AppModel.ActiveRun(
            token: token, request: request,
            snapshotSource: SnapshotSource(
                identity: identity, collectionName: "Frozen collection", requestName: request.name),
            startedAt: Date(), phase: .preparing, progress: nil, redirects: [], cancelRequested: false)
    }

    private func response(request: HTTPRequestConfiguration, bodyURL: URL, byteCount: Int64) -> HTTPResponseRecord {
        HTTPResponseRecord(
            runID: UUID(), request: request, finalURL: URL(string: request.url)!, statusCode: 200,
            requestHeaders: [], responseHeaders: [], redirects: [], bodyFileURL: bodyURL,
            bodyByteCount: byteCount, duration: 0)
    }

    private func ownedResponse(
        manager: HTTPExecutionManager, root: URL, identity: RequestIdentity,
        request: HTTPRequestConfiguration, text: String
    ) async throws -> HTTPResponseRecord {
        let directory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".postie-http-session-") })
        let bodyURL = directory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        try Data(text.utf8).write(to: bodyURL)
        let response = response(request: request, bodyURL: bodyURL, byteCount: Int64(text.utf8.count))
        try await manager.retainCompletedResponse(response, identity: identity)
        return response
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PostieSessionHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        _ checkpoint: String = "session history state", file: StaticString = #filePath, line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(checkpoint).", file: file, line: line)
        throw SessionHistoryTestError.timedOut
    }
}

private enum SessionHistoryTestError: Error {
    case expected, timedOut
}

private struct SessionHistoryKeyStore: ApplicationKeyStore {
    func loadKey() throws -> Data? { Data(repeating: 0x42, count: 32) }
    func createKey(_ proposedKey: Data) throws -> Data { proposedKey }
}

private final class SessionHistoryHTTPFixture {
    private let process: Process
    private let termination: DispatchSemaphore
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let process = Process()
        let output = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = Bundle(for: SessionExecutionStoreTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("PostieHTTPFixture")
        process.arguments = ["--port", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { @Sendable _ in termination.signal() }
        self.process = process
        self.termination = termination
        try process.run()
        do {
            var data = Data()
            let startupDeadline = ProcessInfo.processInfo.systemUptime + 2
            while true {
                var descriptor = pollfd(
                    fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let remainingMilliseconds = Int32(
                    max(0, (startupDeadline - ProcessInfo.processInfo.systemUptime) * 1_000))
                guard remainingMilliseconds > 0, Darwin.poll(&descriptor, 1, remainingMilliseconds) > 0,
                    let byte = try output.fileHandleForReading.read(upToCount: 1)?.first
                else { throw SessionHistoryTestError.timedOut }
                if byte == 0x0A { break }
                data.append(byte)
                guard data.count < 1024 else { throw SessionHistoryTestError.timedOut }
            }
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
            port = try XCTUnwrap(message["port"])
        } catch {
            Self.stop(process, termination: termination)
            throw error
        }
    }

    deinit { Self.stop(process, termination: termination) }

    private static func stop(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning { process.terminate() }
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        XCTAssertEqual(termination.wait(timeout: .now() + .seconds(2)), .success)
    }
}
