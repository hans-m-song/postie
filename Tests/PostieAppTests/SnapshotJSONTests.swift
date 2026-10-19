import Foundation
import PostieCore
import XCTest
@testable import PostieApp

final class SnapshotJSONTests: XCTestCase {
    func testExportsCapturedResolvedRequestAndActualInputValues() throws {
        let fixture = try makeSnapshot(body: Data("{\"ok\":true}".utf8), hasContext: true)
        defer { try? FileManager.default.removeItem(at: fixture.bodyURL.deletingLastPathComponent()) }

        let json = try SnapshotJSONExporter.encode(fixture.snapshot)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try XCTUnwrap(document["request"] as? [String: Any])
        let headers = try XCTUnwrap(request["headers"] as? [[String: Any]])
        let capturedContext = try XCTUnwrap(document["capturedContext"] as? [String: Any])
        let authentication = try XCTUnwrap(capturedContext["authentication"] as? [String: Any])
        let inputs = try XCTUnwrap(capturedContext["referencedInputs"] as? [String: [String: Any]])

        XCTAssertEqual(request["url"] as? String, "https://api.example.invalid/customers/42?token=actual-query-secret")
        XCTAssertEqual(headers.first(where: { $0["name"] as? String == "Authorization" })?["value"] as? String, "Basic c3ludGhldGljLXVzZXI6YWN0dWFsLXBhc3N3b3Jk")
        XCTAssertEqual(request["body"] as? String, "{\"customer\":42,\"token\":\"actual-body-secret\"}")
        XCTAssertEqual(authentication["resolvedSecret"] as? String, "actual-password")
        XCTAssertNil(authentication["secretTemplate"])
        XCTAssertEqual(inputs["customerId"]?["value"] as? String, "42")
        XCTAssertEqual(inputs["token"]?["value"] as? String, "actual-query-secret")
        XCTAssertFalse(json.contains("{{"))
        XCTAssertTrue(json.contains("actual-body-secret"))
    }

    func testExportsBinaryResponsePreviewAsBase64() throws {
        let bytes = Data([0x00, 0xFF, 0x41, 0x80])
        let fixture = try makeSnapshot(body: bytes, hasContext: true)
        defer { try? FileManager.default.removeItem(at: fixture.bodyURL.deletingLastPathComponent()) }

        let document = try exportDocument(fixture.snapshot)
        let response = try XCTUnwrap(document["response"] as? [String: Any])
        let body = try XCTUnwrap(response["body"] as? [String: Any])

        XCTAssertEqual(body["encoding"] as? String, "base64")
        XCTAssertEqual(body["content"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(body["byteCount"] as? Int64, Int64(bytes.count))
        XCTAssertEqual(body["previewByteCount"] as? Int, bytes.count)
        XCTAssertEqual(body["truncated"] as? Bool, false)
    }

    func testMissingContextAndLargeBodyAreExplicitAndBounded() throws {
        let bytes = Data(repeating: 0x61, count: SnapshotJSONExporter.maximumBodyPreviewBytes + 1)
        let fixture = try makeSnapshot(body: bytes, hasContext: false)
        defer { try? FileManager.default.removeItem(at: fixture.bodyURL.deletingLastPathComponent()) }

        let json = try SnapshotJSONExporter.encode(fixture.snapshot)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try XCTUnwrap(document["request"] as? [String: Any])
        let context = try XCTUnwrap(document["capturedContext"] as? [String: Any])
        let response = try XCTUnwrap(document["response"] as? [String: Any])
        let body = try XCTUnwrap(response["body"] as? [String: Any])

        XCTAssertEqual(request["available"] as? Bool, false)
        XCTAssertEqual(context["available"] as? Bool, false)
        XCTAssertEqual(context["error"] as? String, "Synthetic missing-key context")
        XCTAssertNil(response["finalURL"])
        XCTAssertFalse(json.contains("about:blank"))
        XCTAssertFalse(json.contains("{{customerId}}"))
        XCTAssertEqual(body["previewByteCount"] as? Int, SnapshotJSONExporter.maximumBodyPreviewBytes)
        XCTAssertEqual(body["byteCount"] as? Int64, Int64(bytes.count))
        XCTAssertEqual(body["truncated"] as? Bool, true)
    }

    private func exportDocument(_ snapshot: OpenedSnapshot) throws -> [String: Any] {
        let json = try SnapshotJSONExporter.encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func makeSnapshot(body: Data, hasContext: Bool) throws -> (snapshot: OpenedSnapshot, bodyURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appendingPathComponent("synthetic-response.body")
        try body.write(to: bodyURL)

        let collectionID = UUID()
        let requestID = UUID()
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        let source = SnapshotSource(identity: identity, collectionName: "Synthetic collection", requestName: "Synthetic request")
        let templateConfiguration = HTTPRequestConfiguration(
            name: "Synthetic request",
            method: "POST",
            url: "https://api.example.invalid/customers/{{customerId}}?token={{token}}",
            body: "{\"customer\":{{customerId}},\"token\":\"{{token}}\"}",
            bodyEnabled: true,
            bodySyntax: .json
        )
        let template = SnapshotRequestTemplate(configuration: templateConfiguration)
        let submitted = SnapshotTransportRequest(
            method: "POST",
            url: URL(string: "https://api.example.invalid/customers/42?token=actual-query-secret")!,
            headers: [HTTPField(name: "Authorization", value: "Basic c3ludGhldGljLXVzZXI6YWN0dWFsLXBhc3N3b3Jk")],
            body: "{\"customer\":42,\"token\":\"actual-body-secret\"}",
            headerSources: ["authorization": .requestAuth],
            sensitiveNames: ["authorization"],
            secretNames: ["authorization"]
        )
        let preparation = SnapshotPreparationCapture(
            template: template,
            referencedInputs: [
                "customerId": SnapshotInput(value: "42", scope: .collection, isSecret: false),
                "token": SnapshotInput(value: "actual-query-secret", scope: .global, isSecret: true)
            ],
            authentication: SnapshotAuthenticationInput(kind: .basic, username: "synthetic-user", resolvedSecret: "actual-password"),
            submitted: submitted
        )
        let context = hasContext
            ? FrozenSnapshotContext(preparation: preparation, observedTransport: submitted, redirects: [])
            : nil
        let responseURL = context?.observedTransport.url ?? URL(string: "about:blank")!
        let response = HTTPResponseRecord(
            runID: UUID(),
            request: templateConfiguration,
            finalURL: responseURL,
            statusCode: 201,
            requestHeaders: context?.observedTransport.headers ?? [],
            responseHeaders: [HTTPField(name: "Content-Type", value: "application/octet-stream")],
            redirects: [HTTPRedirect(
                statusCode: 302,
                url: context?.observedTransport.url ?? responseURL,
                nextURL: context?.observedTransport.url ?? responseURL,
                method: "POST",
                nextMethod: "GET",
                requestHeaders: context?.observedTransport.headers ?? [],
                responseHeaders: [HTTPField(name: "Location", value: "/next")]
            )],
            bodyFileURL: bodyURL,
            bodyByteCount: Int64(body.count),
            duration: 0.25,
            effectiveMethod: "POST",
            snapshotCapture: hasContext ? preparation : nil
        )
        let summary = SavedSnapshot(
            id: UUID(),
            name: "Synthetic snapshot",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: source,
            statusCode: 201,
            bodyByteCount: Int64(body.count)
        )
        let opened = OpenedSnapshot(
            summary: summary,
            template: template,
            context: context,
            contextError: hasContext ? nil : "Synthetic missing-key context",
            response: response
        )

        return (opened, bodyURL)
    }
}
