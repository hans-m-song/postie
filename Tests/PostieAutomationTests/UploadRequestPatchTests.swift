import Foundation
import PostieCore
import XCTest
@testable import PostieAutomation

final class UploadRequestPatchTests: XCTestCase {
    func testMultipartPatchReferencesMissingFilesWithoutReadingThem() async throws {
        let request = try await patch([
            "bodyKind": .string("multipart"),
            "multipartParts": .array([
                .object(["name": .string("description"), "kind": .string("text"), "text": .string("{{description}}")]),
                .object([
                    "name": .string("document"), "kind": .string("file"),
                    "file": .object([
                        "path": .string("/synthetic/missing.pdf"), "contentType": .string("application/pdf"),
                    ]),
                    "isEnabled": .bool(false),
                ]),
            ]),
        ])
        XCTAssertEqual(request.bodyKind, .multipart)
        XCTAssertEqual(request.multipartParts.map(\.name), ["description", "document"])
        XCTAssertEqual(request.multipartParts[0].text, "{{description}}")
        XCTAssertEqual(request.multipartParts[1].file?.path, "/synthetic/missing.pdf")
        XCTAssertFalse(request.multipartParts[1].isEnabled)
    }

    func testRawFileCanBeSetAndClearedWithoutChangingText() async throws {
        var original = HTTPRequestConfiguration()
        original.body = "keep this inactive text"
        let configured = try await patch(
            [
                "bodyKind": .string("rawFile"),
                "rawFile": .object(["path": .string("/synthetic/file.bin")]),
            ], original: original)
        XCTAssertEqual(configured.body, original.body)
        XCTAssertEqual(configured.rawFile?.path, "/synthetic/file.bin")
        let cleared = try await patch(["rawFile": .null], original: configured)
        XCTAssertNil(cleared.rawFile)
    }

    func testRejectsRelativePathsUnknownFieldsAndInvalidTypes() async {
        let invalid: [[String: AutomationJSON]] = [
            ["rawFile": .object(["path": .string("relative.bin")])],
            ["rawFile": .object(["path": .string("/synthetic/file"), "bytes": .string("unsupported")])],
            ["bodyKind": .string("unknown")],
            [
                "multipartParts": .array([
                    .object(["name": .string("x"), "kind": .string("text"), "isEnabled": .string("yes")])
                ])
            ],
        ]
        for fields in invalid {
            do {
                _ = try await patch(fields)
                XCTFail("Invalid upload configuration was accepted")
            } catch {
                XCTAssertTrue(error is AutomationFailure)
            }
        }
    }

    private func patch(
        _ fields: [String: AutomationJSON], original: HTTPRequestConfiguration = .init()
    ) async throws -> HTTPRequestConfiguration {
        try await RequestPatch.apply(.object(fields), to: original) { _ in
            throw AutomationFailure(.unavailable, "Upload configuration requires no secret access.")
        }
    }
}
