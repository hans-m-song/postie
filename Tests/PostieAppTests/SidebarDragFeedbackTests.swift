import SwiftUI
import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class SidebarDragFeedbackTests: XCTestCase {
    func testEndedDragClearsHoveredIndicatorWithoutTargetExitOrDropCallback() {
        for operation in [DropOperation.cancel, .move] {
            let feedback = SidebarDragFeedback()
            let target = SidebarDropTarget.collection(UUID())
            feedback.setEdge(.before, for: target)

            XCTAssertEqual(feedback.edge(for: target), .before)

            feedback.sessionUpdated(.ended(operation))

            XCTAssertNil(feedback.edge(for: target))
        }
    }

    func testClearingDifferentTargetKeepsCurrentIndicator() {
        let feedback = SidebarDragFeedback()
        let previousTarget = SidebarDropTarget.collection(UUID())
        let currentTarget = SidebarDropTarget.request(
            RequestIdentity(collectionID: UUID(), requestID: UUID())
        )
        feedback.setEdge(.before, for: previousTarget)
        feedback.setEdge(.after, for: currentTarget)

        feedback.setEdge(nil, for: previousTarget)

        XCTAssertNil(feedback.edge(for: previousTarget))
        XCTAssertEqual(feedback.edge(for: currentTarget), .after)
    }

    func testLateTransferCompletionKeepsNextDragIndicator() {
        let feedback = SidebarDragFeedback()
        let target = SidebarDropTarget.collection(UUID())
        feedback.setEdge(.before, for: target)
        feedback.sessionUpdated(.ended(.cancel))
        feedback.sessionUpdated(.initial)

        XCTAssertNil(feedback.edge(for: target))

        feedback.setEdge(.after, for: target)
        feedback.sessionUpdated(.dataTransferCompleted)

        XCTAssertEqual(feedback.edge(for: target), .after)
    }
}
