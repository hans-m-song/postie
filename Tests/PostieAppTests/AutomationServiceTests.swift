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
        let keyStore = AutomationServiceTestKeyStore()
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
            keyStore: keyStore,
            socketPath: socketPath,
            dispatcher: dispatcher
        )
        defer {
            Task {
                _ = await service.stop()
                try? FileManager.default.removeItem(at: directory)
                preferences.removePersistentDomain(forName: suiteName)
            }
        }

        XCTAssertFalse(service.enabled)
        await service.start()

        XCTAssertEqual(service.localStatus, "Available to local CLI")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(keyStore.loadCount, 0)
        XCTAssertEqual(keyStore.createCount, 0)

        let localReply = try await LocalIPC.send(AutomationCommand(operation: .collectionsList), socketPath: socketPath)
        XCTAssertEqual(localReply.result, .string("cli"))
        XCTAssertEqual(keyStore.loadCount, 0)

        let port = try availableLoopbackPort()
        await service.setPort(port)
        XCTAssertEqual(service.port, port)
        XCTAssertEqual(keyStore.loadCount, 0)

        await service.setEnabled(true)

        XCTAssertTrue(service.enabled)
        XCTAssertEqual(preferences.bool(forKey: "automation.mcp.enabled"), true)
        XCTAssertEqual(preferences.integer(forKey: "automation.mcp.port"), port)
        XCTAssertEqual(service.status, "Listening on http://127.0.0.1:\(port)/mcp")
        XCTAssertEqual(keyStore.loadCount, 1)
        XCTAssertEqual(keyStore.createCount, 0)

        let restoredService = AutomationService(
            preferences: preferences,
            keyStore: keyStore,
            socketPath: socketPath,
            dispatcher: dispatcher
        )
        XCTAssertTrue(restoredService.enabled)
        XCTAssertEqual(restoredService.port, port)

        await service.setEnabled(false)

        XCTAssertFalse(service.enabled)
        XCTAssertEqual(preferences.bool(forKey: "automation.mcp.enabled"), false)
        XCTAssertEqual(service.status, "Disabled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let stopped = await service.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(service.status, "Stopped")
        XCTAssertEqual(service.localStatus, "Stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}

private final class AutomationServiceTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private let key = Data(repeating: 0x5A, count: 32)
    private var loads = 0
    private var creates = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var createCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return creates
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        return key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        creates += 1
        return key
    }
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
