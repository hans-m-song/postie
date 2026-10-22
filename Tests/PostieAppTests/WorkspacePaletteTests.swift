import PostieCore
import XCTest
@testable import PostieApp

private func paletteSnapshotGrouping(_ snapshot: SavedSnapshot) -> SnapshotGrouping {
    SnapshotGrouping(
        identity: snapshot.source.identity,
        collectionName: snapshot.source.collectionName,
        requestName: snapshot.source.requestName
    )
}

final class WorkspacePaletteTests: XCTestCase {
    func testInvocationDetectsEachPaletteModeAndKeepsUnprefixedQueries() {
        XCTAssertEqual(WorkspacePalette.invocation(for: ""), .all(query: ""))
        XCTAssertEqual(WorkspacePalette.invocation(for: "@"), .requests(query: ""))
        XCTAssertEqual(WorkspacePalette.invocation(for: "#"), .collections(query: ""))
        XCTAssertEqual(WorkspacePalette.invocation(for: "  @ Fetch  "), .requests(query: "Fetch"))
        XCTAssertEqual(WorkspacePalette.invocation(for: "  # gateway  "), .collections(query: "gateway"))
        XCTAssertEqual(WorkspacePalette.invocation(for: "  > Settings  "), .commands(query: "Settings"))
        XCTAssertEqual(WorkspacePalette.invocation(for: "$way"), .variables(query: "way"))
        XCTAssertEqual(WorkspacePalette.invocation(for: "gateway"), .all(query: "gateway"))
        XCTAssertEqual(WorkspacePalette.invocation(for: "   "), .all(query: "   "))
    }

    func testUnifiedCatalogPreservesTypedVisualOrderAndPrefixModesExcludeOtherKinds() {
        let collectionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let requestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let snapshotID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let request = HTTPRequestConfiguration(
            id: requestID,
            name: "Fetch",
            variables: ["request_key": .plain("value")]
        )
        let collection = RequestCollection(
            id: collectionID,
            name: "Gateway",
            requests: [request],
            variables: ["collection_key": .plain("value")]
        )
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        let snapshot = SavedSnapshot(
            id: snapshotID,
            name: "Capture",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: SnapshotSource(
                identity: identity,
                collectionName: "Gateway",
                requestName: "Fetch"
            ),
            statusCode: 200,
            bodyByteCount: 1
        )
        let navigation = WorkspaceSearchResult.matching(
            "",
            collections: [collection],
            drafts: [:],
            snapshots: [snapshot],
            groupingForSnapshot: { paletteSnapshotGrouping($0) }
        )
        let commands = WorkspacePalette.commands(matching: "", collections: [collection])
        let variables = WorkspacePalette.variables(
            matching: "",
            globalVariables: ["global_key": .plain("value")],
            collections: [collection],
            drafts: [:]
        )

        let unified = WorkspacePalette.results(
            for: .all(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )
        let repeatUnified = WorkspacePalette.results(
            for: .all(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )
        let requestsOnly = WorkspacePalette.results(
            for: .requests(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )
        let collectionsOnly = WorkspacePalette.results(
            for: .collections(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )
        let commandsOnly = WorkspacePalette.results(
            for: .commands(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )
        let variablesOnly = WorkspacePalette.results(
            for: .variables(query: ""),
            navigation: navigation,
            commands: commands,
            variables: variables
        )

        XCTAssertEqual(unified.count, navigation.count + commands.count + variables.count)
        XCTAssertEqual(unified.map(\.id), repeatUnified.map(\.id))
        XCTAssertEqual(Set(unified.map(\.id)).count, unified.count)
        let expectedUnifiedIDs: [WorkspacePaletteResult.ID] =
            navigation.map { .destination($0.destination) }
            + commands.map { .command($0.id) }
            + variables.map { .variable($0.id) }
        XCTAssertEqual(
            unified.map(\.id),
            expectedUnifiedIDs
        )
        XCTAssertEqual(requestsOnly.map(\.id), [.destination(.request(identity))])
        XCTAssertEqual(collectionsOnly.map(\.id), [.destination(.collection(collectionID))])
        XCTAssertEqual(commandsOnly.map(\.id), commands.map { .command($0.id) })
        XCTAssertEqual(variablesOnly.map(\.id), variables.map { .variable($0.id) })
    }

    func testCommandsHaveStableDistinctIDsAndDisambiguateDuplicateCollectionNames() {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let collections = [
            RequestCollection(id: firstID, name: "Production"),
            RequestCollection(id: secondID, name: "production", isReadOnly: true),
        ]

        let results = WorkspacePalette.commands(matching: "", collections: collections)
        let repeatResults = WorkspacePalette.commands(matching: "", collections: collections)
        let collectionSettings = results.filter {
            if case .collectionSettings = $0.command { return true }
            return false
        }
        let createRequests = results.filter {
            if case .createRequest = $0.command { return true }
            return false
        }

        XCTAssertEqual(results.map(\.id), repeatResults.map(\.id))
        XCTAssertEqual(
            Array(results.prefix(4).map(\.command)),
            [.settings, .requestHistory, .globalVariables, .createCollection]
        )
        XCTAssertEqual(Set(results.map(\.id)).count, results.count)
        XCTAssertEqual(collectionSettings.count, 2)
        XCTAssertEqual(Set(collectionSettings.compactMap(\.detail)).count, 2)
        XCTAssertTrue(collectionSettings.allSatisfy { $0.detail?.contains("ID ") == true })
        XCTAssertEqual(createRequests.map(\.isEnabled), [true, false])
        XCTAssertTrue(results.first { $0.command == .createCollection }?.isEnabled == true)
    }

    func testCommandFilteringIsCaseInsensitiveAndReadOnlyWorkspaceBlocksCreation() {
        let collectionID = UUID()
        let collection = RequestCollection(id: collectionID, name: "Gateway QA", isReadOnly: false)
        let matching = WorkspacePalette.commands(matching: "gAtEwAy", collections: [collection])
        let tokenMatching = WorkspacePalette.commands(matching: "gAtEwAy create", collections: [collection])
        let readOnly = WorkspacePalette.commands(
            matching: "",
            collections: [collection],
            workspaceIndexIsReadOnly: true
        )
        let deleting = WorkspacePalette.commands(
            matching: "",
            collections: [collection],
            deletingCollections: [collectionID]
        )

        XCTAssertEqual(matching.map(\.command), [.collectionSettings(collectionID), .createRequest(collectionID)])
        XCTAssertEqual(tokenMatching.map(\.command), [.createRequest(collectionID)])
        XCTAssertTrue(readOnly.first { $0.command == .createCollection }?.isEnabled == false)
        XCTAssertTrue(readOnly.first { $0.command == .createRequest(collectionID) }?.isEnabled == false)
        XCTAssertTrue(readOnly.first { $0.command == .collectionSettings(collectionID) }?.isEnabled == true)
        XCTAssertTrue(deleting.first { $0.command == .createRequest(collectionID) }?.isEnabled == false)
    }

    func testVariableSearchUsesCaseInsensitiveSubstringOfNameAndKeepsScopeCollisions() {
        let collectionID = UUID()
        let requestID = UUID()
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        let request = HTTPRequestConfiguration(
            id: requestID,
            name: "Fetch account",
            variables: ["gateway_url": .plain("https://example.invalid")]
        )
        let collection = RequestCollection(
            id: collectionID,
            name: "gateway profile",
            requests: [request],
            variables: ["gateway_url": .plain("https://collection.invalid")]
        )

        let results = WorkspacePalette.variables(
            matching: "WAY",
            globalVariables: ["gateway_url": .plain("https://global.invalid")],
            collections: [collection],
            drafts: [:]
        )
        let scopeSearch = WorkspacePalette.variables(
            matching: "profile",
            globalVariables: [:],
            collections: [collection],
            drafts: [:]
        )
        let valueSearch = WorkspacePalette.variables(
            matching: "https://collection.invalid",
            globalVariables: ["gateway_url": .plain("https://global.invalid")],
            collections: [collection],
            drafts: [:]
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map(\.id)).count, 3)
        XCTAssertEqual(results.map(\.owner), [.global, .collection(collectionID), .request(identity)])
        XCTAssertEqual(
            results.map(\.preview),
            ["https://global.invalid", "https://collection.invalid", "https://example.invalid"]
        )
        XCTAssertEqual(
            results.map(\.scope),
            ["Global", "Collection · gateway profile", "Request · Fetch account · gateway profile"])
        XCTAssertTrue(scopeSearch.isEmpty)
        XCTAssertTrue(valueSearch.isEmpty)
    }

    func testDraftVariablesReplaceSavedRequestVariables() {
        let collectionID = UUID()
        let requestID = UUID()
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        let savedRequest = HTTPRequestConfiguration(
            id: requestID,
            name: "Saved name",
            variables: [
                "gateway_url": .plain("saved value"),
                "saved_only": .plain("old"),
            ]
        )
        let draft = HTTPRequestConfiguration(
            id: requestID,
            name: "Draft name",
            variables: [
                "gateway_url": .plain("draft value"),
                "draft_only": .plain("new"),
            ]
        )
        let collection = RequestCollection(id: collectionID, name: "Workspace", requests: [savedRequest])

        let matching = WorkspacePalette.variables(
            matching: "gateway",
            globalVariables: [:],
            collections: [collection],
            drafts: [identity: draft]
        )
        let savedOnly = WorkspacePalette.variables(
            matching: "saved_only",
            globalVariables: [:],
            collections: [collection],
            drafts: [identity: draft]
        )

        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.owner, .request(identity))
        XCTAssertEqual(matching.first?.preview, "draft value")
        XCTAssertEqual(matching.first?.scope, "Request · Draft name · Workspace")
        XCTAssertTrue(savedOnly.isEmpty)
    }

    func testDuplicateCollectionAndRequestNamesReceiveDistinctScopeLabels() {
        let firstCollectionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondCollectionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let firstRequestID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let secondRequestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let first = HTTPRequestConfiguration(id: firstRequestID, name: "Fetch", variables: ["base_url": .plain("a")])
        let duplicate = HTTPRequestConfiguration(
            id: secondRequestID, name: "fetch", variables: ["base_url": .plain("b")])
        let collections = [
            RequestCollection(id: firstCollectionID, name: "API", requests: [first, duplicate]),
            RequestCollection(id: secondCollectionID, name: "api", variables: ["base_url": .plain("c")]),
        ]

        let results = WorkspacePalette.variables(
            matching: "base_url",
            globalVariables: [:],
            collections: collections,
            drafts: [:]
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map(\.scope)).count, results.count)
        XCTAssertTrue(results.allSatisfy { $0.scope.contains("ID ") })
    }

    func testEncryptedVariablesExposeOnlyNameScopeAndSecretMarker() {
        let marker = "ENVELOPE-MUST-NOT-LEAK"
        let collectionID = UUID()
        let collection = RequestCollection(
            id: collectionID,
            name: "Private",
            variables: ["api_token": .encrypted(SecretEnvelope(combined: marker))]
        )

        let result = try! XCTUnwrap(
            WorkspacePalette.variables(
                matching: "token",
                globalVariables: [:],
                collections: [collection],
                drafts: [:]
            ).first
        )
        let envelopeSearch = WorkspacePalette.variables(
            matching: marker,
            globalVariables: [:],
            collections: [collection],
            drafts: [:]
        )

        XCTAssertEqual(result.name, "api_token")
        XCTAssertTrue(result.isSecret)
        XCTAssertNil(result.preview)
        XCTAssertFalse(String(reflecting: result).contains(marker))
        XCTAssertTrue(envelopeSearch.isEmpty)
    }

    func testUnifiedSearchNeverMatchesEncryptedOrPlainVariableValues() {
        let secretValue = "ENVELOPE-MUST-NOT-LEAK"
        let plainValue = "PRIVATE-PLAIN-VALUE"
        let collection = RequestCollection(
            id: UUID(),
            name: "Workspace",
            variables: [
                "api_token": .encrypted(SecretEnvelope(combined: secretValue)),
                "private_value": .plain(plainValue),
            ]
        )
        let unifiedResults = { (query: String) in
            let invocation = WorkspacePalette.invocation(for: query)
            let navigation = WorkspaceSearchResult.matching(
                invocation.query,
                collections: [collection],
                drafts: [:],
                snapshots: [],
                groupingForSnapshot: { paletteSnapshotGrouping($0) }
            )
            let commands = WorkspacePalette.commands(matching: invocation.query, collections: [collection])
            let variables = WorkspacePalette.variables(
                matching: invocation.query,
                globalVariables: [:],
                collections: [collection],
                drafts: [:]
            )
            return WorkspacePalette.results(
                for: invocation,
                navigation: navigation,
                commands: commands,
                variables: variables
            )
        }

        let secretNameMatch = unifiedResults("api_token")
        let secretValueMatch = unifiedResults(secretValue)
        let plainValueMatch = unifiedResults(plainValue)

        XCTAssertTrue(
            secretNameMatch.contains { result in
                guard case let .variable(variable) = result else { return false }
                return variable.name == "api_token" && variable.isSecret && variable.preview == nil
            })
        XCTAssertTrue(secretValueMatch.isEmpty)
        XCTAssertTrue(plainValueMatch.isEmpty)
        XCTAssertFalse(String(reflecting: secretNameMatch).contains(secretValue))
    }

    func testPlainPreviewIsSingleLineAndBounded() {
        let collection = RequestCollection(
            id: UUID(),
            name: "Preview",
            variables: ["long_value": .plain("line one\n" + String(repeating: "x", count: 200))]
        )

        let preview = try! XCTUnwrap(
            WorkspacePalette.variables(
                matching: "long_value",
                globalVariables: [:],
                collections: [collection],
                drafts: [:]
            ).first?.preview
        )

        XCTAssertFalse(preview.contains("\n"))
        XCTAssertLessThanOrEqual(preview.count, 120)
        XCTAssertTrue(preview.hasSuffix("…"))
    }
}
