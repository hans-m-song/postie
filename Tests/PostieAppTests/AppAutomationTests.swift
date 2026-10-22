import Foundation
import Darwin
import XCTest
@testable import PostieApp
import PostieCore
import PostieAutomation

@MainActor
final class AppAutomationTests: XCTestCase {
    func testRequestAutomationPreservesPolicyAndSecretsWithoutChangingSelection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AutomationTestKeyStore()
        let vault = SecretVault(keyStore: keyStore, allowsKeyCreation: true)
        let model = makeModel(root: root, vault: vault)
        try await waitUntil { model.canEditVariables(.global) }

        await model.createCollection(name: "Automation")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Selected")
        let selectedIdentity = try XCTUnwrap(model.selectedIdentity)
        let selectedCollectionID = model.selectedCollectionID
        let selectedSnapshotID = model.selectedSnapshotID

        let created = await model.automationReply(
            AutomationCommand(
                operation: .requestsCreate,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "request": .object([
                        "name": .string("Managed request"),
                        "url": .string("https://example.invalid/{{token}}"),
                    ]),
                ]
            ),
            channel: .cli
        )
        let createdObject = try XCTUnwrap(created.result?.objectValue)
        let requestID = try XCTUnwrap(createdObject["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let identity = RequestIdentity(collectionID: collection.id, requestID: requestID)
        XCTAssertEqual(model.selectedIdentity, selectedIdentity)
        XCTAssertEqual(model.selectedCollectionID, selectedCollectionID)
        XCTAssertEqual(model.selectedSnapshotID, selectedSnapshotID)

        let policy = MCPResourcePolicy(excluded: true, responseViewing: .allow)
        model.updateRequestMCPPolicy(policy, for: identity)
        try await model.setAuthenticationSecret("synthetic auth secret", field: .token, for: identity)
        try await model.flushPendingSaves()
        let originalAuthentication = try XCTUnwrap(model.request(for: identity)?.authentication)

        let updated = await model.automationReply(
            AutomationCommand(
                operation: .requestsUpdate,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                    "request": .object(["name": .string("Managed request renamed")]),
                ]
            ),
            channel: .cli
        )
        XCTAssertNil(updated.error)
        XCTAssertEqual(model.request(for: identity)?.name, "Managed request renamed")
        XCTAssertEqual(model.request(for: identity)?.mcpPolicy, policy)
        XCTAssertEqual(model.request(for: identity)?.authentication, originalAuthentication)
        XCTAssertEqual(model.selectedIdentity, selectedIdentity)
        XCTAssertEqual(model.selectedCollectionID, selectedCollectionID)
        XCTAssertEqual(model.selectedSnapshotID, selectedSnapshotID)

        let read = await model.automationReply(
            AutomationCommand(
                operation: .requestsGet,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                ]
            ),
            channel: .cli
        )
        let encodedRead = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        XCTAssertFalse(encodedRead.contains("synthetic auth secret"))
        XCTAssertFalse(encodedRead.contains(originalAuthentication.token?.combined ?? ""))
        XCTAssertEqual(read.result?.objectValue?["authentication"]?.objectValue?["hasToken"]?.boolValue, true)

        let denied = await model.automationReply(
            AutomationCommand(
                operation: .requestsGet,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                ]
            ),
            channel: .mcp
        )
        XCTAssertEqual(denied.error?.code, .forbidden)

        let invalidPatch = await model.automationReply(
            AutomationCommand(
                operation: .requestsUpdate,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                    "request": .object(["mcpPolicy": .object(["excluded": .bool(false)])]),
                ]
            ),
            channel: .cli
        )
        XCTAssertEqual(invalidPatch.error?.code, .invalidArguments)
        XCTAssertEqual(model.request(for: identity)?.mcpPolicy, policy)

        await model.updateCollectionMCPPolicy(MCPResourcePolicy(excluded: true), for: collection.id)
        let collections = await model.automationReply(AutomationCommand(operation: .collectionsList), channel: .mcp)
        XCTAssertEqual(collections.result?.arrayValue?.count, 0)
        let cliRead = await model.automationReply(
            AutomationCommand(
                operation: .requestsGet,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                ]
            ),
            channel: .cli
        )
        XCTAssertNil(cliRead.error)
        XCTAssertEqual(model.selectedIdentity, selectedIdentity)

        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testVariablesListMarksSecretsAndSecretReadsAreDeniedForBothChannels() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root, vault: SecretVault(keyStore: AutomationTestKeyStore(), allowsKeyCreation: true))
        try await waitUntil { model.canEditVariables(.global) }
        try model.setPlainVariable(name: "visible", value: "safe value", owner: .global)
        try await model.setVariable(
            name: "credential", value: "synthetic variable secret", isSecret: true, owner: .global)
        try await model.flushPendingSaves()

        let listed = await model.automationReply(
            AutomationCommand(operation: .variablesList),
            channel: .mcp
        )
        let entries: [AutomationJSON]
        if case .array(let values)? = listed.result {
            entries = values
        } else {
            XCTFail("Expected a variable array.")
            return
        }
        let byName = Dictionary(
            uniqueKeysWithValues: try entries.map { value -> (String, [String: AutomationJSON]) in
                let object = try XCTUnwrap(value.objectValue)
                return (try XCTUnwrap(object["name"]?.stringValue), object)
            })
        XCTAssertEqual(byName["visible"]?["value"]?.stringValue, "safe value")
        XCTAssertEqual(byName["credential"]?["secret"]?.boolValue, true)
        XCTAssertEqual(byName["credential"]?["value"], .null)

        for channel in [AutomationChannel.mcp, .cli] {
            let denied = await model.automationReply(
                AutomationCommand(
                    operation: .variablesGet,
                    arguments: ["name": .string("credential")]
                ),
                channel: channel
            )
            XCTAssertEqual(denied.error?.code, .forbidden)
        }

        let invalidScope = await model.automationReply(
            AutomationCommand(
                operation: .variablesList,
                arguments: ["requestID": .string(UUID().uuidString)]
            ),
            channel: .cli
        )
        XCTAssertEqual(invalidScope.error?.code, .invalidArguments)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(listed), as: UTF8.self).contains("synthetic variable secret"))
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testGlobalResponseViewingPolicyLoadsAndPersists() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AutomationTestKeyStore()
        var model: AppModel? = makeModel(root: root, vault: SecretVault(keyStore: keyStore))
        let modelReference = WeakAutomationModelReference(model)
        try await waitUntil { model?.canEditVariables(.global) == true }

        await model?.saveGlobalMCPResponseViewing(.unredacted)
        XCTAssertEqual(model?.globalMCPResponseViewing, .unredacted)
        let terminated = await model?.prepareForTermination()
        XCTAssertEqual(terminated, true)
        model = nil
        try await waitUntil { modelReference.value == nil }

        let restarted = makeModel(root: root, vault: SecretVault(keyStore: keyStore))
        try await waitUntil { restarted.canEditVariables(.global) }
        XCTAssertEqual(restarted.globalMCPResponseViewing, .unredacted)
        let restartedTerminated = await restarted.prepareForTermination()
        XCTAssertTrue(restartedTerminated)
    }

    func testAutomationRunSnapshotFlowHonorsResponsePolicyAndPreservesRequestSecrets() async throws {
        let fixture = try AutomationHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root, vault: SecretVault(keyStore: AutomationTestKeyStore(), allowsKeyCreation: true))
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Automation flow")
        let collection = try XCTUnwrap(model.collections.first)

        let credentialRequest = await model.automationReply(
            AutomationCommand(
                operation: .requestsCreate,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "request": .object([
                        "name": .string("Credentials"),
                        "headers": .array([
                            .object(["name": .string("Authorization"), "value": .string("Bearer synthetic credential")]
                            ),
                            .object(["name": .string("X-Token"), "value": .string("synthetic api key")]),
                            .object(["name": .string("X-Template"), "value": .string("{{credential}}")]),
                        ]),
                        "inheritsCollectionAuthentication": .bool(false),
                        "authentication": .object(["apiKeyHeaderName": .string("x-token")]),
                    ]),
                ]
            ),
            channel: .mcp
        )
        XCTAssertNil(credentialRequest.error)
        let credentialHeaders = try XCTUnwrap(credentialRequest.result?.objectValue?["headers"]?.arrayValue)
        XCTAssertEqual(credentialHeaders[0].objectValue?["value"]?.stringValue, SecretRetemplating.redaction)
        XCTAssertEqual(credentialHeaders[1].objectValue?["value"]?.stringValue, SecretRetemplating.redaction)
        XCTAssertEqual(credentialHeaders[2].objectValue?["value"]?.stringValue, "{{credential}}")
        let credentialRequestID = try XCTUnwrap(
            credentialRequest.result?.objectValue?["requestID"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
        let cliCredentialRequest = await model.automationReply(
            AutomationCommand(
                operation: .requestsGet,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(credentialRequestID.uuidString),
                ]
            ),
            channel: .cli
        )
        XCTAssertEqual(
            cliCredentialRequest.result?.objectValue?["headers"]?.arrayValue?.first?.objectValue?["value"]?.stringValue,
            "Bearer synthetic credential"
        )

        let created = await model.automationReply(
            AutomationCommand(
                operation: .requestsCreate,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "request": .object([
                        "name": .string("Fixture response"),
                        "url": .string(fixture.baseURL + "/echo"),
                    ]),
                ]
            ),
            channel: .mcp
        )
        let requestID = try XCTUnwrap(
            created.result?.objectValue?["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let identity = RequestIdentity(collectionID: collection.id, requestID: requestID)
        let start = await model.automationReply(
            AutomationCommand(
                operation: .requestsStart,
                arguments: [
                    "collectionID": .string(collection.id.uuidString),
                    "requestID": .string(requestID.uuidString),
                ]
            ),
            channel: .mcp
        )
        let runID = try XCTUnwrap(start.result?.objectValue?["runID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        try await waitUntil { model.activeRuns[identity] == nil }

        let blockedRun = await model.automationReply(
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            channel: .mcp
        )
        let blockedResponse = try XCTUnwrap(blockedRun.result?.objectValue?["response"]?.objectValue)
        XCTAssertEqual(blockedResponse["bodyWithheld"]?.boolValue, true)
        XCTAssertEqual(blockedResponse["body"], .null)

        let rawRun = await model.automationReply(
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            channel: .cli
        )
        let rawResponse = try XCTUnwrap(rawRun.result?.objectValue?["response"]?.objectValue)
        XCTAssertEqual(rawResponse["bodyWithheld"]?.boolValue, false)
        XCTAssertNotNil(rawResponse["body"]?.objectValue?["content"]?.stringValue)

        await model.saveGlobalMCPResponseViewing(.allow)
        let allowedRun = await model.automationReply(
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            channel: .mcp
        )
        let allowedResponse = try XCTUnwrap(allowedRun.result?.objectValue?["response"]?.objectValue)
        XCTAssertEqual(allowedResponse["bodyWithheld"]?.boolValue, false)
        XCTAssertNotNil(allowedResponse["body"]?.objectValue?["content"]?.stringValue)

        let createdSnapshot = await model.automationReply(
            AutomationCommand(
                operation: .snapshotsCreate,
                arguments: ["runID": .string(runID.uuidString), "name": .string("Fixture capture")]
            ),
            channel: .mcp
        )
        let snapshotID = try XCTUnwrap(
            createdSnapshot.result?.objectValue?["snapshotID"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
        model.updateRequestMCPPolicy(MCPResourcePolicy(excluded: true), for: identity)
        let excludedSnapshot = await model.automationReply(
            AutomationCommand(operation: .snapshotsGet, arguments: ["snapshotID": .string(snapshotID.uuidString)]),
            channel: .mcp
        )
        XCTAssertEqual(excludedSnapshot.error?.code, .forbidden)
        let excludedSnapshotList = await model.automationReply(
            AutomationCommand(operation: .snapshotsList),
            channel: .mcp
        )
        XCTAssertFalse(
            excludedSnapshotList.result?.arrayValue?.contains(where: {
                $0.objectValue?["snapshotID"]?.stringValue == snapshotID.uuidString
            }) == true)
        model.updateRequestMCPPolicy(MCPResourcePolicy(), for: identity)

        let allowedSnapshot = await model.automationReply(
            AutomationCommand(operation: .snapshotsGet, arguments: ["snapshotID": .string(snapshotID.uuidString)]),
            channel: .mcp
        )
        XCTAssertEqual(allowedSnapshot.result?.objectValue?["response"]?.objectValue?["bodyWithheld"]?.boolValue, false)

        await model.saveGlobalMCPResponseViewing(.block)
        let blockedSnapshot = await model.automationReply(
            AutomationCommand(operation: .snapshotsGet, arguments: ["snapshotID": .string(snapshotID.uuidString)]),
            channel: .mcp
        )
        XCTAssertEqual(blockedSnapshot.result?.objectValue?["response"]?.objectValue?["bodyWithheld"]?.boolValue, true)

        let renamedSnapshot = await model.automationReply(
            AutomationCommand(
                operation: .snapshotsRename,
                arguments: ["snapshotID": .string(snapshotID.uuidString), "name": .string("Renamed fixture capture")]
            ),
            channel: .mcp
        )
        XCTAssertNil(renamedSnapshot.error)
        XCTAssertEqual(renamedSnapshot.result?.objectValue?["name"]?.stringValue, "Renamed fixture capture")
        let deletedSnapshot = await model.automationReply(
            AutomationCommand(operation: .snapshotsDelete, arguments: ["snapshotID": .string(snapshotID.uuidString)]),
            channel: .mcp
        )
        XCTAssertEqual(deletedSnapshot.result?.objectValue?["deleted"]?.boolValue, true)

        model.updateRequestMCPPolicy(MCPResourcePolicy(excluded: true), for: identity)
        try await model.flushPendingSaves()
        await model.deleteRequest(identity)
        XCTAssertNil(model.request(for: identity))
        let deletedRequestRun = await model.automationReply(
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            channel: .mcp
        )
        XCTAssertEqual(deletedRequestRun.error?.code, .notFound)
        XCTAssertNil(deletedRequestRun.result)

        XCTAssertNil(model.selectedIdentity)
        XCTAssertNil(model.selectedSnapshotID)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testUnredactedLiveAndSnapshotResponsesHonorPolicyDowngradesAndExclusions() async throws {
        let fixture = try AutomationHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root, vault: SecretVault(keyStore: AutomationTestKeyStore(), allowsKeyCreation: true))
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Unredacted responses")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Captured secret")
        let identity = try XCTUnwrap(model.selectedIdentity)
        let secret = "syntheticUnredactedResponseSecret"
        let headerSecret = "syntheticDirectHeaderSecret"
        try await model.setVariable(name: "credential", value: secret, isSecret: true, owner: .request(identity))
        model.updateDraft(identity) { request in
            request.url = fixture.baseURL + "/redirect"
            request.query = [HTTPField(name: "to", value: "/echo?secret={{credential}}")]
            request.headers = [HTTPField(name: "Authorization", value: "Bearer \(headerSecret)")]
            request.options.followRedirects = true
            request.optionOverrides = HTTPOptionsOverrides(followRedirects: true)
        }
        try await model.flushPendingSaves()
        await model.saveGlobalMCPResponseViewing(.unredacted)

        let started = await model.automationReply(
            AutomationCommand(
                operation: .requestsStart,
                arguments: [
                    "collectionID": .string(identity.collectionID.uuidString),
                    "requestID": .string(identity.requestID.uuidString),
                ]),
            channel: .mcp
        )
        let runID = try XCTUnwrap(started.result?.objectValue?["runID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        try await waitUntil { model.activeRuns[identity] == nil }
        let saved = await model.automationReply(
            AutomationCommand(operation: .snapshotsCreate, arguments: ["runID": .string(runID.uuidString)]),
            channel: .mcp
        )
        let snapshotID = try XCTUnwrap(
            saved.result?.objectValue?["snapshotID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let reads = [
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            AutomationCommand(operation: .snapshotsGet, arguments: ["snapshotID": .string(snapshotID.uuidString)]),
        ]

        for command in reads {
            let reply = await model.automationReply(command, channel: .mcp)
            XCTAssertNil(reply.error)
            let response = try XCTUnwrap(reply.result?.objectValue?["response"]?.objectValue)
            XCTAssertEqual(response["bodyWithheld"]?.boolValue, false)
            XCTAssertTrue(try XCTUnwrap(response["body"]?.objectValue?["content"]?.stringValue).contains(secret))
            let redirect = try XCTUnwrap(response["redirects"]?.arrayValue?.first?.objectValue)
            XCTAssertTrue(try XCTUnwrap(redirect["nextURL"]?.stringValue).contains(secret))
            XCTAssertTrue(
                try XCTUnwrap(redirect["headers"]?.arrayValue).contains {
                    $0.objectValue?["value"]?.stringValue?.contains(secret) == true
                })
            if let request = reply.result?.objectValue?["request"] {
                let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
                XCTAssertFalse(encoded.contains(secret))
                XCTAssertFalse(encoded.contains(headerSecret))
            }
        }

        await model.updateCollectionMCPPolicy(MCPResourcePolicy(responseViewing: .allow), for: collection.id)
        for command in reads {
            let reply = await model.automationReply(command, channel: .mcp)
            XCTAssertNil(reply.error)
            let response = try XCTUnwrap(reply.result?.objectValue?["response"]?.objectValue)
            XCTAssertEqual(response["bodyWithheld"]?.boolValue, false)
            let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            XCTAssertFalse(encoded.contains(secret))
            XCTAssertTrue(encoded.contains("{{credential}}"))
        }

        model.updateRequestMCPPolicy(MCPResourcePolicy(responseViewing: .unredacted), for: identity)
        for command in reads {
            let reply = await model.automationReply(command, channel: .mcp)
            let content = try XCTUnwrap(
                reply.result?.objectValue?["response"]?.objectValue?["body"]?.objectValue?["content"]?.stringValue)
            XCTAssertTrue(content.contains(secret))
        }
        let requestRead = await model.automationReply(
            AutomationCommand(
                operation: .requestsGet,
                arguments: [
                    "collectionID": .string(identity.collectionID.uuidString),
                    "requestID": .string(identity.requestID.uuidString),
                ]),
            channel: .mcp
        )
        XCTAssertNil(requestRead.error)
        let encodedRequest = String(decoding: try JSONEncoder().encode(requestRead), as: UTF8.self)
        XCTAssertFalse(encodedRequest.contains(secret))
        XCTAssertFalse(encodedRequest.contains(headerSecret))

        model.updateRequestMCPPolicy(MCPResourcePolicy(responseViewing: .block), for: identity)
        for command in reads {
            let reply = await model.automationReply(command, channel: .mcp)
            XCTAssertNil(reply.error)
            let response = try XCTUnwrap(reply.result?.objectValue?["response"]?.objectValue)
            XCTAssertEqual(response["body"], .null)
            XCTAssertEqual(response["bodyWithheld"]?.boolValue, true)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains(secret))
        }

        let cliRead = await model.automationReply(reads[0], channel: .cli)
        XCTAssertTrue(
            try XCTUnwrap(
                cliRead.result?.objectValue?["response"]?.objectValue?["body"]?.objectValue?["content"]?.stringValue
            ).contains(secret))
        model.updateRequestMCPPolicy(MCPResourcePolicy(excluded: true, responseViewing: .unredacted), for: identity)
        for command in reads {
            let reply = await model.automationReply(command, channel: .mcp)
            XCTAssertEqual(reply.error?.code, .forbidden)
            XCTAssertNil(reply.result)
        }
        try await model.flushPendingSaves()
        await model.deleteRequest(identity)
        let excludedSnapshot = await model.automationReply(reads[1], channel: .mcp)
        XCTAssertEqual(excludedSnapshot.error?.code, .forbidden)
        XCTAssertNil(excludedSnapshot.result)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testStaleRunHandleCannotCancelNewerRun() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Runs")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Fail during preparation")
        let identity = try XCTUnwrap(model.selectedIdentity)
        model.updateDraft(identity) { $0.url = "not a valid request URL" }
        try await model.flushPendingSaves()

        let firstStart = await model.automationReply(
            AutomationCommand(
                operation: .requestsStart,
                arguments: [
                    "collectionID": .string(identity.collectionID.uuidString),
                    "requestID": .string(identity.requestID.uuidString),
                ]
            ),
            channel: .cli
        )
        let firstToken = try XCTUnwrap(
            firstStart.result?.objectValue?["runID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        _ = await model.automationReply(
            AutomationCommand(operation: .runsCancel, arguments: ["runID": .string(firstToken.uuidString)]),
            channel: .cli
        )
        try await waitUntil { model.activeRuns[identity] == nil }

        let secondStart = await model.automationReply(
            AutomationCommand(
                operation: .requestsStart,
                arguments: [
                    "collectionID": .string(identity.collectionID.uuidString),
                    "requestID": .string(identity.requestID.uuidString),
                ]
            ),
            channel: .cli
        )
        let secondToken = try XCTUnwrap(
            secondStart.result?.objectValue?["runID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        XCTAssertNotEqual(firstToken, secondToken)

        let staleCancel = await model.automationReply(
            AutomationCommand(operation: .runsCancel, arguments: ["runID": .string(firstToken.uuidString)]),
            channel: .cli
        )
        XCTAssertTrue(staleCancel.error?.code == .conflict || staleCancel.error?.code == .notFound)
        if let active = model.activeRuns[identity] {
            XCTAssertEqual(active.token, secondToken)
        } else {
            let secondState = await model.automationReply(
                AutomationCommand(operation: .runsGet, arguments: ["runID": .string(secondToken.uuidString)]),
                channel: .cli
            )
            XCTAssertEqual(secondState.result?.objectValue?["state"]?.stringValue, "failed")
        }
        XCTAssertEqual(model.selectedIdentity, identity)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testOngoingRunIncludesProgressAndSanitizesCapturedRedirects() async throws {
        let fixture = try AutomationHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(
            root: root, vault: SecretVault(keyStore: AutomationTestKeyStore(), allowsKeyCreation: true))
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Ongoing redirect")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Redirect progress")
        let identity = try XCTUnwrap(model.selectedIdentity)
        let secret = "syntheticRedirectSecret"
        try await model.setVariable(
            name: "credential",
            value: secret,
            isSecret: true,
            owner: .request(identity)
        )
        model.updateDraft(identity) { request in
            request.url = fixture.baseURL + "/redirect"
            request.query = [
                HTTPField(
                    name: "to",
                    value: "/stream?bytes=524288&chunk_delay=0.04&secret={{credential}}"
                )
            ]
            request.options.followRedirects = true
            request.optionOverrides = HTTPOptionsOverrides(followRedirects: true)
        }
        try await model.flushPendingSaves()

        let started = await model.automationReply(
            AutomationCommand(
                operation: .requestsStart,
                arguments: [
                    "collectionID": .string(identity.collectionID.uuidString),
                    "requestID": .string(identity.requestID.uuidString),
                ]
            ),
            channel: .mcp
        )
        let runID = try XCTUnwrap(started.result?.objectValue?["runID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        try await waitUntil {
            guard let active = model.activeRuns[identity] else { return false }
            return active.redirects.count == 1 && (active.progress?.receivedBytes ?? 0) > 0
        }

        let ongoing = await model.automationReply(
            AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
            channel: .mcp
        )
        let run = try XCTUnwrap(ongoing.result?.objectValue)
        XCTAssertEqual(run["state"]?.stringValue, "running")
        if case let .number(elapsed)? = run["elapsedSeconds"] {
            XCTAssertGreaterThan(elapsed, .zero)
        } else {
            XCTFail("Expected elapsed seconds.")
        }
        XCTAssertEqual(run["redirectCount"], .number(Decimal(1)))
        let progress = try XCTUnwrap(run["progress"]?.objectValue)
        if case let .number(received)? = progress["receivedBytes"] {
            XCTAssertGreaterThan(received, .zero)
        } else {
            XCTFail("Expected received-byte progress.")
        }
        XCTAssertEqual(progress["expectedBytes"], .null)

        let hop = try XCTUnwrap(run["redirects"]?.arrayValue?.first?.objectValue)
        XCTAssertNil(hop["url"])
        XCTAssertNil(hop["nextURL"])
        let headers = try XCTUnwrap(hop["headers"]?.arrayValue)
        let location = try XCTUnwrap(
            headers.first(where: {
                $0.objectValue?["name"]?.stringValue == "Location"
            })?.objectValue?["value"]?.stringValue)
        XCTAssertFalse(location.contains(secret))
        XCTAssertTrue(location.contains("{{credential}}"))

        for mode in [MCPResponseViewPolicy.unredacted, .allow, .block] {
            model.updateRequestMCPPolicy(MCPResourcePolicy(responseViewing: mode), for: identity)
            let reply = await model.automationReply(
                AutomationCommand(operation: .runsGet, arguments: ["runID": .string(runID.uuidString)]),
                channel: .mcp
            )
            let currentHop = try XCTUnwrap(reply.result?.objectValue?["redirects"]?.arrayValue?.first?.objectValue)
            let encoded = String(decoding: try JSONEncoder().encode(currentHop), as: UTF8.self)
            XCTAssertEqual(encoded.contains(secret), mode == .unredacted)
            if mode == .unredacted {
                XCTAssertTrue(try XCTUnwrap(currentHop["nextURL"]?.stringValue).contains(secret))
            } else if mode == .block {
                XCTAssertNil(currentHop["nextURL"])
            }
        }

        model.cancelRequest(identity)
        try await waitUntil { model.activeRuns[identity] == nil }
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testAutomationUpdateFencesEditingAndStartingWhileEncrypting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AutomationGatedKeyStore()
        let model = makeModel(root: root, vault: SecretVault(keyStore: keyStore, allowsKeyCreation: true))
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Fenced update")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "Before")
        let identity = try XCTUnwrap(model.selectedIdentity)
        try await model.flushPendingSaves()

        let update = Task {
            await model.automationReply(
                AutomationCommand(
                    operation: .requestsUpdate,
                    arguments: [
                        "collectionID": .string(identity.collectionID.uuidString),
                        "requestID": .string(identity.requestID.uuidString),
                        "request": .object([
                            "name": .string("Automation update"),
                            "authentication": .object([
                                "kind": .string("bearer"), "token": .string("synthetic gated secret"),
                            ]),
                        ]),
                    ]
                ),
                channel: .cli
            )
        }
        try await waitUntil { keyStore.hasStartedEncryption }
        XCTAssertFalse(model.canEdit(identity))
        model.updateDraft(identity) { $0.name = "Lost concurrent edit" }
        model.startRequest(identity)
        XCTAssertNil(model.activeRuns[identity])

        keyStore.allowEncryption.signal()
        let reply = await update.value
        XCTAssertNil(reply.error)
        XCTAssertEqual(model.request(for: identity)?.name, "Automation update")
        XCTAssertEqual(model.request(for: identity)?.authentication.kind, .bearer)
        XCTAssertNil(model.activeRuns[identity])
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testSourceDeletionAndMoveAreBlockedWhenSnapshotInventoryHasIssues() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let malformedSnapshot =
            dataDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: malformedSnapshot, withIntermediateDirectories: true)
        try Data("not a snapshot document".utf8).write(to: malformedSnapshot.appendingPathComponent("snapshot.json"))

        let model = makeModel(root: root)
        try await waitUntil { model.canEditVariables(.global) && !model.snapshotStorageIssues.isEmpty }
        await model.createCollection(name: "Source")
        let source = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: source.id, name: "Retained source")
        let identity = try XCTUnwrap(model.selectedIdentity)
        await model.createCollection(name: "Destination")
        let destination = try XCTUnwrap(model.collections.first(where: { $0.id != source.id }))

        await model.moveRequest(identity, toCollectionID: destination.id)
        XCTAssertNotNil(model.request(for: identity))
        XCTAssertFalse(
            model.collections.first(where: { $0.id == destination.id })?.requests.contains(where: {
                $0.id == identity.requestID
            }) == true)
        XCTAssertTrue(model.operationError?.contains("fully available") == true)

        await model.deleteRequest(identity)
        XCTAssertNotNil(model.request(for: identity))
        XCTAssertTrue(model.operationError?.contains("fully available") == true)

        await model.deleteCollection(id: source.id)
        XCTAssertNotNil(model.collections.first(where: { $0.id == source.id }))
        XCTAssertTrue(model.operationError?.contains("fully available") == true)
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    private func makeModel(root: URL, vault: SecretVault? = nil) -> AppModel {
        AppModel(
            arguments: [
                "PostieAutomationTests",
                "--data-directory", root.appendingPathComponent("data", isDirectory: true).path,
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path,
            ], secretVault: vault)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieAutomationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the model to reach the expected state.")
    }
}

private final class AutomationTestKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        key = proposedKey
        return proposedKey
    }
}

private final class AutomationHTTPFixture {
    private let process: Process
    private let termination: DispatchSemaphore
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let executable = Bundle(for: AppAutomationTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PostieHTTPFixture")
        let output = Pipe()
        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["--port", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { @Sendable _ in termination.signal() }
        self.process = process
        self.termination = termination
        try process.run()

        var line = Data()
        while true {
            let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
            guard let value = byte.first else { throw AutomationFixtureError.didNotStart }
            if value == 0x0A { break }
            line.append(value)
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Int],
            let port = object["port"]
        else {
            throw AutomationFixtureError.didNotStart
        }
        self.port = port
    }

    deinit {
        guard process.isRunning else { return }
        process.terminate()
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut, process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + .seconds(2))
    }
}

private enum AutomationFixtureError: Error {
    case didNotStart
}

private final class AutomationGatedKeyStore: ApplicationKeyStore, @unchecked Sendable {
    let allowEncryption = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var key: Data?
    private var startedEncryption = false

    var hasStartedEncryption: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedEncryption
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        startedEncryption = true
        lock.unlock()
        allowEncryption.wait()
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        key = proposedKey
        return proposedKey
    }
}

@MainActor
private final class WeakAutomationModelReference {
    weak var value: AppModel?

    init(_ value: AppModel?) {
        self.value = value
    }
}
