import XCTest
import PostieCore
@testable import PostieApp

final class RequestSearchTests: XCTestCase {
    func testSearchUsesDraftNameAndLiteralURLWithStableDuplicateIdentities() {
        var first = HTTPRequestConfiguration(name: "Fetch", url: "https://example.test/old")
        let second = HTTPRequestConfiguration(name: "Fetch", url: "{{base}}/widgets/:id")
        let collection = RequestCollection(name: "Fixtures", requests: [first, second])
        let identity = RequestIdentity(collectionID: collection.id, requestID: first.id)
        first.name = "Edited draft"
        first.url = "https://example.test/NewPath"
        let drafts = [identity: first]

        XCTAssertEqual(
            RequestSearchResult.matching("EDITED", collections: [collection], drafts: drafts).map(\.id), [identity])
        XCTAssertEqual(
            RequestSearchResult.matching("newpath", collections: [collection], drafts: drafts).map(\.id), [identity])
        XCTAssertEqual(
            RequestSearchResult.matching("/:id", collections: [collection], drafts: drafts).first?.id.requestID,
            second.id)
        XCTAssertEqual(RequestSearchResult.matching("", collections: [collection], drafts: drafts).count, 2)
        XCTAssertTrue(RequestSearchResult.matching("missing", collections: [collection], drafts: drafts).isEmpty)
    }
}
