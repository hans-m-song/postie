import Foundation
import XCTest
import PostieCore
@testable import PostieAutomation

final class BodySyntaxAutomationContractTests: XCTestCase {
    func testRequestSchemaAndPatchAcceptEveryBodySyntax() async throws {
        let definition = try XCTUnwrap(
            AutomationToolCatalog.definitions.first { $0.operation == .requestsCreate }
        )
        let inputSchema = try XCTUnwrap(definition.inputSchema.objectValue)
        let inputProperties = try XCTUnwrap(inputSchema["properties"]?.objectValue)
        let requestSchema = try XCTUnwrap(inputProperties["request"]?.objectValue)
        let requestProperties = try XCTUnwrap(requestSchema["properties"]?.objectValue)
        let syntaxSchema = try XCTUnwrap(requestProperties["bodySyntax"]?.objectValue)
        let schemaValues = try XCTUnwrap(syntaxSchema["enum"]?.arrayValue)
            .compactMap(\.stringValue)

        XCTAssertEqual(schemaValues, BodySyntax.allCases.map(\.rawValue))

        for syntax in BodySyntax.allCases {
            let patched = try await RequestPatch.apply(
                .object(["bodySyntax": .string(syntax.rawValue)]),
                to: HTTPRequestConfiguration()
            ) { _ in
                throw AutomationFailure(.unavailable, "This patch does not require encryption.")
            }
            XCTAssertEqual(patched.bodySyntax, syntax)
        }
    }
}
