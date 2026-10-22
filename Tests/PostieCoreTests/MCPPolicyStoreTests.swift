import Foundation
import XCTest
@testable import PostieCore

final class MCPPolicyStoreTests: XCTestCase {
    func testResponseViewingModesResolveClosestOverrideAndNameEachMode() {
        XCTAssertEqual(MCPResponseViewPolicy.resolveMode(), .block)
        XCTAssertEqual(MCPResponseViewPolicy.resolveMode(global: .unredacted), .unredacted)
        XCTAssertEqual(
            MCPResponseViewPolicy.resolveMode(global: .unredacted, collection: .allow),
            .allow
        )
        XCTAssertEqual(
            MCPResponseViewPolicy.resolveMode(global: .unredacted, collection: .allow, request: .block),
            .block
        )
        XCTAssertEqual(
            MCPResponseViewPolicy.resolveMode(global: .block, collection: .allow, request: .unredacted),
            .unredacted
        )
        XCTAssertTrue(MCPResponseViewPolicy.resolve(global: .unredacted))
        XCTAssertEqual(MCPResponseViewPolicy.block.displayName, "Block body; show safe metadata")
        XCTAssertEqual(MCPResponseViewPolicy.allow.displayName, "Show body with secrets redacted")
        XCTAssertEqual(MCPResponseViewPolicy.unredacted.displayName, "Show response unredacted")
        XCTAssertEqual(MCPResponseViewPolicy.inherit.displayName, "Inherit")
    }

    func testLegacyDocumentsDefaultPoliciesAndPersistUpdates() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Legacy")
        let request = HTTPRequestConfiguration(name: "Legacy request", url: "https://example.test")
        try await store.createRequest(request, in: collection.id)

        let globalsURL = root.appendingPathComponent("globals.json")
        var globals = try readObject(at: globalsURL)
        globals.removeValue(forKey: "mcpResponseViewing")
        try writeObject(globals, to: globalsURL)

        let collectionMetadataURL = collectionURL(root, collection.id).appendingPathComponent("collection.json")
        var collectionMetadata = try readObject(at: collectionMetadataURL)
        collectionMetadata.removeValue(forKey: "mcpPolicy")
        try writeObject(collectionMetadata, to: collectionMetadataURL)

        let requestURL = requestURL(root, collection.id, request.id)
        var requestDocument = try readObject(at: requestURL)
        requestDocument.removeValue(forKey: "mcpPolicy")
        try writeObject(requestDocument, to: requestURL)

        let legacy = try await store.load()
        XCTAssertEqual(legacy.globalMCPResponseViewing.rawValue, MCPResponseViewPolicy.block.rawValue)
        XCTAssertEqual(legacy.collections.first?.mcpPolicy, MCPResourcePolicy())
        XCTAssertEqual(legacy.collections.first?.requests.first?.mcpPolicy, MCPResourcePolicy())

        try await store.saveGlobalMCPResponseViewing(.unredacted)
        try await store.saveCollectionMCPPolicy(
            MCPResourcePolicy(excluded: true, responseViewing: .unredacted), in: collection.id)
        var editedRequest = try XCTUnwrap(legacy.collections.first?.requests.first)
        editedRequest.name = "Edited legacy request"
        editedRequest.mcpPolicy = MCPResourcePolicy(excluded: true, responseViewing: .unredacted)
        try await store.saveRequest(editedRequest, in: collection.id)
        do {
            try await store.saveGlobalMCPResponseViewing(.inherit)
            XCTFail("The global policy cannot inherit.")
        } catch CollectionStoreError.ioFailure {
        }

        let updated = try await store.load()
        XCTAssertEqual(updated.globalMCPResponseViewing.rawValue, MCPResponseViewPolicy.unredacted.rawValue)
        XCTAssertEqual(
            updated.collections.first?.mcpPolicy, MCPResourcePolicy(excluded: true, responseViewing: .unredacted))
        XCTAssertEqual(
            updated.collections.first?.requests.first?.mcpPolicy,
            MCPResourcePolicy(excluded: true, responseViewing: .unredacted))
    }

    func testPolicyUpdatesPreserveUnknownFieldsAndUnrelatedRequestEdits() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Future metadata")
        var request = HTTPRequestConfiguration(
            name: "Original", url: "https://example.test", mcpPolicy: .init(excluded: true, responseViewing: .allow))
        try await store.createRequest(request, in: collection.id)

        let globalsURL = root.appendingPathComponent("globals.json")
        var globals = try readObject(at: globalsURL)
        globals["futureGlobalData"] = ["retained": true]
        try writeObject(globals, to: globalsURL)

        let collectionMetadataURL = collectionURL(root, collection.id).appendingPathComponent("collection.json")
        var collectionMetadata = try readObject(at: collectionMetadataURL)
        collectionMetadata["futureCollectionData"] = ["retained": true]
        collectionMetadata["mcpPolicy"] = [
            "excluded": false, "responseViewing": "inherit", "futurePolicyData": ["retained": true],
        ]
        try writeObject(collectionMetadata, to: collectionMetadataURL)

        let requestURL = requestURL(root, collection.id, request.id)
        var requestDocument = try readObject(at: requestURL)
        requestDocument["futureRequestData"] = ["retained": true]
        requestDocument["mcpPolicy"] = [
            "excluded": true, "responseViewing": "allow", "futurePolicyData": ["retained": true],
        ]
        try writeObject(requestDocument, to: requestURL)

        let loadedBeforeEdit = try await store.load()
        request = try XCTUnwrap(loadedBeforeEdit.collections.first?.requests.first)
        request.name = "Renamed without changing policy"
        try await store.saveRequest(request, in: collection.id)
        try await store.saveCollectionMCPPolicy(
            MCPResourcePolicy(excluded: true, responseViewing: .block), in: collection.id)
        try await store.saveGlobalMCPResponseViewing(.allow)

        let savedGlobals = try readObject(at: globalsURL)
        let savedCollection = try readObject(at: collectionMetadataURL)
        let savedRequest = try readObject(at: requestURL)
        XCTAssertEqual((savedGlobals["futureGlobalData"] as? [String: Bool])?["retained"], true)
        XCTAssertEqual((savedCollection["futureCollectionData"] as? [String: Bool])?["retained"], true)
        XCTAssertEqual(
            ((savedCollection["mcpPolicy"] as? [String: Any])?["futurePolicyData"] as? [String: Bool])?["retained"],
            true)
        XCTAssertEqual((savedRequest["futureRequestData"] as? [String: Bool])?["retained"], true)
        XCTAssertEqual(
            ((savedRequest["mcpPolicy"] as? [String: Any])?["futurePolicyData"] as? [String: Bool])?["retained"], true)

        let loaded = try await store.load()
        XCTAssertEqual(loaded.globalMCPResponseViewing.rawValue, MCPResponseViewPolicy.allow.rawValue)
        XCTAssertEqual(loaded.collections.first?.mcpPolicy, MCPResourcePolicy(excluded: true, responseViewing: .block))
        XCTAssertEqual(loaded.collections.first?.requests.first?.name, "Renamed without changing policy")
        XCTAssertEqual(
            loaded.collections.first?.requests.first?.mcpPolicy,
            MCPResourcePolicy(excluded: true, responseViewing: .allow))
    }

    func testInvalidPoliciesFailClosedAndRejectPolicyWrites() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Invalid policy")
        let request = HTTPRequestConfiguration(name: "Invalid request", url: "https://example.test")
        try await store.createRequest(request, in: collection.id)

        let globalsURL = root.appendingPathComponent("globals.json")
        var globals = try readObject(at: globalsURL)
        globals["mcpResponseViewing"] = "future-policy"
        try writeObject(globals, to: globalsURL)

        let collectionMetadataURL = collectionURL(root, collection.id).appendingPathComponent("collection.json")
        var collectionMetadata = try readObject(at: collectionMetadataURL)
        collectionMetadata["mcpPolicy"] = ["excluded": false, "responseViewing": "future-policy"]
        try writeObject(collectionMetadata, to: collectionMetadataURL)

        let requestURL = requestURL(root, collection.id, request.id)
        var requestDocument = try readObject(at: requestURL)
        requestDocument["mcpPolicy"] = ["excluded": false, "responseViewing": "future-policy"]
        try writeObject(requestDocument, to: requestURL)

        let originalGlobals = try Data(contentsOf: globalsURL)
        let originalCollection = try Data(contentsOf: collectionMetadataURL)
        let originalRequest = try Data(contentsOf: requestURL)
        let loaded = try await store.load()
        let loadedCollection = try XCTUnwrap(loaded.collections.first)

        XCTAssertEqual(loaded.globalMCPResponseViewing.rawValue, MCPResponseViewPolicy.block.rawValue)
        XCTAssertTrue(loaded.globalOptionsAreReadOnly)
        XCTAssertTrue(loadedCollection.isReadOnly)
        XCTAssertTrue(loadedCollection.mcpPolicy.excluded)
        XCTAssertEqual(loadedCollection.mcpPolicy.responseViewing.rawValue, MCPResponseViewPolicy.block.rawValue)
        XCTAssertTrue(loadedCollection.requests.isEmpty)
        XCTAssertTrue(
            loaded.issues.contains { $0.id.contains("globals-malformed") && $0.id.contains("mcpResponseViewing") })
        XCTAssertTrue(loaded.issues.contains { $0.id.contains("collection-mcp-policy-malformed") })
        XCTAssertTrue(loaded.issues.contains { $0.id.contains("request-malformed") })

        do {
            try await store.saveGlobalMCPResponseViewing(.allow)
            XCTFail("A malformed stored global policy must stay read-only.")
        } catch CollectionStoreError.ioFailure {
        }
        do {
            try await store.saveCollectionMCPPolicy(.init(), in: collection.id)
            XCTFail("A malformed stored collection policy must stay read-only.")
        } catch CollectionStoreError.collectionIsReadOnly {
        }

        XCTAssertEqual(try Data(contentsOf: globalsURL), originalGlobals)
        XCTAssertEqual(try Data(contentsOf: collectionMetadataURL), originalCollection)
        XCTAssertEqual(try Data(contentsOf: requestURL), originalRequest)
    }

    func testSnapshotExclusionTombstonesPersistAndClearWithGroupingRemoval() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)
        let firstSnapshotID = UUID()
        let secondSnapshotID = UUID()
        let collectionID = UUID()
        let requestID = UUID()

        var index = try await store.setSnapshotMCPExcluded(id: firstSnapshotID, isExcluded: true)
        XCTAssertTrue(index.mcpExcludedSnapshotIDs.contains(firstSnapshotID))

        let indexURL = root.appendingPathComponent("workspace-index.json")
        var indexObject = try readObject(at: indexURL)
        indexObject["futureWorkspaceData"] = ["retained": true]
        indexObject["snapshotGroupingOverrides"] = [
            firstSnapshotID.uuidString.lowercased(): [
                "identity": [
                    "collectionID": collectionID.uuidString.lowercased(),
                    "requestID": requestID.uuidString.lowercased(),
                ],
                "collectionName": "Deleted collection",
                "requestName": "Deleted request",
                "futureGroupingData": ["retained": true],
            ]
        ]
        try writeObject(indexObject, to: indexURL)

        index = try await store.setSnapshotMCPExcluded(id: secondSnapshotID, isExcluded: true)
        XCTAssertEqual(index.mcpExcludedSnapshotIDs, [firstSnapshotID, secondSnapshotID])

        index = try await store.removeSnapshotGrouping(id: firstSnapshotID)
        XCTAssertFalse(index.mcpExcludedSnapshotIDs.contains(firstSnapshotID))
        XCTAssertTrue(index.mcpExcludedSnapshotIDs.contains(secondSnapshotID))
        XCTAssertNil(index.snapshotGroupingOverrides[firstSnapshotID])

        index = try await store.removeSnapshotGrouping(id: secondSnapshotID)
        XCTAssertTrue(index.mcpExcludedSnapshotIDs.isEmpty)
        XCTAssertTrue(index.snapshotGroupingOverrides.isEmpty)
        XCTAssertEqual((try readObject(at: indexURL)["futureWorkspaceData"] as? [String: Bool])?["retained"], true)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.workspaceIndex.mcpExcludedSnapshotIDs.isEmpty)
    }

    func testMalformedSnapshotExclusionsMakeWorkspaceIndexReadOnly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("workspace-index.json")
        let malformedIndex: [String: Any] = [
            "formatVersion": 1,
            "collectionOrder": [],
            "snapshotGroupingOverrides": [:],
            "mcpExcludedSnapshotIDs": ["future-invalid-identity"],
        ]
        try writeObject(malformedIndex, to: indexURL)
        let originalIndex = try Data(contentsOf: indexURL)
        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()

        XCTAssertTrue(loaded.workspaceIndexIsReadOnly)
        XCTAssertTrue(loaded.workspaceIndex.mcpExcludedSnapshotIDs.isEmpty)
        XCTAssertTrue(loaded.issues.contains { $0.id.contains("workspace-index-malformed") })
        do {
            _ = try await store.setSnapshotMCPExcluded(id: UUID(), isExcluded: true)
            XCTFail("Malformed workspace policy metadata must reject writes.")
        } catch CollectionStoreError.workspaceIndexIsReadOnly {
        }
        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PostieMCPPolicyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func collectionURL(_ root: URL, _ collectionID: UUID) -> URL {
        root.appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(collectionID.uuidString.lowercased(), isDirectory: true)
    }

    private func requestURL(_ root: URL, _ collectionID: UUID, _ requestID: UUID) -> URL {
        collectionURL(root, collectionID).appendingPathComponent("\(requestID.uuidString.lowercased()).json")
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(value as? [String: Any])
    }

    private func writeObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}
