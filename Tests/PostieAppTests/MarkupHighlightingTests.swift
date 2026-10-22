import Foundation
import PostieCore
import XCTest
@testable import PostieApp

final class MarkupHighlightingTests: XCTestCase {
    func testHTMLAndEmbeddedLanguagesProduceReadableTokenSpans() {
        let source =
            #"<main data-kind="card">Hello &amp;<!-- note --><style>.card { color: red; }</style><script>const amount = 2;</script><script type="application/json">{"enabled": true}</script></main>"#
        let result = SyntaxHighlighting.result(for: request(source, syntax: .html))

        XCTAssertFalse(result.isPaused)
        XCTAssertFalse(result.isCancelled)
        assertColor(.markupTagName, for: "main", in: source, result: result)
        assertColor(.markupAttributeName, for: "data-kind", in: source, result: result)
        assertColor(.markupString, for: #""card""#, in: source, result: result)
        assertColor(.markupEntity, for: "&amp;", in: source, result: result)
        assertColor(.markupComment, for: "<!-- note -->", in: source, result: result)
        assertColor(.markupSelector, for: ".card", in: source, result: result)
        assertColor(.markupProperty, for: "color", in: source, result: result)
        assertColor(.markupKeyword, for: "const", in: source, result: result)
        assertColor(.markupString, for: #""enabled""#, in: source, result: result)
    }

    func testXMLUsesMarkupTokensAndPreservesUTF16Locations() {
        let source = "🙂<entry><![CDATA[value]]></entry>"
        let result = SyntaxHighlighting.result(for: request(source, syntax: .xml))
        let sourceText = source as NSString
        let tagRange = sourceText.range(of: "entry")
        let span = result.spans.first { $0.range == tagRange }

        XCTAssertEqual(tagRange.location, 3)
        XCTAssertEqual(span?.color, .markupTagName)
        assertColor(.markupCDATA, for: "<![CDATA[value]]>", in: source, result: result)
    }

    func testTemplateSpanOverridesTheMarkupStringSpan() {
        let source = #"<section title="{{label}}"></section>"#
        let result = SyntaxHighlighting.result(
            for: request(source, syntax: .html, availableVariables: ["label"]))
        let templateRange = (source as NSString).range(of: "{{label}}")
        let overlappingSpans = result.spans.filter {
            NSIntersectionRange($0.range, templateRange).length > 0
        }

        XCTAssertTrue(overlappingSpans.contains { $0.color == .markupString })
        XCTAssertEqual(
            overlappingSpans.last,
            SyntaxHighlighting.Span(
                location: templateRange.location,
                length: templateRange.length,
                color: .variable
            ))
    }

    func testNonMarkupSyntaxDoesNotReceiveMarkupColorsAndJSONColorsRemain() {
        let markupSource = "<root>value</root>"
        let plainResult = SyntaxHighlighting.result(for: request(markupSource, syntax: .none))
        XCTAssertTrue(plainResult.spans.isEmpty)

        let jsonSource = #"{"name":"Postie","count":2,"active":true}"#
        let jsonResult = SyntaxHighlighting.result(for: request(jsonSource, syntax: .json))
        XCTAssertTrue(jsonResult.spans.contains { $0.color == .jsonKey })
        XCTAssertTrue(jsonResult.spans.contains { $0.color == .jsonString })
        XCTAssertTrue(jsonResult.spans.contains { $0.color == .jsonNumber })
        XCTAssertTrue(jsonResult.spans.contains { $0.color == .jsonLiteral })
        XCTAssertFalse(jsonResult.spans.contains(where: isMarkupColor))
    }

    func testMarkupHighlightingPausesAboveTheExistingByteLimit() {
        let source = String(repeating: "x", count: SyntaxHighlighting.maximumInputBytes + 1)
        let result = SyntaxHighlighting.result(for: request(source, syntax: .html))

        XCTAssertTrue(result.isPaused)
        XCTAssertFalse(result.isCancelled)
        XCTAssertTrue(result.spans.isEmpty)
    }

    private func request(
        _ text: String,
        syntax: BodySyntax,
        availableVariables: Set<String> = []
    ) -> SyntaxHighlighting.Request {
        SyntaxHighlighting.Request(
            text: text,
            syntax: syntax,
            availableVariables: availableVariables,
            validPathParameters: [],
            isURL: false
        )
    }

    private func assertColor(
        _ color: SyntaxHighlighting.Color,
        for token: String,
        in source: String,
        result: SyntaxHighlighting.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tokenRange = (source as NSString).range(of: token)
        XCTAssertNotEqual(tokenRange.location, NSNotFound, "Missing token \(token)", file: file, line: line)
        XCTAssertTrue(
            result.spans.contains { $0.range == tokenRange && $0.color == color },
            "Expected \(token) to have color \(color)",
            file: file,
            line: line
        )
    }

    private func isMarkupColor(_ span: SyntaxHighlighting.Span) -> Bool {
        switch span.color {
        case .markupTagName, .markupTagDelimiter, .markupAttributeName, .markupString,
            .markupComment, .markupEntity, .markupDeclaration, .markupCDATA, .markupKeyword,
            .markupNumber, .markupIdentifier, .markupPunctuation, .markupSelector, .markupProperty:
            true
        case .variable, .pathParameter, .missing, .invalid, .jsonKey, .jsonString, .jsonNumber,
            .jsonLiteral:
            false
        }
    }
}
