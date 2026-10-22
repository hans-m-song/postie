import AppKit
import Combine
import Foundation
import Security
import PostieCore
import PostieControl
import PostieAutomation

@MainActor
final class AutomationService: ObservableObject {
    static let shared = AutomationService()
    @Published private(set) var enabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var status = "Stopped"
    @Published private(set) var localStatus = "Stopped"
    @Published private(set) var isChanging = false
    private let preferences: UserDefaults
    private let keyStore: any ApplicationKeyStore
    private let dispatcher: AutomationDispatcher
    private let socketPath: String
    private var http: MCPHTTPServer?
    private var httpPort: Int?
    private var local: LocalIPCServer?
    private var started = false
    private var deferredRestart: Task<Void, Never>?

    init(
        preferences: UserDefaults = .standard,
        keyStore: (any ApplicationKeyStore)? = nil,
        socketPath: String = LocalIPC.defaultSocketPath,
        dispatcher: AutomationDispatcher? = nil
    ) {
        self.preferences = preferences
        self.keyStore =
            keyStore
            ?? KeychainApplicationKeyStore(
                service: (Bundle.main.bundleIdentifier ?? "dev.postie") + ".mcp-access", account: "bearer-token-v1"
            )
        self.socketPath = socketPath
        self.dispatcher =
            dispatcher ?? { command, channel in
                await AppModel.shared.automationReply(command, channel: channel)
            }
        enabled = preferences.bool(forKey: "automation.mcp.enabled")
        let storedPort = preferences.integer(forKey: "automation.mcp.port")
        port = (1024...65535).contains(storedPort) ? storedPort : 49157
    }

    func start() async {
        guard !started else { return }
        started = true
        let local = self.local ?? LocalIPCServer(socketPath: socketPath, dispatcher: dispatcher)
        do { try await local.start(); self.local = local; localStatus = "Available to local CLI" } catch {
            localStatus = "Local CLI unavailable: private socket could not be opened."
        }
        if enabled, let http, httpPort == port {
            do { try await http.start(); status = "Listening on http://127.0.0.1:\(port)/mcp" } catch {
                await restartHTTP()
            }
        } else if enabled {
            await restartHTTP()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        self.enabled = enabled
        preferences.set(enabled, forKey: "automation.mcp.enabled")
        await restartHTTP()
    }

    func setPort(_ port: Int) async {
        guard !isChanging, (1024...65535).contains(port) else { return }
        self.port = port
        preferences.set(port, forKey: "automation.mcp.port")
        await restartHTTP()
    }

    private func token() throws -> String {
        if let key = try keyStore.loadKey() {
            guard key.count == 32 else { throw LocalIPCError.unavailable }
            return key.base64EncodedString()
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalIPCError.unavailable
        }
        let key = try keyStore.createKey(Data(bytes))
        guard key.count == 32 else { throw LocalIPCError.unavailable }
        return key.base64EncodedString()
    }

    private func restartHTTP() async {
        isChanging = true
        defer { isChanging = false }
        if let http, !(await http.stop()) {
            status = "MCP is draining accepted operations."
            scheduleRestartAfterDrain()
            return
        }
        http = nil
        httpPort = nil
        guard enabled, started else { status = "Disabled"; return }
        do {
            let server = MCPHTTPServer(port: port, token: try token(), dispatcher: dispatcher)
            try await server.start()
            http = server
            httpPort = port
            status = "Listening on http://127.0.0.1:\(port)/mcp"
        } catch { status = "MCP unavailable: check the port and Keychain access, then retry." }
    }

    private func scheduleRestartAfterDrain() {
        guard deferredRestart == nil else { return }
        deferredRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.deferredRestart = nil
            guard self.started else { return }
            await self.restartHTTP()
        }
    }

    func copyCodexConfiguration() {
        do {
            let value = """
                [mcp_servers.postie]
                url = "http://127.0.0.1:\(port)/mcp"
                http_headers = { Authorization = "Bearer \(try token())" }
                """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch { status = "Could not access the MCP token in Keychain." }
    }

    func stop() async -> Bool {
        started = false
        deferredRestart?.cancel()
        deferredRestart = nil
        async let stopHTTP = http?.stop() ?? true
        async let stopLocal = local?.stop() ?? true
        let (httpStopped, localStopped) = await (stopHTTP, stopLocal)
        if httpStopped { http = nil; httpPort = nil }
        if localStopped { local = nil }
        guard httpStopped && localStopped else {
            status = "Accepted operations are still finishing. Try quitting again shortly."
            return false
        }
        status = "Stopped"
        localStatus = "Stopped"
        return true
    }
}
