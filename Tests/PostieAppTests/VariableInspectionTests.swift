import XCTest
@testable import PostieApp

final class VariableInspectionTests: XCTestCase {
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
