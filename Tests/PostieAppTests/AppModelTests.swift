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

    func testVariableCompletionsPreviewEffectivePlainValueAndExcludeSecrets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore()))
        try await waitUntil { model.canEditVariables(.global) }
        await model.createCollection(name: "Completion")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let request = try XCTUnwrap(model.collections.first?.requests.first)
        let requestIdentity = identity(collectionID, request)

        try model.setPlainVariable(name: "override", value: "global value", owner: .global)
        try model.setPlainVariable(name: "override", value: "collection value", owner: .collection(collectionID))
        try model.setPlainVariable(name: "override", value: "request value", owner: .request(requestIdentity))
        try model.setPlainVariable(
            name: "collectionOnly", value: "collection fallback", owner: .collection(collectionID))
        try model.setPlainVariable(name: "globalOnly", value: "global fallback", owner: .global)
        try await model.setVariable(
            name: "credential",
            value: "synthetic secret text",
            isSecret: true,
            owner: .request(requestIdentity)
        )

        let completions = Dictionary(
            uniqueKeysWithValues: model.variableCompletions(for: requestIdentity).map { ($0.name, $0) })

        XCTAssertEqual(completions["override"]?.scope, .request)
        XCTAssertEqual(completions["override"]?.preview, "request value")
        XCTAssertEqual(completions["collectionOnly"]?.scope, .collection)
        XCTAssertEqual(completions["collectionOnly"]?.preview, "collection fallback")
        XCTAssertEqual(completions["globalOnly"]?.scope, .global)
        XCTAssertEqual(completions["globalOnly"]?.preview, "global fallback")
        XCTAssertEqual(completions["credential"]?.scope, .request)
        XCTAssertEqual(completions["credential"]?.isSecret, true)
        XCTAssertNil(completions["credential"]?.preview)
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

    func testRequestURLAndQueryTableEditsRoundTripAndPersistInOrder() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedURL = "https://example.test/items?tag=a%2Fb&first=a%20%2B%20b&fresh=x%2Fy#frag%2Fvalue?tail"
        let keyStore = AppModelKeyStore()
        var savedIdentity: RequestIdentity?
        weak var firstModel: AppModel?
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            await model.createCollection(name: "Query editing")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID)
            let requestIdentity = try XCTUnwrap(model.selectedIdentity)
            savedIdentity = requestIdentity
            let source = "https://example.test/items?first=one&tag=a%2Fb&tag=two+words&remove=gone#frag%2Fvalue?tail"

            model.updateURL(source, for: requestIdentity)

            XCTAssertEqual(model.displayURL(for: requestIdentity), source)
            var request = try XCTUnwrap(model.request(for: requestIdentity))
            XCTAssertEqual(request.url, "https://example.test/items#frag%2Fvalue?tail")
            XCTAssertEqual(request.query.map(\.name), ["first", "tag", "tag", "remove"])
            XCTAssertEqual(request.query.map(\.value), ["one", "a/b", "two+words", "gone"])

            var rows = request.query
            rows[0].value = "a + b"
            rows[2].isEnabled = false
            rows.remove(at: 3)
            rows.append(HTTPField(name: "fresh", value: "x/y", isEnabled: false))
            rows.swapAt(0, 1)
            model.updateQuery(rows, for: requestIdentity)

            XCTAssertEqual(
                model.displayURL(for: requestIdentity),
                "https://example.test/items?tag=a%2Fb&first=a%20%2B%20b#frag%2Fvalue?tail"
            )
            request = try XCTUnwrap(model.request(for: requestIdentity))
            XCTAssertEqual(request.query.map(\.name), ["tag", "first", "tag", "fresh"])
            XCTAssertEqual(request.query.map(\.isEnabled), [true, true, false, false])

            rows = request.query
            rows[3].isEnabled = true
            model.updateQuery(rows, for: requestIdentity)

            XCTAssertEqual(model.displayURL(for: requestIdentity), expectedURL)
            try await model.flushPendingSaves()

            let stored = try readRequest(root: root, identity: requestIdentity)
            XCTAssertEqual(stored["url"] as? String, "https://example.test/items#frag%2Fvalue?tail")
            let storedQuery = try XCTUnwrap(stored["query"] as? [[String: Any]])
            XCTAssertEqual(storedQuery.compactMap { $0["name"] as? String }, ["tag", "first", "tag", "fresh"])
            XCTAssertEqual(storedQuery.compactMap { $0["isEnabled"] as? Bool }, [true, true, false, true])

            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }

        try await waitUntil { firstModel == nil }
        let requestIdentity = try XCTUnwrap(savedIdentity)
        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { reloaded.request(for: requestIdentity) != nil }
        XCTAssertEqual(reloaded.displayURL(for: requestIdentity), expectedURL)
        XCTAssertEqual(reloaded.request(for: requestIdentity)?.query.map(\.isEnabled), [true, true, false, true])
        _ = await reloaded.prepareForTermination()
    }

    func testBareAndEscapedQueryValuesSurviveURLEditingAndReload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AppModelKeyStore()
        var savedBareIdentity: RequestIdentity?
        var savedEscapedIdentity: RequestIdentity?
        weak var firstModel: AppModel?
        let editedURL = "https://example.test/edited?raw=\\{{literal}}"
        let context = VariableContext(request: ["literal": .plain("must remain literal")])
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            await model.createCollection(name: "Query value round trips")
            let collectionID = try XCTUnwrap(model.collections.first?.id)

            await model.createRequest(in: collectionID, name: "Bare query")
            let bareIdentity = try XCTUnwrap(model.selectedIdentity)
            savedBareIdentity = bareIdentity
            model.updateURL("https://example.test?key=value", for: bareIdentity)
            try await model.flushPendingSaves()
            model.updateURL("https://example.test?key", for: bareIdentity)
            XCTAssertEqual(model.displayURL(for: bareIdentity), "https://example.test?key")

            await model.createRequest(in: collectionID, name: "Escaped query")
            let escapedIdentity = try XCTUnwrap(model.selectedIdentity)
            savedEscapedIdentity = escapedIdentity
            let source = "https://example.test/original?raw=\\{{literal}}"
            model.updateURL(source, for: escapedIdentity)
            model.updateURL(editedURL, for: escapedIdentity)
            XCTAssertEqual(model.displayURL(for: escapedIdentity), editedURL)
            try await model.flushPendingSaves()

            let request = try XCTUnwrap(model.request(for: escapedIdentity))
            let prepared = try await RequestPreparer.prepare(request, context: context, decryptor: nil)
            XCTAssertEqual(prepared.request.url?.absoluteString, "https://example.test/edited?raw=%7B%7Bliteral%7D%7D")
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }

        try await waitUntil { firstModel == nil }
        let bareIdentity = try XCTUnwrap(savedBareIdentity)
        let escapedIdentity = try XCTUnwrap(savedEscapedIdentity)
        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil {
            reloaded.request(for: bareIdentity) != nil && reloaded.request(for: escapedIdentity) != nil
        }
        XCTAssertEqual(reloaded.displayURL(for: bareIdentity), "https://example.test?key")
        XCTAssertEqual(reloaded.displayURL(for: escapedIdentity), editedURL)
        let reloadedEscapedRequest = try XCTUnwrap(reloaded.request(for: escapedIdentity))
        let reloadedPrepared = try await RequestPreparer.prepare(
            reloadedEscapedRequest, context: context, decryptor: nil)
        XCTAssertEqual(
            reloadedPrepared.request.url?.absoluteString, "https://example.test/edited?raw=%7B%7Bliteral%7D%7D")
        _ = await reloaded.prepareForTermination()
    }

    func testGlobalOptionsPersistAndClearedRequestOverridesInheritPerField() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = HTTPOptions(
            followRedirects: true,
            inactivityTimeout: 30,
            overallTimeout: 120,
            maximumResponseBytes: 1_000_000
        )
        let keyStore = AppModelKeyStore()
        var savedInheritedIdentity: RequestIdentity?
        var savedLegacyIdentity: RequestIdentity?
        weak var firstModel: AppModel?
        var overrides = HTTPOptionsOverrides(
            followRedirects: false,
            inactivityTimeout: 9,
            maximumResponseBytes: 1_000,
            overallTimeoutIsUnlimited: true
        )
        let legacyOptions = HTTPOptions(
            followRedirects: false, inactivityTimeout: 17, overallTimeout: nil, maximumResponseBytes: nil)
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            try await waitUntil { !model.globalOptionsAreReadOnly }
            model.updateGlobalOptions(defaults)
            await model.createCollection(name: "HTTP defaults")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID, name: "Inherited")
            let inheritedIdentity = try XCTUnwrap(model.selectedIdentity)
            savedInheritedIdentity = inheritedIdentity
            model.updateRequestOptionOverrides(overrides, for: inheritedIdentity)
            XCTAssertEqual(
                model.requestOptionOverrides(for: inheritedIdentity).resolve(against: defaults),
                HTTPOptions(
                    followRedirects: false, inactivityTimeout: 9, overallTimeout: nil, maximumResponseBytes: 1_000)
            )

            overrides.followRedirects = nil
            overrides.inactivityTimeout = nil
            model.updateRequestOptionOverrides(overrides, for: inheritedIdentity)
            XCTAssertEqual(model.requestOptionOverrides(for: inheritedIdentity), overrides)
            XCTAssertEqual(
                model.requestOptionOverrides(for: inheritedIdentity).resolve(against: defaults),
                HTTPOptions(
                    followRedirects: true, inactivityTimeout: 30, overallTimeout: nil, maximumResponseBytes: 1_000)
            )

            await model.createRequest(in: collectionID, name: "Legacy explicit")
            let legacyIdentity = try XCTUnwrap(model.selectedIdentity)
            savedLegacyIdentity = legacyIdentity
            model.updateDraft(legacyIdentity) {
                $0.optionOverrides = nil
                $0.options = legacyOptions
            }
            XCTAssertEqual(model.requestOptionOverrides(for: legacyIdentity), .explicit(legacyOptions))
            try await model.flushPendingSaves()

            let storedLegacy = try readRequest(root: root, identity: legacyIdentity)
            XCTAssertNil(storedLegacy["optionOverrides"])
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }

        try await waitUntil { firstModel == nil }
        let inheritedIdentity = try XCTUnwrap(savedInheritedIdentity)
        let legacyIdentity = try XCTUnwrap(savedLegacyIdentity)
        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { !reloaded.globalOptionsAreReadOnly && reloaded.request(for: inheritedIdentity) != nil }
        XCTAssertEqual(reloaded.globalOptions, defaults)
        XCTAssertEqual(reloaded.requestOptionOverrides(for: inheritedIdentity), overrides)
        XCTAssertEqual(
            reloaded.requestOptionOverrides(for: inheritedIdentity).resolve(against: reloaded.globalOptions),
            HTTPOptions(followRedirects: true, inactivityTimeout: 30, overallTimeout: nil, maximumResponseBytes: 1_000)
        )
        XCTAssertEqual(reloaded.requestOptionOverrides(for: legacyIdentity), .explicit(legacyOptions))
        XCTAssertEqual(
            reloaded.requestOptionOverrides(for: legacyIdentity).resolve(against: reloaded.globalOptions),
            legacyOptions
        )
        _ = await reloaded.prepareForTermination()
    }

    func testHTTPSettingsInputsRejectInvalidTimeoutsAndSizeOverflow() {
        XCTAssertNil(HTTPSettingsInput.timeout(from: "0", decimalSeparator: "."))
        XCTAssertNil(HTTPSettingsInput.timeout(from: "2s", decimalSeparator: "."))
        XCTAssertNil(HTTPSettingsInput.responseBytes(from: "1.5 MB", multiplier: 1_000_000, decimalSeparator: "."))
        XCTAssertEqual(
            HTTPSettingsInput.responseBytes(from: "1.5", multiplier: 1_000_000, decimalSeparator: "."), 1_500_000)
        XCTAssertNil(
            HTTPSettingsInput.responseBytes(from: "9223372036855", multiplier: 1_000_000, decimalSeparator: "."))
    }

    func testNewRequestInheritsGlobalOptionsThroughSettingsNavigationAndExecution() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: AppModelKeyStore()))
        try await waitUntil { !model.globalOptionsAreReadOnly }
        let defaults = HTTPOptions(
            followRedirects: true,
            inactivityTimeout: 5,
            overallTimeout: 60,
            maximumResponseBytes: 1_000_000
        )
        model.updateGlobalOptions(defaults)
        await model.createCollection(name: "Inherited execution")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID)
        let requestIdentity = try XCTUnwrap(model.selectedIdentity)
        XCTAssertEqual(model.requestOptionOverrides(for: requestIdentity), HTTPOptionsOverrides())
        XCTAssertEqual(
            model.requestOptionOverrides(for: requestIdentity).resolve(against: model.globalOptions), defaults)
        let redirectURL = try fixture.url(path: "/redirect", query: [URLQueryItem(name: "to", value: "/echo")])
        model.updateDraft(requestIdentity) {
            $0.url = redirectURL
        }
        try await model.flushPendingSaves()

        model.showGlobalSettings()
        XCTAssertTrue(model.showsGlobalSettings)
        XCTAssertTrue(model.canNavigateBack)
        model.navigateBack()
        XCTAssertFalse(model.showsGlobalSettings)
        XCTAssertEqual(model.selectedIdentity, requestIdentity)
        XCTAssertTrue(model.canNavigateForward)
        model.navigateForward()
        XCTAssertTrue(model.showsGlobalSettings)
        model.navigateBack()

        model.startRequest(requestIdentity)
        let active = try XCTUnwrap(model.activeRuns[requestIdentity])
        XCTAssertEqual(active.request.options, defaults)
        try await waitUntil {
            model.activeRuns[requestIdentity] == nil && model.latestResponses[requestIdentity] != nil
        }
        let response = try XCTUnwrap(model.latestResponses[requestIdentity]?.response)
        XCTAssertEqual(response.finalURL.path, "/echo")
        XCTAssertNil(model.runErrors[requestIdentity])
        _ = await model.prepareForTermination()
    }

    func testNavigationHistoryRestoresTabsAndVariableDefinitionsWithoutSending() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Navigation")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "First")
        let first = try XCTUnwrap(model.selectedIdentity)
        await model.createRequest(in: collectionID, name: "Second")
        let second = try XCTUnwrap(model.selectedIdentity)
        try model.setPlainVariable(name: "host", value: "synthetic value", owner: .request(second))
        model.updateDraft(second) {
            $0.url = "https://example.test/unsent"
            $0.body = "preserved draft"
        }
        model.setRequestEditorSection(.settings, for: second)
        model.showCollection(collectionID, section: .headers)
        model.setCollectionEditorSection(.authentication)
        model.showGlobalVariables()
        model.showOngoingRequests()

        model.navigateBack()
        XCTAssertTrue(model.showsGlobalVariables)
        model.navigateBack()
        XCTAssertEqual(model.selectedCollectionID, collectionID)
        XCTAssertEqual(model.collectionEditorSection, .authentication)
        model.navigateBack()
        XCTAssertEqual(model.selectedCollectionID, collectionID)
        XCTAssertEqual(model.collectionEditorSection, .headers)
        model.navigateBack()
        XCTAssertEqual(model.selectedIdentity, second)
        XCTAssertEqual(model.requestEditorSection(for: second), .settings)

        let inspection = try XCTUnwrap(model.variableInspection(named: "host", in: .request(second)))
        model.showVariableDefinition(inspection)
        XCTAssertEqual(model.requestEditorSection(for: second), .variables)
        model.showGlobalVariables()
        model.navigateBack()
        XCTAssertEqual(model.selectedIdentity, second)
        XCTAssertEqual(model.requestEditorSection(for: second), .variables)
        XCTAssertEqual(model.variableDefinitionRequest?.owner, .request(second))
        XCTAssertEqual(model.variableDefinitionRequest?.name, "host")
        model.navigateBack()
        XCTAssertEqual(model.requestEditorSection(for: second), .settings)
        model.navigateForward()
        XCTAssertEqual(model.requestEditorSection(for: second), .variables)
        model.navigateBack()
        XCTAssertEqual(model.requestEditorSection(for: second), .settings)

        XCTAssertEqual(model.request(for: second)?.url, "https://example.test/unsent")
        XCTAssertEqual(model.request(for: second)?.body, "preserved draft")
        XCTAssertEqual(model.request(for: first)?.url, "")
        XCTAssertTrue(model.activeRuns.isEmpty)
        XCTAssertNil(model.latestResponses[second])
        try await model.flushPendingSaves()
    }

    func testRequestTabHistoryPreservesManualAccordionChoices() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Accordion navigation")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "First")
        let first = try XCTUnwrap(model.selectedIdentity)
        await model.createRequest(in: collectionID, name: "Second")
        let content = RequestEditorContentSnapshot(queryCount: 0, pathNames: [])
        let allSections = Set(RequestEditorAccordion.allCases)
        model.reconcileRequestEditorExpansion(
            for: first,
            initiallyExpanded: allSections,
            content: content
        )
        model.setRequestEditorAccordionExpanded(.query, isExpanded: false, for: first)

        model.openRequest(first)
        XCTAssertFalse(model.requestEditorExpansionState(for: first).isExpanded(.query))
        model.setRequestEditorSection(.settings, for: first)
        model.setRequestEditorSection(.variables, for: first)

        model.navigateBack()

        XCTAssertEqual(model.selectedIdentity, first)
        XCTAssertEqual(model.requestEditorSection(for: first), .settings)
        XCTAssertFalse(model.requestEditorExpansionState(for: first).isExpanded(.query))

        model.navigateForward()
        XCTAssertEqual(model.requestEditorSection(for: first), .variables)
        XCTAssertFalse(model.requestEditorExpansionState(for: first).isExpanded(.query))
        try await model.flushPendingSaves()
    }

    func testNavigationSkipsADeletedRequestDestination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root)
        await model.createCollection(name: "Navigation")
        let collectionID = try XCTUnwrap(model.collections.first?.id)
        await model.createRequest(in: collectionID, name: "First")
        let first = try XCTUnwrap(model.selectedIdentity)
        await model.createRequest(in: collectionID, name: "Deleted")
        let deleted = try XCTUnwrap(model.selectedIdentity)
        await model.createRequest(in: collectionID, name: "Current")
        let current = try XCTUnwrap(model.selectedIdentity)

        await model.deleteRequest(deleted)
        XCTAssertTrue(model.canNavigateBack)
        model.navigateBack()
        XCTAssertEqual(model.selectedIdentity, first)
        model.navigateForward()
        XCTAssertEqual(model.selectedIdentity, current)
        XCTAssertNil(model.request(for: deleted))
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
        XCTAssertFalse(
            model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
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

        XCTAssertFalse(
            model.collections.first { $0.id == collectionID }?.requests.contains { $0.id == configuration.id } ?? false)
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
        XCTAssertTrue(
            model.storageIssues.contains {
                $0.collectionID == collectionID && $0.requestID == nil
                    && $0.id.hasPrefix("store:collection-metadata-malformed:")
            })

        model.startRequest(requestIdentity)
        XCTAssertNil(
            model.activeRuns[requestIdentity],
            "Unknown collection membership must keep a retained draft from being sent.")
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
        let orphanIssue = try XCTUnwrap(
            model.storageIssues.first {
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
        let redirectURL = try fixture.url(
            path: "/redirect",
            query: [
                URLQueryItem(name: "to", value: "/echo"),
                URLQueryItem(name: "status", value: "302"),
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
            model.activeRuns[requestIdentity] == nil
                && model.latestResponses[requestIdentity]?.response.statusCode == 302
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
            model.activeRuns[requestIdentity] == nil
                && model.latestResponses[requestIdentity]?.response.statusCode == 200
        }
        let finalResponse = try XCTUnwrap(model.latestResponses[requestIdentity]?.response)
        XCTAssertEqual(finalResponse.finalURL.path, "/echo")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: finalResponse.bodyFileURL)) as? [String: Any])
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
            try await model.setVariable(
                name: "host", value: "collection.test", isSecret: false, owner: .collection(collectionID))
            try await model.setVariable(
                name: "host", value: "request.test", isSecret: false, owner: .request(requestIdentity))
            try await model.setVariable(
                name: "credential", value: "synthetic protected value", isSecret: true, owner: .request(requestIdentity)
            )
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
            let serialized = try String(
                contentsOf: requestFileURL(root: root, identity: requestIdentity), encoding: .utf8)
            XCTAssertFalse(serialized.contains("synthetic protected value"))
        }
        try await waitUntil { firstModel == nil }

        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        let requestIdentity = try XCTUnwrap(savedIdentity)
        try await waitUntil { reloaded.request(for: requestIdentity) != nil && reloaded.canEditVariables(.global) }
        XCTAssertEqual(reloaded.variables(for: .global)["host"], .plain("global.test"))
        XCTAssertEqual(
            reloaded.variables(for: .collection(requestIdentity.collectionID))["host"], .plain("collection.test"))
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
        let operationID = UUID()
        do {
            try await model.setVariable(
                name: "credential",
                value: "synthetic failed secret",
                isSecret: true,
                owner: .global,
                operationID: operationID
            )
            XCTFail("Denied key access must fail the accepted secret commit.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyUnavailable)
        }
        XCTAssertEqual(model.globalVariables["credential"], .plain("original literal"))
        XCTAssertNotNil(model.variableSaveErrors[.global])
        let failedTermination = await model.prepareForTermination()
        XCTAssertFalse(failedTermination)
        model.discardVariableSecretEdit(named: "credential", owner: .global, operationID: UUID())
        XCTAssertNotNil(model.variableSaveErrors[.global])
        let stillBlocked = await model.prepareForTermination()
        XCTAssertFalse(stillBlocked)
        model.discardVariableSecretEdit(named: "credential", owner: .global, operationID: operationID)
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
            try await model.setVariable(
                name: "removed", value: "synthetic delayed secret", isSecret: true, owner: .global)
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
        let denied = try makeModel(
            root: deniedRoot, secretVault: SecretVault(keyStore: AppModelKeyStore(deniesAccess: true)))
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
        model.updateCollectionHeaders(
            [
                HTTPField(name: "X-Shared", value: "{{scope}}"),
                HTTPField(name: "X-Suppressed", value: "{{unused}}"),
            ], in: collectionID)
        model.setAuthenticationKind(.basic, owner: .collection(collectionID))
        model.updateAuthenticationUsername("{{scope}}", owner: .collection(collectionID))
        try await model.setAuthenticationSecret(
            "synthetic-password", field: .password, owner: .collection(collectionID))
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
        XCTAssertEqual(
            response.requestHeaders.first { $0.name.lowercased() == "authorization" }?.value,
            "Basic " + Data("request:synthetic-password".utf8).base64EncodedString())
        XCTAssertEqual(response.request.authentication.kind, .none)
        XCTAssertTrue(response.request.inheritsCollectionAuthentication)
        try await model.flushPendingSaves()
        let path = root.appendingPathComponent(
            "data/collections/\(collectionID.uuidString.lowercased())/collection.json")
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

    func testAPIKeyOnlyCiphertextPreventsCreatingAReplacementKey() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceVault = SecretVault(keyStore: AppModelKeyStore())
        let apiKey = try await sourceVault.encrypt("synthetic API key ciphertext")
        do {
            let store = try CollectionStore(rootURL: root.appendingPathComponent("data"))
            let collection = try await store.createCollection(name: "Missing API key key")
            try await store.saveCollectionConfiguration(
                CollectionRequestDefaults(
                    authentication: RequestAuthentication(
                        kind: .apiKey,
                        apiKeyHeaderName: "X-Service-Key",
                        apiKey: apiKey
                    )),
                variables: [:],
                in: collection.id
            )
        }

        let keyStore = MissingCollectionKeyStore()
        let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil { model.canEditVariables(.global) }
        try model.setPlainVariable(name: "newValue", value: "preserved", owner: .global)
        do {
            try await model.setVariableSecret(true, named: "newValue", owner: .global)
            XCTFail("API-key-only ciphertext must prevent replacement-key creation.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
        }
        XCTAssertEqual(keyStore.creationCount, 0)
        XCTAssertEqual(model.globalVariables["newValue"], .plain("preserved"))
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testAPIKeyAuthenticationEncryptsEditsAndReloadsForCollectionAndRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AppModelKeyStore()
        var savedIdentity: RequestIdentity?
        weak var firstModel: AppModel?

        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            await model.createCollection(name: "API key persistence")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            try await waitUntil { model.canEditVariables(.collection(collectionID)) }

            model.setAuthenticationKind(.apiKey, owner: .collection(collectionID))
            model.updateAPIKeyHeaderName("X-Collection-Key", owner: .collection(collectionID))
            try await model.setAuthenticationSecret(
                "synthetic collection API key",
                field: .apiKey,
                owner: .collection(collectionID)
            )

            await model.createRequest(in: collectionID, name: "Request API key")
            let requestIdentity = try XCTUnwrap(model.selectedIdentity)
            savedIdentity = requestIdentity
            try await waitUntil { model.canEditVariables(.request(requestIdentity)) }
            XCTAssertTrue(try XCTUnwrap(model.request(for: requestIdentity)).inheritsCollectionAuthentication)

            model.setAuthenticationKind(.apiKey, owner: .request(requestIdentity))
            model.updateAPIKeyHeaderName("X-Request-Key", owner: .request(requestIdentity))
            try await model.setAuthenticationSecret(
                "synthetic request API key",
                field: .apiKey,
                owner: .request(requestIdentity)
            )

            model.updateAPIKeyHeaderName("X-Collection-Key-Edited", owner: .collection(collectionID))
            try await model.setAuthenticationSecret(
                "synthetic collection API key edited",
                field: .apiKey,
                owner: .collection(collectionID)
            )
            model.updateAPIKeyHeaderName("X-Request-Key-Edited", owner: .request(requestIdentity))
            try await model.setAuthenticationSecret(
                "synthetic request API key edited",
                field: .apiKey,
                owner: .request(requestIdentity)
            )
            try await model.flushPendingSaves()

            let collectionPath = root.appendingPathComponent(
                "data/collections/\(collectionID.uuidString.lowercased())/collection.json"
            )
            let collectionJSON = try String(contentsOf: collectionPath, encoding: .utf8)
            let requestJSON = try String(
                contentsOf: requestFileURL(root: root, identity: requestIdentity),
                encoding: .utf8
            )
            XCTAssertFalse(collectionJSON.contains("synthetic collection API key"))
            XCTAssertFalse(collectionJSON.contains("synthetic collection API key edited"))
            XCTAssertFalse(requestJSON.contains("synthetic request API key"))
            XCTAssertFalse(requestJSON.contains("synthetic request API key edited"))
            XCTAssertEqual(
                model.authentication(for: .collection(collectionID)).apiKeyHeaderName, "X-Collection-Key-Edited")
            XCTAssertEqual(
                model.authentication(for: .request(requestIdentity)).apiKeyHeaderName, "X-Request-Key-Edited")

            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }

        try await waitUntil { firstModel == nil }
        let requestIdentity = try XCTUnwrap(savedIdentity)
        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil {
            reloaded.request(for: requestIdentity) != nil
                && reloaded.canEditVariables(.collection(requestIdentity.collectionID))
        }

        let collectionAuthentication = reloaded.authentication(for: .collection(requestIdentity.collectionID))
        let requestAuthentication = reloaded.authentication(for: .request(requestIdentity))
        XCTAssertEqual(collectionAuthentication.kind, .apiKey)
        XCTAssertEqual(collectionAuthentication.apiKeyHeaderName, "X-Collection-Key-Edited")
        XCTAssertEqual(requestAuthentication.kind, .apiKey)
        XCTAssertEqual(requestAuthentication.apiKeyHeaderName, "X-Request-Key-Edited")
        XCTAssertFalse(try XCTUnwrap(reloaded.request(for: requestIdentity)).inheritsCollectionAuthentication)

        let collectionSecret = try await reloaded.revealAuthenticationSecret(
            field: .apiKey, owner: .collection(requestIdentity.collectionID))
        let requestSecret = try await reloaded.revealAuthenticationSecret(
            field: .apiKey, owner: .request(requestIdentity))
        XCTAssertEqual(collectionSecret, "synthetic collection API key edited")
        XCTAssertEqual(requestSecret, "synthetic request API key edited")
        let terminated = await reloaded.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    func testSnapshotKeepsFrozenRequestAndSourceAfterEditsDeletionAndRestart() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyStore = AppModelKeyStore()
        let capturedURL = try fixture.url(path: "/echo", query: [URLQueryItem(name: "source", value: "captured")])
        weak var firstModel: AppModel?
        var savedSnapshotID: UUID?
        var savedIdentity: RequestIdentity?
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
            firstModel = model
            try await waitUntil { model.canEditVariables(.global) }

            await model.createCollection(name: "Captured collection")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID, name: "Captured request")
            let identity = try XCTUnwrap(model.selectedIdentity)
            savedIdentity = identity
            model.updateDraft(identity) {
                $0.method = "POST"
                $0.url = capturedURL
                $0.body = "captured request body"
                $0.bodyEnabled = true
            }
            try await model.flushPendingSaves()

            XCTAssertFalse(model.canSaveSnapshot(for: identity))
            model.startRequest(identity)
            try await waitUntil {
                model.activeRuns[identity] == nil && model.latestResponses[identity]?.response.statusCode == 200
            }
            XCTAssertTrue(model.canSaveSnapshot(for: identity))

            await model.renameCollection(id: collectionID, name: "Edited collection")
            model.updateDraft(identity) {
                $0.name = "Edited request"
                $0.url = fixture.baseURL + "/echo?source=edited"
                $0.body = "edited request body"
            }
            try await model.flushPendingSaves()

            model.saveSnapshot(for: identity)
            try await waitUntil { model.snapshots.count == 1 && model.savingSnapshotRunIDs.isEmpty }
            let saved = try XCTUnwrap(model.snapshots.first)
            savedSnapshotID = saved.id
            XCTAssertEqual(saved.source.collectionName, "Captured collection")
            XCTAssertEqual(saved.source.requestName, "Captured request")

            model.selectSnapshot(saved.id)
            try await waitUntil { model.openedSnapshots[saved.id] != nil }
            let opened = try XCTUnwrap(model.openedSnapshots[saved.id])
            XCTAssertEqual(opened.template.method, "POST")
            XCTAssertEqual(opened.template.url, capturedURL)
            XCTAssertEqual(opened.template.body, "captured request body")
            XCTAssertEqual(opened.response.finalURL.absoluteString, capturedURL)

            await model.renameSnapshot(id: saved.id, name: "Reviewed exchange")
            XCTAssertEqual(model.snapshots.first?.name, "Reviewed exchange")
            XCTAssertEqual(model.openedSnapshots[saved.id]?.summary.name, "Reviewed exchange")

            await model.deleteRequest(identity)
            XCTAssertNil(model.request(for: identity))
            XCTAssertEqual(model.selectedSnapshotID, saved.id)
            XCTAssertEqual(model.snapshots(for: identity).map(\.id), [saved.id])
            XCTAssertEqual(model.snapshots.first?.source.collectionName, "Captured collection")

            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }
        try await waitUntil { firstModel == nil }

        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: keyStore))
        try await waitUntil {
            reloaded.snapshots.count == 1 || reloaded.snapshotLoadError != nil || reloaded.startupError != nil
        }
        XCTAssertNil(reloaded.startupError)
        XCTAssertNil(reloaded.snapshotLoadError)
        XCTAssertTrue(reloaded.snapshotStorageIssues.isEmpty)
        XCTAssertTrue(reloaded.canEditVariables(.global))
        XCTAssertTrue(reloaded.collections.first?.requests.isEmpty ?? true)
        let reloadedSummary = try XCTUnwrap(reloaded.snapshots.first)
        XCTAssertEqual(reloadedSummary.name, "Reviewed exchange")
        XCTAssertEqual(reloadedSummary.source.collectionName, "Captured collection")
        XCTAssertEqual(reloadedSummary.source.requestName, "Captured request")

        let snapshotID = try XCTUnwrap(savedSnapshotID)
        let identity = try XCTUnwrap(savedIdentity)
        reloaded.selectSnapshot(snapshotID)
        try await waitUntil {
            reloaded.openedSnapshots[snapshotID] != nil || reloaded.snapshotOpenError(for: snapshotID) != nil
        }
        XCTAssertNil(reloaded.snapshotOpenError(for: snapshotID))
        let reloadedSnapshot = try XCTUnwrap(reloaded.openedSnapshots[snapshotID])
        XCTAssertEqual(reloadedSnapshot.template.url, capturedURL)
        XCTAssertNotNil(reloadedSnapshot.context)
        XCTAssertEqual(reloadedSnapshot.response.statusCode, 200)
        let responseBody = try Data(contentsOf: reloadedSnapshot.response.bodyFileURL)
        let responseJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: responseBody) as? [String: Any])
        XCTAssertEqual(responseJSON["method"] as? String, "POST")
        XCTAssertEqual(responseJSON["body"] as? String, "captured request body")

        await reloaded.deleteSnapshot(id: snapshotID)
        XCTAssertTrue(reloaded.snapshots.isEmpty)
        XCTAssertNil(reloaded.selectedSnapshotID)
        XCTAssertEqual(reloaded.snapshots(for: identity), [])
        let reloadedTerminated = await reloaded.prepareForTermination()
        XCTAssertTrue(reloadedTerminated)
    }

    func testSnapshotCiphertextBlocksReplacementKeyAfterDeletingSourceCollection() async throws {
        let fixture = try AppHTTPFixture()
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceKeyStore = AppModelKeyStore()
        weak var sourceModel: AppModel?
        var savedSnapshotID: UUID?
        do {
            let model = try makeModel(root: root, secretVault: SecretVault(keyStore: sourceKeyStore))
            sourceModel = model
            try await waitUntil { model.canEditVariables(.global) }

            await model.createCollection(name: "Encrypted source")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID, name: "Credential request")
            let identity = try XCTUnwrap(model.selectedIdentity)
            try await model.setVariable(
                name: "token",
                value: "synthetic snapshot credential",
                isSecret: true,
                owner: .request(identity)
            )
            model.updateDraft(identity) {
                $0.url = fixture.baseURL + "/presentation"
                $0.headers = [HTTPField(name: "X-Snapshot-Token", value: "{{token}}")]
            }
            try await model.flushPendingSaves()

            model.startRequest(identity)
            try await waitUntil {
                model.activeRuns[identity] == nil && model.latestResponses[identity]?.response.statusCode == 200
            }
            model.saveSnapshot(for: identity)
            try await waitUntil { model.snapshots.count == 1 && model.savingSnapshotRunIDs.isEmpty }
            let snapshotID = try XCTUnwrap(model.snapshots.first?.id)
            savedSnapshotID = snapshotID

            await model.deleteCollection(id: collectionID)
            XCTAssertTrue(model.collections.isEmpty)
            XCTAssertEqual(model.snapshots.map(\.id), [snapshotID])
            let terminated = await model.prepareForTermination()
            XCTAssertTrue(terminated)
        }
        try await waitUntil { sourceModel == nil }

        let missingKeyStore = MissingCollectionKeyStore()
        let reloaded = try makeModel(root: root, secretVault: SecretVault(keyStore: missingKeyStore))
        try await waitUntil {
            reloaded.snapshots.count == 1 || reloaded.snapshotLoadError != nil || reloaded.startupError != nil
        }
        XCTAssertNil(reloaded.startupError)
        XCTAssertNil(reloaded.snapshotLoadError)
        XCTAssertTrue(reloaded.snapshotStorageIssues.isEmpty)
        XCTAssertTrue(reloaded.canEditVariables(.global))
        XCTAssertTrue(reloaded.collections.isEmpty)
        XCTAssertEqual(missingKeyStore.creationCount, 0)

        let snapshotID = try XCTUnwrap(savedSnapshotID)
        reloaded.selectSnapshot(snapshotID)
        try await waitUntil {
            reloaded.openedSnapshots[snapshotID] != nil || reloaded.snapshotOpenError(for: snapshotID) != nil
        }
        XCTAssertNil(reloaded.snapshotOpenError(for: snapshotID))
        let opened = try XCTUnwrap(reloaded.openedSnapshots[snapshotID])
        XCTAssertNil(opened.context)
        XCTAssertNotNil(opened.contextError)
        XCTAssertEqual(opened.response.statusCode, 200)
        XCTAssertEqual(opened.response.finalURL.absoluteString, "about:blank")

        try reloaded.setPlainVariable(name: "replacement", value: "synthetic", owner: .global)
        do {
            try await reloaded.setVariableSecret(true, named: "replacement", owner: .global)
            XCTFail("Snapshot ciphertext must prevent replacement-key creation after source deletion.")
        } catch {
            XCTAssertEqual(error as? SecretVaultError, .keyCreationNotAllowed)
        }
        XCTAssertEqual(missingKeyStore.creationCount, 0)
        XCTAssertEqual(reloaded.globalVariables["replacement"], .plain("synthetic"))
        let reloadedTerminated = await reloaded.prepareForTermination()
        XCTAssertTrue(reloadedTerminated)
    }

    private func makeModel(root: URL, secretVault: SecretVault? = nil) throws -> AppModel {
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let bodyDirectory = root.appendingPathComponent("bodies", isDirectory: true)
        return AppModel(
            arguments: [
                "PostieTests",
                "--data-directory", dataDirectory.path,
                "--body-directory", bodyDirectory.path,
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
            process.isRunning
        else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        guard termination.wait(timeout: .now() + .seconds(2)) == .timedOut,
            process.isRunning
        else { return }
        XCTFail("The HTTP fixture process did not terminate after SIGKILL.")
    }

    private enum FixtureError: Error {
        case didNotStart
    }
}
