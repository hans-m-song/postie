import AppKit
import Combine
import Foundation
import PostieAutomation
import PostieControl

@MainActor
final class AutomationService: ObservableObject {
    static let shared = AutomationService()
    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var status = "Stopped"
    @Published private(set) var localStatus = "Stopped"
    @Published private(set) var isChanging = false
    private let preferences: UserDefaults
    private let tokenProvider: @MainActor @Sendable () async throws -> String
    private let dispatcher: AutomationDispatcher
    private let socketPath: String
    private let configurationWriter: @MainActor @Sendable (String) -> Void
    private var http: MCPHTTPServer?
    private var local: LocalIPCServer?
    private var started = false
    private var generation: UInt64 = 0
    private var changingGeneration: UInt64?
    private var deferredRestart: Task<Void, Never>?
    private var localLifecycleTask: Task<Bool, Never>?
    private var localLifecycleSequence: UInt64 = 0

    init(
        preferences: UserDefaults = .standard,
        tokenProvider: (@MainActor @Sendable () async throws -> String)? = nil,
        socketPath: String = LocalIPC.defaultSocketPath,
        dispatcher: AutomationDispatcher? = nil,
        configurationWriter: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.preferences = preferences
        self.tokenProvider =
            tokenProvider ?? {
                try await AppModel.shared.mcpBearerToken()
            }
        self.socketPath = socketPath
        self.dispatcher =
            dispatcher ?? { command, channel in
                await AppModel.shared.automationReply(command, channel: channel)
            }
        self.configurationWriter =
            configurationWriter ?? { value in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        enabled = preferences.bool(forKey: "automation.mcp.enabled")
        let storedPort = preferences.integer(forKey: "automation.mcp.port")
        port = (1024...65535).contains(storedPort) ? storedPort : 49157
    }

    func start() async {
        guard !started else { return }
        let currentGeneration = advanceGeneration()
        started = true
        beginChange(for: currentGeneration)

        let localServer = local ?? LocalIPCServer(socketPath: socketPath, dispatcher: dispatcher)
        local = localServer
        let localStartTask = enqueueLocalLifecycle { [weak self] in
            guard let self, self.isCurrent(currentGeneration) else { return false }
            do {
                try await localServer.start()
                return true
            } catch {
                return false
            }
        }
        let localStarted = await localStartTask.value
        guard isCurrent(currentGeneration) else { return }
        if localStarted {
            localStatus = "Available to local CLI"
        } else {
            localStatus = "Local CLI unavailable: private socket could not be opened."
        }

        finishChange(for: currentGeneration)
        await restartHTTP(for: currentGeneration)
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        self.enabled = enabled
        preferences.set(enabled, forKey: "automation.mcp.enabled")
        let currentGeneration = advanceGeneration()
        await restartHTTP(for: currentGeneration)
    }

    func setPort(_ port: Int) async {
        guard !isChanging, (1024...65535).contains(port) else { return }
        self.port = port
        preferences.set(port, forKey: "automation.mcp.port")
        let currentGeneration = advanceGeneration()
        await restartHTTP(for: currentGeneration)
    }

    private func restartHTTP(for currentGeneration: UInt64) async {
        guard isCurrentGeneration(currentGeneration) else { return }
        beginChange(for: currentGeneration)
        defer { finishChange(for: currentGeneration) }

        let requestedPort = port
        if let previousServer = http {
            guard await previousServer.stop() else {
                guard isCurrentGeneration(currentGeneration) else { return }
                status = "MCP is draining accepted operations."
                scheduleRestartAfterDrain(for: currentGeneration)
                return
            }
            if http === previousServer {
                http = nil
            }
        }

        guard isCurrentGeneration(currentGeneration), port == requestedPort else { return }
        guard enabled, started else { status = "Disabled"; return }

        let token: String
        do {
            token = try await tokenProvider()
        } catch {
            guard isActive(currentGeneration), port == requestedPort else { return }
            status = "MCP unavailable: check the port and access token, then retry."
            return
        }

        guard isActive(currentGeneration), port == requestedPort else { return }
        let server = MCPHTTPServer(port: requestedPort, token: token, dispatcher: dispatcher)
        http = server
        do {
            try await server.start()
        } catch {
            if http === server {
                http = nil
            }
            guard isActive(currentGeneration), port == requestedPort else { return }
            status = "MCP unavailable: check the port and access token, then retry."
            return
        }

        guard isActive(currentGeneration), port == requestedPort else {
            let stopped = await server.stop()
            if stopped, http === server {
                http = nil
            }
            return
        }

        status = "Listening on http://127.0.0.1:\(requestedPort)/mcp"
    }

    private func scheduleRestartAfterDrain(for currentGeneration: UInt64) {
        guard deferredRestart == nil else { return }
        deferredRestart = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                self.isCurrentGeneration(currentGeneration)
            else { return }
            self.deferredRestart = nil
            await self.restartHTTP(for: currentGeneration)
        }
    }

    func copyCodexConfiguration() async {
        guard enabled, !isChanging else { return }
        let requestGeneration = generation
        do {
            let token = try await tokenProvider()
            guard generation == requestGeneration, enabled else { return }
            let value = """
                [mcp_servers.postie]
                url = "http://127.0.0.1:\(port)/mcp"
                http_headers = { Authorization = "Bearer \(token)" }
                """
            configurationWriter(value)
        } catch {
            guard generation == requestGeneration, enabled else { return }
            status = "Could not access the MCP access token."
        }
    }

    func stop() async -> Bool {
        let currentGeneration = advanceGeneration()
        started = false
        let httpToStop = http
        let localToStop = local
        let localStopTask = localToStop.map { localServer in
            enqueueLocalLifecycle { await localServer.stop() }
        }
        async let stopHTTP = httpToStop?.stop() ?? true
        async let stopLocal = localStopTask?.value ?? true
        let (httpStopped, localStopped) = await (stopHTTP, stopLocal)
        guard isCurrentGeneration(currentGeneration) else { return httpStopped && localStopped }
        if httpStopped, let httpToStop, http === httpToStop {
            http = nil
        }
        if localStopped, let localToStop, local === localToStop {
            local = nil
        }
        guard httpStopped && localStopped else {
            status = "Accepted operations are still finishing. Try quitting again shortly."
            return false
        }
        status = "Stopped"
        localStatus = "Stopped"
        return true
    }

    private func enqueueLocalLifecycle(
        _ operation: @escaping @MainActor @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        localLifecycleSequence &+= 1
        let sequence = localLifecycleSequence
        let previous = localLifecycleTask
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            let result = await operation()
            if self.localLifecycleSequence == sequence {
                self.localLifecycleTask = nil
            }
            return result
        }
        localLifecycleTask = task
        return task
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        deferredRestart?.cancel()
        deferredRestart = nil
        changingGeneration = nil
        isChanging = false
        return generation
    }

    private func beginChange(for generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }
        changingGeneration = generation
        isChanging = true
    }

    private func finishChange(for generation: UInt64) {
        guard changingGeneration == generation else { return }
        changingGeneration = nil
        isChanging = false
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        self.generation == generation
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        isCurrentGeneration(generation) && started
    }

    private func isActive(_ generation: UInt64) -> Bool {
        isCurrent(generation) && enabled
    }
}
