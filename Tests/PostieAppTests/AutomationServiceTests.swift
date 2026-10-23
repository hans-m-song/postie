import Darwin
import Foundation
import XCTest
@testable import PostieApp
import PostieAutomation
import PostieControl
import PostieCore

@MainActor
final class AutomationServiceTests: XCTestCase {
    func testMCPStartsDisabledAndPersistsSettingsAcrossInstances() async throws {
        let suiteName = "AutomationServiceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = URL(fileURLWithPath: "/tmp/pst-svc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = directory.appendingPathComponent("service.sock").path
        let tokenProvider = AutomationTokenProviderProbe(token: "synthetic-service-token")
        let clipboard = AutomationConfigurationWriterProbe()
        let dispatcher: AutomationDispatcher = { command, channel in
            let channelName: String
            switch channel {
            case .cli: channelName = "cli"
            case .mcp: channelName = "mcp"
            }
            return AutomationReply(id: command.id, result: .string(channelName))
        }
        let service = AutomationService(
            preferences: preferences,
            tokenProvider: { try await tokenProvider.provide() },
            socketPath: socketPath,
            dispatcher: dispatcher,
            configurationWriter: { clipboard.write($0) }
        )
        defer {
            Task { @MainActor in
                _ = await service.stop()
                try? FileManager.default.removeItem(at: directory)
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        XCTAssertFalse(service.enabled)
        await service.start()

        XCTAssertEqual(service.localStatus, "Available to local CLI")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(tokenProvider.callCount, 0)

        await service.copyCodexConfiguration()
        XCTAssertEqual(tokenProvider.callCount, 0)
        XCTAssertNil(clipboard.value)

        let localReply = try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: socketPath)
        XCTAssertEqual(localReply.result, .string("cli"))
        XCTAssertEqual(tokenProvider.callCount, 0)

        let port = try availableLoopbackPort()
        await service.setPort(port)
        XCTAssertEqual(service.port, port)
        XCTAssertEqual(tokenProvider.callCount, 0)

        await service.setEnabled(true)

        XCTAssertTrue(service.enabled)
        XCTAssertEqual(preferences.bool(forKey: "automation.mcp.enabled"), true)
        XCTAssertEqual(preferences.integer(forKey: "automation.mcp.port"), port)
        XCTAssertEqual(service.status, "Listening on http://127.0.0.1:\(port)/mcp")
        XCTAssertEqual(tokenProvider.callCount, 1)

        let expectedConfiguration = """
            [mcp_servers.postie]
            url = "http://127.0.0.1:\(port)/mcp"
            http_headers = { Authorization = "Bearer synthetic-service-token" }
            """
        await service.copyCodexConfiguration()
        XCTAssertEqual(tokenProvider.callCount, 2)
        XCTAssertEqual(clipboard.value, expectedConfiguration)

        let restoredService = AutomationService(
            preferences: preferences,
            tokenProvider: { try await tokenProvider.provide() },
            socketPath: socketPath,
            dispatcher: dispatcher
        )
        XCTAssertTrue(restoredService.enabled)
        XCTAssertEqual(restoredService.port, port)

        await service.setEnabled(false)

        XCTAssertFalse(service.enabled)
        XCTAssertEqual(preferences.bool(forKey: "automation.mcp.enabled"), false)
        XCTAssertEqual(service.status, "Disabled")
        XCTAssertEqual(tokenProvider.callCount, 2)
        XCTAssertFalse(try isListeningOnLoopback(port: port))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        await service.copyCodexConfiguration()
        XCTAssertEqual(tokenProvider.callCount, 2)

        let stopped = await service.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(service.status, "Stopped")
        XCTAssertEqual(service.localStatus, "Stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStopDuringDelayedTokenProviderDoesNotRestartAndLaterStartSucceeds() async throws {
        let suiteName = "AutomationServiceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = URL(fileURLWithPath: "/tmp/pst-svc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = directory.appendingPathComponent("service.sock").path
        let port = try availableLoopbackPort()
        preferences.set(true, forKey: "automation.mcp.enabled")
        preferences.set(port, forKey: "automation.mcp.port")
        let tokenProvider = AutomationTokenProviderProbe(token: "synthetic-retry-token", suspendFirstCall: true)
        let service = AutomationService(
            preferences: preferences,
            tokenProvider: { try await tokenProvider.provide() },
            socketPath: socketPath
        )
        defer {
            Task { @MainActor in
                tokenProvider.resumeFirstCall()
                _ = await service.stop()
                try? FileManager.default.removeItem(at: directory)
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        let firstStart = Task { await service.start() }
        try await tokenProvider.waitForFirstCallToSuspend()
        XCTAssertTrue(service.isChanging)

        let stoppedAfterCancellation = await service.stop()
        XCTAssertTrue(stoppedAfterCancellation)
        tokenProvider.resumeFirstCall()
        await firstStart.value

        XCTAssertEqual(tokenProvider.callCount, 1)
        XCTAssertFalse(service.isChanging)
        XCTAssertEqual(service.status, "Stopped")
        XCTAssertFalse(try isListeningOnLoopback(port: port))

        await service.start()

        XCTAssertEqual(tokenProvider.callCount, 2)
        XCTAssertEqual(service.status, "Listening on http://127.0.0.1:\(port)/mcp")
        XCTAssertTrue(try isListeningOnLoopback(port: port))
        let stoppedAfterRestart = await service.stop()
        XCTAssertTrue(stoppedAfterRestart)
    }

    func testStartQueuedDuringLocalDrainLeavesNewListenerRunning() async throws {
        let suiteName = "AutomationServiceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = URL(fileURLWithPath: "/tmp/pst-svc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = directory.appendingPathComponent("service.sock").path
        let dispatcherGate = AutomationDispatcherGate()
        let service = AutomationService(
            preferences: preferences,
            socketPath: socketPath,
            dispatcher: { command, channel in
                await dispatcherGate.dispatch(command, channel)
            }
        )
        await service.start()

        var heldRequestCompleted = false
        let heldRequest = Task {
            defer { heldRequestCompleted = true }
            return try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: socketPath)
        }
        var stopCompleted = false
        var stopTask: Task<Bool, Never>?
        var startCompleted = false
        var startTask: Task<Void, Never>?
        defer {
            Task { @MainActor in
                await dispatcherGate.resumeFirstCall()
                let deadline = Date().addingTimeInterval(5)
                while !(heldRequestCompleted && (stopTask == nil || stopCompleted)
                    && (startTask == nil || startCompleted)), Date() < deadline
                {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard heldRequestCompleted, stopTask == nil || stopCompleted,
                    startTask == nil || startCompleted
                else { return }
                if let stopTask { _ = await stopTask.value }
                if let startTask { await startTask.value }
                _ = try? await heldRequest.value
                _ = await service.stop()
                try? FileManager.default.removeItem(at: directory)
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        try await dispatcherGate.waitForFirstCallToSuspend()
        stopTask = Task {
            defer { stopCompleted = true }
            return await service.stop()
        }
        await Task.yield()
        var startEntered = false
        startTask = Task {
            defer { startCompleted = true }
            startEntered = true
            await service.start()
        }
        await Task.yield()

        let queuedStartDeadline = Date().addingTimeInterval(5)
        while !(startEntered && service.isChanging) && Date() < queuedStartDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let startRemainsQueued = startEntered && service.isChanging
        XCTAssertTrue(startRemainsQueued)

        await dispatcherGate.resumeFirstCall()
        let completionDeadline = Date().addingTimeInterval(5)
        while !(heldRequestCompleted && stopCompleted && startCompleted), Date() < completionDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let operationsCompleted = heldRequestCompleted && stopCompleted && startCompleted
        XCTAssertTrue(operationsCompleted)
        guard operationsCompleted else { return }

        let stopped = await stopTask?.value ?? false
        XCTAssertTrue(stopped)
        _ = try await heldRequest.value
        await startTask?.value

        XCTAssertEqual(service.localStatus, "Available to local CLI")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let laterReply = try await LocalIPC.send(
            AutomationCommand(operation: .collectionsList),
            socketPath: socketPath
        )
        XCTAssertEqual(laterReply.result, .string("cli"))
        let stoppedAfterRestart = await service.stop()
        XCTAssertTrue(stoppedAfterRestart)
    }

    func testStopDuringSuspendedConfigurationCopyDoesNotWriteClipboard() async throws {
        let suiteName = "AutomationServiceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences.set(true, forKey: "automation.mcp.enabled")
        let tokenProvider = AutomationTokenProviderProbe(token: "synthetic-copy-token", suspendFirstCall: true)
        let clipboard = AutomationConfigurationWriterProbe()
        let service = AutomationService(
            preferences: preferences,
            tokenProvider: { try await tokenProvider.provide() },
            configurationWriter: { clipboard.write($0) }
        )
        var copyCompleted = false
        let copyTask = Task {
            defer { copyCompleted = true }
            await service.copyCodexConfiguration()
        }
        var stopCompleted = false
        var stopTask: Task<Bool, Never>?
        defer {
            tokenProvider.resumeFirstCall()
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(5)
                while !(copyCompleted && (stopTask == nil || stopCompleted)), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if stopCompleted, let stopTask { _ = await stopTask.value }
                if copyCompleted { await copyTask.value }
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        try await tokenProvider.waitForFirstCallToSuspend()

        stopTask = Task {
            defer { stopCompleted = true }
            return await service.stop()
        }
        let suspendedStopDeadline = Date().addingTimeInterval(5)
        while !stopCompleted && Date() < suspendedStopDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let stoppedWhileProviderSuspended = stopCompleted
        tokenProvider.resumeFirstCall()
        let completionDeadline = Date().addingTimeInterval(5)
        while !(stopCompleted && copyCompleted), Date() < completionDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let operationsCompleted = stopCompleted && copyCompleted
        XCTAssertTrue(stoppedWhileProviderSuspended)
        XCTAssertTrue(operationsCompleted)
        guard operationsCompleted else {
            XCTAssertNil(clipboard.value)
            return
        }

        let stopped = await stopTask?.value ?? false
        await copyTask.value
        XCTAssertTrue(stopped)
        XCTAssertNil(clipboard.value)
    }

    func testProviderFailureCanBeRetriedWithoutLeavingChangingStateSet() async throws {
        let suiteName = "AutomationServiceTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = URL(fileURLWithPath: "/tmp/pst-svc-\(UUID().uuidString)", isDirectory: true)
        let port = try availableLoopbackPort()
        preferences.set(true, forKey: "automation.mcp.enabled")
        preferences.set(port, forKey: "automation.mcp.port")
        let tokenProvider = AutomationTokenProviderProbe(token: "synthetic-retry-token", failuresRemaining: 1)
        let service = AutomationService(
            preferences: preferences,
            tokenProvider: { try await tokenProvider.provide() },
            socketPath: directory.appendingPathComponent("service.sock").path
        )
        defer {
            Task { @MainActor in
                _ = await service.stop()
                try? FileManager.default.removeItem(at: directory)
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        await service.start()

        XCTAssertEqual(tokenProvider.callCount, 1)
        XCTAssertFalse(service.isChanging)
        XCTAssertTrue(service.status.hasPrefix("MCP unavailable:"))
        XCTAssertFalse(try isListeningOnLoopback(port: port))

        await service.setEnabled(false)
        XCTAssertFalse(service.isChanging)
        await service.setEnabled(true)

        XCTAssertEqual(tokenProvider.callCount, 2)
        XCTAssertFalse(service.isChanging)
        XCTAssertEqual(service.status, "Listening on http://127.0.0.1:\(port)/mcp")
        XCTAssertTrue(try isListeningOnLoopback(port: port))
        let stoppedAfterRetry = await service.stop()
        XCTAssertTrue(stoppedAfterRetry)
    }
}

@MainActor
private final class AutomationTokenProviderProbe {
    let token: String
    private(set) var callCount = 0
    private var failuresRemaining: Int
    private let suspendFirstCall: Bool
    private var firstCallIsSuspended = false
    private var shouldResumeFirstCall = false
    private var firstCallContinuation: CheckedContinuation<String, Error>?

    init(token: String, failuresRemaining: Int = 0, suspendFirstCall: Bool = false) {
        self.token = token
        self.failuresRemaining = failuresRemaining
        self.suspendFirstCall = suspendFirstCall
    }

    func provide() async throws -> String {
        callCount += 1
        if suspendFirstCall, callCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstCallContinuation = continuation
                firstCallIsSuspended = true
                if shouldResumeFirstCall {
                    continuation.resume(returning: token)
                    firstCallContinuation = nil
                }
            }
        }
        guard failuresRemaining > 0 else { return token }
        failuresRemaining -= 1
        throw AutomationServiceTestError.providerFailure
    }

    func waitForFirstCallToSuspend() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !firstCallIsSuspended {
            guard Date() < deadline else { throw AutomationServiceTestError.probeTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func resumeFirstCall() {
        shouldResumeFirstCall = true
        firstCallContinuation?.resume(returning: token)
        firstCallContinuation = nil
    }
}

private actor AutomationDispatcherGate {
    private var callCount = 0
    private var firstCallIsSuspended = false
    private var shouldResumeFirstCall = false
    private var firstCallContinuation: CheckedContinuation<AutomationReply, Never>?
    private var firstCallReply: AutomationReply?

    func dispatch(_ command: AutomationCommand, _ channel: AutomationChannel) async -> AutomationReply {
        let channelName: String
        switch channel {
        case .cli: channelName = "cli"
        case .mcp: channelName = "mcp"
        }
        let reply = AutomationReply(id: command.id, result: .string(channelName))
        callCount += 1
        guard callCount == 1 else { return reply }

        return await withCheckedContinuation { continuation in
            firstCallReply = reply
            firstCallContinuation = continuation
            firstCallIsSuspended = true
            if shouldResumeFirstCall {
                continuation.resume(returning: reply)
                firstCallContinuation = nil
                firstCallReply = nil
            }
        }
    }

    func waitForFirstCallToSuspend() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !firstCallIsSuspended {
            guard Date() < deadline else { throw AutomationServiceTestError.probeTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func resumeFirstCall() {
        shouldResumeFirstCall = true
        guard let firstCallContinuation, let firstCallReply else { return }
        firstCallContinuation.resume(returning: firstCallReply)
        self.firstCallContinuation = nil
        self.firstCallReply = nil
    }
}

@MainActor
private final class AutomationConfigurationWriterProbe {
    private(set) var value: String?

    func write(_ value: String) {
        self.value = value
    }
}

private enum AutomationServiceTestError: Error {
    case providerFailure
    case probeTimedOut
}

private func availableLoopbackPort() throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &addressLength)
        }
    }
    guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return Int(UInt16(bigEndian: address.sin_port))
}

private func isListeningOnLoopback(port: Int) throws -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if result == 0 { return true }
    if errno == ECONNREFUSED || errno == ETIMEDOUT { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
