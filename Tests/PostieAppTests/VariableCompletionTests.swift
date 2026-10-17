import XCTest
import PostieCore
@testable import PostieApp

final class VariableCompletionTests: XCTestCase {
    func testCompletionRangeCoversOnlyCurrentTokenIncludingClosingDelimiters() throws {
        let prefix = "https://api.example/{{ho"
        let value = prefix + "st}}/items"
        let selection = NSRange(location: (prefix as NSString).length, length: 0)

        let context = try XCTUnwrap(VariableCompletionMatcher.context(in: value, selection: selection))

        XCTAssertEqual(context.prefix, "ho")
        XCTAssertEqual(context.replacementRange, NSRange(location: 20, length: 8))
    }

    func testCompletionRangePreservesFollowingURLPathAndTemplate() throws {
        let value = "https://x/{{ho/path/{{other}}"
        let prefix = "https://x/{{ho"
        let selection = NSRange(location: (prefix as NSString).length, length: 0)
        let openingIndex = (value as NSString).range(of: "{{ho").location

        let context = try XCTUnwrap(VariableCompletionMatcher.context(in: value, selection: selection))

        XCTAssertEqual(context.prefix, "ho")
        XCTAssertEqual(context.replacementRange, NSRange(location: openingIndex, length: 4))
    }

    func testCompletionRangeConsumesOnlyOneExistingClosingBrace() throws {
        let value = "{{ho}/path"
        let selection = NSRange(location: 4, length: 0)

        let context = try XCTUnwrap(VariableCompletionMatcher.context(in: value, selection: selection))

        XCTAssertEqual(context.replacementRange, NSRange(location: 0, length: 5))
    }

    func testCompletionContextRejectsEscapedOpenersSelectionsAndInvalidPrefixes() {
        let escaped = "https://api.example.test/\\{{host"
        XCTAssertNil(VariableCompletionMatcher.context(
            in: escaped,
            selection: NSRange(location: (escaped as NSString).length, length: 0)
        ))

        let token = "https://api.example.test/{{api-|}}"
        XCTAssertNil(VariableCompletionMatcher.context(
            in: token,
            selection: NSRange(location: (token as NSString).range(of: "api-").location + 4, length: 0)
        ))
        XCTAssertNil(VariableCompletionMatcher.context(
            in: token,
            selection: NSRange(location: (token as NSString).range(of: "api").location + 3, length: 1)
        ))
    }

    func testUnclosedTokenReplacementIncludesIdentifierSuffixAfterCaret() throws {
        let value = "{{ho" + "st/path"
        let selection = NSRange(location: 4, length: 0)

        let context = try XCTUnwrap(VariableCompletionMatcher.context(in: value, selection: selection))

        XCTAssertEqual(context.prefix, "ho")
        XCTAssertEqual(context.replacementRange, NSRange(location: 0, length: 6))
    }

    func testSuggestionsAreCaseSensitiveUniqueAndBounded() {
        let context = VariableCompletionContext(prefix: "API", replacementRange: NSRange(location: 8, length: 5))
        let variables = [
            VariableCompletion(name: "API_TOKEN", scope: .global, isSecret: true),
            VariableCompletion(name: "apiHost", scope: .request, isSecret: false),
            VariableCompletion(name: "API_HOST", scope: .collection, isSecret: false),
            VariableCompletion(name: "API_HOST", scope: .request, isSecret: true),
            VariableCompletion(name: "API-HOST", scope: .global, isSecret: false)
        ]

        XCTAssertEqual(
            VariableCompletionMatcher.suggestions(for: context, from: variables),
            [
                VariableCompletion(name: "API_HOST", scope: .collection, isSecret: false),
                VariableCompletion(name: "API_TOKEN", scope: .global, isSecret: true)
            ]
        )

        let manyVariables = (0..<25).map {
            VariableCompletion(name: "item\($0)", scope: .request, isSecret: false)
        }
        let unfiltered = VariableCompletionContext(prefix: "item", replacementRange: NSRange(location: 0, length: 0))
        let suggestions = VariableCompletionMatcher.suggestions(for: unfiltered, from: manyVariables)
        XCTAssertEqual(suggestions.count, VariableCompletionMatcher.maximumSuggestionCount)
        XCTAssertEqual(
            suggestions.map(\.name),
            manyVariables.prefix(VariableCompletionMatcher.maximumSuggestionCount).map(\.name).sorted()
        )

        let boundedInput = (0..<VariableCompletionMatcher.maximumCandidatesInspected).map {
            VariableCompletion(name: "miss\($0)", scope: .request, isSecret: false)
        } + [VariableCompletion(name: "target", scope: .request, isSecret: false)]
        let target = VariableCompletionContext(prefix: "target", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(VariableCompletionMatcher.suggestions(for: target, from: boundedInput).isEmpty)
    }

    func testCompletionContextRejectsOversizedInput() {
        let value = String(repeating: "x", count: VariableCompletionMatcher.maximumInputLength + 1) + "{{host"

        XCTAssertNil(VariableCompletionMatcher.context(
            in: value,
            selection: NSRange(location: (value as NSString).length, length: 0)
        ))
    }

    func testBodyContextFindsCaretLocalTokenInLargeBody() throws {
        let prefix = String(repeating: "x", count: VariableCompletionMatcher.maximumInputLength + 5)
        let value = prefix + "{{host}} after"
        let caret = (prefix + "{{ho").utf16.count

        let context = try XCTUnwrap(VariableCompletionMatcher.bodyContext(
            in: value,
            selection: NSRange(location: caret, length: 0)
        ))

        XCTAssertEqual(context.prefix, "ho")
        XCTAssertEqual(
            context.replacementRange,
            NSRange(location: prefix.utf16.count, length: "{{host}}".utf16.count)
        )
    }

    func testBodyContextRejectsEscapedLocalToken() {
        let value = String(repeating: "x", count: VariableCompletionMatcher.maximumInputLength + 5) + "\\{{host"

        XCTAssertNil(VariableCompletionMatcher.bodyContext(
            in: value,
            selection: NSRange(location: (value as NSString).length, length: 0)
        ))
    }

    func testReplacementProducesOneCanonicalTemplateToken() {
        let variable = VariableCompletion(name: "baseURL", scope: .global, isSecret: false)

        XCTAssertEqual(VariableCompletionMatcher.replacement(for: variable), "{{baseURL}}")
    }
}
