import Foundation
import XCTest
@testable import PostieCore

#if os(macOS)
import Darwin
#endif

final class StoreTests: XCTestCase {
    func testRoundTripKeepsIdentityOrderAndDuplicateNamesAcrossRestart() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let collectionID = try await createWorkspace(at: root, requestCount: 3)
        let store = try CollectionStore(rootURL: root)
        let duplicateName = try await store.createCollection(name: "Shared name")
        let loaded = try await store.load()

        XCTAssertEqual(loaded.collections.count, 2)
        XCTAssertEqual(loaded.collections.filter { $0.name == "Shared name" }.map(\.id).count, 2)
        let collection = try XCTUnwrap(loaded.collections.first { $0.id == collectionID })
        XCTAssertNotEqual(collection.id, duplicateName.id)
        XCTAssertEqual(collection.id, collectionID)
        XCTAssertEqual(collection.requests.map(\.name), ["Request 1", "Request 2", "Request 3"])

        try await store.reorderRequests(ids: collection.requests.map(\.id).reversed().map { $0 }, in: collectionID)
        try await store.renameCollection(id: collectionID, name: "Renamed")

        let reloaded = try await store.load()
        let renamed = try XCTUnwrap(reloaded.collections.first)
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(renamed.requests.map(\.name), ["Request 3", "Request 2", "Request 1"])

        let metadata = try readObject(at: collectionURL(root, collectionID).appendingPathComponent("collection.json"))
        XCTAssertNil(metadata["id"])
        let request = try readObject(at: requestURL(root, collectionID, renamed.requests[0].id))
        XCTAssertNil(request["id"])

        let globals = try readObject(at: root.appendingPathComponent("globals.json"))
        XCTAssertEqual(globals["formatVersion"] as? Int, 1)
        XCTAssertEqual((globals["variables"] as? [String: Any])?.count, 0)
    }

    func testSaveRequestClearsOptionalLimitsAndReloadsAsNil() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let initialLoad = try await store.load()
        var request = try XCTUnwrap(initialLoad.collections.first?.requests.first)

        XCTAssertEqual(request.options.overallTimeout, 1_800)
        XCTAssertEqual(request.options.maximumResponseBytes, 1_073_741_824)

        request.options.overallTimeout = nil
        request.options.maximumResponseBytes = nil
        try await store.saveRequest(request, in: collectionID)

        let reloadedWorkspace = try await store.load()
        let reloaded = try XCTUnwrap(reloadedWorkspace.collections.first?.requests.first)
        XCTAssertNil(reloaded.options.overallTimeout)
        XCTAssertNil(reloaded.options.maximumResponseBytes)

        let storedOptions = try readObject(at: requestURL(root, collectionID, request.id))["options"] as? [String: Any]
        XCTAssertTrue(storedOptions?["overallTimeout"] is NSNull)
        XCTAssertTrue(storedOptions?["maximumResponseBytes"] is NSNull)
    }

    func testOlderRequestWithoutPathParametersLoadsAsEmptyAndKeepsUnknownData() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        var metadata = try readObject(at: metadataURL)
        metadata.removeValue(forKey: "variables")
        metadata.removeValue(forKey: "headers")
        metadata.removeValue(forKey: "authentication")
        try writeObject(metadata, to: metadataURL)
        let index = metadata["requests"] as! [String]
        let requestID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(index.first)))
        let storedURL = requestURL(root, collectionID, requestID)
        var stored = try readObject(at: storedURL)
        stored.removeValue(forKey: "pathParameters")
        stored.removeValue(forKey: "variables")
        stored.removeValue(forKey: "authentication")
        stored.removeValue(forKey: "inheritsCollectionAuthentication")
        stored["futureRequestData"] = ["retained": ["value": 42]]
        try writeObject(stored, to: storedURL)

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        let collection = try XCTUnwrap(loaded.collections.first)
        var request = try XCTUnwrap(loaded.collections.first?.requests.first)
        XCTAssertTrue(request.pathParameters.isEmpty)
        XCTAssertTrue(request.variables.isEmpty)
        XCTAssertEqual(request.authentication, RequestAuthentication())
        XCTAssertFalse(request.inheritsCollectionAuthentication)
        XCTAssertTrue(collection.variables.isEmpty)
        XCTAssertTrue(collection.headers.isEmpty)
        XCTAssertEqual(collection.authentication, RequestAuthentication())

        request.name = "Saved after loading old data"
        request.inheritsCollectionAuthentication = true
        try await store.saveRequest(request, in: collectionID)

        let updated = try readObject(at: storedURL)
        XCTAssertEqual((updated["pathParameters"] as? [Any])?.count, 0)
        XCTAssertEqual(updated["inheritsCollectionAuthentication"] as? Bool, true)
        let futureData = try XCTUnwrap(updated["futureRequestData"] as? [String: Any])
        let nestedFutureData = try XCTUnwrap(futureData["retained"] as? [String: Any])
        XCTAssertEqual(nestedFutureData["value"] as? Int, 42)
        let reloaded = try await store.load()
        XCTAssertTrue(reloaded.collections.first?.requests.first?.inheritsCollectionAuthentication ?? false)
    }

    func testVariableScopesAndEncryptedAuthenticationRoundTripWithoutPlaintextAfterConversion() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)

        try await store.saveGlobalVariables(["globalName": .plain("global value")])
        try await store.saveCollectionVariables(["collectionName": .plain("collection value")], in: collectionID)

        let initialLoad = try await store.load()
        var request = try XCTUnwrap(initialLoad.collections.first?.requests.first)
        request.variables = [
            "requestSecret": .plain("synthetic plaintext before conversion"),
            "requestName": .plain("request value")
        ]
        request.authentication = RequestAuthentication(
            kind: .bearer,
            token: SecretEnvelope(combined: "synthetic bearer ciphertext")
        )
        try await store.saveRequest(request, in: collectionID)

        request.variables["requestSecret"] = .encrypted(SecretEnvelope(combined: "synthetic encrypted request value"))
        try await store.saveRequest(request, in: collectionID)

        let loaded = try await store.load()
        let collection = try XCTUnwrap(loaded.collections.first { $0.id == collectionID })
        let reloadedRequest = try XCTUnwrap(collection.requests.first)
        XCTAssertEqual(loaded.globalVariables["globalName"], .plain("global value"))
        XCTAssertFalse(loaded.globalVariablesAreReadOnly)
        XCTAssertEqual(collection.variables["collectionName"], .plain("collection value"))
        XCTAssertEqual(reloadedRequest.variables["requestSecret"], .encrypted(SecretEnvelope(combined: "synthetic encrypted request value")))
        XCTAssertEqual(reloadedRequest.variables["requestName"], .plain("request value"))
        XCTAssertEqual(reloadedRequest.authentication.token, SecretEnvelope(combined: "synthetic bearer ciphertext"))

        let globals = try readObject(at: root.appendingPathComponent("globals.json"))
        let globalValues = try XCTUnwrap(globals["variables"] as? [String: Any])
        XCTAssertEqual(globalValues["globalName"] as? String, "global value")
        let storedRequest = try readObject(at: requestURL(root, collectionID, reloadedRequest.id))
        let requestValues = try XCTUnwrap(storedRequest["variables"] as? [String: Any])
        XCTAssertNil(requestValues["requestSecret"] as? String)
        XCTAssertEqual((requestValues["requestSecret"] as? [String: Any])?["combined"] as? String, "synthetic encrypted request value")
        let storedAuthentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        XCTAssertEqual((storedAuthentication["token"] as? [String: Any])?["combined"] as? String, "synthetic bearer ciphertext")
        let serializedRequest = try String(contentsOf: requestURL(root, collectionID, reloadedRequest.id), encoding: .utf8)
        XCTAssertFalse(serializedRequest.contains("synthetic plaintext before conversion"))
    }

    func testLegacyAuthenticationWithoutAPIKeyFieldsStillDecodes() throws {
        let data = Data(#"{"kind":"bearer","username":"","token":{"version":1,"combined":"synthetic legacy token ciphertext"}}"#.utf8)

        let authentication = try JSONDecoder().decode(RequestAuthentication.self, from: data)

        XCTAssertEqual(authentication.kind, .bearer)
        XCTAssertEqual(authentication.token?.combined, "synthetic legacy token ciphertext")
        XCTAssertNil(authentication.apiKeyHeaderName)
        XCTAssertNil(authentication.apiKey)
    }

    func testAPIKeyAuthenticationPersistsOnlyItsEnvelopeAndClearsFieldsExplicitly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let initialLoad = try await store.load()
        var request = try XCTUnwrap(initialLoad.collections.first?.requests.first)
        request.authentication = RequestAuthentication(
            kind: .apiKey,
            apiKeyHeaderName: "X-Service-Key",
            apiKey: SecretEnvelope(combined: "synthetic API key ciphertext")
        )
        try await store.saveRequest(request, in: collectionID)

        let storedURL = requestURL(root, collectionID, request.id)
        var storedRequest = try readObject(at: storedURL)
        var authentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        XCTAssertEqual(authentication["kind"] as? String, "apiKey")
        XCTAssertEqual(authentication["apiKeyHeaderName"] as? String, "X-Service-Key")
        XCTAssertEqual((authentication["apiKey"] as? [String: Any])?["combined"] as? String, "synthetic API key ciphertext")
        XCTAssertFalse(try String(contentsOf: storedURL, encoding: .utf8).contains("synthetic API key plaintext"))

        var apiKeyEnvelope = try XCTUnwrap(authentication["apiKey"] as? [String: Any])
        apiKeyEnvelope["futureEnvelopeData"] = ["retained": true]
        authentication["apiKey"] = apiKeyEnvelope
        authentication["futureAuthData"] = ["retained": true]
        storedRequest["authentication"] = authentication
        try writeObject(storedRequest, to: storedURL)

        let beforeCredentialUpdate = try await store.load()
        request = try XCTUnwrap(beforeCredentialUpdate.collections.first?.requests.first)
        request.authentication.apiKey = SecretEnvelope(combined: "synthetic updated API key ciphertext")
        try await store.saveRequest(request, in: collectionID)

        storedRequest = try readObject(at: storedURL)
        authentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        XCTAssertEqual((authentication["apiKey"] as? [String: Any])?["combined"] as? String, "synthetic updated API key ciphertext")
        XCTAssertEqual((authentication["apiKey"] as? [String: Any])?["futureEnvelopeData"] as? [String: Bool], ["retained": true])
        XCTAssertEqual((authentication["futureAuthData"] as? [String: Bool])?["retained"], true)

        request.authentication.apiKey = nil
        request.authentication.apiKeyHeaderName = nil
        try await store.saveRequest(request, in: collectionID)

        storedRequest = try readObject(at: storedURL)
        authentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        XCTAssertNil(authentication["apiKey"])
        XCTAssertNil(authentication["apiKeyHeaderName"])
        XCTAssertEqual((authentication["futureAuthData"] as? [String: Bool])?["retained"], true)
    }

    func testAPIKeyCollectionDefaultsRoundTripAsAnEnvelope() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let defaults = CollectionRequestDefaults(
            headers: [HTTPField(name: "X-Collection", value: "default")],
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "X-Collection-Key",
                apiKey: SecretEnvelope(combined: "synthetic collection API key ciphertext")
            )
        )

        try await store.saveCollectionConfiguration(defaults, variables: [:], in: collectionID)

        let loaded = try await store.load()
        let collection = try XCTUnwrap(loaded.collections.first { $0.id == collectionID })
        XCTAssertEqual(collection.authentication, defaults.authentication)
        let metadata = try readObject(at: collectionURL(root, collectionID).appendingPathComponent("collection.json"))
        let authentication = try XCTUnwrap(metadata["authentication"] as? [String: Any])
        XCTAssertEqual(authentication["apiKeyHeaderName"] as? String, "X-Collection-Key")
        XCTAssertEqual((authentication["apiKey"] as? [String: Any])?["combined"] as? String, "synthetic collection API key ciphertext")
    }

    func testOwnedVariableMapsRemoveRenamedKeysAndPreserveUnknownMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let oldEnvelope = SecretEnvelope(combined: "synthetic retained ciphertext")

        try await store.saveGlobalVariables(["oldGlobal": .plain("old"), "keptGlobal": .encrypted(oldEnvelope)])
        try await store.saveCollectionVariables(["oldCollection": .plain("old"), "keptCollection": .encrypted(oldEnvelope)], in: collectionID)
        let initialLoad = try await store.load()
        var request = try XCTUnwrap(initialLoad.collections.first?.requests.first)
        request.variables = ["oldRequest": .plain("old"), "keptRequest": .encrypted(oldEnvelope)]
        request.authentication = RequestAuthentication(
            kind: .basic,
            username: "old user",
            password: oldEnvelope,
            token: SecretEnvelope(combined: "synthetic obsolete token")
        )
        try await store.saveRequest(request, in: collectionID)

        let globalsURL = root.appendingPathComponent("globals.json")
        var globals = try readObject(at: globalsURL)
        var globalValues = try XCTUnwrap(globals["variables"] as? [String: Any])
        var keptGlobal = try XCTUnwrap(globalValues["keptGlobal"] as? [String: Any])
        keptGlobal["futureEnvelopeData"] = ["retained": true]
        globalValues["keptGlobal"] = keptGlobal
        globals["variables"] = globalValues
        globals["futureGlobalsData"] = ["retained": true]
        try writeObject(globals, to: globalsURL)

        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        var metadata = try readObject(at: metadataURL)
        var collectionValues = try XCTUnwrap(metadata["variables"] as? [String: Any])
        var keptCollection = try XCTUnwrap(collectionValues["keptCollection"] as? [String: Any])
        keptCollection["futureEnvelopeData"] = ["retained": true]
        collectionValues["keptCollection"] = keptCollection
        metadata["variables"] = collectionValues
        metadata["futureCollectionData"] = ["retained": true]
        try writeObject(metadata, to: metadataURL)

        let storedRequestURL = requestURL(root, collectionID, request.id)
        var storedRequest = try readObject(at: storedRequestURL)
        var requestValues = try XCTUnwrap(storedRequest["variables"] as? [String: Any])
        var keptRequest = try XCTUnwrap(requestValues["keptRequest"] as? [String: Any])
        keptRequest["futureEnvelopeData"] = ["retained": true]
        requestValues["keptRequest"] = keptRequest
        storedRequest["variables"] = requestValues
        storedRequest["futureRequestData"] = ["retained": true]
        var authentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        var password = try XCTUnwrap(authentication["password"] as? [String: Any])
        password["futureEnvelopeData"] = ["retained": true]
        authentication["password"] = password
        authentication["futureAuthData"] = ["retained": true]
        storedRequest["authentication"] = authentication
        try writeObject(storedRequest, to: storedRequestURL)

        try await store.saveGlobalVariables([
            "newGlobal": .plain("new"),
            "keptGlobal": .encrypted(SecretEnvelope(combined: "synthetic updated global ciphertext"))
        ])
        try await store.saveCollectionVariables([
            "newCollection": .plain("new"),
            "keptCollection": .encrypted(SecretEnvelope(combined: "synthetic updated collection ciphertext"))
        ], in: collectionID)

        let beforeSave = try await store.load()
        var loadedRequest = try XCTUnwrap(beforeSave.collections.first?.requests.first)
        loadedRequest.variables = [
            "newRequest": .plain("new"),
            "keptRequest": .encrypted(SecretEnvelope(combined: "synthetic updated request ciphertext"))
        ]
        loadedRequest.authentication = RequestAuthentication(
            kind: .basic,
            username: "updated user",
            password: SecretEnvelope(combined: "synthetic updated password ciphertext")
        )
        try await store.saveRequest(loadedRequest, in: collectionID)

        globals = try readObject(at: globalsURL)
        globalValues = try XCTUnwrap(globals["variables"] as? [String: Any])
        XCTAssertNil(globalValues["oldGlobal"])
        XCTAssertNotNil(globalValues["newGlobal"])
        XCTAssertEqual((globalValues["keptGlobal"] as? [String: Any])?["futureEnvelopeData"] as? [String: Bool], ["retained": true])
        XCTAssertEqual((globals["futureGlobalsData"] as? [String: Bool])?["retained"], true)

        metadata = try readObject(at: metadataURL)
        collectionValues = try XCTUnwrap(metadata["variables"] as? [String: Any])
        XCTAssertNil(collectionValues["oldCollection"])
        XCTAssertNotNil(collectionValues["newCollection"])
        XCTAssertEqual((collectionValues["keptCollection"] as? [String: Any])?["futureEnvelopeData"] as? [String: Bool], ["retained": true])
        XCTAssertEqual((metadata["futureCollectionData"] as? [String: Bool])?["retained"], true)

        storedRequest = try readObject(at: storedRequestURL)
        requestValues = try XCTUnwrap(storedRequest["variables"] as? [String: Any])
        XCTAssertNil(requestValues["oldRequest"])
        XCTAssertNotNil(requestValues["newRequest"])
        XCTAssertEqual((requestValues["keptRequest"] as? [String: Any])?["futureEnvelopeData"] as? [String: Bool], ["retained": true])
        XCTAssertEqual((storedRequest["futureRequestData"] as? [String: Bool])?["retained"], true)
        authentication = try XCTUnwrap(storedRequest["authentication"] as? [String: Any])
        XCTAssertNil(authentication["token"])
        XCTAssertEqual((authentication["password"] as? [String: Any])?["combined"] as? String, "synthetic updated password ciphertext")
        XCTAssertEqual((authentication["password"] as? [String: Any])?["futureEnvelopeData"] as? [String: Bool], ["retained": true])
        XCTAssertEqual((authentication["futureAuthData"] as? [String: Bool])?["retained"], true)
        XCTAssertFalse(try String(contentsOf: storedRequestURL, encoding: .utf8).contains("synthetic obsolete token"))
    }

    func testCollectionConfigurationRoundTripsAndMergesOwnedSettingsAtomically() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let headerID = UUID()
        let originalDefaults = CollectionRequestDefaults(
            headers: [HTTPField(id: headerID, name: "X-Shared", value: "original")],
            authentication: RequestAuthentication(
                kind: .basic,
                username: "collection user",
                password: SecretEnvelope(combined: "synthetic collection auth ciphertext")
            )
        )
        try await store.saveCollectionConfiguration(
            originalDefaults,
            variables: ["oldVariable": .plain("old"), "keptVariable": .encrypted(SecretEnvelope(combined: "synthetic collection variable ciphertext"))],
            in: collectionID
        )

        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        var metadata = try readObject(at: metadataURL)
        metadata["futureCollectionData"] = ["retained": true]
        var headers = try XCTUnwrap(metadata["headers"] as? [[String: Any]])
        headers[0]["futureHeaderData"] = ["retained": true]
        metadata["headers"] = headers
        var authentication = try XCTUnwrap(metadata["authentication"] as? [String: Any])
        authentication["futureAuthData"] = ["retained": true]
        var password = try XCTUnwrap(authentication["password"] as? [String: Any])
        password["futureEnvelopeData"] = ["retained": true]
        authentication["password"] = password
        metadata["authentication"] = authentication
        try writeObject(metadata, to: metadataURL)

        try await store.saveCollectionVariables(["afterVariablesOnlySave": .plain("retained settings")], in: collectionID)
        let afterVariablesOnlySave = try await store.load()
        let unchangedCollection = try XCTUnwrap(afterVariablesOnlySave.collections.first { $0.id == collectionID })
        XCTAssertEqual(unchangedCollection.headers, originalDefaults.headers)
        XCTAssertEqual(unchangedCollection.authentication, originalDefaults.authentication)

        let updatedDefaults = CollectionRequestDefaults(
            headers: [
                HTTPField(id: headerID, name: "X-Shared", value: "updated"),
                HTTPField(name: "X-New", value: "new")
            ],
            authentication: RequestAuthentication(
                kind: .basic,
                username: "updated user",
                password: SecretEnvelope(combined: "synthetic updated collection auth ciphertext")
            )
        )
        try await store.saveCollectionConfiguration(updatedDefaults, variables: ["newVariable": .plain("new")], in: collectionID)

        let reloadedWorkspace = try await store.load()
        let reloaded = try XCTUnwrap(reloadedWorkspace.collections.first { $0.id == collectionID })
        XCTAssertEqual(reloaded.headers, updatedDefaults.headers)
        XCTAssertEqual(reloaded.authentication, updatedDefaults.authentication)
        XCTAssertEqual(reloaded.variables, ["newVariable": .plain("new")])

        metadata = try readObject(at: metadataURL)
        XCTAssertEqual((metadata["futureCollectionData"] as? [String: Bool])?["retained"], true)
        headers = try XCTUnwrap(metadata["headers"] as? [[String: Any]])
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual((headers[0]["futureHeaderData"] as? [String: Bool])?["retained"], true)
        authentication = try XCTUnwrap(metadata["authentication"] as? [String: Any])
        XCTAssertEqual((authentication["futureAuthData"] as? [String: Bool])?["retained"], true)
        password = try XCTUnwrap(authentication["password"] as? [String: Any])
        XCTAssertEqual(password["combined"] as? String, "synthetic updated collection auth ciphertext")
        XCTAssertEqual((password["futureEnvelopeData"] as? [String: Bool])?["retained"], true)
        let variables = try XCTUnwrap(metadata["variables"] as? [String: Any])
        XCTAssertNil(variables["oldVariable"])
        XCTAssertNil(variables["afterVariablesOnlySave"])
        XCTAssertNotNil(variables["newVariable"])
    }

    func testMalformedCollectionSettingsAreReadOnlyAndPreserved() async throws {
        let malformedSettings: [[String: Any]] = [
            ["headers": ["malformed"]],
            ["authentication": ["kind": "invalid", "username": ""]]
        ]

        for malformedSetting in malformedSettings {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let collectionID = try await createWorkspace(at: root, requestCount: 1)
            let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
            var metadata = try readObject(at: metadataURL)
            for (key, value) in malformedSetting {
                metadata[key] = value
            }
            try writeObject(metadata, to: metadataURL)
            let before = try Data(contentsOf: metadataURL)

            let store = try CollectionStore(rootURL: root)
            let loaded = try await store.load()
            XCTAssertEqual(loaded.collections.first?.isReadOnly, true)
            XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:collection-settings-malformed:") })
            do {
                try await store.saveCollectionConfiguration(.init(), variables: [:], in: collectionID)
                XCTFail("Malformed collection settings must not be overwritten.")
            } catch CollectionStoreError.collectionIsReadOnly {
            }
            XCTAssertEqual(try Data(contentsOf: metadataURL), before)
        }
    }

    func testUnreadableGlobalsAreReadOnlyWithoutBlockingCollections() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let store = try CollectionStore(rootURL: root)
        let globalsURL = root.appendingPathComponent("globals.json")

        var globals = try readObject(at: globalsURL)
        globals["formatVersion"] = 99
        try writeObject(globals, to: globalsURL)
        let unsupportedData = try Data(contentsOf: globalsURL)
        let unsupportedLoad = try await store.load()
        XCTAssertTrue(unsupportedLoad.globalVariablesAreReadOnly)
        XCTAssertTrue(unsupportedLoad.issues.contains { $0.id.hasPrefix("store:globals-version-unsupported") })
        XCTAssertFalse(try XCTUnwrap(unsupportedLoad.collections.first { $0.id == collectionID }).isReadOnly)
        XCTAssertEqual(try XCTUnwrap(unsupportedLoad.collections.first { $0.id == collectionID }).requests.count, 1)
        do {
            try await store.saveGlobalVariables(["new": .plain("value")])
            XCTFail("Unsupported globals must not be overwritten")
        } catch CollectionStoreError.ioFailure {
        }
        XCTAssertEqual(try Data(contentsOf: globalsURL), unsupportedData)

        globals["formatVersion"] = 1
        globals["variables"] = ["unsupportedValue": 42]
        try writeObject(globals, to: globalsURL)
        let malformedData = try Data(contentsOf: globalsURL)
        let malformedLoad = try await store.load()
        XCTAssertTrue(malformedLoad.globalVariablesAreReadOnly)
        XCTAssertTrue(malformedLoad.issues.contains { $0.id.hasPrefix("store:globals-malformed") })
        XCTAssertEqual(try XCTUnwrap(malformedLoad.collections.first { $0.id == collectionID }).requests.count, 1)
        do {
            try await store.saveGlobalVariables(["new": .plain("value")])
            XCTFail("Malformed globals must not be overwritten")
        } catch CollectionStoreError.ioFailure {
        }
        XCTAssertEqual(try Data(contentsOf: globalsURL), malformedData)
    }

    func testLifetimeLockRejectsASecondWriter() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CollectionStore(rootURL: root)

        XCTAssertThrowsError(try CollectionStore(rootURL: root)) { error in
            guard let storeError = error as? CollectionStoreError, case .alreadyOpen = storeError else {
                return XCTFail("Expected alreadyOpen, got \(error)")
            }
        }
        _ = try await store.load()
    }

    func testMalformedMissingAndFutureRequestsDoNotHideUnaffectedRequests() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 4)
        let requests = try readObject(at: collectionURL(root, collectionID).appendingPathComponent("collection.json"))["requests"] as! [String]
        let ids = try requests.map { raw -> UUID in
            try XCTUnwrap(UUID(uuidString: raw))
        }

        try FileManager.default.removeItem(at: requestURL(root, collectionID, ids[1]))
        try Data("not json".utf8).write(to: requestURL(root, collectionID, ids[2]))
        var futureRequest = try readObject(at: requestURL(root, collectionID, ids[3]))
        futureRequest["formatVersion"] = 99
        try writeObject(futureRequest, to: requestURL(root, collectionID, ids[3]))

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        let collection = try XCTUnwrap(loaded.collections.first)

        XCTAssertEqual(collection.requests.map(\.id), [ids[0]])
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:indexed-request-missing:") && $0.requestID == ids[1] })
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:request-malformed:") && $0.requestID == ids[2] })
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:request-version-unsupported:") && $0.requestID == ids[3] })

        var changed = collection.requests[0]
        changed.name = "Updated"
        try await store.saveRequest(changed, in: collectionID)

        let unchangedIndex = try readObject(at: collectionURL(root, collectionID).appendingPathComponent("collection.json"))["requests"] as! [String]
        XCTAssertEqual(unchangedIndex, requests)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL(root, collectionID, ids[1]).path))
        XCTAssertEqual(try Data(contentsOf: requestURL(root, collectionID, ids[2])), Data("not json".utf8))
        XCTAssertEqual(try readObject(at: requestURL(root, collectionID, ids[3]))["formatVersion"] as? Int, 99)
    }

    func testRecoveryAndEditsPreserveUnknownDataAndBrokenIndexEntries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 2)
        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        var metadata = try readObject(at: metadataURL)
        let ids = try (metadata["requests"] as! [String]).map { try XCTUnwrap(UUID(uuidString: $0)) }
        metadata["futureCollectionData"] = ["nested": ["retained": true]]
        metadata["requests"] = [ids[0].uuidString.lowercased(), ids[0].uuidString.lowercased(), 17]
        try writeObject(metadata, to: metadataURL)

        let firstURL = requestURL(root, collectionID, ids[0])
        var first = try readObject(at: firstURL)
        first["futureRequestData"] = ["retained": ["value": 42]]
        try writeObject(first, to: firstURL)
        let secondURL = requestURL(root, collectionID, ids[1])
        var second = try readObject(at: secondURL)
        second["futureRequestData"] = ["retained": true]
        try writeObject(second, to: secondURL)

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        let collection = try XCTUnwrap(loaded.collections.first)
        XCTAssertEqual(collection.requests.map(\.id), [ids[0]])
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:index-identity-duplicate:") && $0.requestID == ids[0] })
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:request-orphan:") && $0.requestID == ids[1] && $0.canRecover })

        try await store.renameCollection(id: collectionID, name: "Edited around broken entries")
        try await store.reorderRequests(ids: [], in: collectionID)
        do {
            try await store.saveRequest(collection.requests[0], in: collectionID)
            XCTFail("Duplicate index membership must not be rewritten as a valid request")
        } catch CollectionStoreError.requestIsAmbiguous {
        }

        try await store.recoverRequest(id: ids[1], in: collectionID)
        let afterRecovery = try await store.load()
        var recovered = try XCTUnwrap(afterRecovery.collections.first?.requests.first { $0.id == ids[1] })
        recovered.url = "https://example.invalid/updated"
        try await store.saveRequest(recovered, in: collectionID)

        let updatedMetadata = try readObject(at: metadataURL)
        let updatedIndex = updatedMetadata["requests"] as! [Any]
        XCTAssertEqual(updatedIndex.count, 4)
        XCTAssertEqual(updatedIndex[0] as? String, ids[0].uuidString.lowercased())
        XCTAssertEqual(updatedIndex[1] as? String, ids[0].uuidString.lowercased())
        XCTAssertEqual(updatedIndex[2] as? Int, 17)
        let futureCollectionData = try XCTUnwrap(updatedMetadata["futureCollectionData"] as? [String: Any])
        let nestedFutureData = try XCTUnwrap(futureCollectionData["nested"] as? [String: Any])
        XCTAssertEqual(nestedFutureData["retained"] as? Bool, true)
        XCTAssertEqual((try readObject(at: secondURL)["futureRequestData"] as? [String: Any])?["retained"] as? Bool, true)
        XCTAssertNil(try readObject(at: secondURL)["id"])
    }

    func testUnsupportedCollectionIsReadOnlyAndPreserved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        var metadata = try readObject(at: metadataURL)
        metadata["formatVersion"] = 99
        try writeObject(metadata, to: metadataURL)
        let before = try Data(contentsOf: metadataURL)

        let store = try CollectionStore(rootURL: root)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.collections.first?.isReadOnly, true)
        XCTAssertTrue(loaded.issues.contains { $0.id.hasPrefix("store:collection-version-unsupported:") })
        do {
            try await store.renameCollection(id: collectionID, name: "Must not write")
            XCTFail("Future collection metadata must block writes")
        } catch CollectionStoreError.collectionIsReadOnly {
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), before)
    }

#if os(macOS)
    func testFailedCreateLeavesAnExplicitlyRecoverableOrphan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 0)
        let metadataURL = collectionURL(root, collectionID).appendingPathComponent("collection.json")
        let store = try CollectionStore(rootURL: root)
        let request = makeRequest(name: "Interrupted create")

        try setImmutable(metadataURL, enabled: true)
        defer { try? setImmutable(metadataURL, enabled: false) }
        do {
            try await store.createRequest(request, in: collectionID)
            XCTFail("The immutable index should prevent the second create step")
        } catch CollectionStoreError.partialFailure {
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL(root, collectionID, request.id).path))
        try setImmutable(metadataURL, enabled: false)
        let interrupted = try await store.load()
        XCTAssertTrue(interrupted.issues.contains { $0.id.hasPrefix("store:request-orphan:") && $0.requestID == request.id && $0.canRecover })
        XCTAssertTrue(interrupted.collections.first?.requests.isEmpty ?? false)

        try await store.recoverRequest(id: request.id, in: collectionID)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.collections.first?.requests.map(\.id), [request.id])
    }

    func testFailedCollectionCleanupLeavesStagedDataVisible() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collectionID = try await createWorkspace(at: root, requestCount: 1)
        let loaded = try await CollectionStore(rootURL: root).load()
        let requestID = try XCTUnwrap(loaded.collections.first?.requests.first?.id)
        let store = try CollectionStore(rootURL: root)
        let requestURL = requestURL(root, collectionID, requestID)

        try setImmutable(requestURL, enabled: true)
        do {
            try await store.deleteCollection(id: collectionID)
            XCTFail("The immutable request should prevent staged cleanup")
        } catch CollectionStoreError.partialFailure {
        }

        let stagingURL = root.appendingPathComponent(".deletion-staging", isDirectory: true)
        let staged = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil).first)
        let stagedRequestURL = staged.appendingPathComponent(requestURL.lastPathComponent)
        defer { try? setImmutable(stagedRequestURL, enabled: false) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedRequestURL.path))
        let afterFailure = try await store.load()
        XCTAssertTrue(afterFailure.issues.contains { $0.id.hasPrefix("store:collection-deletion-staged:") && $0.collectionID == collectionID })

        try setImmutable(stagedRequestURL, enabled: false)
        try FileManager.default.removeItem(at: staged)
        let afterCleanup = try await store.load()
        XCTAssertFalse(afterCleanup.issues.contains { $0.id.hasPrefix("store:collection-deletion-staged:") })
    }

    private func setImmutable(_ url: URL, enabled: Bool) throws {
        let flags = enabled ? UInt32(UF_IMMUTABLE) : 0
        let result = url.path.withCString { Darwin.chflags($0, flags) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
#endif

    private func createWorkspace(at root: URL, requestCount: Int) async throws -> UUID {
        let store = try CollectionStore(rootURL: root)
        let collection = try await store.createCollection(name: "Shared name")
        for index in 0..<requestCount {
            try await store.createRequest(makeRequest(name: "Request \(index + 1)"), in: collection.id)
        }
        return collection.id
    }

    private func makeRequest(name: String) -> HTTPRequestConfiguration {
        HTTPRequestConfiguration(
            name: name,
            method: "GET",
            url: "https://example.invalid/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
            query: [HTTPField(name: "first", value: "1"), HTTPField(name: "second", value: "2")]
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PostieStoreTests-\(UUID().uuidString)", isDirectory: true)
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
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
    }
}
