import Foundation
import MCP
import PostieAutomation

actor MCPDispatcherAdmission {
    static let maximumAcceptedDispatches = 16

    private let dispatcher: AutomationDispatcher
    private var accepting = false
    private var acceptedTasks: [UUID: Task<AutomationReply, Never>] = [:]
    private var drainWaiters: [UUID: MCPDispatcherDrainWaiter] = [:]

    init(dispatcher: @escaping AutomationDispatcher) {
        self.dispatcher = dispatcher
    }

    func startAccepting() {
        accepting = true
    }

    func stopAccepting() {
        accepting = false
    }

    func dispatch(_ command: AutomationCommand, channel: AutomationChannel) async -> AutomationReply {
        guard accepting, !Task.isCancelled else {
            return AutomationReply(
                id: command.id,
                error: AutomationFailure(.unavailable, "The control server is stopping.")
            )
        }
        guard acceptedTasks.count < Self.maximumAcceptedDispatches else {
            return AutomationReply(
                id: command.id,
                error: AutomationFailure(.unavailable, "The control server is busy.")
            )
        }

        let id = UUID()
        let dispatcher = self.dispatcher
        let task = Task.detached {
            await dispatcher(command, channel)
        }
        acceptedTasks[id] = task

        let reply = await task.value
        acceptedTasks.removeValue(forKey: id)
        if acceptedTasks.isEmpty {
            let waiters = Array(drainWaiters.values)
            drainWaiters.removeAll()
            waiters.forEach {
                $0.timeout.cancel()
                $0.continuation.resume(returning: true)
            }
        }
        return reply
    }

    func waitForDrain(timeout duration: Duration = .seconds(30)) async -> Bool {
        guard !acceptedTasks.isEmpty else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeout = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                await self?.expireDrainWaiter(id)
            }
            drainWaiters[id] = MCPDispatcherDrainWaiter(continuation: continuation, timeout: timeout)
        }
    }

    private func expireDrainWaiter(_ id: UUID) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
    }
}

private struct MCPDispatcherDrainWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timeout: Task<Void, Never>
}

struct MCPProtocolAdapter: Sendable {
    let dispatcherAdmission: MCPDispatcherAdmission

    func handle(body: Data, protocolVersion: String?, wantsSSE: Bool) async -> MCPHTTPResponse {
        let transport = StatelessHTTPServerTransport()
        let server = Server(
            name: "postie",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            let tools = try Self.tools()
            return ListTools.Result(tools: tools)
        }

        let dispatcherAdmission = self.dispatcherAdmission
        await server.withMethodHandler(CallTool.self) { parameters in
            await Self.callTool(parameters, dispatcherAdmission: dispatcherAdmission)
        }

        do {
            try await server.start(transport: transport)
        } catch {
            await server.stop()
            return .init(statusCode: 500, contentType: "application/json", body: Self.errorBody())
        }

        var headers = [
            HTTPHeaderName.contentType: "application/json",
            HTTPHeaderName.accept: "application/json",
        ]
        if let protocolVersion {
            headers[HTTPHeaderName.protocolVersion] = protocolVersion
        }
        let request = HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
        let response = await transport.handleRequest(request)
        await server.stop()
        return Self.httpResponse(from: response, wantsSSE: wantsSSE)
    }

    private static func tools() throws -> [Tool] {
        try AutomationToolCatalog.definitions.map { definition in
            Tool(
                name: definition.operation.toolName,
                description: definition.description,
                inputSchema: try sdkValue(from: definition.inputSchema)
            )
        }
    }

    private static func callTool(
        _ parameters: CallTool.Parameters,
        dispatcherAdmission: MCPDispatcherAdmission
    ) async -> CallTool.Result {
        guard let operation = AutomationOperation(toolName: parameters.name) else {
            return errorResult(code: "invalidArguments", message: "Unknown tool.")
        }

        do {
            let arguments = try (parameters.arguments ?? [:]).mapValues(automationJSON(from:))
            let command = AutomationCommand(operation: operation, arguments: arguments)
            let reply = await dispatcherAdmission.dispatch(command, channel: .mcp)

            guard reply.id == command.id else {
                return errorResult(code: "unavailable", message: "The operation returned an invalid response.")
            }
            if let error = reply.error {
                return errorResult(code: error.code.rawValue, message: error.message)
            }
            guard let result = reply.result else {
                return errorResult(code: "unavailable", message: "The operation returned no result.")
            }
            return try resultValue(result)
        } catch {
            return errorResult(code: "invalidArguments", message: "Tool arguments must be valid JSON values.")
        }
    }

    private static func resultValue(_ result: AutomationJSON) throws -> CallTool.Result {
        let value = try sdkValue(from: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(result)
        return try CallTool.Result(
            content: [.text(text: String(decoding: json, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: value,
            isError: false
        )
    }

    private static func errorResult(code: String, message: String) -> CallTool.Result {
        let details = AutomationJSON.object([
            "code": .string(code),
            "message": .string(message),
        ])
        let encoded = try? JSONEncoder().encode(details)
        return CallTool.Result(
            content: [
                .text(
                    text: encoded.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
                    annotations: nil,
                    _meta: nil
                )
            ],
            structuredContent: try? sdkValue(from: details),
            isError: true
        )
    }

    private static func sdkValue(from value: AutomationJSON) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func automationJSON(from value: Value) throws -> AutomationJSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AutomationJSON.self, from: data)
    }

    private static func httpResponse(from response: HTTPResponse, wantsSSE: Bool) -> MCPHTTPResponse {
        switch response {
        case .accepted:
            return .init(statusCode: 202, contentType: nil, body: Data())
        case .ok:
            return .init(statusCode: 200, contentType: nil, body: Data())
        case .data(let body, let headers):
            guard wantsSSE else {
                return .init(
                    statusCode: 200,
                    contentType: headers[HTTPHeaderName.contentType] ?? "application/json",
                    body: body
                )
            }
            let message = String(decoding: body, as: UTF8.self)
            let event = Data("event: message\ndata: \(message)\n\n".utf8)
            return .init(statusCode: 200, contentType: "text/event-stream", body: event)
        case .stream:
            return .init(statusCode: 500, contentType: "application/json", body: errorBody())
        case .error(let statusCode, _, _, let extraHeaders):
            return .init(
                statusCode: statusCode,
                contentType: extraHeaders[HTTPHeaderName.contentType] ?? "application/json",
                body: response.bodyData ?? errorBody()
            )
        }
    }

    private static func errorBody() -> Data {
        Data(#"{"error":"MCP request failed."}"#.utf8)
    }
}
