import XCTest
import PostieCore
@testable import PostieApp

final class InheritedHeaderStatusTests: XCTestCase {
    func testCaseDistinctTemplateNamesRemainVariableDependent() {
        let inherited = HTTPField(name: "{{Name}}", value: "collection")
        let request = HTTPField(name: "{{name}}", value: "request")

        XCTAssertEqual(
            InheritedHeaderStatus.label(for: inherited, requestHeaders: [request]),
            "Variable dependent"
        )
    }

    func testLiteralNamesMatchCaseInsensitivelyAsOverride() {
        let inherited = HTTPField(name: "Content-Type", value: "application/json")
        let request = HTTPField(name: "content-type", value: "text/plain")

        XCTAssertEqual(
            InheritedHeaderStatus.label(for: inherited, requestHeaders: [request]),
            "Overridden"
        )
    }

    func testDisabledLiteralMatchIsSuppressedCaseInsensitively() {
        let inherited = HTTPField(name: "X-Trace", value: "collection")
        let request = HTTPField(name: "x-trace", value: "", isEnabled: false)

        XCTAssertEqual(
            InheritedHeaderStatus.label(for: inherited, requestHeaders: [request]),
            "Suppressed"
        )
    }
}
