import XCTest
@testable import PostieApp

final class JSONBodyEditingTests: XCTestCase {
    func testOpeningDelimitersInsertPairsAndKeepCaretBetweenThem() {
        let examples = [("{", "{}"), ("[", "[]"), ("\"", "\"\"")]

        for (opening, pair) in examples {
            var stateCache = JSONBodyStringStateCache()
            XCTAssertEqual(
                JSONBodyEditing.edit(
                    in: "",
                    range: NSRange(location: 0, length: 0),
                    replacement: opening,
                    inputKind: .typing,
                    stringStateCache: &stateCache
                ),
                .replace(
                    range: NSRange(location: 0, length: 0),
                    with: pair,
                    selection: NSRange(location: 1, length: 0)
                )
            )
        }
    }

    func testNewlineBetweenEmptyContainersPreservesIndentAndAddsTwoSpaces() {
        let value = "  {}"
        let location = 3
        var stateCache = JSONBodyStringStateCache()

        XCTAssertEqual(
            JSONBodyEditing.edit(
                in: value,
                range: NSRange(location: location, length: 0),
                replacement: "\n",
                inputKind: .newline,
                stringStateCache: &stateCache
            ),
            .replace(
                range: NSRange(location: location, length: 0),
                with: "\n    \n  ",
                selection: NSRange(location: 8, length: 0)
            )
        )
    }

    func testNewlineAfterOpenerAddsIndentWithoutAdjacentCloser() {
        let value = "{value}"
        var stateCache = JSONBodyStringStateCache()

        XCTAssertEqual(
            JSONBodyEditing.edit(
                in: value,
                range: NSRange(location: 1, length: 0),
                replacement: "\n",
                inputKind: .newline,
                stringStateCache: &stateCache
            ),
            .replace(
                range: NSRange(location: 1, length: 0),
                with: "\n  ",
                selection: NSRange(location: 4, length: 0)
            )
        )
    }

    func testNewlinePreservesCurrentIndentOutsideContainers() {
        let value = "  value"
        let location = (value as NSString).length
        var stateCache = JSONBodyStringStateCache()

        XCTAssertEqual(
            JSONBodyEditing.edit(
                in: value,
                range: NSRange(location: location, length: 0),
                replacement: "\n",
                inputKind: .newline,
                stringStateCache: &stateCache
            ),
            .replace(
                range: NSRange(location: location, length: 0),
                with: "\n  ",
                selection: NSRange(location: location + 3, length: 0)
            )
        )
    }

    func testOpeningContainerWrapsSelectedTextInlineAndPreservesItsSelection() {
        let value = "  alpha"
        let selection = NSRange(location: 2, length: 5)
        var stateCache = JSONBodyStringStateCache()

        XCTAssertEqual(
            JSONBodyEditing.edit(
                in: value,
                range: selection,
                replacement: "[",
                inputKind: .typing,
                stringStateCache: &stateCache
            ),
            .replace(
                range: selection,
                with: "[alpha]",
                selection: NSRange(location: 3, length: 5)
            )
        )
    }

    func testOpeningQuoteWrapsSelectedTextAndPreservesItsSelection() {
        let value = "value"
        let selection = NSRange(location: 0, length: (value as NSString).length)
        var stateCache = JSONBodyStringStateCache()

        XCTAssertEqual(
            JSONBodyEditing.edit(
                in: value,
                range: selection,
                replacement: "\"",
                inputKind: .typing,
                stringStateCache: &stateCache
            ),
            .replace(
                range: selection,
                with: "\"value\"",
                selection: NSRange(location: 1, length: 5)
            )
        )
    }

    func testClosingDelimiterTypingDoesNotDiscardSelectedText() {
        let value = "alpha}"
        let selection = NSRange(location: 0, length: 5)
        var stateCache = JSONBodyStringStateCache()

        XCTAssertNil(JSONBodyEditing.edit(
            in: value,
            range: selection,
            replacement: "}",
            inputKind: .typing,
            stringStateCache: &stateCache
        ))
    }

    func testNewlineDoesNotExpandPairsInsideStringsOrAcrossNonEmptyText() {
        let examples = [("\"{}\"", 2), ("{value}", 2)]

        for (value, location) in examples {
            var stateCache = JSONBodyStringStateCache()
            XCTAssertNil(JSONBodyEditing.edit(
                in: value,
                range: NSRange(location: location, length: 0),
                replacement: "\n",
                inputKind: .newline,
                stringStateCache: &stateCache
            ))
        }
    }

    func testTypingExistingCloserMovesCaretAcrossIt() {
        let examples = [("{}", 1, "}"), ("[]", 1, "]"), ("\"\"", 1, "\"")]

        for (value, location, closer) in examples {
            var stateCache = JSONBodyStringStateCache()
            XCTAssertEqual(
                JSONBodyEditing.edit(
                    in: value,
                    range: NSRange(location: location, length: 0),
                    replacement: closer,
                    inputKind: .typing,
                    stringStateCache: &stateCache
                ),
                .moveCaret(to: location + 1)
            )
        }
    }

    func testBackspaceBetweenPairDeletesBothCharacters() {
        let examples = ["{}", "[]", "\"\""]

        for value in examples {
            var stateCache = JSONBodyStringStateCache()
            XCTAssertEqual(
                JSONBodyEditing.edit(
                    in: value,
                    range: NSRange(location: 0, length: 1),
                    replacement: "",
                    inputKind: .backspace,
                    stringStateCache: &stateCache
                ),
                .replace(
                    range: NSRange(location: 0, length: 2),
                    with: "",
                    selection: NSRange(location: 0, length: 0)
                )
            )
        }
    }

    func testBackspaceInsideStringDoesNotDeleteBracketTextAsPair() {
        let value = "\"[]\""
        var stateCache = JSONBodyStringStateCache()

        XCTAssertNil(JSONBodyEditing.edit(
            in: value,
            range: NSRange(location: 1, length: 1),
            replacement: "",
            inputKind: .backspace,
            stringStateCache: &stateCache
        ))
    }

    func testPairingRespectsStringAndEscapeState() {
        let insideString = "\"value\""
        var insideStringCache = JSONBodyStringStateCache()
        XCTAssertNil(JSONBodyEditing.edit(
            in: insideString,
            range: NSRange(location: 3, length: 0),
            replacement: "{",
            inputKind: .typing,
            stringStateCache: &insideStringCache
        ))

        let escapedQuote = "\"value\\"
        var escapedQuoteCache = JSONBodyStringStateCache()
        XCTAssertNil(JSONBodyEditing.edit(
            in: escapedQuote,
            range: NSRange(location: (escapedQuote as NSString).length, length: 0),
            replacement: "\"",
            inputKind: .typing,
            stringStateCache: &escapedQuoteCache
        ))
    }

    func testNonKeyboardInsertionIsLeftUnchanged() {
        var stateCache = JSONBodyStringStateCache()

        XCTAssertNil(JSONBodyEditing.edit(
            in: "",
            range: NSRange(location: 0, length: 0),
            replacement: "{",
            inputKind: .other,
            stringStateCache: &stateCache
        ))
    }
}
