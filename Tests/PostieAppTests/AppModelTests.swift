import Darwin
import Dispatch
import Foundation
import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class AppModelTests: XCTestCase {
    func testVariableInspectionUsesEffectiveDefinitionAndRejectsStaleNavigation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore()))
        await model.createCollection(name: "Inspection")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let request = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, request)
        let origin = VariableOwner.request(requestIdentity)
        try model.setPlainVariable(name: "host", value: "global", owner: .global)
        try model.setPlainVariable(name: "host", value: "collection", owner: .collection(collectionID))
        let collectionValue = try XCTUnwrap(model.variableInspection(named: "host", in: origin))
        XCTAssertEqual(collectionValue.owner, .collection(collectionID))
        XCTAssertEqual(collectionValue.value, .plain("collection"))
        try model.setPlainVariable(name: "host", value: "request", owner: origin)
        XCTAssertFalse(model.isCurrent(collectionValue))
        let effective = try XCTUnwrap(model.variableInspection(named: "host", in: origin))
        XCTAssertEqual(effective.owner, origin)
        model.showVariableDefinition(effective)
        XCTAssertEqual(model.variableDefinitionRequest?.owner, origin)
        XCTAssertEqual(model.variableDefinitionRequest?.name, "host")
        model.showCollection(collectionID, section: .headers)
        XCTAssertEqual(model.collectionEditorSection, .headers)
        XCTAssertNil(model.variableInspection(named: "host", in: origin))
        model.showVariableDefinition(effective)
        XCTAssertEqual(model.selectedCollectionID, collectionID)
        let fromCollection = try XCTUnwrap(model.variableInspection(named: "host", in: .collection(collectionID)))
        model.showVariableDefinition(fromCollection)
        XCTAssertEqual(model.collectionEditorSection, .variables)
        try await model.flushPendingSaves()
    }

    func testFlushPersistsLatestEditAndNavigationRetainsOtherDrafts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collection = try XCTUnwrap(model.collections.first)
        await model.createRequest(in: collection.id, name: "First")
        await model.createRequest(in: collection.id, name: "Second")
        let requests = try XCTUnwrap(model.collections.first?.requests)
        let first = identity(collection.id, try XCTUnwrap(requests.first { $0.name == "First" }))
        let second = identity(collection.id, try XCTUnwrap(requests.first { $0.name == "Second" }))

        model.updateDraft(first) { request in
            request.url = "http://example.test/edited"
            request.body = "last edit before flush"
            request.bodyEnabled = true
        }
        model.select(second)
        XCTAssertEqual(model.request(for: first)?.body, "last edit before flush")
        XCTAssertEqual(model.selectedIdentity, second)

        try await model.flushPendingSaves()

        let stored = try readRequest(root: root, identity: first)
        XCTAssertEqual(stored["url"] as? String, "http://example.test/edited")
        XCTAssertEqual(stored["body"] as? String, "last edit before flush")
        XCTAssertEqual(stored["bodyEnabled"] as? Bool, true)
        XCTAssertNil(model.autosaveErrors[first])
    }

    func testOverlappingCollectionMutationsPreserveEveryCreatedRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Before")
        let collectionID = try XCTUnwrap(model.collections.first?.id)

        let rename = Task { @MainActor in await model.renameCollection(id: collectionID, name: "After") }
        let createTasks = (0..<6).map { index in
            Task { @MainActor in await model.createRequest(in: collectionID, name: "Request \(index)") }
        }
        await rename.value
        for task in createTasks { await task.value }

        let collection = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        XCTAssertEqual(collection.name, "After")
        XCTAssertEqual(collection.requests.count, 6)
        XCTAssertEqual(Set(collection.requests.map(\.id)).count, 6)

        let reversedIDs = collection.requests.map(\.id).reversed()
        await model.reorderRequests(Array(reversedIDs), in: collectionID)
        let reordered = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        XCTAssertEqual(reordered.requests.map(\.id), Array(reversedIDs))
        try await model.flushPendingSaves()
    }

    func testSaveFailureKeepsDraftAndBlocksTermination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Protected")
        let request = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, request)
        let requestURL = requestFileURL(root: root, identity: requestIdentity)
        try setImmutable(requestURL, enabled: true)
        defer { try? setImmutable(requestURL, enabled: false) }

        model.updateDraft(requestIdentity) { $0.name = "Unsaved latest edit" }

        do {
            try await model.flushPendingSaves()
            XCTFail("An immutable request file must report a failed save.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not save pending changes"))
        }
        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved latest edit")
        XCTAssertNotNil(model.autosaveErrors[requestIdentity])
        let canTerminate = await model.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertFalse(model.isTerminating)
        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved latest edit")
    }

    func testDeletingRequestGatesEditingAndWaitsForActiveRunSettlement() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Slow request")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let slowURL = try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "2")])
        model.updateDraft(requestIdentity) { $0.url = slowURL }
        try await model.flushPendingSaves()

        model.startRequest(requestIdentity)
        try await waitUntil { model.activeRuns[requestIdentity]?.runID != nil }
        let deletion = Task { @MainActor in await model.deleteRequest(requestIdentity) }
        await Task.yield()
        XCTAssertTrue(model.deletingRequests.contains(requestIdentity))
        XCTAssertFalse(model.canEdit(requestIdentity))
        XCTAssertNotNil(model.activeRuns[requestIdentity])

        await deletion.value

        XCTAssertNil(model.activeRuns[requestIdentity])
        XCTAssertNil(model.request(for: requestIdentity))
        XCTAssertFalse(model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
    }

    func testPartialDeletionOrphanCannotBeEditedOrStartedFromStaleDraft() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Orphan candidate")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        model.updateDraft(requestIdentity) { $0.url = fixture.baseURL + "/echo" }
        try await model.flushPendingSaves()

        let requestURL = requestFileURL(root: root, identity: requestIdentity)
        try setImmutable(requestURL, enabled: true)
        defer { try? setImmutable(requestURL, enabled: false) }
        await model.deleteRequest(requestIdentity)

        XCTAssertFalse(model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
        XCTAssertTrue(model.storageIssues.contains { $0.requestID == configuration.id && $0.canRecover })
        XCTAssertFalse(model.canEdit(requestIdentity))

        model.startRequest(requestIdentity)
        XCTAssertNil(model.activeRuns[requestIdentity], "An unindexed orphan must not be sent through its stale draft.")
        if model.activeRuns[requestIdentity] != nil {
            await model.cancelAndWait(for: requestIdentity)
        }
    }

    func testMutationReloadPreservesDirtyDraftWhenCollectionMembershipIsUnknown() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Draft owner")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let slowURL = try fixture.url(path: "/delay", query: [URLQueryItem(name: "seconds", value: "2")])
        model.updateDraft(requestIdentity) {
            $0.name = "Unsaved edit retained"
            $0.url = slowURL
        }

        let metadataURL = root.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(collectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("collection.json")
        try Data("{ malformed collection metadata".utf8).write(to: metadataURL, options: .atomic)
        await model.renameCollection(id: collectionID, name: "Cannot be saved")

        XCTAssertEqual(model.request(for: requestIdentity)?.name, "Unsaved edit retained")
        XCTAssertTrue(model.collections.first { $0.id == collectionID }?.isReadOnly == true)
        XCTAssertFalse(model.canEdit(requestIdentity))
        XCTAssertTrue(model.storageIssues.contains {
            $0.collectionID == collectionID && $0.requestID == nil && $0.id.hasPrefix("store:collection-metadata-malformed:")
        })

        model.startRequest(requestIdentity)
        XCTAssertNil(model.activeRuns[requestIdentity], "Unknown collection membership must keep a retained draft from being sent.")
        if model.activeRuns[requestIdentity] != nil {
            await model.cancelAndWait(for: requestIdentity)
        }
    }

    func testDeletingCollectionClearsRetainedMalformedDraftAfterOrphanRecovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Malformed request")
        await model.createRequest(in: collectionID, name: "Orphan request")
        let collection = try XCTUnwrap(model.collections.first { $0.id == collectionID })
        let malformedRequest = try XCTUnwrap(collection.requests.first { $0.name == "Malformed request" })
        let orphanRequest = try XCTUnwrap(collection.requests.first { $0.name == "Orphan request" })
        let malformedIdentity = identity(collectionID, malformedRequest)
        let orphanIdentity = identity(collectionID, orphanRequest)
        let malformedURL = requestFileURL(root: root, identity: malformedIdentity)
        let orphanURL = requestFileURL(root: root, identity: orphanIdentity)

        model.updateDraft(malformedIdentity) { $0.name = "Unsaved malformed draft" }
        try Data("{ malformed request".utf8).write(to: malformedURL, options: .atomic)
        try setImmutable(orphanURL, enabled: true)
        defer {
            if FileManager.default.fileExists(atPath: orphanURL.path) {
                try? setImmutable(orphanURL, enabled: false)
            }
        }

        await model.deleteRequest(orphanIdentity)
        let orphanIssue = try XCTUnwrap(model.storageIssues.first {
            $0.requestID == orphanIdentity.requestID && $0.canRecover
        })
        await model.recover(orphanIssue)
        try await waitUntil { model.autosaveErrors[malformedIdentity] != nil }
        XCTAssertEqual(model.request(for: malformedIdentity)?.name, "Unsaved malformed draft")

        try setImmutable(orphanURL, enabled: false)
        await model.deleteCollection(id: collectionID)

        XCTAssertFalse(model.collections.contains { $0.id == collectionID })
        XCTAssertNil(model.request(for: malformedIdentity))
        XCTAssertNil(model.autosaveErrors[malformedIdentity])
        XCTAssertFalse(model.drafts.keys.contains { $0.collectionID == collectionID })

        let canTerminate = await model.prepareForTermination()
        XCTAssertTrue(canTerminate)
    }

    func testManualRedirectUsesCapturedHopAndPreservesEditedDraft() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Workspace")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "Redirected request")
        let configuration = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, configuration)
        let redirectURL = try fixture.url(path: "/redirect", query: [
            URLQueryItem(name: "to", value: "/echo"),
            URLQueryItem(name: "status", value: "302")
        ])
        model.updateDraft(requestIdentity) {
            $0.method = "POST"
            $0.url = redirectURL
            $0.body = "submitted body"
            $0.bodyEnabled = true
        }
        try await model.flushPendingSaves()

        model.startRequest(requestIdentity)
        try await waitUntil {
            model.activeRuns[requestIdentity] == nil && model.latestResponses[requestIdentity]?.response.statusCode == 302
        }
        XCTAssertTrue(model.canFollowRedirect(requestIdentity))

        let editedURL = try fixture.url(path: "/echo", query: [URLQueryItem(name: "draft", value: "preserved")])
        model.updateDraft(requestIdentity) {
            $0.method = "PUT"
            $0.url = editedURL
            $0.body = "later edit"
            $0.options.followRedirects = true
        }
        try await model.flushPendingSaves()

        model.followRedirect(requestIdentity)
        let active = try XCTUnwrap(model.activeRuns[requestIdentity])
        XCTAssertEqual(active.request.method, "GET")
        XCTAssertEqual(active.request.url, fixture.baseURL + "/echo")
        XCTAssertEqual(active.redirects.count, 1)
        XCTAssertFalse(model.canFollowRedirect(requestIdentity))

        try await waitUntil {
            model.activeRuns[requestIdentity] == nil && model.latestResponses[requestIdentity]?.response.statusCode == 200
        }
        let finalResponse = try XCTUnwrap(model.latestResponses[requestIdentity]?.response)
        XCTAssertEqual(finalResponse.finalURL.path, "/echo")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: finalResponse.bodyFileURL)) as? [String: Any])
        XCTAssertEqual(payload["method"] as? String, "GET")
        XCTAssertEqual(payload["path"] as? String, "/echo")
        XCTAssertEqual(payload["query"] as? String, "")
        XCTAssertEqual(payload["body"] as? String, "")

        let currentDraft = try XCTUnwrap(model.request(for: requestIdentity))
        XCTAssertEqual(currentDraft.method, "PUT")
        XCTAssertEqual(currentDraft.url, editedURL)
        XCTAssertEqual(currentDraft.body, "later edit")
        XCTAssertTrue(currentDraft.options.followRedirects)
        try await model.flushPendingSaves()
        let stored = try readRequest(root: root, identity: requestIdentity)
        XCTAssertEqual(stored["method"] as? String, "PUT")
        XCTAssertEqual(stored["url"] as? String, editedURL)
        XCTAssertEqual(stored["body"] as? String, "later edit")
        let storedOptions = try XCTUnwrap(stored["options"] as? [String: Any])
        XCTAssertEqual(storedOptions["followRedirects"] as? Bool, true)

        _ = await model.prepareForTermination()
    }

    func testScopedVariablesPersistRestartAndResolveRequestPrecedence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AppModelKeyStore()
        var savedIdentity: RequestIdentity?
        weak var firstModel: AppModel?
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            try await waitUntil { model.canEditVariables(.global) }
            await model.createCollection(name: "Synthetic scopes")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID)
            let request = try XCTUnwrap(model.collections.first?.requests.first)
            let requestIdentity = identity(collectionID, request)
            savedIdentity = requestIdentity
            try await model.setVariable(name: "host", value: "global.test", isSecret: false, owner: .global)
            try await model.setVariable(name: "host", value: "collection.test", isSecret: false, owner: .collection(collectionID))
            try await model.setVariable(name: "host", value: "request.test", isSecret: false, owner: .request(requestIdentity))
            try await model.setVariable(name: "credential", value: "synthetic protected value", isSecret: true, owner: .request(requestIdentity))
            model.updateDraft(requestIdentity) { $0.url = "https://{{host}}/" }
            let prepared = try await RequestPreparer.prepare(
                try XCTUnwrap(model.request(for: requestIdentity)),
                context: model.variableContext(for: requestIdentity),
                decryptor: nil
            )
            XCTAssertEqual(prepared.request.url?.host, "request.test")
            XCTAssertEqual(prepared.referencedInputs["host"]?.scope, .request)
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
            let serialized = try String(contentsOf: requestFileURL(root: root, identity: requestIdentity), encoding: .utf8)
            XCTAssertFalse(serialized.contains("synthetic protected value"))
        }
        try await waitUntil { firstModel == nil }

        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        let requestIdentity = try XCTUnwrap(savedIdentity)
        try await waitUntil { reloaded.request(for: requestIdentity) != nil && reloaded.canEditVariables(.global) }
        XCTAssertEqual(reloaded.variables(for: .global)["host"], .plain("global.test"))
        XCTAssertEqual(reloaded.variables(for: .collection(requestIdentity.collectionID))["host"], .plain("collection.test"))
        XCTAssertEqual(reloaded.variables(for: .request(requestIdentity))["host"], .plain("request.test"))
        let revealed = try await reloaded.revealVariable(named: "credential", owner: .request(requestIdentity))
        XCTAssertEqual(revealed, "synthetic protected value")
        _ = await reloaded.prepareForTermination()
    }

    func testFailedSecretCommitPreservesValueAndBlocksQuitUntilCancelled() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore(deniesAccess: true)))
        try await waitUntil { model.canEditVariables(.global) }
        try await model.setVariable(name: "credential", value: "original literal", isSecret: false, owner: .global)
        do {
            try await model.setVariable(name: "credential", value: "synthetic failed secret", isSecret: true, owner: .global)
            XCTFail("Denied key access must fail the accepted secret commit.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyUnavailable)
        }
        XCTAssertEqual(model.globalVariables["credential"], .plain("original literal"))
        XCTAssertNotNil(model.variableSaveErrors[.global])
        let failedTermination = await model.prepareForTermination()
        XCTAssertFalse(failedTermination)
        model.discardVariableSecretEdit(named: "credential", owner: .global)
        XCTAssertNil(model.variableSaveErrors[.global])
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
        let globals = try String(contentsOf: root.appendingPathComponent("data/globals.json"), encoding: .utf8)
        XCTAssertFalse(globals.contains("synthetic failed secret"))
    }

    func testQuitDrainsAcceptedSecretCommitAndDeletedValueCannotResurrect() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AppModelKeyStore(blocksLoad: true)
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { model.canEditVariables(.global) }
        let commit = Task { @MainActor in
            try await model.setVariable(name: "removed", value: "synthetic delayed secret", isSecret: true, owner: .global)
        }
        try await waitUntil { keyStore.loadStarted }
        model.removeVariable(named: "removed", owner: .global)
        let termination = Task { @MainActor in await model.prepareForTermination() }
        await Task.yield()
        XCTAssertTrue(model.isTerminating)
        keyStore.releaseLoad()
        do {
            try await commit.value
            XCTFail("Removing a variable must invalidate its pending encrypted edit.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let terminated = await termination.value
        XCTAssertTrue(terminated)
        XCTAssertNil(model.globalVariables["removed"])
        let globals = try String(contentsOf: root.appendingPathComponent("data/globals.json"), encoding: .utf8)
        XCTAssertFalse(globals.contains("removed"))
        XCTAssertFalse(globals.contains("synthetic delayed secret"))
    }

    func testEncryptedPreparationCancellationAndDeletionCannotLaunchRun() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AppHTTPFixture()
        let sourceVault = SecretVault(keyStore: AppModelKeyStore())
        let envelope = try await sourceVault.encrypt("synthetic held credential")
        let keyStore = AppModelKeyStore(blocksLoad: true)
        defer { keyStore.releaseLoad() }
        let heldVault = SecretVault(keyStore: keyStore)
        let model = try makeModel(root: root, secretVault: heldVault)
        await model.createCollection(name: "Held preparation")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let request = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, request)
        model.updateDraft(requestIdentity) {
            $0.url = fixture.baseURL + "/echo"
            $0.headers = [HTTPField(name: "X-Synthetic-Credential", value: "{{credential}}")]
            $0.variables = ["credential": .encrypted(envelope)]
        }
        model.startRequest(requestIdentity)
        let preparationToken = try XCTUnwrap(model.activeRuns[requestIdentity]?.token)
        try await waitUntil { keyStore.loadStarted }
        XCTAssertEqual(model.activeRuns[requestIdentity]?.phase, .preparing)
        XCTAssertNil(model.activeRuns[requestIdentity]?.runID)
        model.startRequest(requestIdentity)
        XCTAssertEqual(model.activeRuns[requestIdentity]?.token, preparationToken)

        await model.cancelAndWait(for: requestIdentity)
        XCTAssertNil(model.activeRuns[requestIdentity])
        XCTAssertTrue(model.cancelledRequests.contains(requestIdentity))
        await model.deleteRequest(requestIdentity)
        XCTAssertNil(model.request(for: requestIdentity))
        keyStore.releaseLoad()
        _ = try await heldVault.decrypt(envelope)
        await Task.yield()
        XCTAssertNil(model.activeRuns[requestIdentity])
        XCTAssertNil(model.latestResponses[requestIdentity])
        XCTAssertNil(model.runErrors[requestIdentity])
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testSecretCheckboxRoundTripsAcrossScopesAndFailureKeepsOriginalValue() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore()))
        await model.createCollection(name: "Checkbox fixtures")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let requestIdentity = try XCTUnwrap(model.selectedIdentity)
        for owner in [VariableOwner.global, .collection(collectionID), .request(requestIdentity)] {
            try model.setPlainVariable(name: "value", value: "synthetic toggle", owner: owner)
            try await model.setVariableSecret(true, named: "value", owner: owner)
            XCTAssertEqual(model.variables(for: owner)["value"]?.isEncrypted, true)
            try await model.setVariableSecret(false, named: "value", owner: owner)
            XCTAssertEqual(model.variables(for: owner)["value"], .plain("synthetic toggle"))
        }
        try await model.flushPendingSaves()
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)

        let deniedRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        let denied = try makeModel(root: deniedRoot, secretVault: SecretVault(keyStore: AppModelKeyStore(deniesAccess: true)))
        try await waitUntil { denied.canEditVariables(.global) }
        try denied.setPlainVariable(name: "value", value: "unchanged", owner: .global)
        do {
            try await denied.setVariableSecret(true, named: "value", owner: .global)
            XCTFail("Conversion must fail when key access fails.")
        } catch { XCTAssertEqual(error as? SecretVaultError, .keyUnavailable) }
        XCTAssertEqual(denied.globalVariables["value"], .plain("unchanged"))
        let deniedTerminated = await denied.prepareForTermination()
        XCTAssertTrue(deniedTerminated)
    }

    func testCollectionDefaultsFlushAndExecuteWithRequestScopesWithoutMutatingDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AppHTTPFixture()
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore()))
        await model.createCollection(name: "Shared defaults")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let requestIdentity = try XCTUnwrap(model.selectedIdentity)
        XCTAssertTrue(try XCTUnwrap(model.request(for: requestIdentity)).inheritsCollectionAuthentication)
        try model.setPlainVariable(name: "scope", value: "collection", owner: .collection(collectionID))
        try model.setPlainVariable(name: "scope", value: "request", owner: .request(requestIdentity))
        model.updateCollectionHeaders([
            HTTPField(name: "X-Shared", value: "{{scope}}"),
            HTTPField(name: "X-Suppressed", value: "{{unused}}")
        ], in: collectionID)
        model.setAuthenticationKind(.basic, owner: .collection(collectionID))
        model.updateAuthenticationUsername("{{scope}}", owner: .collection(collectionID))
        try await model.setAuthenticationSecret("synthetic-password", field: .password, owner: .collection(collectionID))
        model.updateDraft(requestIdentity) {
            $0.url = fixture.baseURL + "/echo"
            $0.headers = [HTTPField(name: "x-suppressed", value: "{{unused}}", isEnabled: false)]
        }
        model.showCollection(collectionID)
        XCTAssertEqual(model.selectedCollectionID, collectionID)
        model.openRequest(requestIdentity)
        XCTAssertNil(model.selectedCollectionID)
        model.startRequest(requestIdentity)
        try await waitUntil { model.latestResponses[requestIdentity] != nil || model.runErrors[requestIdentity] != nil }
        XCTAssertNil(model.runErrors[requestIdentity])
        let response = try XCTUnwrap(model.latestResponses[requestIdentity]?.response)
        XCTAssertEqual(response.requestHeaders.first { $0.name.lowercased() == "x-shared" }?.value, "request")
        XCTAssertNil(response.requestHeaders.first { $0.name.lowercased() == "x-suppressed" })
        XCTAssertEqual(response.requestHeaders.first { $0.name.lowercased() == "authorization" }?.value,
                       "Basic " + Data("request:synthetic-password".utf8).base64EncodedString())
        XCTAssertEqual(response.request.authentication.kind, .none)
        XCTAssertTrue(response.request.inheritsCollectionAuthentication)
        try await model.flushPendingSaves()
        let path = root.appendingPathComponent("data/collections/\(collectionID.uuidString.lowercased())/collection.json")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual((saved["variables"] as? [String: String])?["scope"], "collection")
        XCTAssertEqual((saved["headers"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("synthetic-password"))
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testCollectionOnlyCiphertextPreventsCreatingAReplacementKey() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceVault = SecretVault(keyStore: AppModelKeyStore())
        let token = try await sourceVault.encrypt("synthetic collection credential")
        do {
            let store = try CollectionStore(rootURL: root.appendingPathComponent("data"))
            let collection = try await store.createCollection(name: "Missing collection key")
            try await store.saveCollectionConfiguration(
                CollectionRequestDefaults(authentication: RequestAuthentication(kind: .bearer, token: token)),
                variables: [:], in: collection.id
            )
        }
        let keyStore = MissingCollectionKeyStore()
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { model.canEditVariables(.global) }
        try model.setPlainVariable(name: "newValue", value: "preserved", owner: .global)
        do {
            try await model.setVariableSecret(true, named: "newValue", owner: .global)
            XCTFail("Existing collection ciphertext must prevent replacement-key creation.")
        } catch { XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed) }
        XCTAssertEqual(keyStore.creationCount, 0)
        XCTAssertEqual(model.globalVariables["newValue"], .plain("preserved"))
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    private func makeModel(root: URL, secretVault: SecretVault? = nil) throws -> AppModel {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        return AppModel(arguments: [
            "PostieTests",
            "--data-directory", dataDirectory.path,
            "--body-directory", bodyDirectory.path
        ], secretVault: secretVault)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieAppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func identity(_ collectionID: UUID, _ request: HTTPRequestConfiguration) -> RequestIdentity {
        RequestIdentity(collectionID: collectionID, requestID: request.id)
    }

    private func requestFileURL(root: URL, identity: RequestIdentity) -> URL {
        root.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("collections", isDirectory: true)
            .appendingPathComponent(identity.collectionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("\(identity.requestID.uuidString.lowercased()).json")
    }

    private func readRequest(root: URL, identity: RequestIdentity) throws -> [String: Any] {
        let data = try Data(contentsOf: requestFileURL(root: root, identity: identity))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func setImmutable(_ url: URL, enabled: Bool) throws {
        let flags = enabled ? UInt32(UF_IMMUTABLE) : 0
        let result = url.path.withCString { Darwin.chflags($0, flags) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the model to reach the expected state.")
    }
}

private final class MissingCollectionKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    var creationCount: Int { lock.withLock { creations } }
    func loadKey() throws -> Data? { nil }
    func createKey(_ proposedKey: Data) throws -> Data {
        lock.withLock { creations += 1 }
        return proposedKey
    }
}

private final class AppModelKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private let loadGate = DispatchSemaphore(value: 0)
    private let deniesAccess: Bool
    private let blocksLoad: Bool
    private var didStartLoad = false

    init(deniesAccess: Bool = false, blocksLoad: Bool = false) {
        self.deniesAccess = deniesAccess
        self.blocksLoad = blocksLoad
    }

    var loadStarted: Bool { lock.withLock { didStartLoad } }

    func loadKey() throws -> Data? {
        lock.withLock { didStartLoad = true }
        if blocksLoad { loadGate.wait() }
        if deniesAccess { throw TestError.denied }
        return Data(repeating: 0x42, count: 32)
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        throw TestError.unexpectedCreation
    }

    func releaseLoad() { loadGate.signal() }

    private enum TestError: Error {
        case denied
        case unexpectedCreation
    }
}

private final class AppHTTPFixture {
    private let process: Process
    private let termination: DispatchSemaphore
    let port: Int

    var baseURL: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fixtureExecutable = Bundle(for: AppModelTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("PostieHTTPFixture")
        let output = Pipe()
        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = fixtureExecutable
        process.arguments = ["--port", "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { @Sendable _ in termination.signal() }
        self.process = process
        self.termination = termination
        try process.run()

        do {
            let line = try Self.readLine(from: output.fileHandleForReading)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int])
            self.port = try XCTUnwrap(value["port"])
        } catch {
            Self.stop(process: process, termination: termination)
            throw error
        }
    }

    deinit {
        Self.stop(process: process, termination: termination)
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> String {
        var components = URLComponents(string: baseURL + path)
        components?.queryItems = query.isEmpty ? nil : query
        return try XCTUnwrap(components?.url?.absoluteString)
    }

    private static func readLine(from handle: FileHandle) throws -> String {
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: 1) ?? Data()
            guard let byte = chunk.first else { throw FixtureError.didNotStart }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private static func stop(process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }

        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
              process.isRunning else { return }
        XCTFail("The HTTP fixture process did not terminate after SIGKILL.")
    }

    private enum FixtureError: Error {
        case didNotStart
    }
}
