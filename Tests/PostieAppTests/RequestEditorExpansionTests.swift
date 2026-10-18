import XCTest
@testable import PostieApp

final class RequestEditorExpansionTests: XCTestCase {
    func testAllRequestSectionsStartOpenAndManualCollapsePersists() {
        var state = RequestEditorExpansionState()
        let content = RequestEditorContentSnapshot(queryCount: 0, pathNames: [])
        let allSections = Set(RequestEditorAccordion.allCases)

        state.reconcile(initiallyExpanded: allSections, content: content)

        XCTAssertEqual(Set(allSections.filter(state.isExpanded)), allSections)

        state.setExpanded(.query, false)
        state.setExpanded(.headers, false)
        state.reconcile(initiallyExpanded: allSections, content: content)

        XCTAssertFalse(state.isExpanded(.query))
        XCTAssertFalse(state.isExpanded(.headers))
        XCTAssertTrue(state.isExpanded(.path))
        XCTAssertTrue(state.isExpanded(.body))
    }

    func testQueryAndNewPathParameterAdditionsExpandTheirSections() {
        var state = RequestEditorExpansionState()
        let empty = RequestEditorContentSnapshot(queryCount: 0, pathNames: [])
        let allSections = Set(RequestEditorAccordion.allCases)
        state.reconcile(initiallyExpanded: allSections, content: empty)
        state.setExpanded(.query, false)
        state.setExpanded(.path, false)
        state.setExpanded(.headers, false)
        state.setExpanded(.body, false)

        state.reconcile(
            initiallyExpanded: allSections,
            content: RequestEditorContentSnapshot(queryCount: 1, pathNames: ["itemID"])
        )

        XCTAssertTrue(state.isExpanded(.query))
        XCTAssertTrue(state.isExpanded(.path))
        XCTAssertFalse(state.isExpanded(.headers))
        XCTAssertFalse(state.isExpanded(.body))
    }
}
