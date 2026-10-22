import Foundation
import XCTest
@testable import PostieCore

final class MarkupLexingTests: XCTestCase {
    func testMarkupTokenRangesUseUTF16AndDoNotOverlap() {
        let source = "🌍<root café='é &amp; >'><!-- 🌍 --><![CDATA[<raw>]]>&#x1F30D;</root>"
        let result = MarkupLexing.tokens(in: source, syntax: .xml)
        XCTAssertFalse(result.isPaused)
        XCTAssertFalse(result.isCancelled)
        XCTAssertTrue(result.tokens.contains { $0.kind == .tagDelimiter && $0.location == 2 })
        XCTAssertEqual(values(result, source, .tagName), ["root", "root"])
        XCTAssertEqual(values(result, source, .attributeName), ["café"])
        XCTAssertEqual(values(result, source, .entity), ["&amp;", "&#x1F30D;"])
        XCTAssertEqual(values(result, source, .comment), ["<!-- 🌍 -->"])
        XCTAssertEqual(values(result, source, .cdata), ["<![CDATA[<raw>]]>"])
        assertRanges(result, source)
    }

    func testQuotedDelimitersDeclarationsAndTruncationRemainBounded() {
        let cases = [
            #"<!DOCTYPE x [<!ENTITY a "<fake>">]><x value="a > <b>"/>"#,
            "<x value='unterminated > <fake>", "<!-- unterminated <fake>", "<![CDATA[<fake>", "<?xml nope",
        ]
        for source in cases {
            let result = MarkupLexing.tokens(in: source, syntax: .xml)
            assertRanges(result, source)
            XCTAssertFalse(values(result, source, .tagName).contains("fake"))
        }
    }

    func testEmbeddedLanguagesAndRawTextBoundaries() {
        let source =
            #"<STYLE>p { color: red; content: "<fake>"; /* x */ }</STYLE><script type='module'>const x = "<fake>"; // x"#
            + "\nlet y = 42;</script><script type='application/ld+json'>{\"x\":true}</script>"
            + "<script type='importmap'>{\"imports\":{}}</script><script type='application/unknown'>const hidden = 9;</script>"
        let result = MarkupLexing.tokens(in: source, syntax: .html)
        XCTAssertTrue(values(result, source, .selector).contains("p"))
        XCTAssertTrue(values(result, source, .property).contains("color"))
        XCTAssertFalse(values(result, source, .property).contains("red"))
        XCTAssertTrue(values(result, source, .keyword).contains("const"))
        XCTAssertTrue(values(result, source, .keyword).contains("true"))
        XCTAssertTrue(values(result, source, .number).contains("42"))
        XCTAssertFalse(values(result, source, .number).contains("9"))
        XCTAssertFalse(values(result, source, .tagName).contains("fake"))
        assertRanges(result, source)
    }

    func testRawClosingTagBoundaryAndUnknownEmbeddedTypes() {
        let source = "<script>const a = '</scripture>'; let b = 1;</script><textarea><fake>&amp;</textarea>"
        let result = MarkupLexing.tokens(in: source, syntax: .html)
        XCTAssertTrue(values(result, source, .number).contains("1"))
        XCTAssertFalse(values(result, source, .tagName).contains("fake"))
        XCTAssertEqual(values(result, source, .entity), ["&amp;"])
        assertRanges(result, source)
    }

    func testHighlightSizeCapAndUnsupportedSyntax() {
        let source = String(repeating: "🌍", count: MarkupLexing.maximumInputBytes / 4 + 1)
        let oversized = MarkupLexing.tokens(in: source, syntax: .html)
        XCTAssertTrue(oversized.isPaused)
        XCTAssertTrue(oversized.tokens.isEmpty)
        XCTAssertFalse(oversized.isCancelled)
        XCTAssertTrue(MarkupLexing.tokens(in: "<root/>", syntax: .none).tokens.isEmpty)
        XCTAssertTrue(MarkupLexing.tokens(in: "{}", syntax: .json).tokens.isEmpty)
    }

    private func values(_ result: MarkupLexing.Result, _ source: String, _ kind: MarkupLexing.Kind) -> [String] {
        let text = source as NSString
        return result.tokens.filter { $0.kind == kind }.map {
            text.substring(with: NSRange(location: $0.location, length: $0.length))
        }
    }

    private func assertRanges(
        _ result: MarkupLexing.Result, _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var end = 0
        for token in result.tokens {
            XCTAssertGreaterThan(token.length, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(token.location, end, file: file, line: line)
            end = token.location + token.length
            XCTAssertLessThanOrEqual(end, source.utf16.count, file: file, line: line)
        }
    }
}
