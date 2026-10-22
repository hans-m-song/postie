import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import PostieAutomation

public actor MCPHTTPServer {
    private let port: Int
    private let readTimeout: TimeAmount
    private let security: MCPRequestSecurity
    private let dispatcherAdmission: MCPDispatcherAdmission
    private let adapter: MCPProtocolAdapter
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var connections = MCPConnectionRegistry()
    private var lifecycle: Lifecycle = .stopped
    private var stopRequestedDuringStart = false
    private var acceptingRequests = false
    private var inFlightRequests = 0
    private var drainWaiters: [UUID: DrainWaiter] = [:]
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []

    public init(port: Int, token: String, dispatcher: @escaping AutomationDispatcher) {
        self.port = port
        readTimeout = .seconds(30)
        security = MCPRequestSecurity(token: token, port: port)
        let dispatcherAdmission = MCPDispatcherAdmission(dispatcher: dispatcher)
        self.dispatcherAdmission = dispatcherAdmission
        adapter = MCPProtocolAdapter(dispatcherAdmission: dispatcherAdmission)
    }

    init(
        port: Int,
        token: String,
        readTimeout: TimeAmount,
        dispatcher: @escaping AutomationDispatcher
    ) {
        self.port = port
        self.readTimeout = readTimeout
        security = MCPRequestSecurity(token: token, port: port)
        let dispatcherAdmission = MCPDispatcherAdmission(dispatcher: dispatcher)
        self.dispatcherAdmission = dispatcherAdmission
        adapter = MCPProtocolAdapter(dispatcherAdmission: dispatcherAdmission)
    }

    public var boundPort: Int? {
        listener?.localAddress?.port
    }

    public func start() async throws {
        guard lifecycle == .stopped || lifecycle == .draining else {
            throw MCPHTTPServerError.alreadyStarted
        }
        guard (0...65_535).contains(port) else {
            throw MCPHTTPServerError.invalidPort
        }

        lifecycle = .starting
        stopRequestedDuringStart = false
        await dispatcherAdmission.startAccepting()
        if stopRequestedDuringStart {
            await dispatcherAdmission.stopAccepting()
            lifecycle = .stopping
            let stopped = await drainAndStop()
            finishStop(stopped: stopped)
            return
        }
        let group: MultiThreadedEventLoopGroup
        if let existingGroup = eventLoopGroup {
            group = existingGroup
        } else {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            eventLoopGroup = group
        }
        let connectionRegistry = MCPConnectionRegistry()
        connections = connectionRegistry
        let readTimeout = self.readTimeout

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self, security, readTimeout] channel in
                guard connectionRegistry.add(channel) else {
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in
                    connectionRegistry.remove(channel)
                }
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        MCPHTTPChannelHandler(server: self, security: security, readTimeout: readTimeout)
                    )
                }
            }

        do {
            let listener = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            self.listener = listener
            if let boundPort = listener.localAddress?.port {
                security.setBoundPort(boundPort)
            }
            if stopRequestedDuringStart {
                await dispatcherAdmission.stopAccepting()
                lifecycle = .stopping
                await closeAdmissionAndConnections()
                let stopped = await drainAndStop()
                finishStop(stopped: stopped)
                return
            }
            acceptingRequests = true
            lifecycle = .running
        } catch {
            acceptingRequests = false
            listener = nil
            await dispatcherAdmission.stopAccepting()
            lifecycle = .stopping
            await closeAdmissionAndConnections()
            let stopped = await drainAndStop()
            finishStop(stopped: stopped)
            throw error
        }
    }

    @discardableResult
    public func stop() async -> Bool {
        switch lifecycle {
        case .stopped:
            return true
        case .starting:
            stopRequestedDuringStart = true
            return await withCheckedContinuation { stopWaiters.append($0) }
        case .stopping:
            return await withCheckedContinuation { stopWaiters.append($0) }
        case .running:
            lifecycle = .stopping
            acceptingRequests = false
            await dispatcherAdmission.stopAccepting()
            await closeAdmissionAndConnections()
            let stopped = await drainAndStop()
            finishStop(stopped: stopped)
            return stopped
        case .draining:
            lifecycle = .stopping
            acceptingRequests = false
            await dispatcherAdmission.stopAccepting()
            await closeAdmissionAndConnections()
            let stopped = await drainAndStop()
            finishStop(stopped: stopped)
            return stopped
        }
    }

    fileprivate func process(body: Data, metadata: MCPHTTPRequestMetadata) async -> MCPHTTPResponse {
        guard acceptingRequests else {
            return .init(statusCode: 503, contentType: "application/json", body: Data())
        }
        inFlightRequests += 1
        defer { finishRequest() }
        return await adapter.handle(
            body: body,
            protocolVersion: metadata.protocolVersion,
            wantsSSE: metadata.wantsSSE
        )
    }

    private func finishRequest() {
        inFlightRequests -= 1
        guard inFlightRequests == 0 else { return }
        let waiters = Array(drainWaiters.values)
        drainWaiters.removeAll()
        waiters.forEach {
            $0.timeout.cancel()
            $0.continuation.resume(returning: true)
        }
    }

    private func waitForRequestsToDrain() async -> Bool {
        guard inFlightRequests > 0 else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeout = Task.detached { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await self?.expireDrainWaiter(id)
            }
            drainWaiters[id] = DrainWaiter(continuation: continuation, timeout: timeout)
        }
    }

    private func expireDrainWaiter(_ id: UUID) {
        guard let waiter = drainWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func closeAdmissionAndConnections() async {
        acceptingRequests = false
        let channels = connections.stopAccepting()
        if let listener {
            await MCPHTTPServer.close(listener)
            self.listener = nil
        }
        for channel in channels {
            await MCPHTTPServer.close(channel)
        }
    }

    private func drainAndStop() async -> Bool {
        async let requestsDrained = waitForRequestsToDrain()
        async let dispatchersDrained = dispatcherAdmission.waitForDrain()
        let drainedRequests = await requestsDrained
        let drainedDispatchers = await dispatchersDrained
        guard drainedRequests, drainedDispatchers else {
            lifecycle = .draining
            return false
        }
        if let eventLoopGroup {
            await MCPHTTPServer.shutdown(eventLoopGroup)
            self.eventLoopGroup = nil
        }
        lifecycle = .stopped
        return true
    }

    private func finishStop(stopped: Bool) {
        lifecycle = stopped ? .stopped : .draining
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume(returning: stopped) }
    }

    private static func close(_ channel: Channel) async {
        await withCheckedContinuation { continuation in
            channel.closeFuture.whenComplete { _ in continuation.resume() }
            channel.close(promise: nil)
        }
    }

    private static func shutdown(_ group: MultiThreadedEventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }
}

private enum Lifecycle {
    case stopped
    case starting
    case running
    case stopping
    case draining
}

private struct DrainWaiter {
    let continuation: CheckedContinuation<Bool, Never>
    let timeout: Task<Void, Never>
}

private enum MCPHTTPServerError: Error {
    case invalidPort
    case alreadyStarted
}

struct MCPHTTPResponse: Sendable {
    let statusCode: Int
    let contentType: String?
    let body: Data
}

struct MCPHTTPRequestMetadata: Sendable {
    let protocolVersion: String?
    let wantsSSE: Bool
}

enum MCPRequestSecurityDecision: Sendable {
    case accepted(MCPHTTPRequestMetadata)
    case rejected(statusCode: Int)
}

final class MCPRequestSecurity: @unchecked Sendable {
    static let maximumBodySize = 1_048_576

    private let token: String
    private let portLock = NSLock()
    private var effectivePort: Int

    init(token: String, port: Int) {
        self.token = token
        effectivePort = port
    }

    func setBoundPort(_ port: Int) {
        portLock.lock()
        defer { portLock.unlock() }
        effectivePort = port
    }

    func evaluate(method: String, path: String, headers: [String: [String]]) -> MCPRequestSecurityDecision {
        guard path == "/mcp" else { return .rejected(statusCode: 404) }
        guard method.uppercased() == "POST" else { return .rejected(statusCode: 405) }
        guard exactlyOne("host", in: headers), exactlyOne("content-type", in: headers)
        else { return .rejected(statusCode: 400) }
        let authorizations = headers["authorization"] ?? []
        guard authorizations.count <= 1 else { return .rejected(statusCode: 400) }

        portLock.lock()
        let port = effectivePort
        portLock.unlock()
        guard validHost(headers["host"]![0], port: port) else {
            return .rejected(statusCode: 403)
        }

        let origins = headers["origin"] ?? []
        guard origins.count <= 1 else { return .rejected(statusCode: 400) }
        if let origin = origins.first, !validOrigin(origin, port: port) {
            return .rejected(statusCode: 403)
        }

        guard let authorization = authorizations.first, validBearer(authorization) else {
            return .rejected(statusCode: 401)
        }

        guard validJSONContentType(headers["content-type"]![0]) else {
            return .rejected(statusCode: 415)
        }
        guard (headers["content-length"] ?? []).count <= 1,
            (headers["transfer-encoding"] ?? []).count <= 1
        else { return .rejected(statusCode: 400) }
        let contentLengths = headers["content-length"] ?? []
        let transferEncodings = headers["transfer-encoding"] ?? []
        if !contentLengths.isEmpty && !transferEncodings.isEmpty {
            return .rejected(statusCode: 400)
        }
        if let contentLength = contentLengths.first {
            guard let length = Int(contentLength), length >= 0 else {
                return .rejected(statusCode: 400)
            }
            guard length <= Self.maximumBodySize else { return .rejected(statusCode: 413) }
        }
        if let transferEncoding = transferEncodings.first,
            transferEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "chunked"
        {
            return .rejected(statusCode: 400)
        }

        let versions = headers["mcp-protocol-version"] ?? []
        guard versions.count <= 1 else { return .rejected(statusCode: 400) }
        let acceptValues = headers["accept"] ?? []
        let acceptedTypes =
            acceptValues
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .compactMap { $0.split(separator: ";", maxSplits: 1).first }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard acceptedTypes.contains("application/json") || acceptedTypes.contains("text/event-stream") else {
            return .rejected(statusCode: 406)
        }
        return .accepted(
            .init(
                protocolVersion: versions.first,
                wantsSSE: acceptedTypes.contains("text/event-stream")
            ))
    }

    private func exactlyOne(_ name: String, in headers: [String: [String]]) -> Bool {
        headers[name]?.count == 1
    }

    private func validHost(_ value: String, port: Int) -> Bool {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    private func validOrigin(_ value: String, port: Int) -> Bool {
        guard let components = URLComponents(string: value),
            components.scheme?.lowercased() == "http",
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.isEmpty,
            let host = components.host?.lowercased(),
            host == "127.0.0.1" || host == "localhost"
        else { return false }
        return (components.port ?? 80) == port
    }

    private func validBearer(_ authorization: String) -> Bool {
        let parts = authorization.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts[0].lowercased() == "bearer",
            !parts[1].isEmpty
        else { return false }
        return constantTimeEqual(Data(parts[1].utf8), Data(token.utf8))
    }

    private func validJSONContentType(_ value: String) -> Bool {
        value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        var difference = UInt64(lhs.count ^ rhs.count)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= UInt64(left ^ right)
        }
        return difference == 0
    }
}

private final class MCPConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var accepting = true

    func add(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, channels.count < 16 else { return false }
        channels[ObjectIdentifier(channel as AnyObject)] = channel
        return true
    }

    func remove(_ channel: Channel) {
        lock.lock()
        channels.removeValue(forKey: ObjectIdentifier(channel as AnyObject))
        lock.unlock()
    }

    func stopAccepting() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        accepting = false
        return Array(channels.values)
    }
}

// NIO serializes all mutable handler state access on the channel's event loop.
private final class MCPHTTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct IncomingRequest {
        let id: UUID
        let head: HTTPRequestHead
        let metadata: MCPHTTPRequestMetadata
        var body: ByteBuffer
    }

    private let server: MCPHTTPServer
    private let security: MCPRequestSecurity
    private let readTimeout: TimeAmount
    private weak var channelContext: ChannelHandlerContext?
    private var incomingRequest: IncomingRequest?
    private var activeRequestID: UUID?
    private var activeRequestHead: HTTPRequestHead?
    private var timeoutTask: Scheduled<Void>?

    init(server: MCPHTTPServer, security: MCPRequestSecurity, readTimeout: TimeAmount) {
        self.server = server
        self.security = security
        self.readTimeout = readTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        channelContext = context
        scheduleReadDeadline(on: context.eventLoop)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeoutTask?.cancel()
        timeoutTask = nil
        channelContext = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            receiveHead(head, context: context)
        case .body(var part):
            receiveBody(&part, context: context)
        case .end:
            receiveEnd(context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        timeoutTask?.cancel()
        timeoutTask = nil
        incomingRequest = nil
        activeRequestID = nil
        activeRequestHead = nil
        channelContext = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard activeRequestID == nil else {
            write(
                statusCode: 400, body: Self.errorBody(), contentType: "application/json", head: head,
                keepAlive: false, context: context)
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil

        var headers: [String: [String]] = [:]
        for header in head.headers {
            headers[header.name.lowercased(), default: []].append(header.value)
        }
        let path =
            head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            ?? head.uri
        switch security.evaluate(method: head.method.rawValue, path: path, headers: headers) {
        case .rejected(let statusCode):
            write(
                statusCode: statusCode,
                body: Self.errorBody(),
                contentType: "application/json",
                head: head,
                keepAlive: false,
                context: context
            )
        case .accepted(let metadata):
            let id = UUID()
            activeRequestID = id
            activeRequestHead = head
            incomingRequest = IncomingRequest(
                id: id,
                head: head,
                metadata: metadata,
                body: context.channel.allocator.buffer(capacity: 0)
            )
            scheduleReadDeadline(on: context.eventLoop)
        }
    }

    private func receiveBody(_ part: inout ByteBuffer, context: ChannelHandlerContext) {
        guard var request = incomingRequest else {
            context.close(promise: nil)
            return
        }
        guard request.body.readableBytes + part.readableBytes <= MCPRequestSecurity.maximumBodySize else {
            rejectActiveRequest(statusCode: 413, context: context)
            return
        }
        request.body.writeBuffer(&part)
        incomingRequest = request
    }

    private func receiveEnd(context: ChannelHandlerContext) {
        guard var request = incomingRequest else {
            context.close(promise: nil)
            return
        }
        incomingRequest = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let body = Data(request.body.readBytes(length: request.body.readableBytes) ?? [])
        let server = self.server
        let requestID = request.id
        let head = request.head
        let metadata = request.metadata
        let keepAlive = Self.keepAlive(for: head)
        let eventLoop = context.eventLoop
        Task { [weak self] in
            let response = await server.process(body: body, metadata: metadata)
            eventLoop.execute { [weak self] in
                guard let self, let context = self.channelContext else { return }
                self.complete(
                    id: requestID,
                    response: response,
                    requestHead: head,
                    keepAlive: keepAlive,
                    context: context
                )
            }
        }
    }

    private func complete(
        id: UUID,
        response: MCPHTTPResponse,
        requestHead: HTTPRequestHead,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        guard activeRequestID == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        activeRequestID = nil
        activeRequestHead = nil
        guard context.channel.isActive else { return }
        write(
            statusCode: response.statusCode,
            body: response.body,
            contentType: response.contentType,
            head: requestHead,
            keepAlive: keepAlive,
            context: context
        )
    }

    private func timeout(id: UUID, head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard activeRequestID == id else { return }
        activeRequestID = nil
        activeRequestHead = nil
        timeoutTask = nil
        incomingRequest = nil
        write(
            statusCode: 408,
            body: Self.errorBody(),
            contentType: "application/json",
            head: head,
            keepAlive: false,
            context: context
        )
    }

    private func rejectActiveRequest(statusCode: Int, context: ChannelHandlerContext) {
        guard let request = incomingRequest else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        activeRequestID = nil
        activeRequestHead = nil
        incomingRequest = nil
        write(
            statusCode: statusCode,
            body: Self.errorBody(),
            contentType: "application/json",
            head: request.head,
            keepAlive: false,
            context: context
        )
    }

    private func write(
        statusCode: Int,
        body: Data,
        contentType: String?,
        head: HTTPRequestHead,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var responseHead = HTTPResponseHead(
            version: head.version,
            status: HTTPResponseStatus(statusCode: statusCode)
        )
        if let contentType {
            responseHead.headers.add(name: "Content-Type", value: contentType)
        }
        responseHead.headers.add(name: "Content-Length", value: String(body.count))
        if statusCode == 401 {
            responseHead.headers.add(name: "WWW-Authenticate", value: "Bearer")
        }
        if statusCode == 405 {
            responseHead.headers.add(name: "Allow", value: "POST")
        }
        responseHead.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        let channel = context.channel
        let eventLoop = context.eventLoop
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let writeFuture = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if keepAlive {
            writeFuture.whenComplete { [weak self] _ in
                eventLoop.execute { [weak self] in
                    guard let self,
                        self.activeRequestID == nil,
                        let context = self.channelContext
                    else { return }
                    self.scheduleReadDeadline(on: context.eventLoop)
                }
            }
        } else {
            writeFuture.whenComplete { _ in channel.close(promise: nil) }
        }
    }

    private func scheduleReadDeadline(on eventLoop: EventLoop) {
        timeoutTask?.cancel()
        timeoutTask = eventLoop.scheduleTask(in: readTimeout) { [weak self] in
            guard let self, let context = self.channelContext else { return }
            guard let id = self.activeRequestID, let head = self.activeRequestHead else {
                self.timeoutTask = nil
                context.close(promise: nil)
                return
            }
            self.timeout(id: id, head: head, context: context)
        }
    }

    private static func keepAlive(for head: HTTPRequestHead) -> Bool {
        let connections = head.headers["connection"].joined(separator: ",").lowercased()
        if connections.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "close" }) {
            return false
        }
        return head.version.major > 1 || (head.version.major == 1 && head.version.minor >= 1)
    }

    private static func errorBody() -> Data {
        Data(#"{"error":"Request rejected."}"#.utf8)
    }
}
