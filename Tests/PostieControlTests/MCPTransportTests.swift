import Foundation
import XCTest
import PostieAutomation
@testable import PostieControl

final class MCPTransportTests: XCTestCase {
    func testAuthenticatedToolCallUsesMCPChannelAndPublishesCatalog() async throws {
        let recorder = DispatchRecorder()
        let server = MCPHTTPServer(port: 0, token: "transport-test-token") { command, channel in
            await recorder.dispatch(command, channel: channel)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let maybePort = await server.boundPort
        let port = try XCTUnwrap(maybePort)
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 41,
            "method": "tools/call",
            "params": ["name": "collections_list", "arguments": [:]],
        ])
        let (response, body) = try await Self.post(
            to: port,
            accept: "application/json",
            body: requestBody
        )

        XCTAssertEqual(response.statusCode, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["channel"] as? String, "mcp")
        XCTAssertEqual(structured["operation"] as? String, "collections.list")

        let recorded = await recorder.recordedCalls()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].operation, .collectionsList)
    }

    func testAcceptingEventStreamReturnsOneRequestLocalSSEMessage() async throws {
        let recorder = DispatchRecorder()
        let server = MCPHTTPServer(port: 0, token: "transport-test-token") { command, channel in
            await recorder.dispatch(command, channel: channel)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let maybePort = await server.boundPort
        let port = try XCTUnwrap(maybePort)
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": ["name": "collections_list", "arguments": [:]],
        ])
        let (response, body) = try await Self.post(
            to: port,
            accept: "application/json, text/event-stream",
            body: requestBody
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true)
        let event = String(decoding: body, as: UTF8.self)
        let lines = event.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "event: message")
        XCTAssertTrue(lines[1].hasPrefix("data: {"))
        XCTAssertTrue(event.hasSuffix("\n\n"))
        let payload = String(lines[1].dropFirst("data: ".count))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 42)
    }

    func testConcurrentPostsCanReuseJSONRPCIDWithoutCrossingResults() async throws {
        let recorder = DispatchRecorder()
        let server = MCPHTTPServer(port: 0, token: "transport-test-token") { command, channel in
            await recorder.dispatch(command, channel: channel)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let maybePort = await server.boundPort
        let port = try XCTUnwrap(maybePort)
        let firstRequestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": ["name": "requests_list", "arguments": ["collectionID": "first"]],
        ])
        let secondRequestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": ["name": "requests_list", "arguments": ["collectionID": "second"]],
        ])
        async let first = Self.post(
            to: port,
            accept: "application/json",
            body: firstRequestBody
        )
        async let second = Self.post(
            to: port,
            accept: "application/json",
            body: secondRequestBody
        )

        let (firstResponse, firstResponseBody) = try await first
        let (secondResponse, secondResponseBody) = try await second
        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(try Self.structuredCollectionID(from: firstResponseBody), "first")
        XCTAssertEqual(try Self.structuredCollectionID(from: secondResponseBody), "second")
    }

    func testReadDeadlineDoesNotExpireAfterFullBodyIsReceived() async throws {
        let pendingDispatcher = PendingDispatcher()
        let server = MCPHTTPServer(
            port: 0,
            token: "transport-test-token",
            readTimeout: .milliseconds(1_000)
        ) { command, _ in
            await pendingDispatcher.dispatch(command)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let maybePort = await server.boundPort
        let port = try XCTUnwrap(maybePort)
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 43,
            "method": "tools/call",
            "params": ["name": "collections_list", "arguments": [:]],
        ])
        async let response = Self.post(to: port, accept: "application/json", body: requestBody)

        await pendingDispatcher.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(1_200))
        await pendingDispatcher.complete()

        let (httpResponse, body) = try await response
        XCTAssertEqual(httpResponse.statusCode, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 43)
    }

    func testMalformedJSONAndUnsupportedMethodsDoNotDispatch() async throws {
        let recorder = DispatchRecorder()
        let server = MCPHTTPServer(port: 0, token: "transport-test-token") { command, channel in
            await recorder.dispatch(command, channel: channel)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let maybePort = await server.boundPort
        let port = try XCTUnwrap(maybePort)
        var malformed = Self.makeRequest(port: port, accept: "application/json")
        malformed.httpBody = Data("{".utf8)
        let (_, malformedResponse) = try await URLSession.shared.data(for: malformed)
        XCTAssertEqual((malformedResponse as? HTTPURLResponse)?.statusCode, 400)

        for method in ["GET", "DELETE"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = method
            request.setValue("Bearer transport-test-token", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
        }

        let recorded = await recorder.recordedCalls()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSecurityRejectsBadHostOriginDuplicateAuthorizationAndOversizedBody() {
        let security = MCPRequestSecurity(token: "transport-test-token", port: 41234)
        let valid: [String: [String]] = [
            "host": ["127.0.0.1:41234"],
            "authorization": ["Bearer transport-test-token"],
            "content-type": ["application/json"],
            "accept": ["application/json"],
        ]

        XCTAssertEqual(
            Self.rejectedStatus(
                security.evaluate(
                    method: "POST", path: "/mcp", headers: Self.replacing(valid, "host", ["example.test:41234"]))),
            403
        )
        XCTAssertEqual(
            Self.rejectedStatus(
                security.evaluate(
                    method: "POST", path: "/mcp", headers: Self.replacing(valid, "origin", ["https://localhost:41234"]))
            ),
            403
        )
        XCTAssertEqual(
            Self.rejectedStatus(
                security.evaluate(
                    method: "POST", path: "/mcp",
                    headers: Self.replacing(
                        valid, "authorization", ["Bearer transport-test-token", "Bearer transport-test-token"]))),
            400
        )
        XCTAssertEqual(
            Self.rejectedStatus(
                security.evaluate(
                    method: "POST", path: "/mcp", headers: Self.replacing(valid, "content-length", ["1048577"]))),
            413
        )
        XCTAssertEqual(
            Self.rejectedStatus(
                security.evaluate(
                    method: "POST", path: "/mcp", headers: Self.replacing(valid, "authorization", ["Bearer incorrect"]))
            ),
            401
        )
    }

    func testAcceptedDispatcherWorkSurvivesCallerCancellationAndDrains() async {
        let pendingDispatcher = PendingDispatcher()
        let admission = MCPDispatcherAdmission { command, _ in
            await pendingDispatcher.dispatch(command)
        }
        await admission.startAccepting()

        let command = AutomationCommand(operation: .requestsStart)
        let request = Task {
            await admission.dispatch(command, channel: .mcp)
        }
        await pendingDispatcher.waitUntilStarted()
        request.cancel()
        await admission.stopAccepting()

        let rejected = await admission.dispatch(
            AutomationCommand(operation: .collectionsList),
            channel: .mcp
        )
        XCTAssertEqual(rejected.error?.code, .unavailable)

        let drainedWhilePending = await admission.waitForDrain(timeout: .milliseconds(20))
        XCTAssertFalse(drainedWhilePending)

        await pendingDispatcher.complete()
        let completed = await request.value
        XCTAssertEqual(completed.id, command.id)
        let drainedAfterCompletion = await admission.waitForDrain(timeout: .milliseconds(20))
        XCTAssertTrue(drainedAfterCompletion)
    }

    func testAcceptedDispatcherWorkIsBoundedAcrossDisconnectedRequests() async {
        let pendingDispatcher = PendingDispatcher()
        let admission = MCPDispatcherAdmission { command, _ in
            await pendingDispatcher.dispatch(command)
        }
        await admission.startAccepting()

        let limit = MCPDispatcherAdmission.maximumAcceptedDispatches
        XCTAssertEqual(limit, 16)
        let requests = (0..<limit).map { _ in
            let command = AutomationCommand(operation: .requestsStart)
            return Task { await admission.dispatch(command, channel: .mcp) }
        }
        await pendingDispatcher.waitUntilStarted(count: limit)
        requests.forEach { $0.cancel() }

        let overflow = await admission.dispatch(
            AutomationCommand(operation: .requestsStart),
            channel: .mcp
        )
        XCTAssertEqual(overflow.error?.code, .unavailable)
        let dispatchCount = await pendingDispatcher.startedCount()
        XCTAssertEqual(dispatchCount, limit)

        await pendingDispatcher.complete()
        for request in requests {
            let reply = await request.value
            XCTAssertNil(reply.error)
        }
        let drained = await admission.waitForDrain(timeout: .milliseconds(20))
        XCTAssertTrue(drained)
    }

    private nonisolated static func post(
        to port: Int,
        accept: String,
        body: Data
    ) async throws -> (HTTPURLResponse, Data) {
        var request = makeRequest(port: port, accept: accept)
        request.httpBody = body
        let (body, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), body)
    }

    private nonisolated static func makeRequest(port: Int, accept: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer transport-test-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        return request
    }

    private nonisolated static func structuredCollectionID(from body: Data) throws -> String? {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        return structured["collectionID"] as? String
    }

    private nonisolated static func replacing(
        _ headers: [String: [String]],
        _ name: String,
        _ values: [String]
    ) -> [String: [String]] {
        var result = headers
        result[name] = values
        return result
    }

    private nonisolated static func rejectedStatus(_ decision: MCPRequestSecurityDecision) -> Int? {
        guard case .rejected(let statusCode) = decision else { return nil }
        return statusCode
    }
}

private actor DispatchRecorder {
    private var commands: [AutomationCommand] = []

    func dispatch(_ command: AutomationCommand, channel: AutomationChannel) -> AutomationReply {
        commands.append(command)
        let channelName: String
        switch channel {
        case .mcp:
            channelName = "mcp"
        case .cli:
            channelName = "cli"
        }
        var result = command.arguments
        result["channel"] = .string(channelName)
        result["operation"] = .string(command.operation.rawValue)
        return AutomationReply(id: command.id, result: .object(result))
    }

    func recordedCalls() -> [AutomationCommand] {
        commands
    }
}

private actor PendingDispatcher {
    private var startedRequestIDs = Set<UUID>()
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var pending: [UUID: CheckedContinuation<AutomationReply, Never>] = [:]

    func dispatch(_ command: AutomationCommand) async -> AutomationReply {
        startedRequestIDs.insert(command.id)
        let ready = startWaiters.filter { $0.count <= startedRequestIDs.count }
        startWaiters.removeAll { $0.count <= startedRequestIDs.count }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { pending[command.id] = $0 }
    }

    func waitUntilStarted(count: Int = 1) async {
        guard startedRequestIDs.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func complete() {
        let pending = self.pending
        self.pending.removeAll()
        for (id, continuation) in pending {
            continuation.resume(returning: AutomationReply(id: id, result: .object([:])))
        }
    }

    func startedCount() -> Int {
        startedRequestIDs.count
    }
}
