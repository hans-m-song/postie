import Foundation
import XCTest
@testable import PostieCore

final class OrderingStoreTests: XCTestCase {
    func testLegacyAlphabeticalOrderCanBeChangedAndKeepsUnknownIndexDataAcrossRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let alphaID: UUID
        let zuluID: UUID
        do {
            let store = try CollectionStore(rootURL: root)
            alphaID = try await store.createCollection(name: "Alpha").id
            zuluID = try await store.createCollection(name: "Zulu").id

            let legacy = try await store.load()
            XCTAssertEqual(legacy.collections.map(\.id), [alphaID, zuluID])
            XCTAssertFalse(legacy.workspaceIndexIsReadOnly)

            _ = try await store.reorderCollections(ids: [zuluID, alphaID])
            let indexURL = root.appendingPathComponent("workspace-index.json")
            var index = try readObject(at: indexURL)
            index["futureWorkspaceData"] = ["retained": true]
            try writeObject(index, to: indexURL)
            _ = try await store.reorderCollections(ids: [zuluID, alphaID])
        }

        let restarted = try CollectionStore(rootURL: root)
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded.collections.map(\.id), [zuluID, alphaID])
        XCTAssertEqual(loaded.workspaceIndex.collectionOrder, [zuluID, alphaID])
        XCTAssertEqual(
            (try readObject(at: root.appendingPathComponent("workspace-index.json"))["futureWorkspaceData"]
                as? [String: Bool])?["retained"], true)
    }

    func testMovePreservesRequestBytesBrokenIndexSlotsAndSnapshotGrouping() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceID: UUID
        let destinationID: UUID
        let movedRequestID: UUID
        let beforeRequestID: UUID
        let snapshotID = UUID()
        let originalRequestBytes: Data

        do {
            let store = try CollectionStore(rootURL: root)
            let source = try await store.createCollection(name: "Source")
            let destination = try await store.createCollection(name: "Destination")
            sourceID = source.id
            destinationID = destination.id
            try await store.saveCollectionConfiguration(
                CollectionRequestDefaults(
                    authentication: RequestAuthentication(
                        kind: .bearer,
                        token: SecretEnvelope(combined: "synthetic destination token ciphertext")
                    )),
                variables: [:],
                in: destination.id
            )

            let movedRequest = HTTPRequestConfiguration(
                name: "Template request",
                method: "POST",
                url: "https://{{missingHost}}.invalid/{{missingPath}}",
                body: "{{missingBody}}",
                bodyEnabled: true,
                bodySyntax: .json,
                optionOverrides: HTTPOptionsOverrides(followRedirects: false, overallTimeout: nil),
                inheritsCollectionAuthentication: true
            )
            try await store.createRequest(movedRequest, in: source.id)
            movedRequestID = movedRequest.id

            let beforeRequest = HTTPRequestConfiguration(name: "Before target", url: "https://target.invalid")
            try await store.createRequest(beforeRequest, in: destination.id)
            beforeRequestID = beforeRequest.id

            let requestURL = requestURL(root, source.id, movedRequest.id)
            originalRequestBytes = try Data(contentsOf: requestURL)

            let sourceMetadataURL = collectionURL(root, source.id).appendingPathComponent("collection.json")
            var sourceMetadata = try readObject(at: sourceMetadataURL)
            sourceMetadata["requests"] = [movedRequest.id.uuidString.lowercased(), 42, "broken-source-slot"]
            try writeObject(sourceMetadata, to: sourceMetadataURL)

            let destinationMetadataURL = collectionURL(root, destination.id).appendingPathComponent("collection.json")
            var destinationMetadata = try readObject(at: destinationMetadataURL)
            destinationMetadata["requests"] = ["broken-destination-slot", beforeRequest.id.uuidString.lowercased()]
            try writeObject(destinationMetadata, to: destinationMetadataURL)

            let indexURL = root.appendingPathComponent("workspace-index.json")
            try writeObject(
                [
                    "formatVersion": 1,
                    "collectionOrder": [destination.id.uuidString.lowercased(), source.id.uuidString.lowercased()],
                    "mcpExcludedSnapshotIDs": [snapshotID.uuidString.lowercased()],
                    "snapshotGroupingOverrides": [String: Any](),
                    "futureWorkspaceData": ["retained": true],
                ], to: indexURL)

            let result = try await store.moveRequest(
                RequestIdentity(collectionID: source.id, requestID: movedRequest.id),
                toCollectionID: destination.id,
                beforeRequestID: beforeRequest.id,
                snapshotIDs: [snapshotID]
            )
            XCTAssertEqual(result.oldIdentity.collectionID, source.id)
            XCTAssertEqual(result.newIdentity.collectionID, destination.id)
            XCTAssertEqual(
                result.workspaceIndex.snapshotGroupingOverrides[snapshotID],
                SnapshotGrouping(
                    identity: RequestIdentity(collectionID: destination.id, requestID: movedRequest.id),
                    collectionName: "Destination",
                    requestName: "Template request"
                ))
            XCTAssertFalse(result.workspaceIndex.mcpExcludedSnapshotIDs.contains(snapshotID))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(root, sourceID, movedRequestID).path))
        XCTAssertEqual(try Data(contentsOf: requestURL(root, destinationID, movedRequestID)), originalRequestBytes)

        let sourceEntries = try XCTUnwrap(
            try readObject(at: collectionURL(root, sourceID).appendingPathComponent("collection.json"))["requests"]
                as? [Any])
        XCTAssertEqual(sourceEntries.count, 2)
        XCTAssertEqual(sourceEntries[0] as? Int, 42)
        XCTAssertEqual(sourceEntries[1] as? String, "broken-source-slot")

        let destinationEntries = try XCTUnwrap(
            try readObject(at: collectionURL(root, destinationID).appendingPathComponent("collection.json"))["requests"]
                as? [String])
        XCTAssertEqual(
            destinationEntries,
            [
                "broken-destination-slot", movedRequestID.uuidString.lowercased(),
                beforeRequestID.uuidString.lowercased(),
            ])

        let loaded = try await CollectionStore(rootURL: root).load()
        XCTAssertEqual(loaded.collections.map(\.id), [destinationID, sourceID])
        XCTAssertEqual(
            loaded.workspaceIndex.snapshotGroupingOverrides[snapshotID]?.identity,
            RequestIdentity(collectionID: destinationID, requestID: movedRequestID))
        XCTAssertFalse(loaded.workspaceIndex.mcpExcludedSnapshotIDs.contains(snapshotID))
        XCTAssertTrue(
            try XCTUnwrap(loaded.collections.first { $0.id == destinationID }?.requests.first)
                .inheritsCollectionAuthentication)
        XCTAssertEqual(
            loaded.collections.first { $0.id == destinationID }?.authentication.token?.combined,
            "synthetic destination token ciphertext")
        XCTAssertEqual(
            (try readObject(at: root.appendingPathComponent("workspace-index.json"))["futureWorkspaceData"]
                as? [String: Bool])?["retained"], true)
    }

    func testMoveRejectsDestinationCollisionWithoutChangingEitherRequestFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID: UUID
        let destinationID: UUID
        let requestID: UUID
        let sourceBytes: Data
        let destinationBytes: Data

        do {
            let store = try CollectionStore(rootURL: root)
            let source = try await store.createCollection(name: "Source")
            let destination = try await store.createCollection(name: "Destination")
            sourceID = source.id
            destinationID = destination.id
            let request = HTTPRequestConfiguration(id: UUID(), name: "Source request", url: "https://source.invalid")
            requestID = request.id
            try await store.createRequest(request, in: source.id)
            sourceBytes = try Data(contentsOf: requestURL(root, source.id, request.id))

            var destinationRequest = request
            destinationRequest.name = "Conflicting destination request"
            try writeObject(try requestObject(destinationRequest), to: requestURL(root, destination.id, request.id))
            destinationBytes = try Data(contentsOf: requestURL(root, destination.id, request.id))
            let destinationMetadataURL = collectionURL(root, destination.id).appendingPathComponent("collection.json")
            var metadata = try readObject(at: destinationMetadataURL)
            metadata["requests"] = [request.id.uuidString.lowercased()]
            try writeObject(metadata, to: destinationMetadataURL)

            do {
                _ = try await store.moveRequest(
                    RequestIdentity(collectionID: source.id, requestID: request.id),
                    toCollectionID: destination.id,
                    beforeRequestID: nil,
                    snapshotIDs: []
                )
                XCTFail("A destination request identity collision must be rejected")
            } catch CollectionStoreError.requestAlreadyExists {}
        }

        XCTAssertEqual(try Data(contentsOf: requestURL(root, sourceID, requestID)), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: requestURL(root, destinationID, requestID)), destinationBytes)
    }

    func testFutureWorkspaceIndexIsPreservedAndBlocksIndexWrites() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await CollectionStore(rootURL: root).createCollection(name: "Collection").id
        let indexURL = root.appendingPathComponent("workspace-index.json")
        let futureIndex: [String: Any] = [
            "formatVersion": 2,
            "collectionOrder": [collectionID.uuidString.lowercased()],
            "snapshotGroupingOverrides": [String: Any](),
            "futureWorkspaceData": ["retained": true],
        ]
        try writeObject(futureIndex, to: indexURL)
        let originalBytes = try Data(contentsOf: indexURL)

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.workspaceIndexIsReadOnly)
        XCTAssertTrue(loaded.issues.contains { $0.id == "store:workspace-index-version-unsupported" })
        do {
            _ = try await store.reorderCollections(ids: [collectionID])
            XCTFail("A future workspace index must remain read-only")
        } catch CollectionStoreError.workspaceIndexIsReadOnly {}
        XCTAssertEqual(try Data(contentsOf: indexURL), originalBytes)
    }

    func testRemovingSnapshotGroupingPreservesUnknownWorkspaceData() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotID = UUID()
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let indexURL = root.appendingPathComponent("workspace-index.json")
        try writeObject(
            [
                "formatVersion": 1,
                "collectionOrder": [String](),
                "snapshotGroupingOverrides": [
                    snapshotID.uuidString.lowercased(): [
                        "identity": [
                            "collectionID": identity.collectionID.uuidString.lowercased(),
                            "requestID": identity.requestID.uuidString.lowercased(),
                        ],
                        "collectionName": "Collection",
                        "requestName": "Request",
                        "futureGroupingData": ["retained": true],
                    ]
                ],
                "futureWorkspaceData": ["retained": true],
            ], to: indexURL)

        let store = try CollectionStore(rootURL: root)
        let updated = try await store.removeSnapshotGrouping(id: snapshotID)
        XCTAssertNil(updated.snapshotGroupingOverrides[snapshotID])
        let persisted = try readObject(at: indexURL)
        XCTAssertTrue((persisted["snapshotGroupingOverrides"] as? [String: Any])?.isEmpty ?? false)
        XCTAssertEqual((persisted["futureWorkspaceData"] as? [String: Bool])?["retained"], true)
    }

    func testStartupReplaysMoveThatStoppedAfterDestinationIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID: UUID
        let destinationID: UUID
        let request: HTTPRequestConfiguration
        let sourceBefore: Data
        let destinationBefore: Data
        let requestBytes: Data

        do {
            let store = try CollectionStore(rootURL: root)
            let source = try await store.createCollection(name: "Source")
            let destination = try await store.createCollection(name: "Destination")
            sourceID = source.id
            destinationID = destination.id
            request = HTTPRequestConfiguration(name: "Recover me", url: "https://recovery.invalid")
            try await store.createRequest(request, in: source.id)
            sourceBefore = try Data(
                contentsOf: collectionURL(root, source.id).appendingPathComponent("collection.json"))
            destinationBefore = try Data(
                contentsOf: collectionURL(root, destination.id).appendingPathComponent("collection.json"))
            requestBytes = try Data(contentsOf: requestURL(root, source.id, request.id))
        }

        var sourceAfterObject = try readObject(
            at: collectionURL(root, sourceID).appendingPathComponent("collection.json"))
        sourceAfterObject["requests"] = [String]()
        let sourceAfter = try jsonData(sourceAfterObject)
        var destinationAfterObject = try readObject(
            at: collectionURL(root, destinationID).appendingPathComponent("collection.json"))
        destinationAfterObject["requests"] = [request.id.uuidString.lowercased()]
        let destinationAfter = try jsonData(destinationAfterObject)
        let workspaceAfter = try jsonData([
            "formatVersion": 1,
            "collectionOrder": [sourceID.uuidString.lowercased(), destinationID.uuidString.lowercased()],
            "snapshotGroupingOverrides": [String: Any](),
        ])

        let transactionID = UUID()
        let transactionDirectory = root.appendingPathComponent(".moves", isDirectory: true)
            .appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: true)
        try requestBytes.write(to: transactionDirectory.appendingPathComponent("request.json"))
        try sourceBefore.write(to: transactionDirectory.appendingPathComponent("source-index-before.json"))
        try sourceAfter.write(to: transactionDirectory.appendingPathComponent("source-index-after.json"))
        try destinationBefore.write(to: transactionDirectory.appendingPathComponent("destination-index-before.json"))
        try destinationAfter.write(to: transactionDirectory.appendingPathComponent("destination-index-after.json"))
        try workspaceAfter.write(to: transactionDirectory.appendingPathComponent("workspace-index-after.json"))

        let destinationRequestURL = requestURL(root, destinationID, request.id)
        try requestBytes.write(to: destinationRequestURL)
        try destinationAfter.write(to: collectionURL(root, destinationID).appendingPathComponent("collection.json"))
        try writeObject(
            [
                "formatVersion": 1,
                "transactionID": transactionID.uuidString,
                "sourceCollectionID": sourceID.uuidString,
                "destinationCollectionID": destinationID.uuidString,
                "requestID": request.id.uuidString,
                "sourceFilename": "\(request.id.uuidString.lowercased()).json",
                "workspaceIndexExistedBefore": false,
            ], to: transactionDirectory.appendingPathComponent("intent.json"))

        let recoveredStore = try CollectionStore(rootURL: root)
        let recovered = try await recoveredStore.load()
        XCTAssertFalse(recovered.issues.contains { $0.id.hasPrefix("store:request-move-recovery:") })
        XCTAssertEqual(recovered.collections.map(\.id), [sourceID, destinationID])
        XCTAssertTrue(try XCTUnwrap(recovered.collections.first { $0.id == sourceID }).requests.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(recovered.collections.first { $0.id == destinationID }).requests.map(\.id), [request.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(root, sourceID, request.id).path))
        XCTAssertEqual(try Data(contentsOf: destinationRequestURL), requestBytes)
    }

    func testUncommittedUnknownMoveStagingIsPreservedWithoutFreezingCollectionWrites() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = try await CollectionStore(rootURL: root).createCollection(name: "Before")
        let staging = root.appendingPathComponent(".moves", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let unknownURL = staging.appendingPathComponent("future-stage.bin")
        let unknownBytes = Data("preserve unknown staging".utf8)
        try unknownBytes.write(to: unknownURL)

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:request-move-staging:") })
        try await store.renameCollection(id: collection.id, name: "After")
        XCTAssertEqual(try Data(contentsOf: unknownURL), unknownBytes)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PostieOrderingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func collectionURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func requestURL(_ root: URL, _ collectionID: UUID, _ requestID: UUID) -> URL {
        collectionURL(root, collectionID).appendingPathComponent("\(requestID.uuidString.lowercased()).json")
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeObject(_ object: Any, to url: URL) throws {
        try jsonData(object).write(to: url, options: [.atomic])
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func requestObject(_ request: HTTPRequestConfiguration) throws -> Any {
        let data = try JSONEncoder().encode(request)
        return try JSONSerialization.jsonObject(with: data)
    }
}
