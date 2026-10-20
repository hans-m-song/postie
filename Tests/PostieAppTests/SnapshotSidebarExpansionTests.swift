import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class SnapshotSidebarExpansionTests: XCTestCase {
    func testSameRequestIDInDifferentCollectionsExpandsIndependentlyAndCanCollapse() {
        let expansion = SnapshotSidebarExpansion()
        let requestID = UUID()
        let firstIdentity = RequestIdentity(collectionID: UUID(), requestID: requestID)
        let secondIdentity = RequestIdentity(collectionID: UUID(), requestID: requestID)

        XCTAssertFalse(expansion.isExpanded(identity: firstIdentity))
        XCTAssertFalse(expansion.isExpanded(identity: secondIdentity))

        expansion.toggle(identity: firstIdentity)

        XCTAssertTrue(expansion.isExpanded(identity: firstIdentity))
        XCTAssertFalse(expansion.isExpanded(identity: secondIdentity))

        expansion.toggle(identity: firstIdentity)

        XCTAssertFalse(expansion.isExpanded(identity: firstIdentity))
        XCTAssertFalse(expansion.isExpanded(identity: secondIdentity))
    }
}
