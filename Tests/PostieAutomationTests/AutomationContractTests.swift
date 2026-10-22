import Foundation
import XCTest
import PostieCore
@testable import PostieAutomation

final class AutomationContractTests: XCTestCase {
    func testArgumentsRejectPrivilegeSwitches() throws {
        for field in ["raw", "channel", "mcpPolicy", "excluded", "responseViewing"] {
            XCTAssertThrowsError(try AutomationArguments([field: .bool(true)], allowed: ["requestID"]))
        }
        let arguments = try AutomationArguments(["requestID": .string("invalid")], allowed: ["requestID"])
        XCTAssertThrowsError(try arguments.uuid("requestID"))
    }

    func testCommandsRoundTripWithoutEncodingAChannel() throws {
        let command = AutomationCommand(operation: .requestsStart, arguments: ["requestID": .string(UUID().uuidString)])
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(AutomationCommand.self, from: data), command)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "operation", "arguments"])
        XCTAssertEqual(AutomationOperation(toolName: "requests_start"), .requestsStart)
    }

    func testParentExclusionAndClosestResponsePolicy() {
        XCTAssertFalse(MCPResourcePolicy.isAccessible(collection: .init(excluded: true), request: .init()))
        XCTAssertFalse(MCPResourcePolicy.isAccessible(collection: .init(), request: .init(excluded: true)))
        XCTAssertTrue(MCPResourcePolicy.isAccessible(collection: .init(), request: .init()))
        XCTAssertFalse(MCPResponseViewPolicy.resolve())
        XCTAssertTrue(MCPResponseViewPolicy.resolve(global: .block, collection: .allow))
        XCTAssertFalse(MCPResponseViewPolicy.resolve(global: .allow, collection: .allow, request: .block))
    }

    func testRequestPatchPreservesPolicyAndRejectsPolicyMutation() async throws {
        var original = HTTPRequestConfiguration(name: "Original")
        original.mcpPolicy = .init(excluded: true, responseViewing: .block)
        original.variables = ["secret": .encrypted(.init(combined: "synthetic-envelope"))]
        let patched = try await RequestPatch.apply(.object(["name": .string("Edited")]), to: original) { _ in
            throw AutomationFailure(.unavailable, "Encryption is outside this test.")
        }
        XCTAssertEqual(patched.name, "Edited")
        XCTAssertEqual(patched.mcpPolicy, original.mcpPolicy)
        XCTAssertEqual(patched.variables, original.variables)
        do {
            _ = try await RequestPatch.apply(.object(["mcpPolicy": .object([:])]), to: original) { _ in
                .init(combined: "unused")
            }
            XCTFail("Policy edit accepted")
        } catch let error as AutomationFailure { XCTAssertEqual(error.code, .invalidArguments) }
    }

    func testRequestPatchParsesURLQueryAndEncryptsAuthInput() async throws {
        let patched = try await RequestPatch.apply(
            .object([
                "url": .string("https://example.invalid/path?key=value"),
                "authentication": .object([
                    "kind": .string("apiKey"), "apiKeyHeaderName": .string("X-Key"), "apiKey": .string("synthetic"),
                ]),
            ]), to: HTTPRequestConfiguration()
        ) { value in
            XCTAssertEqual(value, "synthetic")
            return .init(combined: "encrypted-synthetic")
        }
        XCTAssertEqual(patched.url, "https://example.invalid/path")
        XCTAssertEqual(patched.query.map(\.name), ["key"])
        XCTAssertEqual(patched.authentication.apiKey?.combined, "encrypted-synthetic")
    }
}
