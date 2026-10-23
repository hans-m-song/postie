import Foundation
import XCTest
@testable import PostieCore

final class HTTPFieldBulkTextTests: XCTestCase {
    func testRoundTripPreservesOrderDuplicatesEmptyValuesEscapesAndEnabledState() throws {
        let fields = [
            HTTPField(name: "duplicate", value: "first: second"),
            HTTPField(name: "duplicate", value: "line one\nline two\r\t\\tail"),
            HTTPField(name: "name:with colon", value: "https://example.test/a:b"),
            HTTPField(name: "# literal", value: " value with edges "),
            HTTPField(name: "{{header}}", value: "Bearer {{token}}"),
            HTTPField(name: "", value: ""),
            HTTPField(name: "disabled", value: "", isEnabled: false),
            HTTPField(name: "# disabled name", value: "value", isEnabled: false),
            HTTPField(name: "spaces", value: "   ", isEnabled: false),
        ]

        let text = HTTPFieldBulkText.encode(fields)
        let decoded = try HTTPFieldBulkText.decode(text)

        XCTAssertEqual(decoded.map(\.name), fields.map(\.name))
        XCTAssertEqual(decoded.map(\.value), fields.map(\.value))
        XCTAssertEqual(decoded.map(\.isEnabled), fields.map(\.isEnabled))
        XCTAssertEqual(text.components(separatedBy: "\n").count, fields.count)
        XCTAssertTrue(text.contains("\\# literal: "))
        XCTAssertTrue(text.contains("# disabled: "))
        XCTAssertTrue(text.contains("# \\# disabled name: value"))
        XCTAssertTrue(text.contains("duplicate: first: second"))
        XCTAssertTrue(text.contains("name\\:with colon: https://example.test/a:b"))
    }

    func testDecodeIgnoresBlankLinesAndReportsOriginalLineForMissingDelimiter() {
        XCTAssertThrowsError(try HTTPFieldBulkText.decode("\n   \nfirst: value\n \nmalformed")) { error in
            XCTAssertEqual(error as? HTTPFieldBulkTextError, .missingDelimiter(line: 5))
        }
    }

    func testDecodeReportsLineForInvalidEscape() {
        XCTAssertThrowsError(try HTTPFieldBulkText.decode("first: value\nsecond: bad\\q")) { error in
            XCTAssertEqual(error as? HTTPFieldBulkTextError, .invalidEscape(line: 2))
        }
    }

    func testRoundTripPreservesLeadingAndTrailingWhitespaceInNames() throws {
        let fields = [
            HTTPField(name: " leading", value: "value"),
            HTTPField(name: "trailing ", value: "value"),
            HTTPField(name: "\u{00A0}edge\u{00A0}", value: "value"),
        ]

        let decoded = try HTTPFieldBulkText.decode(HTTPFieldBulkText.encode(fields))

        XCTAssertEqual(decoded.map(\.name), fields.map(\.name))
    }

    func testRoundTripEscapesInternalAndEdgeCRLFInNamesAndValues() throws {
        let fields = [
            HTTPField(name: "first\r\nmiddle\r\nlast", value: "left\r\nmiddle\r\nright"),
            HTTPField(name: "\r\nedge\r\n", value: "\r\nedge\r\n"),
        ]

        let text = HTTPFieldBulkText.encode(fields)
        let decoded = try HTTPFieldBulkText.decode(text)

        XCTAssertEqual(
            text,
            "first\\r\\nmiddle\\r\\nlast: left\\r\\nmiddle\\r\\nright\n\\r\\nedge\\r\\n: \\r\\nedge\\r\\n")
        XCTAssertEqual(decoded.map(\.name), fields.map(\.name))
        XCTAssertEqual(decoded.map(\.value), fields.map(\.value))
    }

    func testNoOpReconciliationPreservesRawQueryAndFlagEncoding() throws {
        let source = "https://example.test?flag&x=%2f&x=%2F"
        let parsed = QueryParameters.parse(displayURL: source)
        let decoded = try HTTPFieldBulkText.decode(HTTPFieldBulkText.encode(parsed.fields))
        let reconciled = HTTPFieldBulkText.reconcile(decoded, against: parsed.fields)

        XCTAssertEqual(QueryParameters.render(baseURL: parsed.baseURL, fields: reconciled), source)
        XCTAssertEqual(reconciled.map(\.id), parsed.fields.map(\.id))
        XCTAssertEqual(reconciled.map(\.queryEncoding), parsed.fields.map(\.queryEncoding))
    }

    func testChangedComponentKeepsRawEncodingForUnchangedComponent() throws {
        let source = "https://example.test?%71=a%2fb"
        let parsed = QueryParameters.parse(displayURL: source)
        let decoded = try HTTPFieldBulkText.decode("q: changed")
        let reconciled = HTTPFieldBulkText.reconcile(decoded, against: parsed.fields)

        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: reconciled),
            "https://example.test?%71=changed")
        XCTAssertEqual(reconciled.first?.id, parsed.fields.first?.id)
    }

    func testChangedNameKeepsRawEncodingForUnchangedValue() throws {
        let source = "https://example.test?%71=a%2fb"
        let parsed = QueryParameters.parse(displayURL: source)
        let decoded = try HTTPFieldBulkText.decode("renamed: a/b")
        let reconciled = HTTPFieldBulkText.reconcile(decoded, against: parsed.fields)

        XCTAssertEqual(
            QueryParameters.render(baseURL: parsed.baseURL, fields: reconciled),
            "https://example.test?renamed=a%2fb")
        XCTAssertEqual(reconciled.first?.id, parsed.fields.first?.id)
    }

    func testInsertedRowDoesNotInheritUnrelatedQueryEncoding() throws {
        let parsed = QueryParameters.parse(displayURL: "https://example.test?flag")
        let decoded = try HTTPFieldBulkText.decode("new: value\nflag: ")
        let reconciled = HTTPFieldBulkText.reconcile(decoded, against: parsed.fields)

        XCTAssertNil(reconciled.first?.queryEncoding)
        XCTAssertEqual(reconciled.last?.queryEncoding, parsed.fields.first?.queryEncoding)
    }
}
