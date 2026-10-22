import Foundation
import Darwin
import XCTest
import PostieAutomation
@testable import PostieControl

final class LocalIPCTests: XCTestCase {
    func testPrivateSocketDispatchesOnlyCLIChannelAndStopsCleanly() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "postie-ipc-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("control.sock").path
        let server = LocalIPCServer(socketPath: path) { command, channel in
            switch channel {
            case .cli: return AutomationReply(id: command.id, result: .string("trusted-local"))
            case .mcp: return AutomationReply(id: command.id, error: .init(.forbidden, "Wrong adapter."))
            }
        }
        try await server.start()
        do {
            let command = AutomationCommand(operation: .collectionsList)
            let result = try await LocalIPC.send(command, socketPath: path)
            XCTAssertEqual(result, AutomationReply(id: command.id, result: .string("trusted-local")))
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            await server.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            try FileManager.default.removeItem(at: directory)
        } catch {
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testWorldAccessibleDirectoryIsRejected() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "postie-ipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = LocalIPCServer(socketPath: directory.appendingPathComponent("control.sock").path) { command, _ in
            AutomationReply(id: command.id, result: .null)
        }
        do { try await server.start(); XCTFail("Unsafe directory accepted") } catch LocalIPCError.unsafePath {}
    }

    func testMissingSocketDirectoryIsUnavailableWithOpenPostieGuidance() async {
        let path = "/tmp/postie-ipc-\(UUID().uuidString)/control.sock"

        await assertUnavailable(socketPath: path)
        XCTAssertTrue(LocalIPCError.unavailable.errorDescription?.contains("Open Postie") == true)
    }

    func testMissingSocketIsUnavailableWithOpenPostieGuidance() async throws {
        let directory = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        await assertUnavailable(socketPath: directory.appendingPathComponent("control.sock").path)
        XCTAssertTrue(LocalIPCError.unavailable.errorDescription?.contains("Open Postie") == true)
    }

    func testInsecureSocketDirectoryModeRemainsUnsafePath() async throws {
        let directory = try makeSocketDirectory(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: directory) }

        await assertUnsafePath(socketPath: directory.appendingPathComponent("control.sock").path)
    }

    func testRegularFileAtSocketPathRemainsUnsafePath() async throws {
        let directory = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))

        await assertUnsafePath(socketPath: path)
    }

    func testSymbolicLinkAtSocketPathRemainsUnsafePath() async throws {
        let directory = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let path = directory.appendingPathComponent("control.sock").path
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)

        await assertUnsafePath(socketPath: path)
    }

    func testInsecureSocketModeRemainsUnsafePath() async throws {
        let directory = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        try createStaleSocket(at: path, mode: 0o644)

        await assertUnsafePath(socketPath: path)
    }

    func testRefusedStaleSocketIsUnavailable() async throws {
        let directory = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        try createStaleSocket(at: path)

        await assertUnavailable(socketPath: path)
    }

    func testUnstartedOrRepeatedStopCannotRemoveAnotherServerSocket() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "postie-ipc-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("control.sock").path
        let dispatch: AutomationDispatcher = { command, _ in AutomationReply(id: command.id, result: .null) }
        let owner = LocalIPCServer(socketPath: path, dispatcher: dispatch)
        let other = LocalIPCServer(socketPath: path, dispatcher: dispatch)
        try await owner.start()
        await other.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await owner.stop()
        try await other.start()
        await owner.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await other.stop()
        try FileManager.default.removeItem(at: directory)
    }

    func testIncompleteDrainPreservesAcceptedOperationAndCanResume() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "postie-ipc-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("control.sock").path
        let gate = DispatchGate()
        let server = LocalIPCServer(socketPath: path) { command, _ in
            await gate.acceptAndWait()
            return AutomationReply(id: command.id, result: .bool(true))
        }
        try await server.start()
        let operation = Task {
            try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: path)
        }
        for _ in 0..<200 {
            if await gate.accepted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let accepted = await gate.accepted
        guard accepted else { await server.stop(); XCTFail("Command was not accepted"); return }
        let drained = await server.stop(drainTimeout: 0.05)
        XCTAssertFalse(drained)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        await gate.finish()
        let result = try await operation.value
        XCTAssertEqual(result.result, .bool(true))
        try await server.start()
        let finalDrain = await server.stop()
        XCTAssertTrue(finalDrain)
        try FileManager.default.removeItem(at: directory)
    }
}

private func makeSocketDirectory(mode: Int = 0o700) throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
        "postie-ipc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
    return directory
}

private func createStaleSocket(at path: String, mode: mode_t = 0o600) throws {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: "LocalIPCTests", code: Int(errno)) }
    defer { Darwin.close(descriptor) }

    let result = try LocalIPC.address(path: path) { Darwin.bind(descriptor, $0, $1) }
    guard result == 0, chmod(path, mode) == 0 else { throw NSError(domain: "LocalIPCTests", code: Int(errno)) }
}

private func assertUnavailable(socketPath: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: socketPath)
        XCTFail("Expected unavailable local socket", file: file, line: line)
    } catch LocalIPCError.unavailable {} catch { XCTFail("Expected unavailable, got \(error)", file: file, line: line) }
}

private func assertUnsafePath(socketPath: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: socketPath)
        XCTFail("Expected unsafe local socket path", file: file, line: line)
    } catch LocalIPCError.unsafePath {} catch { XCTFail("Expected unsafePath, got \(error)", file: file, line: line) }
}

private actor DispatchGate {
    var accepted = false
    private var continuation: CheckedContinuation<Void, Never>?
    func acceptAndWait() async {
        accepted = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
