import Foundation
import XCTest
@testable import PostieCore

final class MarkupPresentationTests: XCTestCase {
    func testMIMEClassificationNormalizesCaseParametersAndEnabledHeaders() {
        let cases: [(String, BodySyntax)] = [
            ("Text/HTML; charset=UTF-8", .html), (" APPLICATION/XML ; charset=utf-8", .xml),
            ("text/xml", .xml), ("application/xhtml+xml", .xml), ("image/svg+xml", .xml),
            ("application/problem+json", .json), ("application/json", .json), ("text/json", .json),
            ("text/plain", .none), ("application/octet-stream", .none),
        ]
        for (type, expected) in cases {
            let headers = [
                HTTPField(name: "Content-Type", value: "application/json", isEnabled: false),
                HTTPField(name: "cOnTeNt-TyPe", value: type),
            ]
            XCTAssertEqual(BodyMediaType.syntax(for: headers), expected, type)
        }
        XCTAssertEqual(
            BodyMediaType.contentType(for: [HTTPField(name: "Content-Type", value: " Text/HTML ; x=y")]), "text/html")
        XCTAssertNil(BodyMediaType.contentType(for: []))
        XCTAssertEqual(BodyMediaType.syntax(for: []), .none)
    }

    func testSyntaxValuesRoundTripAndExistingRequestsStillDecode() throws {
        for syntax in BodySyntax.allCases {
            var request = HTTPRequestConfiguration()
            request.bodySyntax = syntax
            let data = try JSONEncoder().encode(request)
            XCTAssertEqual(try JSONDecoder().decode(HTTPRequestConfiguration.self, from: data).bodySyntax, syntax)
        }
        XCTAssertEqual(try JSONDecoder().decode(BodySyntax.self, from: Data("\"json\"".utf8)), .json)
        XCTAssertEqual(try JSONDecoder().decode(BodySyntax.self, from: Data("\"none\"".utf8)), .none)
    }

    func testElementOnlyStructureFormatsWithoutChangingLexemes() throws {
        let source = #"<?xml version="1.0"?><root a="&amp; >"><one/><two value='1e2'></two><!-- > --></root>"#
        let pretty = try format(source, .xml)
        XCTAssertEqual(
            pretty,
            "<?xml version=\"1.0\"?>\n<root a=\"&amp; >\">\n  <one/>\n  <two value='1e2'></two>\n  <!-- > -->\n</root>")
        XCTAssertEqual(try format(pretty, .xml), pretty)
    }

    func testMixedTextAndWhitespaceOnlyLeafArePreserved() throws {
        let mixed = "<p>Hello <b>world</b>! &amp; 🌍</p>"
        XCTAssertEqual(try format(mixed, .html), mixed)
        XCTAssertEqual(
            try format("<root><leaf>  \n </leaf><empty></empty></root>", .xml),
            "<root>\n  <leaf>  \n </leaf>\n  <empty></empty>\n</root>")
        XCTAssertEqual(try format("before <b>text</b> after", .html), "before <b>text</b> after")
    }

    func testHTMLBooleanAttributesKeepTheirSeparators() throws {
        XCTAssertEqual(
            try format(
                "<form><input disabled checked required><button disabled type='button'>go</button></form>", .html),
            "<form>\n  <input disabled checked required>\n  <button disabled type='button'>go</button>\n</form>")
    }

    func testProtectedSubtreesRemainExact() throws {
        let cases: [(String, BodySyntax)] = [
            ("<pre>  <b>x</b>\n   y</pre>", .html),
            ("<textarea><b> &amp;\n  raw</textarea>", .html),
            ("<root xml:space='preserve'> <a/>\n <b><c/></b></root>", .xml),
            ("<r xml:space=\"pre&#x73;erve\"><a/>  <b/></r>", .xml),
            ("<root><![CDATA[ <x> & untouched\n ]]><child/></root>", .xml),
            ("<script>const x = '<tag>';\n// source stays\n x++;</script>", .html),
            ("<style>p::before { content: '<tag>'; }\n  /* spacing */</style>", .html),
        ]
        for (source, syntax) in cases { XCTAssertEqual(try format(source, syntax), source) }
    }

    func testDeclarationsNeverResolveExternalEntitiesAndPreserveInternalSubset() throws {
        let source = #"<!DOCTYPE root [<!ENTITY value SYSTEM "file:///not-read">]><root>&value;</root>"#
        XCTAssertEqual(
            try format(source, .xml),
            "<!DOCTYPE root [<!ENTITY value SYSTEM \"file:///not-read\">]>\n<root>&value;</root>")
    }

    func testMalformedTruncatedAndUnsupportedDocumentsFailConservatively() {
        let cases = [
            "", "plain text", "<a>", "<a></b>", "<a x='unterminated></a>", "<a><!-- nope</a>",
            "<a><![CDATA[nope</a>", "<a>&missing</a>", "<a x='&missing'></a>", "<a>&#xyz;</a>",
            "<a/><b/>", "<a/>trailing", "<a x=value/>", "<a></a><", "<!DOCTYPE a [<a>",
        ]
        for source in cases {
            XCTAssertThrowsError(try format(source, .xml), source) {
                XCTAssertEqual($0 as? MarkupPresentation.PresentationError, .invalidMarkup, source)
            }
        }
        XCTAssertThrowsError(try format("<p>optional closing", .html))
        XCTAssertThrowsError(try MarkupPresentation.pretty(Data([0xFF, 0xFE]), syntax: .xml))
        XCTAssertThrowsError(try format("<a/>", .json))
    }

    func testInputOutputDepthAndFileBounds() throws {
        let source = Data("<root><one/><two/></root>".utf8)
        XCTAssertThrowsError(try MarkupPresentation.pretty(source, syntax: .xml, maximumBytes: source.count)) {
            XCTAssertEqual($0 as? MarkupPresentation.PresentationError, .tooLarge)
        }
        XCTAssertThrowsError(try MarkupPresentation.pretty(source, syntax: .xml, maximumBytes: 0))
        let deep = String(repeating: "<a>", count: 257) + String(repeating: "</a>", count: 257)
        XCTAssertThrowsError(try format(deep, .xml)) {
            XCTAssertEqual($0 as? MarkupPresentation.PresentationError, .tooLarge)
        }
        let huge = Data(repeating: 32, count: MarkupPresentation.maximumBytes + 1)
        XCTAssertThrowsError(try MarkupPresentation.pretty(huge, syntax: .xml, maximumBytes: Int.max))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try source.write(to: file)
        XCTAssertEqual(
            try MarkupPresentation.pretty(at: file, syntax: .xml), try MarkupPresentation.pretty(source, syntax: .xml))
        XCTAssertEqual(try Data(contentsOf: file), source)
        XCTAssertThrowsError(try MarkupPresentation.pretty(at: file, syntax: .xml, maximumBytes: 3))
        let missing = file.appendingPathComponent("missing")
        XCTAssertThrowsError(try MarkupPresentation.pretty(at: missing, syntax: .xml)) {
            XCTAssertEqual($0 as? MarkupPresentation.PresentationError, .unreadable)
        }
    }

    func testCancellationIsExplicitAndDoesNotProducePartialOutput() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try MarkupPresentation.pretty(Data("<a/>".utf8), syntax: .xml)
                XCTFail("Cancelled formatting returned output")
            } catch { XCTAssertTrue(error is CancellationError) }
            let result = MarkupLexing.tokens(in: "<a/>", syntax: .xml)
            XCTAssertTrue(result.isCancelled)
            XCTAssertTrue(result.tokens.isEmpty)
        }
        await task.value
    }

    private func format(_ text: String, _ syntax: BodySyntax) throws -> String {
        try MarkupPresentation.pretty(Data(text.utf8), syntax: syntax)
    }
}
