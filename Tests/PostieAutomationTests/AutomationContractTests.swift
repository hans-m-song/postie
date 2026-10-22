import Foundation
import XCTest
import PostieCore
@testable import PostieAutomation

final class AutomationContractTests: XCTestCase {
    func testMCPCollectionSelectorsUseNamesAndDiscoveryArgumentsAreOptional() throws {
        let requiredCollection: [AutomationOperation] = [
            .requestsGet, .requestsCreate, .requestsUpdate, .requestsStart,
        ]
        let optionalCollection: [AutomationOperation] = [.requestsList, .variablesList, .variablesGet, .snapshotsList]
        for definition in AutomationToolCatalog.definitions {
            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let required = Set(try XCTUnwrap(schema["required"]?.arrayValue).compactMap(\.stringValue))
            XCTAssertNil(properties["collectionID"], definition.operation.rawValue)
            if requiredCollection.contains(definition.operation) || optionalCollection.contains(definition.operation) {
                XCTAssertEqual(properties["collectionName"]?.objectValue?["type"], .string("string"))
                XCTAssertEqual(required.contains("collectionName"), requiredCollection.contains(definition.operation))
            } else {
                XCTAssertNil(properties["collectionName"])
            }
            if definition.operation == .requestsList {
                XCTAssertEqual(properties["query"]?.objectValue?["type"], .string("string"))
                XCTAssertTrue(required.isEmpty)
                XCTAssertEqual(Set(properties.keys), ["collectionName", "query"])
            }
            if [.requestsGet, .requestsUpdate, .requestsStart].contains(definition.operation) {
                XCTAssertTrue(required.contains("requestID"))
            }
            if [.runsGet, .runsCancel, .snapshotsCreate].contains(definition.operation) {
                XCTAssertTrue(required.contains("runID"))
            }
            if [.snapshotsGet, .snapshotsRename, .snapshotsDelete].contains(definition.operation) {
                XCTAssertTrue(required.contains("snapshotID"))
            }
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
        }
    }

    func testRequestDiscoveryMatchesOnlyUnresolvedNamesAndSavedPaths() {
        let cases: [(url: String, pathQuery: String, excludedQueries: [String])] = [
            (
                "https://user-secret:password-secret@authority-secret.invalid/v1/People?token=query-secret#fragment-secret",
                "PEOPLE", ["user-secret", "password-secret", "authority-secret", "query-secret", "fragment-secret"]
            ),
            (
                "{{baseURL}}/v1/People/{{person}}?token=query-secret#fragment-secret",
                "{{PERSON}}", ["baseURL", "query-secret", "fragment-secret"]
            ),
            ("{{origin}}:8080/api", "/API", ["origin", "8080"]),
            ("{{origin}}.authority-secret.invalid/api", "/api", ["origin", "authority-secret"]),
            ("{{scheme}}://{{authority}}/route", "/route", ["scheme", "authority"]),
            ("//authority-secret.invalid/route", "/route", ["authority-secret"]),
            ("https://example.invalid/caf%C3%A9", "caf%c3%a9", ["café"]),
            ("/redirect/http://nested.invalid/route", "/redirect/http://", []),
        ]
        for entry in cases {
            let request = HTTPRequestConfiguration(
                name: "Profile lookup", url: entry.url,
                query: [HTTPField(name: "query-table", value: "query-table-secret")],
                headers: [HTTPField(name: "X-Key", value: "header-secret")], body: "body-secret")
            XCTAssertTrue(RequestDiscovery.matches(request, query: entry.pathQuery), entry.url)
            XCTAssertTrue(RequestDiscovery.matches(request, query: "  PROFILE  "), entry.url)
            XCTAssertTrue(RequestDiscovery.matches(request, query: ""), entry.url)
            XCTAssertTrue(RequestDiscovery.matches(request, query: " \n"), entry.url)
            for query in entry.excludedQueries + ["query-table-secret", "header-secret", "body-secret", "missing"] {
                XCTAssertFalse(RequestDiscovery.matches(request, query: query), "\(entry.url): \(query)")
            }
        }
        let substringRequest = HTTPRequestConfiguration(name: "Profile lookup", url: "{{baseURL}}/v1/People/{{person}}")
        XCTAssertTrue(RequestDiscovery.matches(substringRequest, query: "rofil"))
        XCTAssertTrue(RequestDiscovery.matches(substringRequest, query: "eopl"))
        for url in ["https://authority-secret.invalid?token=query-secret", "{{baseURL}}", "{{origin}}:8080"] {
            let request = HTTPRequestConfiguration(name: "Neutral", url: url)
            for query in ["authority-secret", "query-secret", "baseURL", "origin", "8080"] {
                XCTAssertFalse(RequestDiscovery.matches(request, query: query), "\(url): \(query)")
            }
        }
    }

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
