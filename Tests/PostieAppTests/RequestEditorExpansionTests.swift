import XCTest
@testable import PostieApp

final class RequestEditorExpansionTests: XCTestCase {
    func testInitialExpansionKeepsEmptySectionsClosedAndManualCollapseAcrossReconcile() {
        var state = RequestEditorExpansionState()
        let content = RequestEditorContentSnapshot(queryCount: 1, pathNames: ["itemID"])

        state.reconcile(initiallyExpanded: [.query, .path, .headers], content: content)

        XCTAssertTrue(state.isExpanded(.query))
        XCTAssertTrue(state.isExpanded(.path))
        XCTAssertTrue(state.isExpanded(.headers))
        XCTAssertFalse(state.isExpanded(.body))

        state.setExpanded(.query, false)
        state.setExpanded(.headers, false)
        state.reconcile(initiallyExpanded: Set(RequestEditorAccordion.allCases), content: content)

        XCTAssertFalse(state.isExpanded(.query))
        XCTAssertFalse(state.isExpanded(.headers))
        XCTAssertTrue(state.isExpanded(.path))
    }

    func testQueryAndNewPathParameterAdditionsExpandTheirSections() {
        var state = RequestEditorExpansionState()
        let empty = RequestEditorContentSnapshot(queryCount: 0, pathNames: [])
        state.reconcile(initiallyExpanded: [], content: empty)
        state.setExpanded(.query, false)
        state.setExpanded(.path, false)
        state.setExpanded(.headers, false)

        state.reconcile(
            initiallyExpanded: [.headers],
            content: RequestEditorContentSnapshot(queryCount: 1, pathNames: ["itemID"])
        )

        XCTAssertTrue(state.isExpanded(.query))
        XCTAssertTrue(state.isExpanded(.path))
        XCTAssertFalse(state.isExpanded(.headers))
    }

    func testDefinitionJumpCanReopenManuallyCollapsedVariables() {
        var state = RequestEditorExpansionState()
        state.reconcile(initiallyExpanded: [.variables], content: .init(queryCount: 0, pathNames: []))
        state.setExpanded(.variables, false)

        state.expand(.variables)

        XCTAssertTrue(state.isExpanded(.variables))
    }
}
