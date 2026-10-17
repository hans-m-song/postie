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
