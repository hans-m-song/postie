import PostieCore
import XCTest
@testable import PostieApp

final class CapturedHeaderSensitivityTests: XCTestCase {
    func testFrozenTemplatedSensitiveNamesMaskLiteralValuesBeforeBulkEncoding() throws {
        let fields = [
            HTTPField(name: "{{standard}}", value: "Bearer synthetic-private"),
            HTTPField(name: "{{custom}}", value: "synthetic-custom-private"),
            HTTPField(name: "{{hidden}}", value: "synthetic-hidden-private"),
            HTTPField(name: "X-Public", value: "visible"),
        ]
        let inputs: [String: SnapshotInput] = [
            "standard": .init(value: "Authorization", scope: .collection, isSecret: false),
            "custom": .init(value: "X-API-Key", scope: .request, isSecret: false),
            "hidden": .init(value: "X-Private-Name", scope: .global, isSecret: true),
        ]
        let sensitivity = CapturedHeaderSensitivity.resolve(
            fields: fields, inputs: inputs, sensitiveNames: ["x-api-key"], secretNames: ["x-private-name"])
        let text = ReadOnlyHTTPFieldPresentation.bulkText(
            fields, sensitiveNames: sensitivity.sensitiveNames, secretNames: sensitivity.secretNames,
            includesStandardHeaderNames: true, hidesSecretFieldNames: true)
        let displayed = try HTTPFieldBulkText.decode(text)
        XCTAssertEqual(displayed.map(\.value), ["••••••••", "••••••••", "••••••••", "visible"])
        XCTAssertEqual(displayed.map(\.name), ["{{standard}}", "{{custom}}", "Secret header", "X-Public"])
        XCTAssertFalse(text.contains("synthetic-"))

        let revealed = ReadOnlyHTTPFieldPresentation.bulkText(
            fields, sensitiveNames: sensitivity.sensitiveNames, secretNames: sensitivity.secretNames,
            hidesSecretFieldNames: true, revealingSensitive: true)
        XCTAssertEqual(try HTTPFieldBulkText.decode(revealed).map(\.value), fields.map(\.value))
    }

    func testMissingContextAndUnresolvedNamesMaskValuesWithoutLiveResolution() throws {
        let fields = [
            HTTPField(name: "{{missing}}", value: "private-a"), HTTPField(name: "X-Custom", value: "private-b"),
        ]
        let missing = CapturedHeaderSensitivity.resolve(
            fields: fields, inputs: nil, sensitiveNames: [], secretNames: [])
        XCTAssertTrue(missing.sensitiveNames.isSuperset(of: Set(fields.map { $0.name.lowercased() })))
        let missingText = ReadOnlyHTTPFieldPresentation.bulkText(fields, sensitiveNames: missing.sensitiveNames)
        XCTAssertFalse(missingText.contains("private-"))

        let unresolved = CapturedHeaderSensitivity.resolve(
            fields: fields, inputs: [:], sensitiveNames: [], secretNames: [])
        let displayed = try HTTPFieldBulkText.decode(
            ReadOnlyHTTPFieldPresentation.bulkText(fields, sensitiveNames: unresolved.sensitiveNames))
        XCTAssertEqual(displayed.map(\.value), ["••••••••", "private-b"])
    }
}
