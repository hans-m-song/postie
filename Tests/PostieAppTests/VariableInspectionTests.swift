import XCTest
@testable import PostieApp

final class VariableInspectionTests: XCTestCase {
    func testClosedPartialNameRemainsEligibleForCompletionUntilDefined() throws {
        let value = "{{var_}}"
        let caret = NSRange(location: 6, length: 0)
        XCTAssertNil(VariableInspectionMatcher.reference(in: value, selection: caret, definedNames: ["var_foo"]))
        let context = try XCTUnwrap(VariableCompletionMatcher.context(in: value, selection: caret))
        let suggestions = VariableCompletionMatcher.suggestions(for: context, from: [
            VariableCompletion(name: "var_foo", scope: .request, isSecret: false)
        ])
        XCTAssertEqual(context.prefix, "var_")
        XCTAssertEqual(context.replacementRange, NSRange(location: 0, length: 8))
        XCTAssertEqual(suggestions.map(\.name), ["var_foo"])
        XCTAssertEqual(VariableInspectionMatcher.reference(in: value, selection: caret, definedNames: ["var_"])?.name, "var_")
    }

    func testInspectionTargetsCompleteTokenAtCaretOrSelectionOnly() throws {
        let value = "https://x/{{host}}/{{path}}"
        let host = (value as NSString).range(of: "{{host}}")
        let path = (value as NSString).range(of: "{{path}}")
        XCTAssertEqual(VariableInspectionMatcher.reference(in: value, selection: NSRange(location: host.location + 3, length: 0))?.range, host)
        XCTAssertEqual(VariableInspectionMatcher.reference(in: value, selection: path)?.name, "path")
        XCTAssertNil(VariableInspectionMatcher.reference(in: value, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(VariableInspectionMatcher.reference(in: value, selection: NSRange(location: host.location, length: host.length + 2)))
        XCTAssertNil(VariableInspectionMatcher.reference(in: "{{host", selection: NSRange(location: 3, length: 0)))
    }

    func testInspectionRejectsEscapedMalformedAndOversizedInputs() {
        for value in ["\\{{host}}", "{{bad-name}}", String(repeating: "x", count: 16_385) + "{{host}}"] {
            XCTAssertNil(VariableInspectionMatcher.reference(in: value, selection: NSRange(location: 3, length: 0)))
        }
        XCTAssertNil(VariableInspectionMatcher.reference(in: "{{host}}", selection: NSRange(location: NSNotFound, length: 0)))
    }
}
