import XCTest
import PostieCore
@testable import PostieApp

final class WorkspaceSearchTests: XCTestCase {
    func testSearchUsesDraftMetadataAndStableTypedIdentities() {
        let collectionID = UUID()
        let firstRequestID = UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000001")!
        let secondRequestID = UUID()
        let thirdRequestID = UUID(uuidString: "ABCDEF12-9999-4000-8000-000000000003")!
        let first = HTTPRequestConfiguration(
            id: firstRequestID,
            name: "Fetch",
            url: "https://example.test/old",
            body: "never-search-this-body",
            bodyEnabled: true
        )
        let second = HTTPRequestConfiguration(
            id: secondRequestID,
            name: "Fetch",
            url: "{{base}}/widgets/:id"
        )
        let third = HTTPRequestConfiguration(
            id: thirdRequestID,
            name: "Fetch",
            url: "https://example.test/old"
        )
        let collection = RequestCollection(
            id: collectionID,
            name: "Fixtures",
            requests: [first, second, third]
        )
        let firstIdentity = RequestIdentity(collectionID: collectionID, requestID: firstRequestID)
        let secondIdentity = RequestIdentity(collectionID: collectionID, requestID: secondRequestID)
        let thirdIdentity = RequestIdentity(collectionID: collectionID, requestID: thirdRequestID)
        var editedDraft = first
        editedDraft.name = "Edited draft"
        editedDraft.url = "https://example.test/NewPath"
        let drafts = [firstIdentity: editedDraft]
        let sourceGrouping: (SavedSnapshot) -> SnapshotGrouping = { $0.sourceGrouping }

        let collectionResults = WorkspaceSearchResult.matching(
            "FIXTURES", collections: [collection], drafts: drafts, snapshots: [],
            groupingForSnapshot: sourceGrouping)
        let draftResults = WorkspaceSearchResult.matching(
            "ited dra", collections: [collection], drafts: drafts, snapshots: [],
            groupingForSnapshot: sourceGrouping)
        let pathResults = WorkspaceSearchResult.matching(
            "test/NewP", collections: [collection], drafts: drafts, snapshots: [],
            groupingForSnapshot: sourceGrouping)
        let unresolvedPathResults = WorkspaceSearchResult.matching(
            "/:ID", collections: [collection], drafts: drafts, snapshots: [],
            groupingForSnapshot: sourceGrouping)
        let duplicateNameResults = WorkspaceSearchResult.matching(
            "fetch", collections: [collection], drafts: [:], snapshots: [],
            groupingForSnapshot: sourceGrouping)
        let emptyQueryResults = WorkspaceSearchResult.matching(
            "", collections: [collection], drafts: drafts, snapshots: [],
            groupingForSnapshot: sourceGrouping)

        XCTAssertEqual(collectionResults.map(\.destination), [.collection(collectionID)])
        XCTAssertEqual(draftResults.map(\.destination), [.request(firstIdentity)])
        XCTAssertEqual(pathResults.map(\.destination), [.request(firstIdentity)])
        XCTAssertEqual(unresolvedPathResults.map(\.destination), [.request(secondIdentity)])
        XCTAssertEqual(
            duplicateNameResults.map(\.destination),
            [.request(firstIdentity), .request(secondIdentity), .request(thirdIdentity)]
        )
        XCTAssertEqual(
            WorkspaceSearchResult.disambiguator(for: duplicateNameResults[0], among: duplicateNameResults),
            "ABCDEF12-000"
        )
        XCTAssertEqual(
            WorkspaceSearchResult.disambiguator(for: duplicateNameResults[2], among: duplicateNameResults),
            "ABCDEF12-999"
        )
        XCTAssertNil(WorkspaceSearchResult.disambiguator(for: duplicateNameResults[1], among: duplicateNameResults))
        XCTAssertEqual(
            emptyQueryResults.map(\.destination),
            [
                .collection(collectionID),
                .request(firstIdentity),
                .request(secondIdentity),
                .request(thirdIdentity),
            ]
        )
        XCTAssertEqual(
            emptyQueryResults.map(\.destination),
            WorkspaceSearchResult.matching(
                "", collections: [collection], drafts: drafts, snapshots: [],
                groupingForSnapshot: sourceGrouping
            ).map(\.destination)
        )
        XCTAssertTrue(
            WorkspaceSearchResult.matching(
                "missing", collections: [collection], drafts: drafts, snapshots: [],
                groupingForSnapshot: sourceGrouping
            ).isEmpty
        )
        XCTAssertTrue(
            WorkspaceSearchResult.matching(
                "never-search-this-body", collections: [collection], drafts: drafts, snapshots: [],
                groupingForSnapshot: sourceGrouping
            ).isEmpty
        )
    }

    func testDisambiguatorFallsBackToFullRequestIdentityWhenRequestIDsCollide() {
        let requestID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let firstCollectionID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let secondCollectionID = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
        let firstCollection = RequestCollection(
            id: firstCollectionID,
            name: "Fixtures",
            requests: [HTTPRequestConfiguration(id: requestID, name: "Fetch", url: "/same")]
        )
        let secondCollection = RequestCollection(
            id: secondCollectionID,
            name: "Fixtures",
            requests: [HTTPRequestConfiguration(id: requestID, name: "Fetch", url: "/same")]
        )
        let sourceGrouping: (SavedSnapshot) -> SnapshotGrouping = { $0.sourceGrouping }
        let results = WorkspaceSearchResult.matching(
            "Fetch", collections: [firstCollection, secondCollection], drafts: [:], snapshots: [],
            groupingForSnapshot: sourceGrouping)

        XCTAssertEqual(
            WorkspaceSearchResult.disambiguator(for: results[0], among: results),
            "request/\(firstCollectionID.uuidString)/\(requestID.uuidString)"
        )
    }

    func testUnfilteredResultsInterleaveCollectionsAndRequestsInSavedOrder() {
        let firstCollectionID = UUID()
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let secondCollectionID = UUID()
        let thirdRequestID = UUID()
        let collections = [
            RequestCollection(
                id: firstCollectionID,
                name: "First",
                requests: [
                    HTTPRequestConfiguration(id: firstRequestID, name: "One"),
                    HTTPRequestConfiguration(id: secondRequestID, name: "Two"),
                ]
            ),
            RequestCollection(
                id: secondCollectionID,
                name: "Second",
                requests: [HTTPRequestConfiguration(id: thirdRequestID, name: "Three")]
            ),
        ]

        let results = WorkspaceSearchResult.matching(
            "", collections: collections, drafts: [:], snapshots: [],
            groupingForSnapshot: { $0.sourceGrouping })

        XCTAssertEqual(
            results.map(\.destination),
            [
                .collection(firstCollectionID),
                .request(RequestIdentity(collectionID: firstCollectionID, requestID: firstRequestID)),
                .request(RequestIdentity(collectionID: firstCollectionID, requestID: secondRequestID)),
                .collection(secondCollectionID),
                .request(RequestIdentity(collectionID: secondCollectionID, requestID: thirdRequestID)),
            ]
        )
    }

    func testSnapshotNameSubstringFindsRetainedSnapshotWithoutLiveParent() {
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let snapshot = SavedSnapshot(
            id: UUID(),
            name: "Production response",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: SnapshotSource(
                identity: identity,
                collectionName: "Deleted collection",
                requestName: "Deleted request"
            ),
            statusCode: 200,
            bodyByteCount: 128
        )
        let grouping: (SavedSnapshot) -> SnapshotGrouping = { $0.sourceGrouping }
        let nameMatches = WorkspaceSearchResult.matching(
            "duction res", collections: [], drafts: [:], snapshots: [snapshot],
            groupingForSnapshot: grouping)
        let requestContextMatches = WorkspaceSearchResult.matching(
            "Deleted request", collections: [], drafts: [:], snapshots: [snapshot],
            groupingForSnapshot: grouping)
        let collectionContextMatches = WorkspaceSearchResult.matching(
            "Deleted collection", collections: [], drafts: [:], snapshots: [snapshot],
            groupingForSnapshot: grouping)
        let rootResults = WorkspaceSearchResult.matching(
            "", collections: [], drafts: [:], snapshots: [snapshot], groupingForSnapshot: grouping)

        XCTAssertEqual(nameMatches.map(\.destination), [.snapshot(snapshot.id)])
        XCTAssertTrue(requestContextMatches.isEmpty)
        XCTAssertTrue(collectionContextMatches.isEmpty)
        XCTAssertEqual(nameMatches.first?.collectionName, "Deleted collection")
        XCTAssertEqual(nameMatches.first?.requestName, "Deleted request")
        XCTAssertEqual(rootResults.map(\.destination), [.snapshot(snapshot.id)])
    }

    func testMovedSnapshotUsesCurrentGroupingInUnfilteredResults() {
        let originalIdentity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let movedCollectionID = UUID()
        let movedRequestID = UUID()
        let movedIdentity = RequestIdentity(collectionID: movedCollectionID, requestID: movedRequestID)
        let movedCollection = RequestCollection(
            id: movedCollectionID,
            name: "Live collection",
            requests: [HTTPRequestConfiguration(id: movedRequestID, name: "Moved request")]
        )
        let snapshot = SavedSnapshot(
            id: UUID(),
            name: "Moved capture",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: SnapshotSource(
                identity: originalIdentity,
                collectionName: "Original collection",
                requestName: "Original request"
            ),
            statusCode: 200,
            bodyByteCount: 128
        )
        let movedGrouping = SnapshotGrouping(
            identity: movedIdentity,
            collectionName: "Live collection",
            requestName: "Moved request"
        )
        let allResults = WorkspaceSearchResult.matching(
            "", collections: [movedCollection], drafts: [:], snapshots: [snapshot],
            groupingForSnapshot: { _ in movedGrouping })

        XCTAssertEqual(
            allResults.map(\.destination),
            [.collection(movedCollectionID), .request(movedIdentity), .snapshot(snapshot.id)]
        )
        let movedSnapshotResult = allResults.first { $0.destination == .snapshot(snapshot.id) }
        XCTAssertEqual(movedSnapshotResult?.collectionName, "Live collection")
        XCTAssertEqual(movedSnapshotResult?.requestName, "Moved request")
    }
}

private extension SavedSnapshot {
    var sourceGrouping: SnapshotGrouping {
        SnapshotGrouping(
            identity: source.identity,
            collectionName: source.collectionName,
            requestName: source.requestName
        )
    }
}
