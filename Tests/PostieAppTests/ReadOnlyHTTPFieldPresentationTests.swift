import PostieCore
import XCTest

@testable import PostieApp

final class ReadOnlyHTTPFieldPresentationTests: XCTestCase {
    func testBulkTextMasksStandardAndCallerSensitiveValuesAndSecretNamesBeforeEncoding() {
        let fields = [
            HTTPField(name: "Authorization", value: "authorization-secret"),
            HTTPField(name: "Proxy-Authorization", value: "proxy-secret"),
            HTTPField(name: "Cookie", value: "cookie-secret"),
            HTTPField(name: "Cookie2", value: "cookie2-secret"),
            HTTPField(name: "Set-Cookie", value: "set-cookie-secret"),
            HTTPField(name: "X-Session-Key", value: "custom-secret"),
            HTTPField(name: "X-Secret-Name", value: "hidden-name-secret"),
        ]

        let text = ReadOnlyHTTPFieldPresentation.bulkText(
            fields,
            sensitiveNames: ["x-session-key"],
            secretNames: ["x-secret-name"],
            includesStandardHeaderNames: true,
            hidesSecretFieldNames: true
        )

        for value in [
            "authorization-secret", "proxy-secret", "cookie-secret", "cookie2-secret", "set-cookie-secret",
            "custom-secret", "hidden-name-secret",
        ] {
            XCTAssertFalse(text.contains(value))
        }
        for name in ["Authorization", "Proxy-Authorization", "Cookie", "Cookie2", "Set-Cookie", "X-Session-Key"] {
            XCTAssertTrue(text.contains("\(name): ••••••••"))
        }
        XCTAssertTrue(text.contains("Secret header: ••••••••"))
        XCTAssertFalse(text.contains("X-Secret-Name"))
    }

    func testBulkTextPreservesDuplicateRowsAndDisabledState() throws {
        let fields = [
            HTTPField(name: "X-Duplicate", value: "first-secret", isEnabled: true),
            HTTPField(name: "X-Duplicate", value: "second-secret", isEnabled: false),
        ]

        let text = ReadOnlyHTTPFieldPresentation.bulkText(
            fields,
            sensitiveNames: ["x-duplicate"]
        )
        let decoded = try HTTPFieldBulkText.decode(text)

        XCTAssertEqual(decoded.map(\.name), ["X-Duplicate", "X-Duplicate"])
        XCTAssertEqual(decoded.map(\.value), ["••••••••", "••••••••"])
        XCTAssertEqual(decoded.map(\.isEnabled), [true, false])
    }

    func testExplicitRevealReturnsOriginalSensitiveHeaderNamesAndValues() {
        let fields = [
            HTTPField(name: "Authorization", value: "authorization-secret"),
            HTTPField(name: "X-Secret-Name", value: "hidden-name-secret"),
        ]

        let text = ReadOnlyHTTPFieldPresentation.bulkText(
            fields,
            secretNames: ["x-secret-name"],
            includesStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            revealingSensitive: true
        )

        XCTAssertTrue(text.contains("Authorization: authorization-secret"))
        XCTAssertTrue(text.contains("X-Secret-Name: hidden-name-secret"))
    }

    func testRevealKeyIsBoundToFieldsSensitivityAndSource() {
        let fieldID = UUID()
        let fields = [HTTPField(id: fieldID, name: "X-Session-Key", value: "first-secret")]
        let currentKey = ReadOnlyHTTPFieldRevealKey(
            fields: fields,
            sensitiveNames: ["x-session-key"],
            secretNames: [],
            sources: ["x-session-key": .request],
            masksStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            isBulkMode: true
        )
        let changedFieldKey = ReadOnlyHTTPFieldRevealKey(
            fields: [HTTPField(id: fieldID, name: "X-Session-Key", value: "next-secret")],
            sensitiveNames: ["x-session-key"],
            secretNames: [],
            sources: ["x-session-key": .request],
            masksStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            isBulkMode: true
        )
        let changedSensitivityKey = ReadOnlyHTTPFieldRevealKey(
            fields: fields,
            sensitiveNames: [],
            secretNames: [],
            sources: ["x-session-key": .request],
            masksStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            isBulkMode: true
        )
        let changedSourceKey = ReadOnlyHTTPFieldRevealKey(
            fields: fields,
            sensitiveNames: ["x-session-key"],
            secretNames: [],
            sources: ["x-session-key": .collection],
            masksStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            isBulkMode: true
        )
        let changedModeKey = ReadOnlyHTTPFieldRevealKey(
            fields: fields,
            sensitiveNames: ["x-session-key"],
            secretNames: [],
            sources: ["x-session-key": .request],
            masksStandardHeaderNames: true,
            hidesSecretFieldNames: true,
            isBulkMode: false
        )

        XCTAssertTrue(ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: currentKey, currentKey: currentKey))
        XCTAssertFalse(ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: currentKey, currentKey: changedFieldKey))
        XCTAssertFalse(
            ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: currentKey, currentKey: changedSensitivityKey))
        XCTAssertFalse(ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: currentKey, currentKey: changedSourceKey))
        XCTAssertFalse(ReadOnlyHTTPFieldPresentation.isRevealed(revealedKey: currentKey, currentKey: changedModeKey))
    }
}
