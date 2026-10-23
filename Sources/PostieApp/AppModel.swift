import Foundation
import Combine
import PostieCore
import PostieAutomation

enum CollectionEditorSection: Hashable {
    case requests, variables, headers, authentication, settings
}

@MainActor
private final class AutomationResultBox<Value> {
    var result: Result<Value, Error>?
}

private struct AutomationResponseProjections: Sendable {
    let fallback: AutomationJSON
    let redacted: AutomationJSON?
    let unredacted: AutomationJSON?

    init(
        response: HTTPResponseRecord,
        bodyURL: URL?,
        context: SnapshotPreparationCapture?,
        mcpMode: MCPResponseViewPolicy?
    ) {
        guard let mcpMode else {
            fallback = ResponseProjection.cliRaw(response: response, bodyURL: bodyURL)
            redacted = nil
            unredacted = nil
            return
        }

        fallback = ResponseProjection.mcpBlocked(response: response, context: context)
        redacted =
            mcpMode == .allow || mcpMode == .unredacted
            ? ResponseProjection.mcpAllowed(response: response, bodyURL: bodyURL, context: context)
            : nil
        unredacted =
            mcpMode == .unredacted
            ? ResponseProjection.mcpUnredacted(response: response, bodyURL: bodyURL)
            : nil
    }

    func response(for mode: MCPResponseViewPolicy) -> AutomationJSON {
        switch mode {
        case .unredacted: unredacted ?? redacted ?? fallback
        case .allow: redacted ?? fallback
        case .block, .inherit: fallback
        }
    }
}

private enum SnapshotSaveFailure: LocalizedError {
    case storageUnavailable
    case bodyUnavailable

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Snapshot storage is unavailable."
        case .bodyUnavailable:
            return "The response body is unavailable."
        }
    }
}

extension AppModel {
    func automationReply(_ command: AutomationCommand, channel: AutomationChannel) async -> AutomationReply {
        guard !workspaceMutationIsBlocked, workspaceLoaded else {
            return AutomationReply(
                id: command.id, error: AutomationFailure(.unavailable, "The workspace is unavailable."))
        }

        do {
            let result = try await performAutomationOperation(command, channel: channel)
            return AutomationReply(id: command.id, result: result)
        } catch let failure as AutomationFailure {
            return AutomationReply(id: command.id, error: failure)
        } catch {
            return AutomationReply(
                id: command.id, error: AutomationFailure(.storageFailure, "The operation could not be completed."))
        }
    }

    private func performAutomationOperation(
        _ command: AutomationCommand,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        switch command.operation {
        case .collectionsList:
            _ = try AutomationArguments(command.arguments, allowed: [])
            return .array(
                collections.compactMap { collection in
                    if isMCP(channel), collection.mcpPolicy.excluded { return nil }
                    return collectionJSON(collection)
                })

        case .requestsList:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "query"])
            let collectionID = try automationCollectionID(arguments, channel: channel, required: false)
            let query = try arguments.string("query", required: false) ?? ""
            let visibleCollections: [RequestCollection]
            if let collectionID {
                visibleCollections = [try requireCollection(collectionID, channel: channel)]
            } else {
                visibleCollections = collections.filter { collection in
                    !isMCP(channel) || !collection.mcpPolicy.excluded
                }
            }
            return .array(
                visibleCollections.flatMap { collection in
                    collection.requests.compactMap { loadedRequest in
                        let identity = RequestIdentity(collectionID: collection.id, requestID: loadedRequest.id)
                        let request = drafts[identity] ?? loadedRequest
                        if isMCP(channel), request.mcpPolicy.excluded { return nil }
                        guard RequestDiscovery.matches(request, query: query) else { return nil }
                        return requestSummaryJSON(request, in: collection, channel: channel)
                    }
                })

        case .requestsGet:
            let identity = try requestIdentity(command.arguments, channel: channel)
            let (collection, request) = try requireRequest(identity, channel: channel)
            return requestJSON(request, in: collection, channel: channel)

        case .requestsCreate:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "request"])
            guard let collectionID = try automationCollectionID(arguments, channel: channel),
                let patch = arguments.value("request")
            else {
                throw AutomationFailure(.invalidArguments, "Missing request fields.")
            }
            return try await createAutomationRequest(patch, in: collectionID, channel: channel)

        case .requestsUpdate:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "requestID", "request"])
            guard let collectionID = try automationCollectionID(arguments, channel: channel),
                let requestID = try arguments.uuid("requestID"),
                let patch = arguments.value("request")
            else {
                throw AutomationFailure(.invalidArguments, "Missing request fields.")
            }
            let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
            return try await updateAutomationRequest(identity, with: patch, channel: channel)

        case .requestsStart:
            let identity = try requestIdentity(command.arguments, channel: channel)
            let _ = try requireRequest(identity, channel: channel)
            guard canEdit(identity), activeRuns[identity] == nil else {
                throw AutomationFailure(.conflict, "The request cannot start in its current state.")
            }
            startRequest(identity)
            guard let active = activeRuns[identity] else {
                throw AutomationFailure(.unavailable, "The request could not start.")
            }
            return runStartJSON(active, identity: identity)

        case .runsList:
            _ = try AutomationArguments(command.arguments, allowed: [])
            return .array(
                activeRuns.keys.sorted(by: requestIdentitySort).compactMap { identity in
                    guard let active = activeRuns[identity], isAccessibleRun(identity, channel: channel) else {
                        return nil
                    }
                    return activeRunJSON(active, identity: identity, channel: channel)
                })

        case .runsGet:
            let arguments = try AutomationArguments(command.arguments, allowed: ["runID"])
            guard let token = try arguments.uuid("runID") else {
                throw AutomationFailure(.invalidArguments, "Missing runID.")
            }
            return try await automationRunJSON(token: token, channel: channel)

        case .runsCancel:
            let arguments = try AutomationArguments(command.arguments, allowed: ["runID"])
            guard let token = try arguments.uuid("runID") else {
                throw AutomationFailure(.invalidArguments, "Missing runID.")
            }
            return try cancelAutomationRun(token: token, channel: channel)

        case .variablesList:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "requestID"])
            let scope = try variableScope(arguments, channel: channel)
            return variableListJSON(scope)

        case .variablesGet:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "requestID", "name"])
            guard let name = try arguments.string("name") else {
                throw AutomationFailure(.invalidArguments, "Missing name.")
            }
            let scope = try variableScope(arguments, channel: channel)
            guard let value = variables(for: scope.owner)[name] else {
                throw AutomationFailure(.notFound, "The variable was not found.")
            }
            guard case .plain(let plainValue) = value else {
                throw AutomationFailure(.forbidden, "Secret variables cannot be read directly.")
            }
            return .object([
                "name": .string(name),
                "scope": .string(scope.label),
                "secret": .bool(false),
                "value": .string(plainValue),
            ])

        case .snapshotsList:
            let arguments = try AutomationArguments(
                command.arguments, allowed: ["collectionID", "collectionName", "requestID"])
            try requireMCPWorkspaceIndex(channel)
            let scope = try optionalRequestScope(arguments, channel: channel)
            let matching = snapshots.filter { snapshot in
                if let scope {
                    let identity = snapshotGrouping(for: snapshot).identity
                    if let requestIdentity = scope.identity, identity != requestIdentity { return false }
                    if scope.identity == nil, identity.collectionID != scope.collectionID { return false }
                }
                return !isMCP(channel) || !snapshotIsMCPExcluded(snapshot)
            }
            return .array(matching.map(snapshotJSON))

        case .snapshotsGet:
            let arguments = try AutomationArguments(command.arguments, allowed: ["snapshotID"])
            guard let id = try arguments.uuid("snapshotID") else {
                throw AutomationFailure(.invalidArguments, "Missing snapshotID.")
            }
            return try await openAutomationSnapshot(id: id, channel: channel)

        case .snapshotsCreate:
            let arguments = try AutomationArguments(command.arguments, allowed: ["runID", "name"])
            guard let token = try arguments.uuid("runID"),
                let outcome = automationRunOutcome(token: token)
            else {
                throw AutomationFailure(.notFound, "The run handle is no longer available.")
            }
            let name = try arguments.string("name", required: false)
            return try await createAutomationSnapshot(outcome: outcome, name: name, channel: channel)

        case .snapshotsRename:
            let arguments = try AutomationArguments(command.arguments, allowed: ["snapshotID", "name"])
            guard let id = try arguments.uuid("snapshotID"),
                let name = try arguments.string("name")
            else {
                throw AutomationFailure(.invalidArguments, "Missing snapshot fields.")
            }
            return try await renameAutomationSnapshot(id: id, name: name, channel: channel)

        case .snapshotsDelete:
            let arguments = try AutomationArguments(command.arguments, allowed: ["snapshotID"])
            guard let id = try arguments.uuid("snapshotID") else {
                throw AutomationFailure(.invalidArguments, "Missing snapshotID.")
            }
            return try await deleteAutomationSnapshot(id: id, channel: channel)
        }
    }

    private func requestIdentity(
        _ values: [String: AutomationJSON],
        channel: AutomationChannel
    ) throws -> RequestIdentity {
        let arguments = try AutomationArguments(values, allowed: ["collectionID", "collectionName", "requestID"])
        guard let collectionID = try automationCollectionID(arguments, channel: channel),
            let requestID = try arguments.uuid("requestID")
        else {
            throw AutomationFailure(.invalidArguments, "Missing request identity.")
        }
        return RequestIdentity(collectionID: collectionID, requestID: requestID)
    }

    private func automationCollectionID(
        _ arguments: AutomationArguments,
        channel: AutomationChannel,
        required: Bool = true
    ) throws -> UUID? {
        let id = try arguments.uuid("collectionID", required: false)
        let name = try arguments.string("collectionName", required: false)
        guard id == nil || name == nil else {
            throw AutomationFailure(.invalidArguments, "Supply either collectionName or collectionID, not both.")
        }
        if let id { return try requireCollection(id, channel: channel).id }
        guard let name else {
            if required { throw AutomationFailure(.invalidArguments, "Missing collectionName.") }
            return nil
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AutomationFailure(.invalidArguments, "Invalid collectionName.")
        }
        let matches = collections.filter { collection in
            (!isMCP(channel) || !collection.mcpPolicy.excluded)
                && collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(normalizedName, options: .caseInsensitive) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw AutomationFailure(.notFound, "The collection was not found.")
        }
        guard matches.count == 1 else {
            throw AutomationFailure(.conflict, "The collection name is ambiguous. Use a unique collection name.")
        }
        return matches[0].id
    }

    private func requireCollection(_ id: UUID, channel: AutomationChannel) throws -> RequestCollection {
        guard let collection = collections.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The collection was not found.")
        }
        if isMCP(channel), collection.mcpPolicy.excluded {
            throw AutomationFailure(.forbidden, "The collection is excluded from MCP access.")
        }
        return collection
    }

    private func requireRequest(
        _ identity: RequestIdentity,
        channel: AutomationChannel
    ) throws -> (RequestCollection, HTTPRequestConfiguration) {
        let collection = try requireCollection(identity.collectionID, channel: channel)
        guard let request = drafts[identity] else {
            throw AutomationFailure(.notFound, "The request was not found.")
        }
        if isMCP(channel), request.mcpPolicy.excluded {
            throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
        }
        return (collection, request)
    }

    private func isMCP(_ channel: AutomationChannel) -> Bool {
        if case .mcp = channel { return true }
        return false
    }

    private func isAccessibleRun(_ identity: RequestIdentity, channel: AutomationChannel) -> Bool {
        guard isMCP(channel) else { return true }
        if let collection = collections.first(where: { $0.id == identity.collectionID }), collection.mcpPolicy.excluded
        {
            return false
        }
        if let request = drafts[identity], request.mcpPolicy.excluded { return false }
        return true
    }

    private func requireAccessibleRun(_ outcome: AutomationRunOutcome, channel: AutomationChannel) throws {
        if isMCP(channel), runIsMCPExcluded(outcome) || !isAccessibleRun(outcome.identity, channel: channel) {
            throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
        }
    }

    private func retainedRunOutcome(_ token: UUID) throws -> AutomationRunOutcome {
        guard let outcome = automationRunOutcome(token: token) else {
            throw AutomationFailure(.notFound, "The run handle was not found.")
        }
        return outcome
    }

    private func runIsMCPExcluded(_ outcome: AutomationRunOutcome) -> Bool {
        guard let collection = collections.first(where: { $0.id == outcome.identity.collectionID }) else {
            return outcome.mcpAccessExcluded
        }
        if collection.mcpPolicy.excluded { return true }
        guard let request = drafts[outcome.identity] else { return outcome.mcpAccessExcluded }
        return request.mcpPolicy.excluded
    }

    private func collectionJSON(_ collection: RequestCollection) -> AutomationJSON {
        .object([
            "collectionID": .string(collection.id.uuidString),
            "name": .string(collection.name),
            "requestCount": integer(collection.requests.count),
        ])
    }

    private func requestSummaryJSON(
        _ request: HTTPRequestConfiguration,
        in collection: RequestCollection,
        channel: AutomationChannel
    ) -> AutomationJSON {
        .object([
            "collectionID": .string(collection.id.uuidString),
            "collectionName": .string(collection.name),
            "requestID": .string(request.id.uuidString),
            "name": .string(request.name),
            "method": .string(request.method),
            "url": .string(QueryParameters.render(baseURL: request.url, fields: request.query)),
        ])
    }

    private func requestJSON(
        _ request: HTTPRequestConfiguration,
        in collection: RequestCollection,
        channel: AutomationChannel
    ) -> AutomationJSON {
        var result = requestSummaryJSON(request, in: collection, channel: channel).objectValue ?? [:]
        result["pathParameters"] = .array(request.pathParameters.map { httpFieldJSON($0, channel: channel) })
        result["query"] = .array(request.query.map { httpFieldJSON($0, channel: channel) })
        let sensitiveHeaderNames = Set(
            ["authorization", "proxy-authorization", "cookie", "cookie2"]
                + [request.authentication.apiKeyHeaderName, collection.authentication.apiKeyHeaderName]
                .compactMap { $0?.lowercased() }
        )
        result["headers"] = .array(
            request.headers.map { httpFieldJSON($0, sensitiveHeaderNames: sensitiveHeaderNames, channel: channel) })
        result["body"] = .string(request.body)
        result["bodyEnabled"] = .bool(request.bodyEnabled)
        result["bodySyntax"] = .string(request.bodySyntax.rawValue)
        result["bodyKind"] = .string(request.bodyKind.rawValue)
        result["rawFile"] = request.rawFile.flatMap { try? automationJSON($0) } ?? .null
        result["multipartParts"] = .array(
            request.multipartParts.map { part in
                .object([
                    "name": .string(part.name), "kind": .string(part.kind.rawValue),
                    "text": .string(part.text),
                    "file": part.file.flatMap { try? automationJSON($0) } ?? .null,
                    "isEnabled": .bool(part.isEnabled),
                ])
            })
        result["optionOverrides"] = (try? automationJSON(request.optionOverrides ?? .init())) ?? .object([:])
        result["inheritsCollectionAuthentication"] = .bool(request.inheritsCollectionAuthentication)
        result["authentication"] = .object([
            "kind": .string(request.authentication.kind.rawValue),
            "username": .string(request.authentication.username),
            "apiKeyHeaderName": request.authentication.apiKeyHeaderName.map(AutomationJSON.string) ?? .null,
            "hasPassword": .bool(request.authentication.password != nil),
            "hasToken": .bool(request.authentication.token != nil),
            "hasAPIKey": .bool(request.authentication.apiKey != nil),
        ])
        return .object(result)
    }

    private func httpFieldJSON(
        _ field: HTTPField,
        sensitiveHeaderNames: Set<String> = [],
        channel: AutomationChannel = .cli
    ) -> AutomationJSON {
        let isSensitiveHeader = sensitiveHeaderNames.contains(field.name.lowercased())
        let value =
            isMCP(channel) && isSensitiveHeader && !containsOnlyTemplateReferencesAndScheme(field.value)
            ? SecretRetemplating.redaction
            : field.value
        return .object([
            "name": .string(field.name),
            "value": .string(value),
            "isEnabled": .bool(field.isEnabled),
        ])
    }

    private func containsOnlyTemplateReferencesAndScheme(_ value: String) -> Bool {
        let scan = TemplateEngine.scan(value)
        guard !scan.references.isEmpty, scan.invalidRanges.isEmpty else { return false }
        let text = value as NSString
        var cursor = 0
        var sawReference = false
        for reference in scan.references {
            let literal = text.substring(with: NSRange(location: cursor, length: reference.range.location - cursor))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !literal.isEmpty {
                if !sawReference, ["bearer", "basic"].contains(literal.lowercased()) {
                    sawReference = true
                } else if sawReference, literal.allSatisfy({ $0 == ":" }) {
                    continue
                } else {
                    return false
                }
            }
            sawReference = true
            cursor = NSMaxRange(reference.range)
        }
        let suffix = text.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty || suffix.allSatisfy { $0 == ":" }
    }

    private func integer(_ value: Int) -> AutomationJSON {
        .number(Decimal(value))
    }

    private func automationJSON<Value: Encodable>(_ value: Value) throws -> AutomationJSON {
        try JSONDecoder().decode(AutomationJSON.self, from: JSONEncoder().encode(value))
    }

    private func requestIdentitySort(_ left: RequestIdentity, _ right: RequestIdentity) -> Bool {
        if left.collectionID != right.collectionID {
            return left.collectionID.uuidString < right.collectionID.uuidString
        }
        return left.requestID.uuidString < right.requestID.uuidString
    }

    private func canContinueAutomationRequestUpdate(_ identity: RequestIdentity) -> Bool {
        guard !workspaceMutationIsBlocked,
            let collection = collection(for: identity), !collection.isReadOnly,
            drafts[identity] != nil,
            activeRuns[identity] == nil,
            !deletingCollections.contains(identity.collectionID),
            !deletingRequests.contains(identity),
            !movingRequests.contains(identity),
            !reconcilingRequests.contains(identity)
        else { return false }
        return true
    }

    private func createAutomationRequest(
        _ patch: AutomationJSON,
        in collectionID: UUID,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        let result = AutomationResultBox<AutomationJSON>()
        await withCollectionMutation(collectionID) { [weak self] in
            guard let self else {
                result.result = .failure(AutomationFailure(.unavailable, "The workspace is unavailable."))
                return
            }
            do {
                let collection = try self.requireCollection(collectionID, channel: channel)
                guard !self.isTerminating, !collection.isReadOnly,
                    !self.deletingCollections.contains(collectionID), let store = self.store
                else {
                    throw AutomationFailure(.conflict, "The collection cannot be changed in its current state.")
                }
                var request = HTTPRequestConfiguration()
                request.inheritsCollectionAuthentication = true
                request.optionOverrides = HTTPOptionsOverrides()
                let vault = self.secretVault
                request = try await RequestPatch.apply(patch, to: request) { value in
                    try await vault.encrypt(value)
                }
                let currentCollection = try self.requireCollection(collectionID, channel: channel)
                guard !self.isTerminating, !currentCollection.isReadOnly,
                    !self.deletingCollections.contains(collectionID)
                else {
                    throw AutomationFailure(.conflict, "The collection cannot be changed in its current state.")
                }
                try await store.createRequest(request, in: collectionID)
                guard !self.isTerminating, !self.deletingCollections.contains(collectionID) else {
                    throw AutomationFailure(.conflict, "The collection changed while the request was being created.")
                }
                var outputCollection = collection
                if var updatedCollection = self.collections.first(where: { $0.id == collectionID }) {
                    updatedCollection.requests.append(request)
                    self.replaceCollection(updatedCollection)
                    outputCollection = updatedCollection
                }
                let identity = RequestIdentity(collectionID: collectionID, requestID: request.id)
                self.drafts[identity] = request
                self.editVersions[identity] = 0
                self.markWorkspaceChanged()
                let (_, savedRequest) = try self.requireRequest(identity, channel: channel)
                outputCollection = self.collections.first(where: { $0.id == collectionID }) ?? outputCollection
                result.result = .success(self.requestJSON(savedRequest, in: outputCollection, channel: channel))
            } catch {
                result.result = .failure(error)
            }
        }
        guard let operation = result.result else {
            throw AutomationFailure(.unavailable, "The request could not be created.")
        }
        return try operation.get()
    }

    private func updateAutomationRequest(
        _ identity: RequestIdentity,
        with patch: AutomationJSON,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        let (_, _) = try requireRequest(identity, channel: channel)
        guard canEdit(identity), activeRuns[identity] == nil,
            !movingRequests.contains(identity), !deletingRequests.contains(identity),
            !deletingCollections.contains(identity.collectionID)
        else {
            throw AutomationFailure(.conflict, "The request cannot be changed in its current state.")
        }
        automationEditingRequests.insert(identity)
        defer { automationEditingRequests.remove(identity) }

        let result = AutomationResultBox<AutomationJSON>()
        await withCollectionMutation(identity.collectionID) { [weak self] in
            guard let self else {
                result.result = .failure(AutomationFailure(.unavailable, "The workspace is unavailable."))
                return
            }
            do {
                let (_, original) = try self.requireRequest(identity, channel: channel)
                guard self.canContinueAutomationRequestUpdate(identity),
                    let store = self.store
                else {
                    throw AutomationFailure(.conflict, "The request cannot be changed in its current state.")
                }
                await self.waitForSecretEdits(owner: .request(identity))
                try await self.flushRequestSaves(for: identity)
                let current = self.drafts[identity] ?? original
                let vault = self.secretVault
                var updated = try await RequestPatch.apply(patch, to: current) { value in
                    try await vault.encrypt(value)
                }
                updated.id = identity.requestID
                let (_, latest) = try self.requireRequest(identity, channel: channel)
                guard self.canContinueAutomationRequestUpdate(identity) else {
                    throw AutomationFailure(.conflict, "The request cannot be changed in its current state.")
                }
                updated.mcpPolicy = latest.mcpPolicy
                try await store.saveRequest(updated, in: identity.collectionID)
                let (_, latestAfterSave) = try self.requireRequest(identity, channel: channel)
                guard self.canContinueAutomationRequestUpdate(identity) else {
                    throw AutomationFailure(.conflict, "The request changed while it was being saved.")
                }
                guard latestAfterSave.mcpPolicy == updated.mcpPolicy else {
                    throw AutomationFailure(.conflict, "The request policy changed while it was being saved.")
                }
                self.drafts[identity] = updated
                if var currentCollection = self.collections.first(where: { $0.id == identity.collectionID }),
                    let index = currentCollection.requests.firstIndex(where: { $0.id == identity.requestID })
                {
                    currentCollection.requests[index] = updated
                    self.replaceCollection(currentCollection)
                }
                let (latestCollection, savedRequest) = try self.requireRequest(identity, channel: channel)
                guard self.canContinueAutomationRequestUpdate(identity) else {
                    throw AutomationFailure(.conflict, "The request changed while it was being saved.")
                }
                self.markWorkspaceChanged()
                result.result = .success(self.requestJSON(savedRequest, in: latestCollection, channel: channel))
            } catch {
                result.result = .failure(error)
            }
        }
        guard let operation = result.result else {
            throw AutomationFailure(.unavailable, "The request could not be updated.")
        }
        return try operation.get()
    }

    private struct AutomationVariableScope {
        let owner: VariableOwner
        let label: String
    }

    private func variableScope(
        _ arguments: AutomationArguments,
        channel: AutomationChannel
    ) throws -> AutomationVariableScope {
        guard let scope = try optionalVariableScope(arguments, channel: channel) else {
            return AutomationVariableScope(owner: .global, label: "global")
        }
        return scope
    }

    private func optionalVariableScope(
        _ arguments: AutomationArguments,
        channel: AutomationChannel
    ) throws -> AutomationVariableScope? {
        let collectionID = try automationCollectionID(arguments, channel: channel, required: false)
        let requestID = try arguments.uuid("requestID", required: false)
        guard requestID == nil || collectionID != nil else {
            throw AutomationFailure(.invalidArguments, "requestID requires collectionName or collectionID.")
        }
        guard let collectionID else { return nil }
        _ = try requireCollection(collectionID, channel: channel)
        guard let requestID else {
            return AutomationVariableScope(owner: .collection(collectionID), label: "collection")
        }
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        let (_, _) = try requireRequest(identity, channel: channel)
        return AutomationVariableScope(owner: .request(identity), label: "request")
    }

    private func optionalRequestScope(
        _ arguments: AutomationArguments,
        channel: AutomationChannel
    ) throws -> (collectionID: UUID, identity: RequestIdentity?)? {
        let collectionID = try automationCollectionID(arguments, channel: channel, required: false)
        let requestID = try arguments.uuid("requestID", required: false)
        guard requestID == nil || collectionID != nil else {
            throw AutomationFailure(.invalidArguments, "requestID requires collectionName or collectionID.")
        }
        guard let collectionID else { return nil }
        _ = try requireCollection(collectionID, channel: channel)
        guard let requestID else { return (collectionID, nil) }
        let identity = RequestIdentity(collectionID: collectionID, requestID: requestID)
        _ = try requireRequest(identity, channel: channel)
        return (collectionID, identity)
    }

    private func variableListJSON(_ scope: AutomationVariableScope?) -> AutomationJSON {
        let effectiveScope = scope ?? AutomationVariableScope(owner: .global, label: "global")
        let variables = self.variables(for: effectiveScope.owner)
        return .array(
            variables.keys.sorted().compactMap { name in
                guard let value = variables[name] else { return nil }
                if case .plain(let plainValue) = value {
                    return .object([
                        "name": .string(name),
                        "scope": .string(effectiveScope.label),
                        "secret": .bool(false),
                        "value": .string(plainValue),
                    ])
                }
                return .object([
                    "name": .string(name),
                    "scope": .string(effectiveScope.label),
                    "secret": .bool(true),
                    "value": .null,
                ])
            })
    }

    private func runStartJSON(_ active: ActiveRun, identity: RequestIdentity) -> AutomationJSON {
        .object([
            "runID": .string(active.token.uuidString),
            "state": .string("preparing"),
            "collectionID": .string(identity.collectionID.uuidString),
            "requestID": .string(identity.requestID.uuidString),
        ])
    }

    private func activeRunJSON(
        _ active: ActiveRun,
        identity: RequestIdentity,
        channel: AutomationChannel
    ) -> AutomationJSON {
        let state: String
        switch active.phase {
        case .preparing: state = "preparing"
        case .running: state = "running"
        case .cancelling: state = "cancelling"
        }
        let elapsed = max(0, Date().timeIntervalSince(active.startedAt))
        let progress =
            active.progress.map { progress in
                AutomationJSON.object([
                    "receivedBytes": .number(Decimal(max(0, progress.receivedBytes))),
                    "expectedBytes": progress.expectedBytes.map { .number(Decimal(max(0, $0))) } ?? .null,
                ])
            } ?? .null
        let redirects =
            isMCP(channel)
            ? ResponseProjection.mcpRedirects(
                active.redirects,
                context: active.snapshotCapture,
                mode: responseViewingMode(for: identity)
            )
            : ResponseProjection.cliRedirects(active.redirects)
        return .object([
            "runID": .string(active.token.uuidString),
            "state": .string(state),
            "collectionID": .string(identity.collectionID.uuidString),
            "requestID": .string(identity.requestID.uuidString),
            "startedAt": .string(iso8601(active.startedAt)),
            "elapsedSeconds": .number(Decimal(elapsed)),
            "progress": progress,
            "redirectCount": integer(active.redirects.count),
            "redirects": redirects,
        ])
    }

    private func automationRunOutcome(token: UUID) -> AutomationRunOutcome? {
        automationRunOutcomes.values.first { $0.token == token }
    }

    private func automationRunJSON(token: UUID, channel: AutomationChannel) async throws -> AutomationJSON {
        if let (identity, active) = activeRuns.first(where: { $0.value.token == token }) {
            guard isAccessibleRun(identity, channel: channel) else {
                throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
            }
            return activeRunJSON(active, identity: identity, channel: channel)
        }

        guard let outcome = automationRunOutcome(token: token) else {
            throw AutomationFailure(.notFound, "The run handle was not found.")
        }
        if isMCP(channel), runIsMCPExcluded(outcome) || !isAccessibleRun(outcome.identity, channel: channel) {
            throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
        }

        var result: [String: AutomationJSON] = [
            "runID": .string(outcome.token.uuidString),
            "collectionID": .string(outcome.identity.collectionID.uuidString),
            "requestID": .string(outcome.identity.requestID.uuidString),
            "finishedAt": .string(iso8601(outcome.finishedAt)),
        ]
        switch outcome.terminal {
        case let .completed(response, _):
            result["state"] = .string("completed")
            result["response"] = try await projectLiveResponse(response, outcome: outcome, channel: channel)
        case let .failed(message):
            result["state"] = .string("failed")
            result["error"] =
                isMCP(channel)
                ? ResponseProjection.mcpFailure("Request failed.", context: nil)
                : .string(message)
        case .cancelled:
            result["state"] = .string("cancelled")
        }
        return .object(result)
    }

    private func cancelAutomationRun(token: UUID, channel: AutomationChannel) throws -> AutomationJSON {
        if let (identity, _) = activeRuns.first(where: { $0.value.token == token }) {
            guard isAccessibleRun(identity, channel: channel) else {
                throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
            }
            cancelRequest(identity)
            let state = activeRuns[identity]?.phase == .cancelling ? "cancelling" : "cancelled"
            return .object(["runID": .string(token.uuidString), "state": .string(state)])
        }

        guard let outcome = automationRunOutcome(token: token) else {
            throw AutomationFailure(.notFound, "The run handle was not found.")
        }
        if isMCP(channel), runIsMCPExcluded(outcome) || !isAccessibleRun(outcome.identity, channel: channel) {
            throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
        }
        throw AutomationFailure(.conflict, "The specified run has already ended.")
    }

    private func projectLiveResponse(
        _ response: HTTPResponseRecord,
        outcome: AutomationRunOutcome,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        let capture = response.snapshotCapture
        let isMCPChannel = isMCP(channel)
        try requireAccessibleRun(outcome, channel: channel)
        var mode = responseViewingMode(for: outcome.identity)
        let mayProjectBody = !isMCPChannel || mode != .block
        var bodyURL: URL?
        var lease: HTTPBodyLease?

        if mayProjectBody {
            if let executionManager, let acquired = try? await executionManager.acquireBodyLease(for: response) {
                lease = acquired
                bodyURL = acquired.bodyURL
            } else if isMCPChannel {
                mode = .block
            }
        }

        let projectionMode = isMCPChannel ? mode : nil
        let projectedBodyURL = bodyURL
        let projection = Task.detached(priority: .utility) {
            AutomationResponseProjections(
                response: response, bodyURL: projectedBodyURL, context: capture, mcpMode: projectionMode
            )
        }
        let projected = await projection.value
        if let lease, let executionManager {
            await executionManager.releaseBodyLease(lease)
        }
        let currentOutcome = try retainedRunOutcome(outcome.token)
        try requireAccessibleRun(currentOutcome, channel: channel)

        return projected.response(for: isMCPChannel ? responseViewingMode(for: currentOutcome.identity) : .block)
    }

    private func responseViewingMode(for identity: RequestIdentity) -> MCPResponseViewPolicy {
        let collection = collections.first(where: { $0.id == identity.collectionID })
        let request = drafts[identity] ?? collection?.requests.first(where: { $0.id == identity.requestID })
        return MCPResponseViewPolicy.resolveMode(
            global: globalMCPResponseViewing,
            collection: collection?.mcpPolicy.responseViewing ?? .inherit,
            request: request?.mcpPolicy.responseViewing ?? .inherit
        )
    }

    private func openAutomationSnapshot(id: UUID, channel: AutomationChannel) async throws -> AutomationJSON {
        try requireMCPWorkspaceIndex(channel)
        guard let snapshot = snapshots.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The snapshot was not found.")
        }
        if isMCP(channel), snapshotIsMCPExcluded(snapshot) {
            throw AutomationFailure(.forbidden, "The snapshot is excluded from MCP access.")
        }
        guard let snapshotStore else {
            throw AutomationFailure(.unavailable, "Snapshot storage is unavailable.")
        }

        let opened: OpenedSnapshot
        do {
            opened = try await snapshotStore.open(id: id)
        } catch {
            throw AutomationFailure(.storageFailure, "The snapshot could not be opened.")
        }
        guard let currentSnapshot = snapshots.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The snapshot was not found.")
        }
        try requireAccessibleSnapshot(currentSnapshot, channel: channel)
        let grouping = snapshotGrouping(for: currentSnapshot)
        let mode = isMCP(channel) ? responseViewingMode(for: grouping.identity) : nil
        let response = opened.response
        let context = opened.context?.preparation
        var templateRequest = opened.template.configuration
        templateRequest.id = opened.summary.source.identity.requestID
        templateRequest.name = opened.summary.source.requestName
        let projection = Task.detached(priority: .utility) {
            AutomationResponseProjections(
                response: response, bodyURL: response.bodyFileURL, context: context, mcpMode: mode
            )
        }
        let projections = await projection.value
        guard let latestSnapshot = snapshots.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The snapshot was not found.")
        }
        try requireAccessibleSnapshot(latestSnapshot, channel: channel)
        let latestGrouping = snapshotGrouping(for: latestSnapshot)
        let projected = projections.response(
            for: isMCP(channel) ? responseViewingMode(for: latestGrouping.identity) : .block)
        return .object([
            "snapshot": snapshotJSON(latestSnapshot),
            "grouping": groupingJSON(latestGrouping),
            "request": requestJSON(
                templateRequest,
                in: RequestCollection(
                    id: opened.summary.source.identity.collectionID, name: opened.summary.source.collectionName),
                channel: channel
            ),
            "response": projected,
        ])
    }

    private func createAutomationSnapshot(
        outcome: AutomationRunOutcome,
        name: String?,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        try requireMCPWorkspaceIndex(channel)
        guard isAccessibleRun(outcome.identity, channel: channel),
            !(isMCP(channel) && runIsMCPExcluded(outcome))
        else {
            throw AutomationFailure(.forbidden, "The request is excluded from MCP access.")
        }
        guard case let .completed(response, capturedSource) = outcome.terminal,
            response.snapshotCapture != nil,
            let capturedSource
        else {
            throw AutomationFailure(.conflict, "Only a completed run with captured request context can be saved.")
        }
        guard canEdit(outcome.identity),
            !movingRequests.contains(outcome.identity),
            !deletingRequests.contains(outcome.identity),
            !deletingCollections.contains(outcome.identity.collectionID),
            let collection = collections.first(where: { $0.id == outcome.identity.collectionID }),
            collection.requests.contains(where: { $0.id == outcome.identity.requestID }),
            let request = drafts[outcome.identity]
        else {
            throw AutomationFailure(.conflict, "The request cannot save a snapshot in its current state.")
        }
        guard !workspaceMutationIsBlocked, snapshotStore != nil, executionManager != nil else {
            throw AutomationFailure(.unavailable, "Snapshot storage is unavailable.")
        }
        let normalizedName = name ?? Self.defaultSnapshotName(source: capturedSource, completedAt: response.completedAt)
        guard !normalizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationFailure(.invalidArguments, "Snapshot name cannot be empty.")
        }
        guard !savingSnapshotRunIDs.contains(response.runID) else {
            throw AutomationFailure(.conflict, "A snapshot is already being saved for this run.")
        }

        let source = SnapshotSource(
            identity: outcome.identity,
            collectionName: collection.name,
            requestName: request.name
        )
        let operationID = UUID()
        let result = AutomationResultBox<AutomationJSON>()
        let task = Task { @MainActor [self] in
            do {
                let saved = try await saveSnapshotRecord(
                    response: response,
                    source: source,
                    name: normalizedName,
                    runID: response.runID,
                    operationID: operationID
                )
                result.result = .success(snapshotJSON(saved))
            } catch {
                result.result = .failure(error)
            }
        }
        snapshotSaveTasks[response.runID, default: [:]][operationID] = task
        savingSnapshotRunIDs.insert(response.runID)
        await task.value

        guard let operation = result.result else {
            throw AutomationFailure(.unavailable, "The snapshot could not be saved.")
        }
        do {
            return try operation.get()
        } catch SnapshotSaveFailure.bodyUnavailable {
            throw AutomationFailure(.unavailable, "The response body is unavailable.")
        } catch SnapshotSaveFailure.storageUnavailable {
            throw AutomationFailure(.unavailable, "Snapshot storage is unavailable.")
        } catch {
            throw AutomationFailure(.storageFailure, "The snapshot could not be saved.")
        }
    }

    private func renameAutomationSnapshot(
        id: UUID,
        name: String,
        channel: AutomationChannel
    ) async throws -> AutomationJSON {
        try requireMCPWorkspaceIndex(channel)
        guard let snapshot = snapshots.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The snapshot was not found.")
        }
        if isMCP(channel), snapshotIsMCPExcluded(snapshot) {
            throw AutomationFailure(.forbidden, "The snapshot is excluded from MCP access.")
        }
        guard !workspaceMutationIsBlocked, let snapshotStore else {
            throw AutomationFailure(.unavailable, "Snapshot storage is unavailable.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationFailure(.invalidArguments, "Snapshot name cannot be empty.")
        }

        do {
            let renamed = try await snapshotStore.rename(id: id, name: name)
            upsertSnapshot(renamed)
            return snapshotJSON(renamed)
        } catch {
            throw AutomationFailure(.storageFailure, "The snapshot could not be renamed.")
        }
    }

    private func deleteAutomationSnapshot(id: UUID, channel: AutomationChannel) async throws -> AutomationJSON {
        try requireMCPWorkspaceIndex(channel)
        guard let snapshot = snapshots.first(where: { $0.id == id }) else {
            throw AutomationFailure(.notFound, "The snapshot was not found.")
        }
        if isMCP(channel), snapshotIsMCPExcluded(snapshot) {
            throw AutomationFailure(.forbidden, "The snapshot is excluded from MCP access.")
        }
        guard !workspaceMutationIsBlocked, let snapshotStore else {
            throw AutomationFailure(.unavailable, "Snapshot storage is unavailable.")
        }

        let result = AutomationResultBox<AutomationJSON>()
        await withWorkspaceIndexMutation { [weak self] in
            guard let self else {
                result.result = .failure(AutomationFailure(.unavailable, "The workspace is unavailable."))
                return
            }
            do {
                self.deletingBodySnapshotIDs.insert(id)
                defer { self.deletingBodySnapshotIDs.remove(id) }
                await self.releaseBodyResources(for: .snapshot(id))
                try await snapshotStore.delete(id: id)
                self.markWorkspaceChanged()
                self.snapshots.removeAll { $0.id == id }
                self.openedSnapshots.removeValue(forKey: id)
                self.openingSnapshots.remove(id)
                self.snapshotOpenErrors.removeValue(forKey: id)
                guard let store = self.store else {
                    throw AutomationFailure(
                        .storageFailure, "The snapshot was deleted but workspace metadata could not be updated.")
                }
                do {
                    self.workspaceIndex = try await store.removeSnapshotGrouping(id: id)
                    result.result = .success(.object(["snapshotID": .string(id.uuidString), "deleted": .bool(true)]))
                } catch {
                    self.operationError = "A deleted snapshot's workspace metadata could not be cleared."
                    result.result = .failure(
                        AutomationFailure(
                            .storageFailure, "The snapshot was deleted but workspace metadata could not be updated."))
                }
            } catch {
                result.result = .failure(AutomationFailure(.storageFailure, "The snapshot could not be deleted."))
            }
        }
        guard let operation = result.result else {
            throw AutomationFailure(.unavailable, "The snapshot could not be deleted.")
        }
        return try operation.get()
    }

    private func requireMCPWorkspaceIndex(_ channel: AutomationChannel) throws {
        guard !isMCP(channel) || !workspaceIndexIsReadOnly else {
            throw AutomationFailure(.forbidden, "Snapshot access is unavailable while workspace metadata is read-only.")
        }
    }

    private func requireAccessibleSnapshot(_ snapshot: SavedSnapshot, channel: AutomationChannel) throws {
        try requireMCPWorkspaceIndex(channel)
        if isMCP(channel), snapshotIsMCPExcluded(snapshot) {
            throw AutomationFailure(.forbidden, "The snapshot is excluded from MCP access.")
        }
    }

    private func snapshotJSON(_ snapshot: SavedSnapshot) -> AutomationJSON {
        .object([
            "snapshotID": .string(snapshot.id.uuidString),
            "name": .string(snapshot.name),
            "capturedAt": .string(iso8601(snapshot.capturedAt)),
            "statusCode": integer(snapshot.statusCode),
            "bodyByteCount": .number(Decimal(snapshot.bodyByteCount)),
            "source": .object([
                "collectionID": .string(snapshot.source.identity.collectionID.uuidString),
                "requestID": .string(snapshot.source.identity.requestID.uuidString),
                "collectionName": .string(snapshot.source.collectionName),
                "requestName": .string(snapshot.source.requestName),
            ]),
        ])
    }

    private func groupingJSON(_ grouping: SnapshotGrouping) -> AutomationJSON {
        .object([
            "collectionID": .string(grouping.identity.collectionID.uuidString),
            "requestID": .string(grouping.identity.requestID.uuidString),
            "collectionName": .string(grouping.collectionName),
            "requestName": .string(grouping.requestName),
        ])
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func requestScope(
        _ arguments: AutomationArguments,
        channel: AutomationChannel
    ) throws -> (collectionID: UUID, identity: RequestIdentity?)? {
        try optionalRequestScope(arguments, channel: channel)
    }

}

enum RequestEditorSection: Hashable {
    case request, authentication, variables, settings
}

struct VariableDefinitionRequest: Identifiable {
    let id = UUID()
    let owner: VariableOwner
    let name: String
}

private enum EncryptionKeyTransferError: LocalizedError {
    case workspaceUnavailable
    case storageNeedsRepair
    case workspaceChanged

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace could not be checked for encrypted values."
        case .storageNeedsRepair:
            "Key import is unavailable while workspace or snapshot storage has unresolved issues."
        case .workspaceChanged:
            "The workspace changed during key import. Try again."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let sessionHistory = SessionExecutionStore()

    struct ActiveRun {
        enum Phase: Equatable {
            case preparing
            case running
            case cancelling
        }

        let token: UUID
        let request: HTTPRequestConfiguration
        let snapshotSource: SnapshotSource?
        var snapshotCapture: SnapshotPreparationCapture? = nil
        let startedAt: Date
        var phase: Phase
        var runID: UUID?
        var progress: HTTPProgress?
        var redirects: [HTTPRedirect]
        var cancelRequested: Bool
    }

    struct LatestResponse {
        let response: HTTPResponseRecord
        let snapshotSource: SnapshotSource?
        var preview: BodyPreview?
        var previewError: String?
        var isLoadingPreview: Bool
    }

    private enum AutomationRunTerminal {
        case completed(HTTPResponseRecord, SnapshotSource?)
        case failed(String)
        case cancelled
    }

    private struct AutomationRunOutcome {
        let token: UUID
        var identity: RequestIdentity
        let terminal: AutomationRunTerminal
        let finishedAt: Date
        var mcpAccessExcluded: Bool
    }

    @Published private(set) var globalVariables: VariableValues = [:]
    @Published private(set) var globalVariablesAreReadOnly = true
    @Published private(set) var globalOptions = HTTPOptions()
    @Published private(set) var globalOptionsAreReadOnly = true
    @Published private(set) var workspaceIndex = WorkspaceIndex()
    @Published private(set) var workspaceIndexIsReadOnly = false
    @Published private(set) var globalMCPResponseViewing: MCPResponseViewPolicy = .block
    @Published private(set) var showsGlobalSettings = false
    @Published private(set) var variableSaveErrors: [VariableOwner: String] = [:]
    @Published private(set) var showsGlobalVariables = false
    @Published var showsRequestSearch = false
    @Published var workspaceSearchQuery = ""
    @Published private(set) var workspaceSearchFocusRequestID = UUID()
    @Published private(set) var collections: [RequestCollection] = []
    @Published private(set) var drafts: [RequestIdentity: HTTPRequestConfiguration] = [:]
    @Published private(set) var activeRuns: [RequestIdentity: ActiveRun] = [:]
    @Published private(set) var latestResponses: [RequestIdentity: LatestResponse] = [:]
    @Published private(set) var runErrors: [RequestIdentity: String] = [:]
    @Published private(set) var cancelledRequests: Set<RequestIdentity> = []
    @Published private(set) var autosaveErrors: [RequestIdentity: String] = [:]
    @Published private(set) var storageIssues: [StorageIssue] = []
    @Published private(set) var snapshots: [SavedSnapshot] = []
    @Published private(set) var snapshotStorageIssues: [StorageIssue] = []
    @Published private(set) var snapshotLoadError: String?
    @Published private(set) var openedSnapshots: [UUID: OpenedSnapshot] = [:]
    @Published private(set) var openingSnapshots: Set<UUID> = []
    @Published private(set) var snapshotOpenErrors: [UUID: String] = [:]
    @Published private(set) var savingSnapshotRunIDs: Set<UUID> = []
    @Published private(set) var selectedIdentity: RequestIdentity?
    @Published private(set) var selectedSnapshotID: UUID?
    @Published private(set) var selectedCollectionID: UUID?
    @Published private(set) var collectionEditorSection: CollectionEditorSection = .requests
    @Published private(set) var requestEditorSections: [RequestIdentity: RequestEditorSection] = [:]
    @Published private(set) var requestEditorExpansionStates: [RequestIdentity: RequestEditorExpansionState] = [:]
    @Published private(set) var variableDefinitionRequest: VariableDefinitionRequest?
    @Published private(set) var showsOngoingRequests = false
    @Published private(set) var now = Date()
    @Published private(set) var startupError: String?
    @Published private(set) var isTerminating = false
    @Published private var keyRotationIsRunning = false
    @Published private var encryptionLoadCount = 0
    @Published private(set) var encryptionRecoveryRequired = false

    var isRotatingEncryptionKey: Bool { keyRotationIsRunning || encryptionLoadCount > 0 }

    var workspaceMutationIsBlocked: Bool {
        isTerminating || isRotatingEncryptionKey || encryptionRecoveryRequired
    }
    @Published private(set) var deletingCollections: Set<UUID> = []
    @Published private(set) var deletingRequests: Set<RequestIdentity> = []
    @Published private(set) var reconcilingRequests: Set<RequestIdentity> = []
    @Published private(set) var movingRequests: Set<RequestIdentity> = []
    @Published var operationError: String?

    private struct Directories {
        let data: URL
        let body: URL
    }

    private struct PendingPreview {
        let runID: UUID
        let task: Task<BodyPreview, Error>
    }

    private enum SecretEditTarget: Hashable {
        case variable(VariableOwner, String)
        case authentication(VariableOwner, AuthenticationSecretField)

        var owner: VariableOwner {
            switch self {
            case let .variable(owner, _): owner
            case let .authentication(owner, _): owner
            }
        }
    }

    private let secretVault: SecretVault
    private var keyRotation: WorkspaceKeyRotation?
    private var keyPreparationTask: Task<Void, Error>?
    private var workspaceLoaded = false
    private var initialWorkspaceLoadTask: Task<Void, Never>?
    private var dirtyVariableOwners: Set<VariableOwner> = []
    private var variableVersions: [VariableOwner: UInt64] = [:]
    private var pendingVariableSaves: [VariableOwner: Task<Void, Never>] = [:]
    private var variableSaveChains: [VariableOwner: Task<Void, Never>] = [:]
    private var scopeSaveErrors: [VariableOwner: String] = [:]
    private var secretEditTokens: [SecretEditTarget: UUID] = [:]
    private var secretCommitErrors: [SecretEditTarget: String] = [:]
    private var secretCommitTasks: [SecretEditTarget: (token: UUID, task: Task<Result<Void, Error>, Never>)] = [:]
    private var automationEditingRequests: Set<RequestIdentity> = []
    private var preparationTasks: [RequestIdentity: Task<Void, Never>] = [:]
    private var store: CollectionStore?
    private var snapshotStore: SnapshotStore?
    private var mcpTokenStore: EncryptedMCPTokenStore?
    private var executionManager: HTTPExecutionManager?
    private var responseBodyResources: [UUID: ResponseBodyResource] = [:]
    private var deletingBodySnapshotIDs: Set<UUID> = []
    private var editVersions: [RequestIdentity: UInt64] = [:]
    private var dirtyDrafts: Set<RequestIdentity> = []
    private var pendingSaveTasks: [RequestIdentity: Task<Void, Never>] = [:]
    private var saveChains: [RequestIdentity: Task<Void, Never>] = [:]
    private var previewTasks: [RequestIdentity: PendingPreview] = [:]
    private var snapshotSaveTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    private var navigationHistory = NavigationHistory()
    private var settlementWaiters: [RequestIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var collectionMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var collectionMutationTokens: [UUID: UUID] = [:]
    private var workspaceIndexMutationTask: Task<Void, Never>?
    private var workspaceIndexMutationToken: UUID?
    private var acceptedMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var mutationDrainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var mutationDrainTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var workspaceRevision: UInt64 = 0
    private var automationRunOutcomes: [RequestIdentity: AutomationRunOutcome] = [:]
    private var automationRunOutcomeOrder: [RequestIdentity] = []
    private let maximumAutomationRunOutcomes = 256

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        secretVault: SecretVault? = nil,
        legacyMCPKeyStore: (any ApplicationKeyStore)? = nil,
        keyRotationCoordinator: WorkspaceKeyRotation? = nil
    ) {
        self.secretVault =
            secretVault
            ?? SecretVault(
                keyStore: KeychainApplicationKeyStore(
                    service: (Bundle.main.bundleIdentifier ?? "dev.postie.local") + ".workspace-encryption"
                ))
        do {
            let directories = try Self.directories(from: arguments)
            store = try CollectionStore(rootURL: directories.data)
            keyRotation =
                keyRotationCoordinator ?? WorkspaceKeyRotation(rootURL: directories.data, vault: self.secretVault)
            mcpTokenStore = EncryptedMCPTokenStore(
                rootURL: directories.data,
                vault: self.secretVault,
                legacyKeyStore: legacyMCPKeyStore
                    ?? KeychainApplicationKeyStore(
                        service: (Bundle.main.bundleIdentifier ?? "dev.postie") + ".mcp-access",
                        account: "bearer-token-v1"
                    )
            )
            snapshotStore = SnapshotStore(
                rootURL: directories.data.appendingPathComponent("snapshots", isDirectory: true),
                vault: self.secretVault
            )
            executionManager = try HTTPExecutionManager(bodyDirectory: directories.body)
            if let executionManager { sessionHistory.connect(to: executionManager) }
            initialWorkspaceLoadTask = Task { [weak self] in
                await self?.loadWorkspace()
            }
        } catch {
            startupError = error.localizedDescription
        }

        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.now = Date()
            }
        }
    }

    var requestCount: Int {
        collections.reduce(0) { $0 + $1.requests.count }
    }

    var activeRunCount: Int {
        activeRuns.count
    }

    var canNavigateBack: Bool {
        navigationHistory.canGoBack(to: availableNavigationLocations)
    }

    var canNavigateForward: Bool {
        navigationHistory.canGoForward(to: availableNavigationLocations)
    }

    func requestEditorSection(for identity: RequestIdentity) -> RequestEditorSection {
        requestEditorSections[identity] ?? .request
    }

    func setRequestEditorSection(_ section: RequestEditorSection, for identity: RequestIdentity) {
        guard drafts[identity] != nil, requestEditorSection(for: identity) != section else { return }
        requestEditorSections[identity] = section
        if section != .variables, variableDefinitionRequest?.owner == .request(identity) {
            variableDefinitionRequest = nil
        }
        guard selectedIdentity == identity,
            selectedCollectionID == nil,
            selectedSnapshotID == nil,
            !showsOngoingRequests,
            !showsGlobalVariables,
            !showsGlobalSettings
        else { return }
        recordNavigation(.request(identity, section: section))
    }

    func requestEditorExpansionState(for identity: RequestIdentity) -> RequestEditorExpansionState {
        requestEditorExpansionStates[identity] ?? RequestEditorExpansionState()
    }

    func reconcileRequestEditorExpansion(
        for identity: RequestIdentity,
        initiallyExpanded: Set<RequestEditorAccordion>,
        content: RequestEditorContentSnapshot
    ) {
        guard drafts[identity] != nil else { return }
        let previous = requestEditorExpansionState(for: identity)
        var state = requestEditorExpansionState(for: identity)
        state.reconcile(initiallyExpanded: initiallyExpanded, content: content)
        guard state != previous else { return }
        requestEditorExpansionStates[identity] = state
    }

    func setRequestEditorAccordionExpanded(
        _ section: RequestEditorAccordion,
        isExpanded: Bool,
        for identity: RequestIdentity
    ) {
        guard drafts[identity] != nil else { return }
        let previous = requestEditorExpansionState(for: identity)
        var state = requestEditorExpansionState(for: identity)
        state.setExpanded(section, isExpanded)
        if state != previous {
            requestEditorExpansionStates[identity] = state
        }
        guard isExpanded else { return }
        setRequestEditorSection(.request, for: identity)
    }

    func request(for identity: RequestIdentity) -> HTTPRequestConfiguration? {
        drafts[identity]
    }

    func collection(for identity: RequestIdentity) -> RequestCollection? {
        collections.first { $0.id == identity.collectionID }
    }

    func canEdit(_ identity: RequestIdentity) -> Bool {
        guard workspaceLoaded, let collection = collection(for: identity), drafts[identity] != nil else { return false }
        return !collection.isReadOnly && !deletingCollections.contains(identity.collectionID)
            && !deletingRequests.contains(identity) && !reconcilingRequests.contains(identity)
            && !movingRequests.contains(identity) && !automationEditingRequests.contains(identity) && !isTerminating
            && !isRotatingEncryptionKey && !encryptionRecoveryRequired
    }

    private var snapshotInventoryAllowsSourceMutation: Bool {
        workspaceLoaded && snapshotLoadError == nil && snapshotStorageIssues.isEmpty
    }

    var canReorderCollections: Bool {
        workspaceLoaded && !workspaceIndexIsReadOnly && !workspaceMutationIsBlocked && collections.count > 1
    }

    func snapshotGrouping(for snapshot: SavedSnapshot) -> SnapshotGrouping {
        let fallback = SnapshotGrouping(
            identity: snapshot.source.identity,
            collectionName: snapshot.source.collectionName,
            requestName: snapshot.source.requestName
        )
        let grouping = workspaceIndex.snapshotGroupingOverrides[snapshot.id] ?? fallback
        guard let collection = collections.first(where: { $0.id == grouping.identity.collectionID }),
            let request = collection.requests.first(where: { $0.id == grouping.identity.requestID })
        else {
            return grouping
        }
        return SnapshotGrouping(
            identity: grouping.identity,
            collectionName: collection.name,
            requestName: request.name
        )
    }

    func snapshotIsMCPExcluded(_ snapshot: SavedSnapshot) -> Bool {
        workspaceIndexIsReadOnly || workspaceIndex.mcpExcludedSnapshotIDs.contains(snapshot.id)
            || snapshotPolicyIsMCPExcluded(snapshot)
    }

    private func snapshotPolicyIsMCPExcluded(_ snapshot: SavedSnapshot) -> Bool {
        let grouping = snapshotGrouping(for: snapshot)
        guard let collection = collections.first(where: { $0.id == grouping.identity.collectionID }) else {
            return false
        }
        let requestPolicy =
            drafts[grouping.identity]?.mcpPolicy ?? collection.requests
            .first(where: { $0.id == grouping.identity.requestID })?.mcpPolicy ?? MCPResourcePolicy()
        return !MCPResourcePolicy.isAccessible(collection: collection.mcpPolicy, request: requestPolicy)
    }

    func canFollowRedirect(_ identity: RequestIdentity) -> Bool {
        guard canEdit(identity),
            activeRuns[identity] == nil,
            let response = latestResponses[identity]?.response,
            !response.redirectLimitReached,
            response.redirects.count <= 10,
            let redirect = response.pendingRedirect,
            [301, 302, 303, 307, 308].contains(redirect.statusCode),
            let request = response.redirectRequest,
            let url = request.url,
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return false }

        return response.redirects.last?.id == redirect.id && response.finalURL == redirect.url
            && redirect.nextURL == url && request.httpMethod?.uppercased() == redirect.nextMethod.uppercased()
    }

    func select(_ identity: RequestIdentity?) {
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedIdentity = identity
        selectedSnapshotID = nil
        selectedCollectionID = nil
        showsOngoingRequests = false
        showsGlobalVariables = false
        if let identity { recordNavigation(.request(identity, section: requestEditorSection(for: identity))) }
    }

    func showOngoingRequests() {
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        selectedCollectionID = nil
        showsGlobalVariables = false
        showsOngoingRequests = true
        recordNavigation(.ongoingRequests)
    }

    func showRequests() {
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        selectedCollectionID = nil
        showsOngoingRequests = false
        showsGlobalVariables = false
        if selectedIdentity == nil {
            selectFirstRequest()
        }
        if let selectedIdentity {
            recordNavigation(.request(selectedIdentity, section: requestEditorSection(for: selectedIdentity)))
        }
    }

    func openRequest(_ identity: RequestIdentity) {
        guard drafts[identity] != nil, !reconcilingRequests.contains(identity) else { return }
        showRequest(identity)
        recordNavigation(.request(identity, section: requestEditorSection(for: identity)))
    }

    func selectSnapshot(_ id: UUID) {
        guard !workspaceMutationIsBlocked, snapshots.contains(where: { $0.id == id }) else { return }
        if selectedSnapshotID != id { clearSelectedSnapshotContext() }
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        selectedCollectionID = nil
        showsOngoingRequests = false
        showsGlobalVariables = false
        selectedSnapshotID = id
        recordNavigation(.snapshot(id))
        openSnapshotIfNeeded(id)
    }

    func showGlobalVariables() {
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        selectedCollectionID = nil
        showsGlobalVariables = true
        showsOngoingRequests = false
        recordNavigation(.globalVariables)
    }

    func showRequestSearch(query: String = "") {
        guard !workspaceMutationIsBlocked else { return }
        workspaceSearchQuery = query
        workspaceSearchFocusRequestID = UUID()
        showsRequestSearch = true
    }

    func showWorkspaceVariable(owner: VariableOwner, name: String) {
        guard !workspaceMutationIsBlocked else { return }
        switch owner {
        case .global:
            guard globalVariables[name] != nil else { return }
            showGlobalVariables()
        case let .collection(id):
            guard collection(id: id)?.variables[name] != nil else { return }
            showCollection(id, section: .variables)
        case let .request(identity):
            let location = NavigationLocation.requestVariableDefinition(identity, name: name)
            guard isAvailableNavigationLocation(location) else { return }
            showRequest(identity)
            requestEditorSections[identity] = .variables
            variableDefinitionRequest = VariableDefinitionRequest(owner: owner, name: name)
            recordNavigation(location)
        }
    }

    func showGlobalSettings() {
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        selectedCollectionID = nil
        showsGlobalVariables = false
        showsOngoingRequests = false
        showsGlobalSettings = true
        recordNavigation(.globalSettings)
    }

    func updateGlobalOptions(_ options: HTTPOptions) {
        guard workspaceLoaded, !globalOptionsAreReadOnly, !workspaceMutationIsBlocked else { return }
        globalOptions = options
        markWorkspaceChanged()
        scheduleVariableSave(.global)
    }

    func saveGlobalMCPResponseViewing(_ policy: MCPResponseViewPolicy) async {
        guard workspaceLoaded, !workspaceMutationIsBlocked, policy != .inherit, let store else { return }
        await withAcceptedMutation { [weak self] in
            guard let self, !self.isTerminating else { return }
            do {
                try await store.saveGlobalMCPResponseViewing(policy)
                self.globalMCPResponseViewing = policy
                self.markWorkspaceChanged()
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }

    func requestOptionOverrides(for identity: RequestIdentity) -> HTTPOptionsOverrides {
        guard let request = request(for: identity) else { return HTTPOptionsOverrides() }
        return request.optionOverrides ?? .explicit(request.options)
    }

    func updateRequestOptionOverrides(_ overrides: HTTPOptionsOverrides, for identity: RequestIdentity) {
        updateDraft(identity) {
            $0.optionOverrides = overrides
        }
    }

    func showCollection(_ id: UUID, section: CollectionEditorSection = .requests) {
        showsGlobalSettings = false
        guard collections.contains(where: { $0.id == id }) else { return }
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        collectionEditorSection = section
        selectedCollectionID = id
        showsGlobalVariables = false
        showsOngoingRequests = false
        recordNavigation(.collection(id, section: section))
    }

    func setCollectionEditorSection(_ section: CollectionEditorSection) {
        guard let selectedCollectionID,
            collections.contains(where: { $0.id == selectedCollectionID }),
            collectionEditorSection != section
        else { return }
        collectionEditorSection = section
        recordNavigation(.collection(selectedCollectionID, section: section))
    }

    func navigateBack() {
        guard let location = navigationHistory.goBack(to: availableNavigationLocations) else { return }
        restoreNavigation(to: location)
    }

    func navigateForward() {
        guard let location = navigationHistory.goForward(to: availableNavigationLocations) else { return }
        restoreNavigation(to: location)
    }

    private func showRequest(_ identity: RequestIdentity) {
        showsGlobalSettings = false
        variableDefinitionRequest = nil
        clearSelectedSnapshotContext()
        selectedSnapshotID = nil
        selectedIdentity = identity
        selectedCollectionID = nil
        showsOngoingRequests = false
        showsGlobalVariables = false
    }

    private func recordNavigation(_ location: NavigationLocation) {
        guard isAvailableNavigationLocation(location) else { return }
        navigationHistory.visit(location)
    }

    private var availableNavigationLocations: Set<NavigationLocation> {
        var available: Set<NavigationLocation> = []
        for location in navigationHistory.locations where isAvailableNavigationLocation(location) {
            available.insert(location)
        }
        return available
    }

    private func isAvailableNavigationLocation(_ location: NavigationLocation) -> Bool {
        switch location {
        case let .request(identity, _):
            return isAvailableRequest(identity)
        case let .requestVariableDefinition(identity, name):
            return isAvailableRequest(identity) && variables(for: .request(identity))[name] != nil
        case let .collection(id, _):
            return collections.contains { $0.id == id }
        case let .snapshot(id):
            return snapshots.contains { $0.id == id }
        case .globalVariables, .globalSettings, .ongoingRequests:
            return true
        }
    }

    private func isAvailableRequest(_ identity: RequestIdentity) -> Bool {
        guard drafts[identity] != nil,
            !reconcilingRequests.contains(identity),
            let collection = collection(id: identity.collectionID)
        else { return false }
        return collection.requests.contains { $0.id == identity.requestID }
    }

    private func restoreNavigation(to location: NavigationLocation) {
        guard isAvailableNavigationLocation(location) else { return }
        variableDefinitionRequest = nil
        showsGlobalSettings = false

        switch location {
        case let .request(identity, section):
            showRequest(identity)
            requestEditorSections[identity] = section
        case let .requestVariableDefinition(identity, name):
            showRequest(identity)
            requestEditorSections[identity] = .variables
            variableDefinitionRequest = VariableDefinitionRequest(owner: .request(identity), name: name)
        case let .collection(id, section):
            clearSelectedSnapshotContext()
            selectedSnapshotID = nil
            collectionEditorSection = section
            selectedCollectionID = id
            showsGlobalVariables = false
            showsOngoingRequests = false
        case .globalVariables:
            clearSelectedSnapshotContext()
            selectedSnapshotID = nil
            selectedCollectionID = nil
            showsGlobalVariables = true
            showsOngoingRequests = false
        case .globalSettings:
            clearSelectedSnapshotContext()
            selectedSnapshotID = nil
            selectedCollectionID = nil
            showsGlobalVariables = false
            showsOngoingRequests = false
            showsGlobalSettings = true
        case .ongoingRequests:
            clearSelectedSnapshotContext()
            selectedSnapshotID = nil
            selectedCollectionID = nil
            showsGlobalVariables = false
            showsOngoingRequests = true
        case let .snapshot(id):
            if selectedSnapshotID != id { clearSelectedSnapshotContext() }
            selectedSnapshotID = id
            selectedCollectionID = nil
            showsGlobalVariables = false
            showsOngoingRequests = false
            openSnapshotIfNeeded(id)
        }
    }

    func collection(id: UUID) -> RequestCollection? {
        collections.first { $0.id == id }
    }

    func updateCollectionHeaders(_ headers: [HTTPField], in id: UUID) {
        guard canEditVariables(.collection(id)), let index = collections.firstIndex(where: { $0.id == id }) else {
            return
        }
        collections[index].headers = headers
        markWorkspaceChanged()
        scheduleVariableSave(.collection(id))
    }

    func updateCollectionMCPPolicy(_ policy: MCPResourcePolicy, for collectionID: UUID) async {
        guard !workspaceMutationIsBlocked,
            let store,
            collections.contains(where: { $0.id == collectionID && !$0.isReadOnly })
        else { return }
        await withCollectionMutation(collectionID) { [weak self] in
            guard let self,
                !self.isTerminating,
                let index = self.collections.firstIndex(where: { $0.id == collectionID && !$0.isReadOnly })
            else { return }
            do {
                try await store.saveCollectionMCPPolicy(policy, in: collectionID)
                self.collections[index].mcpPolicy = policy
                self.markWorkspaceChanged()
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }

    func updateRequestMCPPolicy(_ policy: MCPResourcePolicy, for identity: RequestIdentity) {
        updateDraft(identity) { $0.mcpPolicy = policy }
    }

    func setInheritsCollectionAuthentication(_ inherits: Bool, for identity: RequestIdentity) {
        updateDraft(identity) { $0.inheritsCollectionAuthentication = inherits }
    }

    func variableCompletions(for identity: RequestIdentity) -> [VariableCompletion] {
        variableCompletions(in: variableContext(for: identity))
    }

    func variableCompletions(for owner: VariableOwner) -> [VariableCompletion] {
        switch owner {
        case .global:
            variableCompletions(in: VariableContext(global: globalVariables))
        case let .collection(id):
            variableCompletions(
                in: VariableContext(global: globalVariables, collection: variables(for: .collection(id))))
        case let .request(identity):
            variableCompletions(for: identity)
        }
    }

    private func variableCompletions(in context: VariableContext) -> [VariableCompletion] {
        let names = Set(context.global.keys).union(context.collection.keys).union(context.request.keys)
        return names.sorted().compactMap { name in
            let resolved: (VariableValue, VariableScope)? =
                context.request[name].map { ($0, .request) } ?? context.collection[name].map { ($0, .collection) }
                ?? context.global[name].map { ($0, .global) }
            guard let (value, scope) = resolved else { return nil }

            let preview: String?
            if case let .plain(plainValue) = value {
                preview = plainValue
            } else {
                preview = nil
            }

            return VariableCompletion(name: name, scope: scope, isSecret: value.isEncrypted, preview: preview)
        }
    }

    func variables(for owner: VariableOwner) -> VariableValues {
        switch owner {
        case .global: globalVariables
        case let .collection(id): collections.first { $0.id == id }?.variables ?? [:]
        case let .request(identity): drafts[identity]?.variables ?? [:]
        }
    }

    func canEditVariables(_ owner: VariableOwner) -> Bool {
        workspaceLoaded && !workspaceMutationIsBlocked && canCommitVariables(owner)
    }

    func variableContext(for identity: RequestIdentity) -> VariableContext {
        VariableContext(
            global: globalVariables,
            collection: collection(for: identity)?.variables ?? [:],
            request: drafts[identity]?.variables ?? [:]
        )
    }

    func variableInspection(named name: String, in origin: VariableOwner) -> VariableInspection? {
        guard !workspaceMutationIsBlocked, activeVariableOwner == origin else { return nil }
        let owners: [VariableOwner]
        switch origin {
        case .global: owners = [.global]
        case let .collection(id): owners = [.collection(id), .global]
        case let .request(identity): owners = [.request(identity), .collection(identity.collectionID), .global]
        }
        for owner in owners {
            if let value = variables(for: owner)[name] {
                return VariableInspection(origin: origin, owner: owner, name: name, value: value)
            }
        }
        return nil
    }

    func isCurrent(_ inspection: VariableInspection) -> Bool {
        variableInspection(named: inspection.name, in: inspection.origin) == inspection
    }

    func showVariableDefinition(_ inspection: VariableInspection) {
        guard isCurrent(inspection) else { return }
        switch inspection.owner {
        case .global: showGlobalVariables()
        case let .collection(id): showCollection(id, section: .variables)
        case let .request(identity):
            guard isAvailableNavigationLocation(.requestVariableDefinition(identity, name: inspection.name)) else {
                return
            }
            showRequest(identity)
            requestEditorSections[identity] = .variables
            variableDefinitionRequest = VariableDefinitionRequest(owner: inspection.owner, name: inspection.name)
            recordNavigation(.requestVariableDefinition(identity, name: inspection.name))
        }
    }

    func consumeVariableDefinitionRequest(_ id: UUID) {
        guard variableDefinitionRequest?.id == id else { return }
        variableDefinitionRequest = nil
    }

    private var activeVariableOwner: VariableOwner? {
        guard selectedSnapshotID == nil, !showsOngoingRequests, !showsGlobalSettings else { return nil }
        if showsGlobalVariables { return .global }
        if let selectedCollectionID { return .collection(selectedCollectionID) }
        if let selectedIdentity { return .request(selectedIdentity) }
        return nil
    }

    private func clearSelectedSnapshotContext() {
        openedSnapshots.removeAll()
        openingSnapshots.removeAll()
        snapshotOpenErrors.removeAll()
    }

    func setVariable(
        name: String,
        value: String,
        isSecret: Bool,
        owner: VariableOwner,
        operationID: UUID = UUID()
    ) async throws {
        guard TemplateEngine.isValidVariableName(name) else { throw ConfigurationEditError.invalidName }
        guard canEditVariables(owner) else { throw ConfigurationEditError.readOnly }
        let target = SecretEditTarget.variable(owner, name)
        if isSecret {
            try await commitSecret(value, target: target, operationID: operationID) { [weak self] envelope in
                self?.updateVariables(owner) { $0[name] = .encrypted(envelope) }
            }
        } else {
            try setPlainVariable(name: name, value: value, owner: owner)
        }
    }

    func setPlainVariable(name: String, value: String, owner: VariableOwner) throws {
        guard TemplateEngine.isValidVariableName(name) else { throw ConfigurationEditError.invalidName }
        guard canEditVariables(owner) else { throw ConfigurationEditError.readOnly }
        discardSecretEdit(.variable(owner, name))
        updateVariables(owner) { $0[name] = .plain(value) }
    }

    func removeVariable(named name: String, owner: VariableOwner) {
        guard canEditVariables(owner) else { return }
        discardSecretEdit(.variable(owner, name))
        updateVariables(owner) { $0.removeValue(forKey: name) }
    }

    func renameVariable(from oldName: String, to newName: String, owner: VariableOwner) throws {
        guard canEditVariables(owner) else { throw ConfigurationEditError.readOnly }
        guard TemplateEngine.isValidVariableName(newName) else { throw ConfigurationEditError.invalidName }
        guard oldName != newName else { return }
        let values = variables(for: owner)
        guard let value = values[oldName] else { throw ConfigurationEditError.unavailable }
        guard values[newName] == nil else { throw ConfigurationEditError.duplicateName }
        discardSecretEdit(.variable(owner, oldName))
        discardSecretEdit(.variable(owner, newName))
        updateVariables(owner) {
            $0.removeValue(forKey: oldName)
            $0[newName] = value
        }
    }

    func revealVariable(named name: String, owner: VariableOwner) async throws -> String {
        guard let value = variables(for: owner)[name] else { throw ConfigurationEditError.unavailable }
        switch value {
        case let .plain(value): return value
        case let .encrypted(envelope): return try await secretVault.decrypt(envelope)
        }
    }

    func discardVariableSecretEdit(named name: String, owner: VariableOwner, operationID: UUID? = nil) {
        let target = SecretEditTarget.variable(owner, name)
        if let operationID, secretEditTokens[target] != operationID { return }
        discardSecretEdit(target)
    }

    func setVariableSecret(_ isSecret: Bool, named name: String, owner: VariableOwner) async throws {
        guard canEditVariables(owner) else { throw ConfigurationEditError.readOnly }
        guard let value = variables(for: owner)[name] else { throw ConfigurationEditError.unavailable }
        guard value.isEncrypted != isSecret else { return }
        let vault = secretVault
        try await commitProtectedValue(
            target: .variable(owner, name), blocksTerminationOnFailure: false,
            operation: {
                switch value {
                case let .plain(plain): return VariableValue.encrypted(try await vault.encrypt(plain))
                case let .encrypted(envelope): return VariableValue.plain(try await vault.decrypt(envelope))
                }
            }
        ) { [weak self] converted in
            self?.updateVariables(owner) { $0[name] = converted }
        }
    }

    func setAuthenticationKind(_ kind: AuthenticationKind, for identity: RequestIdentity) {
        setAuthenticationKind(kind, owner: .request(identity))
    }

    func updateAuthenticationUsername(_ username: String, for identity: RequestIdentity) {
        updateAuthenticationUsername(username, owner: .request(identity))
    }

    func setAuthenticationSecret(_ value: String, field: AuthenticationSecretField, for identity: RequestIdentity)
        async throws
    {
        try await setAuthenticationSecret(value, field: field, owner: .request(identity))
    }

    func revealAuthenticationSecret(field: AuthenticationSecretField, for identity: RequestIdentity) async throws
        -> String
    {
        try await revealAuthenticationSecret(field: field, owner: .request(identity))
    }

    func discardAuthenticationSecretEdit(field: AuthenticationSecretField, for identity: RequestIdentity) {
        discardAuthenticationSecretEdit(field: field, owner: .request(identity))
    }

    func authentication(for owner: VariableOwner) -> RequestAuthentication {
        switch owner {
        case let .request(identity): drafts[identity]?.authentication ?? .init()
        case let .collection(id): collection(id: id)?.authentication ?? .init()
        case .global: .init()
        }
    }

    func setAuthenticationKind(_ kind: AuthenticationKind, owner: VariableOwner) {
        guard canEditVariables(owner) else { return }
        if case let .request(identity) = owner {
            setInheritsCollectionAuthentication(false, for: identity)
        }
        updateAuthentication(owner) {
            $0.kind = kind
            if kind == .apiKey, $0.apiKeyHeaderName == nil {
                $0.apiKeyHeaderName = "X-API-Key"
            }
        }
    }

    func updateAuthenticationUsername(_ username: String, owner: VariableOwner) {
        guard canEditVariables(owner) else { return }
        updateAuthentication(owner) { $0.username = username }
    }

    func updateAPIKeyHeaderName(_ headerName: String, owner: VariableOwner) {
        guard owner != .global, canEditVariables(owner) else { return }
        updateAuthentication(owner) { $0.apiKeyHeaderName = headerName.isEmpty ? nil : headerName }
    }

    func setAuthenticationSecret(_ value: String, field: AuthenticationSecretField, owner: VariableOwner) async throws {
        guard owner != .global, canEditVariables(owner) else { throw ConfigurationEditError.readOnly }
        try await commitSecret(value, target: .authentication(owner, field)) { [weak self] envelope in
            self?.updateAuthentication(owner) {
                switch field {
                case .password: $0.password = envelope
                case .token: $0.token = envelope
                case .apiKey: $0.apiKey = envelope
                }
            }
        }
    }

    func revealAuthenticationSecret(field: AuthenticationSecretField, owner: VariableOwner) async throws -> String {
        guard owner != .global else { throw ConfigurationEditError.unavailable }
        let authentication = authentication(for: owner)
        let envelope: SecretEnvelope?
        switch field {
        case .password: envelope = authentication.password
        case .token: envelope = authentication.token
        case .apiKey: envelope = authentication.apiKey
        }
        guard let envelope else { return "" }
        return try await secretVault.decrypt(envelope)
    }

    func previewAuthenticationHeader(for identity: RequestIdentity, source: HTTPHeaderSource) async throws -> String {
        guard let request = request(for: identity),
            let collection = collection(for: identity)
        else { throw ConfigurationEditError.unavailable }
        let variableContext = variableContext(for: identity)
        let collectionHeaders = collection.headers

        let authentication: RequestAuthentication
        switch source {
        case .requestAuth:
            guard !request.inheritsCollectionAuthentication else { throw ConfigurationEditError.unavailable }
            authentication = request.authentication
        case .collectionAuth:
            guard request.inheritsCollectionAuthentication else { throw ConfigurationEditError.unavailable }
            authentication = collection.authentication
        case .request, .collection, .automatic:
            throw ConfigurationEditError.unavailable
        }

        var preview = HTTPRequestConfiguration()
        preview.url = "https://postie.invalid/"
        preview.pathParameters = []
        preview.query = []
        preview.headers = []
        preview.body = ""
        preview.bodyEnabled = false
        preview.authentication = authentication
        preview.inheritsCollectionAuthentication = false

        let expectedHeaderName = HeaderPresentation.authenticationHeaderName(for: authentication)
        guard let expectedHeaderName, !expectedHeaderName.isEmpty else {
            throw ConfigurationEditError.unavailable
        }

        let prepared = try await RequestPreparer.prepare(
            preview,
            context: variableContext,
            decryptor: secretVault,
            captureRedactionInputs: false
        )

        let resolvedHeaderName: String?
        if HeaderPresentation.hasTemplateSyntax(in: expectedHeaderName) {
            resolvedHeaderName = prepared.requestHeaderSources.first { $0.value == .requestAuth }?.key
        } else {
            resolvedHeaderName = expectedHeaderName
        }
        guard let resolvedHeaderName,
            let value = prepared.request.value(forHTTPHeaderField: resolvedHeaderName),
            self.request(for: identity) == request,
            self.variableContext(for: identity) == variableContext,
            self.collection(for: identity)?.headers == collectionHeaders,
            source != .collectionAuth || self.collection(for: identity)?.authentication == authentication,
            selectedIdentity == identity,
            selectedCollectionID == nil,
            !showsGlobalVariables,
            !showsGlobalSettings,
            !showsOngoingRequests,
            requestEditorSection(for: identity) == .request || requestEditorSection(for: identity) == .authentication
        else {
            throw ConfigurationEditError.unavailable
        }
        return value
    }

    func discardAuthenticationSecretEdit(field: AuthenticationSecretField, owner: VariableOwner) {
        discardSecretEdit(.authentication(owner, field))
    }

    private func updateAuthentication(_ owner: VariableOwner, _ update: (inout RequestAuthentication) -> Void) {
        guard canCommitVariables(owner) else { return }
        switch owner {
        case let .request(identity):
            guard var draft = drafts[identity] else { return }
            update(&draft.authentication)
            drafts[identity] = draft
            scheduleAutosave(for: identity)
        case let .collection(id):
            guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
            update(&collections[index].authentication)
            scheduleVariableSave(owner)
        case .global: return
        }
        markWorkspaceChanged()
    }

    private func canCommitVariables(_ owner: VariableOwner) -> Bool {
        switch owner {
        case .global:
            return workspaceLoaded && !globalVariablesAreReadOnly
        case let .collection(id):
            return !deletingCollections.contains(id) && collections.contains { $0.id == id && !$0.isReadOnly }
        case let .request(identity):
            guard let collection = collection(for: identity), drafts[identity] != nil else { return false }
            return !collection.isReadOnly && !deletingCollections.contains(identity.collectionID)
                && !deletingRequests.contains(identity) && !reconcilingRequests.contains(identity)
                && !movingRequests.contains(identity) && !automationEditingRequests.contains(identity)
        }
    }

    private func commitSecret(
        _ value: String,
        target: SecretEditTarget,
        operationID: UUID = UUID(),
        apply: @escaping @MainActor (SecretEnvelope) -> Void
    ) async throws {
        let vault = secretVault
        try await commitProtectedValue(
            target: target, operationID: operationID,
            operation: {
                let envelope = try await vault.encrypt(value)
                await vault.setAllowsKeyCreation(false)
                return envelope
            }, apply: apply)
    }

    private func commitProtectedValue<Value: Sendable>(
        target: SecretEditTarget,
        operationID: UUID = UUID(),
        blocksTerminationOnFailure: Bool = true,
        operation: @escaping @Sendable () async throws -> Value,
        apply: @escaping @MainActor (Value) -> Void
    ) async throws {
        let token = operationID
        secretEditTokens[target] = token
        let task = Task { @MainActor [self] () -> Result<Void, Error> in
            do {
                let value = try await operation()
                await secretVault.setAllowsKeyCreation(false)
                guard secretEditTokens[target] == token, canCommitVariables(target.owner) else {
                    return .failure(CancellationError())
                }
                apply(value)
                secretCommitErrors.removeValue(forKey: target)
                refreshVariableError(target.owner)
                return .success(())
            } catch {
                if blocksTerminationOnFailure && secretEditTokens[target] == token && canCommitVariables(target.owner) {
                    secretCommitErrors[target] = error.localizedDescription
                    refreshVariableError(target.owner)
                }
                return .failure(error)
            }
        }
        acceptedMutationTasks[token] = Task { _ = await task.value }
        secretCommitTasks[target] = (token, task)
        let result = await task.value
        if secretCommitTasks[target]?.token == token {
            secretCommitTasks.removeValue(forKey: target)
        }
        finishAcceptedMutation(token)
        try result.get()
    }

    private func waitForSecretEdits(owner: VariableOwner) async {
        let tasks =
            secretCommitTasks
            .filter { $0.key.owner == owner }
            .map { $0.value.task }
        for task in tasks { _ = await task.value }
    }

    private func discardSecretEdit(_ target: SecretEditTarget) {
        secretEditTokens.removeValue(forKey: target)
        secretCommitErrors.removeValue(forKey: target)
        refreshVariableError(target.owner)
    }

    private func invalidateSecretEdits(for owner: VariableOwner) {
        for target in Array(secretEditTokens.keys) where target.owner == owner { discardSecretEdit(target) }
        for target in Array(secretCommitErrors.keys) where target.owner == owner { discardSecretEdit(target) }
    }

    private func refreshVariableError(_ owner: VariableOwner) {
        let requestError: String?
        if case let .request(identity) = owner { requestError = autosaveErrors[identity] } else { requestError = nil }
        variableSaveErrors[owner] =
            secretCommitErrors.first { $0.key.owner == owner }?.value ?? scopeSaveErrors[owner] ?? requestError
    }

    private func updateVariables(_ owner: VariableOwner, _ update: (inout VariableValues) -> Void) {
        switch owner {
        case .global:
            update(&globalVariables)
            scheduleVariableSave(owner)
        case let .collection(id):
            guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
            update(&collections[index].variables)
            scheduleVariableSave(owner)
        case let .request(identity):
            guard var draft = drafts[identity] else { return }
            update(&draft.variables)
            drafts[identity] = draft
            scheduleAutosave(for: identity)
        }
        markWorkspaceChanged()
    }

    func previousResponseMessage(for identity: RequestIdentity) -> String? {
        guard latestResponses[identity] != nil else { return nil }
        if cancelledRequests.contains(identity) {
            return "Previous response · The latest run was cancelled."
        }
        if runErrors[identity] != nil {
            return "Previous response · The latest run did not complete."
        }
        if activeRuns[identity] != nil {
            return "Previous response · A newer run is in progress."
        }
        return nil
    }

    func updateDraft(_ identity: RequestIdentity, _ update: (inout HTTPRequestConfiguration) -> Void) {
        guard canEdit(identity), var draft = drafts[identity] else { return }
        let oldOptions = draft.options
        let oldOverrides = draft.optionOverrides
        update(&draft)
        if draft.options != oldOptions, draft.optionOverrides == oldOverrides {
            draft.optionOverrides = .explicit(draft.options)
        }
        drafts[identity] = draft
        scheduleAutosave(for: identity)
    }

    func displayURL(for identity: RequestIdentity) -> String {
        guard let request = request(for: identity) else { return "" }
        return QueryParameters.render(baseURL: request.url, fields: request.query)
    }

    func updateURL(_ url: String, for identity: RequestIdentity) {
        updateDraft(identity) { request in
            let parsed = QueryParameters.parse(
                displayURL: url, previousFields: request.query, previousBase: request.url)
            request.url = parsed.baseURL
            request.query = parsed.fields
        }
    }

    func updateQuery(_ fields: [HTTPField], for identity: RequestIdentity) {
        updateDraft(identity) { $0.query = fields }
    }

    func createCollection(name: String) async {
        await initialWorkspaceLoadTask?.value
        guard !workspaceMutationIsBlocked, let store else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }
        guard !workspaceIndexIsReadOnly else {
            operationError = "Collection order is read-only because the workspace index could not be updated."
            return
        }

        await withWorkspaceIndexMutation { [weak self] in
            guard let self else { return }
            do {
                let collection = try await store.createCollection(name: normalizedName)
                self.markWorkspaceChanged()
                self.workspaceIndex = try await store.reorderCollections(
                    ids: self.collections.map(\.id) + [collection.id])
                self.collections = self.ordered(self.collections + [collection])
            } catch {
                self.operationError = error.localizedDescription
                await self.loadWorkspace()
            }
        }
    }

    func renameCollection(id: UUID, name: String) async {
        guard !workspaceMutationIsBlocked,
            !deletingCollections.contains(id),
            store != nil,
            collections.contains(where: { $0.id == id && !$0.isReadOnly })
        else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        await withCollectionMutation(id) { [weak self] in
            await self?.performRenameCollection(id: id, name: normalizedName)
        }
    }

    func deleteCollection(id: UUID) async {
        guard snapshotInventoryAllowsSourceMutation else {
            operationError = "Collections cannot be deleted until snapshot storage is fully available."
            return
        }
        guard !workspaceMutationIsBlocked,
            !deletingCollections.contains(id),
            !deletingRequests.contains(where: { $0.collectionID == id }),
            !automationEditingRequests.contains(where: { $0.collectionID == id }),
            collections.contains(where: { $0.id == id && !$0.isReadOnly })
        else { return }
        guard !workspaceIndexIsReadOnly else {
            operationError = "Collection order is read-only because the workspace index could not be updated."
            return
        }
        deletingCollections.insert(id)
        await withCollectionMutation(id) { [weak self] in
            await self?.performDeleteCollection(id: id)
        }
        deletingCollections.remove(id)
    }

    func createRequest(in collectionID: UUID, name: String = "New request") async {
        guard !workspaceMutationIsBlocked,
            !deletingCollections.contains(collectionID),
            collections.contains(where: { $0.id == collectionID && !$0.isReadOnly })
        else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        await withCollectionMutation(collectionID) { [weak self] in
            await self?.performCreateRequest(
                in: collectionID,
                name: normalizedName.isEmpty ? "New request" : normalizedName
            )
        }
    }

    func duplicateRequest(_ identity: RequestIdentity) async {
        guard canEdit(identity), drafts[identity] != nil else { return }
        await withCollectionMutation(identity.collectionID) { [weak self] in
            await self?.performDuplicateRequest(identity)
        }
    }

    func deleteRequest(_ identity: RequestIdentity) async {
        guard snapshotInventoryAllowsSourceMutation else {
            operationError = "Requests cannot be deleted until snapshot storage is fully available."
            return
        }
        guard !workspaceMutationIsBlocked,
            !deletingCollections.contains(identity.collectionID),
            !deletingRequests.contains(identity),
            canEdit(identity)
        else { return }
        deletingRequests.insert(identity)
        await withCollectionMutation(identity.collectionID) { [weak self] in
            await self?.performDeleteRequest(identity)
        }
        deletingRequests.remove(identity)
    }

    func reorderRequests(_ requestIDs: [UUID], in collectionID: UUID) async {
        guard !workspaceMutationIsBlocked,
            !deletingCollections.contains(collectionID),
            collections.contains(where: { $0.id == collectionID && !$0.isReadOnly })
        else { return }
        await withCollectionMutation(collectionID) { [weak self] in
            await self?.performReorderRequests(requestIDs, in: collectionID)
        }
    }

    func reorderCollections(_ collectionIDs: [UUID]) async {
        guard canReorderCollections else { return }
        await withWorkspaceIndexMutation { [weak self] in
            await self?.performReorderCollections(collectionIDs)
        }
    }

    func moveRequest(
        _ identity: RequestIdentity,
        toCollectionID: UUID,
        beforeRequestID: UUID? = nil
    ) async {
        guard !workspaceMutationIsBlocked,
            !movingRequests.contains(identity),
            !deletingCollections.contains(identity.collectionID),
            !deletingRequests.contains(identity),
            !reconcilingRequests.contains(identity),
            !automationEditingRequests.contains(identity),
            let sourceCollection = collection(for: identity),
            !sourceCollection.isReadOnly,
            sourceCollection.requests.contains(where: { $0.id == identity.requestID })
        else { return }

        if identity.collectionID == toCollectionID {
            guard let collection = collections.first(where: { $0.id == toCollectionID }),
                beforeRequestID != identity.requestID
            else { return }
            var orderedIDs = collection.requests.map(\.id).filter { $0 != identity.requestID }
            let insertionIndex = beforeRequestID.flatMap { id in orderedIDs.firstIndex(of: id) } ?? orderedIDs.endIndex
            orderedIDs.insert(identity.requestID, at: insertionIndex)
            await reorderRequests(orderedIDs, in: toCollectionID)
            return
        }

        guard snapshotInventoryAllowsSourceMutation else {
            operationError = "Requests cannot move between collections until snapshot storage is fully available."
            return
        }

        guard let destinationCollection = collections.first(where: { $0.id == toCollectionID }) else {
            operationError = "The destination collection is no longer available."
            return
        }
        guard !destinationCollection.isReadOnly else {
            operationError = "Requests cannot be moved into a read-only collection."
            return
        }

        guard !workspaceIndexIsReadOnly else {
            operationError = "Requests cannot move while the workspace index is read-only."
            return
        }
        guard activeRuns[identity] == nil else {
            operationError = "Stop the request before moving it to another collection."
            return
        }

        let destinationIdentity = RequestIdentity(collectionID: toCollectionID, requestID: identity.requestID)
        guard !movingRequests.contains(destinationIdentity) else { return }
        movingRequests.formUnion([identity, destinationIdentity])
        invalidateSecretEdits(for: .request(identity))
        if let definition = variableDefinitionRequest,
            case let .request(definitionIdentity) = definition.owner,
            definitionIdentity == identity
        {
            variableDefinitionRequest = nil
        }
        defer {
            movingRequests.remove(identity)
            movingRequests.remove(destinationIdentity)
        }
        await withCollectionMutations([identity.collectionID, toCollectionID]) { [weak self] in
            await self?.performMoveRequest(identity, toCollectionID: toCollectionID, beforeRequestID: beforeRequestID)
        }
    }

    func moveRequest(_ identity: RequestIdentity, by offset: Int) async {
        guard let collection = collections.first(where: { $0.id == identity.collectionID }),
            let currentIndex = collection.requests.firstIndex(where: { $0.id == identity.requestID })
        else { return }
        let destinationIndex = currentIndex + offset
        guard collection.requests.indices.contains(destinationIndex) else { return }
        var requestIDs = collection.requests.map(\.id)
        requestIDs.swapAt(currentIndex, destinationIndex)
        await reorderRequests(requestIDs, in: identity.collectionID)
    }

    func recover(_ issue: StorageIssue) async {
        guard issue.canRecover,
            let collectionID = issue.collectionID,
            let requestID = issue.requestID,
            !workspaceMutationIsBlocked,
            !deletingCollections.contains(collectionID),
            let store
        else { return }

        await withCollectionMutation(collectionID) { [weak self] in
            guard let self else { return }
            do {
                try await store.recoverRequest(id: requestID, in: collectionID)
                self.markWorkspaceChanged()
                await self.loadWorkspace()
            } catch {
                self.operationError = error.localizedDescription
                await self.loadWorkspace()
            }
        }
    }

    func retryAutosave(for identity: RequestIdentity) {
        guard canEdit(identity), drafts[identity] != nil else { return }
        autosaveErrors.removeValue(forKey: identity)
        scheduleAutosave(for: identity, delayNanoseconds: 0)
    }

    func flushPendingSaves() async throws {
        try await drainAcceptedMutations()
        let identities = Array(dirtyDrafts)
        let variableOwners = Array(dirtyVariableOwners)
        guard !identities.isEmpty || !variableOwners.isEmpty || !secretCommitErrors.isEmpty else { return }
        guard store != nil else { throw SaveFlushError.workspaceUnavailable }

        for identity in identities {
            pendingSaveTasks.removeValue(forKey: identity)?.cancel()
            let version = (editVersions[identity] ?? 0) &+ 1
            editVersions[identity] = version
            autosaveErrors.removeValue(forKey: identity)
            guard let draft = drafts[identity] else { continue }
            enqueueSave(draft, for: identity, version: version)
        }

        for owner in variableOwners {
            pendingVariableSaves.removeValue(forKey: owner)?.cancel()
            variableVersions[owner, default: 0] &+= 1
            enqueueVariableSave(variables(for: owner), owner: owner, version: variableVersions[owner, default: 0])
        }

        for identity in identities {
            await saveChains[identity]?.value
        }
        for owner in variableOwners {
            await variableSaveChains[owner]?.value
        }

        var failures = identities.compactMap { identity -> String? in
            guard dirtyDrafts.contains(identity) else { return nil }
            let name = drafts[identity]?.name ?? "Deleted request"
            let detail = autosaveErrors[identity] ?? "The latest change is still unsaved."
            return "\(name): \(detail)"
        }
        failures.append(
            contentsOf: variableOwners.compactMap { owner in
                guard dirtyVariableOwners.contains(owner) else { return nil }
                return scopeSaveErrors[owner] ?? "Variable changes are still unsaved."
            })
        failures.append(contentsOf: secretCommitErrors.values)
        guard failures.isEmpty else { throw SaveFlushError.failed(failures) }
    }

    func prepareForTermination() async -> Bool {
        guard !isTerminating, !isRotatingEncryptionKey else { return false }
        isTerminating = true
        do {
            try await drainAcceptedMutations()
            if !encryptionRecoveryRequired { try await flushPendingSaves() }
            for identity in Array(preparationTasks.keys) where activeRuns[identity]?.runID == nil {
                cancelRequest(identity)
            }
            await waitForSnapshotSaves()
            await releaseBodyResources()
            await sessionHistory.clear()
            await executionManager?.shutdown()
            return true
        } catch {
            isTerminating = false
            operationError = error.localizedDescription
            return false
        }
    }

    func curlCommand(for identity: RequestIdentity) async throws -> String {
        guard workspaceLoaded, !isTerminating,
            let original = request(for: identity),
            let collection = collection(for: identity)
        else { throw ConfigurationEditError.unavailable }

        let context = variableContext(for: identity)
        let defaults = CollectionRequestDefaults(headers: collection.headers, authentication: collection.authentication)
        let options = requestOptionOverrides(for: identity).resolve(against: globalOptions)
        var configuration = original
        configuration.options = options
        let prepared = try await RequestPreparer.prepare(
            configuration, context: context, decryptor: secretVault, collection: defaults)
        try Task.checkCancellation()
        guard !workspaceMutationIsBlocked, request(for: identity) == original,
            variableContext(for: identity) == context,
            self.collection(for: identity)?.headers == defaults.headers,
            self.collection(for: identity)?.authentication == defaults.authentication,
            requestOptionOverrides(for: identity).resolve(against: globalOptions) == options
        else { throw ConfigurationEditError.unavailable }
        return try CURLExport.command(for: prepared, configuration: configuration)
    }

    func startRequest(_ identity: RequestIdentity) {
        guard canEdit(identity),
            activeRuns[identity] == nil,
            var configuration = drafts[identity],
            let collection = collection(for: identity),
            let executionManager
        else { return }

        configuration.options = requestOptionOverrides(for: identity).resolve(against: globalOptions)
        let snapshotSource = SnapshotSource(
            identity: identity,
            collectionName: collection.name,
            requestName: configuration.name
        )

        let token = UUID()
        let context = variableContext(for: identity)
        let collectionDefaults = CollectionRequestDefaults(
            headers: collection.headers,
            authentication: collection.authentication
        )
        let secretVault = secretVault
        activeRuns[identity] = ActiveRun(
            token: token,
            request: configuration,
            snapshotSource: snapshotSource,
            startedAt: Date(),
            phase: .preparing,
            runID: nil,
            progress: nil,
            redirects: [],
            cancelRequested: false
        )
        if let active = activeRuns[identity] { sessionHistory.begin(identity: identity, active: active) }
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        preparationTasks[identity] = Task { [weak self] in
            do {
                let prepared = try await RequestPreparer.prepare(
                    configuration, context: context, decryptor: secretVault,
                    collection: collectionDefaults, captureRedactionInputs: true
                )
                try Task.checkCancellation()
                guard let self, var active = self.activeRuns[identity], active.token == token else { return }
                active.snapshotCapture = prepared.snapshotCapture
                self.activeRuns[identity] = active
                self.sessionHistory.update(active)
                guard self.canEdit(identity), self.activeRuns[identity]?.cancelRequested == false else {
                    self.cancelledRequests.insert(identity)
                    self.settleRun(identity, token: token, terminal: .cancelled)
                    return
                }
                let run = try await executionManager.start(identity: identity, prepared: prepared)
                await self.observe(run, for: identity, token: token, using: executionManager)
            } catch is CancellationError {
                guard let self, self.activeRuns[identity]?.token == token else { return }
                self.cancelledRequests.insert(identity)
                self.settleRun(identity, token: token, terminal: .cancelled)
            } catch {
                self?.finishRun(identity, token: token, error: error.localizedDescription)
            }
        }
    }

    func followRedirect(_ identity: RequestIdentity) {
        guard canFollowRedirect(identity),
            let response = latestResponses[identity]?.response,
            let redirectRequest = response.redirectRequest,
            let redirectURL = redirectRequest.url,
            let executionManager
        else { return }

        var currentRequest = response.request
        currentRequest.url = redirectURL.absoluteString
        currentRequest.method =
            redirectRequest.httpMethod ?? response.pendingRedirect?.nextMethod ?? currentRequest.method

        let token = UUID()
        activeRuns[identity] = ActiveRun(
            token: token,
            request: currentRequest,
            snapshotSource: latestResponses[identity]?.snapshotSource,
            snapshotCapture: response.snapshotCapture,
            startedAt: Date(),
            phase: .preparing,
            runID: nil,
            progress: nil,
            redirects: response.redirects,
            cancelRequested: false
        )
        if let active = activeRuns[identity] { sessionHistory.begin(identity: identity, active: active) }
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        preparationTasks[identity] = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.activeRuns[identity]?.token == token else { return }
                guard self.canEdit(identity), self.activeRuns[identity]?.cancelRequested == false else {
                    self.cancelledRequests.insert(identity)
                    self.settleRun(identity, token: token, terminal: .cancelled)
                    return
                }
                let run = try await executionManager.followRedirect(identity: identity, response: response)
                await self.observe(run, for: identity, token: token, using: executionManager)
            } catch is CancellationError {
                guard let self, self.activeRuns[identity]?.token == token else { return }
                self.cancelledRequests.insert(identity)
                self.settleRun(identity, token: token, terminal: .cancelled)
            } catch {
                self?.finishRun(identity, token: token, error: error.localizedDescription)
            }
        }
    }

    private func observe(
        _ run: HTTPRun,
        for identity: RequestIdentity,
        token: UUID,
        using executionManager: HTTPExecutionManager
    ) async {
        guard var active = activeRuns[identity], active.token == token else {
            await executionManager.cancel(identity: identity, runID: run.id)
            return
        }

        active.runID = run.id
        active.phase = active.cancelRequested ? .cancelling : .running
        activeRuns[identity] = active
        sessionHistory.update(active)
        if active.cancelRequested {
            await executionManager.cancel(identity: identity, runID: run.id)
        }

        var receivedTerminalEvent = false
        for await event in run.events {
            guard activeRuns[identity]?.token == token,
                activeRuns[identity]?.runID == run.id
            else { break }
            if await receive(event, for: identity, token: token, runID: run.id) {
                receivedTerminalEvent = true
                break
            }
        }

        if !receivedTerminalEvent {
            finishRun(
                identity,
                token: token,
                runID: run.id,
                error: "The request ended without a final result."
            )
        }
    }

    func cancelRequest(_ identity: RequestIdentity) {
        guard var active = activeRuns[identity] else { return }
        active.cancelRequested = true
        active.phase = .cancelling
        activeRuns[identity] = active
        sessionHistory.update(active)
        guard active.runID != nil else {
            preparationTasks.removeValue(forKey: identity)?.cancel()
            cancelledRequests.insert(identity)
            settleRun(identity, token: active.token, terminal: .cancelled)
            return
        }
        guard let runID = active.runID, let executionManager else { return }
        Task {
            await executionManager.cancel(identity: identity, runID: runID)
        }
    }

    func cancelAndWait(for identity: RequestIdentity) async {
        guard activeRuns[identity] != nil else { return }
        cancelRequest(identity)
        guard activeRuns[identity] != nil else { return }
        await withCheckedContinuation { continuation in
            settlementWaiters[identity, default: []].append(continuation)
        }
    }

    func cancelHistoryRun(token: UUID) {
        guard let identity = sessionHistory.entry(for: token)?.liveSourceIdentity,
            activeRuns[identity]?.token == token
        else { return }
        cancelRequest(identity)
    }

    func openHistorySource(token: UUID) {
        guard let identity = sessionHistory.entry(for: token)?.liveSourceIdentity,
            request(for: identity) != nil
        else { return }
        select(identity)
    }

    func withRetainedResponse<Value>(
        for token: UUID,
        operation: @MainActor (HTTPResponseRecord, URL) async throws -> Value
    ) async throws -> Value {
        try await sessionHistory.withRetainedResponse(for: token, operation: operation)
    }

    func acquireBodyResource(from source: ResponseBodySource) async throws -> ResponseBodyResource {
        try Task.checkCancellation()
        guard !workspaceMutationIsBlocked else { throw ResponseBodyAccessError.unavailable }
        let resource: ResponseBodyResource
        switch source {
        case let .live(response):
            guard let executionManager else { throw ResponseBodyAccessError.unavailable }
            let lease = try await executionManager.acquireBodyLease(for: response)
            resource = ResponseBodyResource(url: lease.bodyURL, origin: .live(response.runID)) {
                await executionManager.releaseBodyLease(lease)
            }
        case let .history(token, response):
            guard sessionHistory.entry(for: token)?.response?.runID == response.runID else {
                throw ResponseBodyAccessError.unavailable
            }
            resource = try await sessionHistory.acquireBodyResource(for: token)
        case let .snapshot(id, response):
            guard !deletingBodySnapshotIDs.contains(id),
                snapshots.contains(where: { $0.id == id }),
                let opened = openedSnapshots[id], opened.response.runID == response.runID,
                opened.response.bodyFileURL == response.bodyFileURL
            else { throw ResponseBodyAccessError.unavailable }
            resource = ResponseBodyResource(url: response.bodyFileURL, origin: .snapshot(id))
        }
        guard !workspaceMutationIsBlocked, !Task.isCancelled else {
            await resource.invalidate()
            throw ResponseBodyAccessError.unavailable
        }
        responseBodyResources[resource.id] = resource
        return resource
    }

    func releaseBodyResource(_ id: UUID) async {
        guard let resource = responseBodyResources.removeValue(forKey: id) else { return }
        await resource.invalidate()
    }

    private func releaseBodyResources(for origin: ResponseBodyResource.Origin? = nil) async {
        let resources = responseBodyResources.values.filter { origin == nil || $0.origin == origin }
        for resource in resources {
            responseBodyResources.removeValue(forKey: resource.id)
            await resource.invalidate()
        }
    }

    func withResponseBody<Value: Sendable>(
        for response: HTTPResponseRecord,
        operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !workspaceMutationIsBlocked, let executionManager else { throw ResponseBodyAccessError.unavailable }
        let lease = try await executionManager.acquireBodyLease(for: response)
        do {
            try Task.checkCancellation()
            let value = try await operation(lease.bodyURL)
            await executionManager.releaseBodyLease(lease)
            return value
        } catch {
            await executionManager.releaseBodyLease(lease)
            throw error
        }
    }

    func loadPreview(for identity: RequestIdentity) {
        guard var latest = latestResponses[identity],
            latest.preview == nil,
            latest.previewError == nil,
            !latest.isLoadingPreview,
            previewTasks[identity] == nil
        else { return }

        let response = latest.response
        latest.isLoadingPreview = true
        latestResponses[identity] = latest

        let task = Task.detached(priority: .userInitiated) {
            try ResponseBodyReader.preview(at: response.bodyFileURL, maximumBytes: 1_048_576)
        }
        previewTasks[identity] = PendingPreview(runID: response.runID, task: task)

        Task { [weak self] in
            do {
                let preview = try await task.value
                self?.finishPreview(preview, for: identity, runID: response.runID)
            } catch {
                self?.failPreview(error.localizedDescription, for: identity, runID: response.runID)
            }
        }
    }

    func retryPreview(for identity: RequestIdentity) {
        guard var latest = latestResponses[identity] else { return }
        latest.previewError = nil
        latest.isLoadingPreview = false
        latestResponses[identity] = latest
        loadPreview(for: identity)
    }

    func response(for identity: RequestIdentity) -> LatestResponse? {
        latestResponses[identity]
    }

    func snapshots(for identity: RequestIdentity) -> [SavedSnapshot] {
        snapshots.filter { snapshotGrouping(for: $0).identity == identity }
    }

    func canSaveSnapshot(for identity: RequestIdentity) -> Bool {
        guard !workspaceMutationIsBlocked,
            snapshotStore != nil,
            executionManager != nil,
            !movingRequests.contains(identity),
            !deletingCollections.contains(identity.collectionID),
            !deletingRequests.contains(identity),
            let latest = latestResponses[identity],
            latest.snapshotSource != nil,
            latest.response.snapshotCapture != nil
        else { return false }
        return !savingSnapshotRunIDs.contains(latest.response.runID)
    }

    func isSavingSnapshot(for identity: RequestIdentity) -> Bool {
        guard let runID = latestResponses[identity]?.response.runID else { return false }
        return savingSnapshotRunIDs.contains(runID)
    }

    func saveSnapshot(for identity: RequestIdentity) {
        guard canSaveSnapshot(for: identity),
            let latest = latestResponses[identity],
            let source = latest.snapshotSource
        else { return }

        let response = latest.response
        let runID = response.runID
        let operationID = UUID()
        let name = Self.defaultSnapshotName(source: source, completedAt: response.completedAt)
        let task = Task { @MainActor [self] in
            await performSnapshotSave(
                response: response,
                source: source,
                name: name,
                runID: runID,
                operationID: operationID
            )
        }
        snapshotSaveTasks[runID, default: [:]][operationID] = task
        savingSnapshotRunIDs.insert(runID)
    }

    func renameSnapshot(id: UUID, name: String) async {
        guard !workspaceMutationIsBlocked, let snapshotStore else { return }
        do {
            let saved = try await snapshotStore.rename(id: id, name: name)
            upsertSnapshot(saved)
        } catch {
            operationError = error.localizedDescription
        }
    }

    func deleteSnapshot(id: UUID) async {
        guard !workspaceMutationIsBlocked, let snapshotStore else { return }
        await withWorkspaceIndexMutation { [weak self] in
            guard let self, !self.isTerminating else { return }
            do {
                self.deletingBodySnapshotIDs.insert(id)
                defer { self.deletingBodySnapshotIDs.remove(id) }
                await self.releaseBodyResources(for: .snapshot(id))
                try await snapshotStore.delete(id: id)
                self.markWorkspaceChanged()
                self.snapshots.removeAll { $0.id == id }
                self.openedSnapshots.removeValue(forKey: id)
                self.openingSnapshots.remove(id)
                self.snapshotOpenErrors.removeValue(forKey: id)
                if self.selectedSnapshotID == id { self.selectedSnapshotID = nil }
                guard let store = self.store else { return }
                do {
                    self.workspaceIndex = try await store.removeSnapshotGrouping(id: id)
                } catch {
                    self.operationError = error.localizedDescription
                    await self.loadWorkspace()
                }
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }

    func snapshotOpenError(for id: UUID) -> String? {
        snapshotOpenErrors[id]
    }

    func exportEncryptionKey() async throws -> Data {
        await initialWorkspaceLoadTask?.value
        guard workspaceLoaded, !workspaceMutationIsBlocked, let keyRotation, try await !keyRotation.isPending() else {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }
        return try await secretVault.exportKey()
    }

    var canRotateEncryptionKey: Bool {
        workspaceLoaded && !workspaceMutationIsBlocked && activeRuns.isEmpty
            && preparationTasks.isEmpty && secretCommitTasks.isEmpty && secretCommitErrors.isEmpty
    }

    func rotateEncryptionKey() async throws {
        guard canRotateEncryptionKey, let keyRotation else {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }
        keyRotationIsRunning = true
        defer { keyRotationIsRunning = false }
        var attemptedRotation = false
        do {
            try await flushPendingSaves()
            await waitForSnapshotSaves()
            guard activeRuns.isEmpty, preparationTasks.isEmpty, secretCommitTasks.isEmpty else {
                throw EncryptionKeyTransferError.workspaceChanged
            }
            _ = try await encryptionEnvelopesForKeyImport()
            attemptedRotation = true
            try await keyRotation.rotate()
            drafts.removeAll()
            openedSnapshots.removeAll()
            snapshotOpenErrors.removeAll()
            await loadWorkspace()
            guard workspaceLoaded else { throw EncryptionKeyTransferError.workspaceUnavailable }
        } catch {
            if (try? await keyRotation.isPending()) != false {
                encryptionRecoveryRequired = true
                workspaceLoaded = false
                startupError =
                    "Encryption-key rotation needs recovery. Reopen Postie to resume. "
                    + error.localizedDescription
            } else if attemptedRotation {
                drafts.removeAll()
                openedSnapshots.removeAll()
                snapshotOpenErrors.removeAll()
                await loadWorkspace()
            }
            throw error
        }
    }

    func mcpBearerToken() async throws -> String {
        await initialWorkspaceLoadTask?.value
        guard workspaceLoaded, !isTerminating, !isRotatingEncryptionKey, let mcpTokenStore else {
            throw AutomationFailure(.unavailable, "The workspace is unavailable.")
        }
        let result = AutomationResultBox<String>()
        await withWorkspaceIndexMutation { [self] in
            guard workspaceLoaded, !isTerminating, !isRotatingEncryptionKey else {
                result.result = .failure(AutomationFailure(.unavailable, "The workspace is unavailable."))
                return
            }
            do {
                let token = try await mcpTokenStore.token()
                await secretVault.setAllowsKeyCreation(false)
                markWorkspaceChanged()
                guard !isTerminating else { throw CancellationError() }
                result.result = .success(token)
            } catch {
                result.result = .failure(error)
            }
        }
        guard let value = result.result else {
            throw AutomationFailure(.unavailable, "The MCP access token is unavailable.")
        }
        return try value.get()
    }

    func importEncryptionKey(_ key: Data) async throws -> SecretKeyImportResult {
        await initialWorkspaceLoadTask?.value
        guard workspaceLoaded, !workspaceMutationIsBlocked, let keyRotation, try await !keyRotation.isPending() else {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }
        let envelopes = try await encryptionEnvelopesForKeyImport()
        guard !isRotatingEncryptionKey else { throw EncryptionKeyTransferError.workspaceChanged }
        let result = try await secretVault.importKey(key, validating: envelopes)
        await refreshSelectedSnapshotAfterKeyImport()
        return result
    }

    func elapsed(for identity: RequestIdentity) -> TimeInterval? {
        activeRuns[identity].map { max(0, now.timeIntervalSince($0.startedAt)) }
    }

    private func performSnapshotSave(
        response: HTTPResponseRecord,
        source: SnapshotSource,
        name: String,
        runID: UUID,
        operationID: UUID
    ) async {
        do {
            _ = try await saveSnapshotRecord(
                response: response,
                source: source,
                name: name,
                runID: runID,
                operationID: operationID
            )
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveSnapshotRecord(
        response: HTTPResponseRecord,
        source: SnapshotSource,
        name: String,
        runID: UUID,
        operationID: UUID
    ) async throws -> SavedSnapshot {
        defer { finishSnapshotSave(runID: runID, operationID: operationID) }
        guard let snapshotStore, let executionManager else {
            throw SnapshotSaveFailure.storageUnavailable
        }

        let lease: HTTPBodyLease
        do {
            lease = try await executionManager.acquireBodyLease(for: response)
        } catch {
            throw SnapshotSaveFailure.bodyUnavailable
        }

        do {
            let saved = try await snapshotStore.save(
                response: response,
                source: source,
                name: name,
                bodyLease: lease
            )
            await executionManager.releaseBodyLease(lease)
            upsertSnapshot(saved)
            return saved
        } catch {
            await executionManager.releaseBodyLease(lease)
            throw error
        }
    }

    private func finishSnapshotSave(runID: UUID, operationID: UUID) {
        snapshotSaveTasks[runID]?.removeValue(forKey: operationID)
        if snapshotSaveTasks[runID]?.isEmpty == true {
            snapshotSaveTasks.removeValue(forKey: runID)
            savingSnapshotRunIDs.remove(runID)
        }
    }

    private func upsertSnapshot(_ snapshot: SavedSnapshot) {
        markWorkspaceChanged()
        snapshots.removeAll { $0.id == snapshot.id }
        snapshots.append(snapshot)
        snapshots = Self.sortedSnapshots(snapshots)
        if let opened = openedSnapshots[snapshot.id] {
            openedSnapshots[snapshot.id] = OpenedSnapshot(
                summary: snapshot,
                template: opened.template,
                context: opened.context,
                contextError: opened.contextError,
                response: opened.response
            )
        }
    }

    private func openSnapshotIfNeeded(_ id: UUID) {
        guard openedSnapshots[id] == nil,
            !openingSnapshots.contains(id),
            let snapshotStore
        else { return }
        openingSnapshots.insert(id)
        snapshotOpenErrors.removeValue(forKey: id)
        Task { @MainActor [weak self, snapshotStore] in
            do {
                let opened = try await snapshotStore.open(id: id)
                guard let self else { return }
                if self.selectedSnapshotID == id,
                    self.snapshots.contains(where: { $0.id == id })
                {
                    self.openedSnapshots[id] = opened
                }
                self.openingSnapshots.remove(id)
            } catch {
                guard let self else { return }
                if self.selectedSnapshotID == id {
                    self.snapshotOpenErrors[id] = error.localizedDescription
                }
                self.openingSnapshots.remove(id)
            }
        }
    }

    private static func defaultSnapshotName(source: SnapshotSource, completedAt: Date) -> String {
        "\(source.requestName) · \(completedAt.formatted(date: .numeric, time: .shortened))"
    }

    private static func sortedSnapshots(_ snapshots: [SavedSnapshot]) -> [SavedSnapshot] {
        snapshots.sorted {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func waitForSnapshotSaves() async {
        let tasks = snapshotSaveTasks.values.flatMap(\.values)
        for task in tasks { await task.value }
    }

    private func encryptionEnvelopesForKeyImport() async throws -> [SecretEnvelope] {
        guard workspaceLoaded, !isTerminating, let store, let snapshotStore, let mcpTokenStore else {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }

        let currentGlobals = globalVariables
        let currentCollections = collections
        let currentDrafts = drafts
        let currentSnapshots = snapshots
        let currentStorageIssues = storageIssues
        let currentSnapshotStorageIssues = snapshotStorageIssues
        let currentSnapshotLoadError = snapshotLoadError
        let tokenEnvelope: SecretEnvelope?
        do {
            tokenEnvelope = try await mcpTokenStore.storedEnvelope()
        } catch {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }
        guard !globalVariablesAreReadOnly, !globalOptionsAreReadOnly,
            !currentCollections.contains(where: \.isReadOnly), currentStorageIssues.isEmpty,
            currentSnapshotStorageIssues.isEmpty, currentSnapshotLoadError == nil,
            variableSaveErrors.isEmpty, scopeSaveErrors.isEmpty, autosaveErrors.isEmpty
        else {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        let loaded: WorkspaceLoad
        do {
            loaded = try await store.load()
        } catch {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }
        guard loaded.issues.isEmpty, !loaded.globalVariablesAreReadOnly, !loaded.globalOptionsAreReadOnly,
            !loaded.collections.contains(where: \.isReadOnly)
        else {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        let snapshotEnvelopes: [SecretEnvelope]
        do {
            snapshotEnvelopes = try await snapshotStore.encryptionEnvelopes()
        } catch {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        let latestTokenEnvelope: SecretEnvelope?
        do {
            latestTokenEnvelope = try await mcpTokenStore.storedEnvelope()
        } catch {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        guard workspaceLoaded, !isTerminating,
            globalVariables == currentGlobals, collections == currentCollections,
            drafts == currentDrafts, snapshots == currentSnapshots,
            storageIssues == currentStorageIssues, snapshotStorageIssues == currentSnapshotStorageIssues,
            snapshotLoadError == currentSnapshotLoadError,
            tokenEnvelope == latestTokenEnvelope,
            !globalVariablesAreReadOnly, !globalOptionsAreReadOnly,
            !collections.contains(where: \.isReadOnly), variableSaveErrors.isEmpty,
            scopeSaveErrors.isEmpty, autosaveErrors.isEmpty
        else {
            throw EncryptionKeyTransferError.workspaceChanged
        }

        var envelopes = Self.encryptedEnvelopes(in: currentGlobals)
        envelopes += Self.encryptedEnvelopes(in: loaded.globalVariables)
        for collection in currentCollections + loaded.collections {
            envelopes += Self.encryptedEnvelopes(in: collection)
        }
        for request in currentDrafts.values {
            envelopes += Self.encryptedEnvelopes(in: request)
        }
        return envelopes + snapshotEnvelopes + (tokenEnvelope.map { [$0] } ?? [])
    }

    private static func encryptedEnvelopes(in values: VariableValues) -> [SecretEnvelope] {
        values.values.compactMap { value in
            guard case let .encrypted(envelope) = value else { return nil }
            return envelope
        }
    }

    private static func encryptedEnvelopes(in authentication: RequestAuthentication) -> [SecretEnvelope] {
        [authentication.password, authentication.token, authentication.apiKey].compactMap { $0 }
    }

    private static func encryptedEnvelopes(in request: HTTPRequestConfiguration) -> [SecretEnvelope] {
        encryptedEnvelopes(in: request.variables) + encryptedEnvelopes(in: request.authentication)
    }

    private static func encryptedEnvelopes(in collection: RequestCollection) -> [SecretEnvelope] {
        var envelopes = encryptedEnvelopes(in: collection.variables) + encryptedEnvelopes(in: collection.authentication)
        for request in collection.requests {
            envelopes += encryptedEnvelopes(in: request)
        }
        return envelopes
    }

    private func refreshSelectedSnapshotAfterKeyImport() async {
        guard !isTerminating,
            let id = selectedSnapshotID,
            snapshots.contains(where: { $0.id == id }),
            !openingSnapshots.contains(id),
            let opened = openedSnapshots[id],
            opened.context == nil,
            opened.contextError?.contains(SecretVaultError.missingKey.localizedDescription) == true,
            let snapshotStore
        else { return }

        openedSnapshots.removeValue(forKey: id)
        snapshotOpenErrors.removeValue(forKey: id)
        openingSnapshots.insert(id)
        do {
            let refreshed = try await snapshotStore.open(id: id)
            if selectedSnapshotID == id, snapshots.contains(where: { $0.id == id }), !isTerminating {
                openedSnapshots[id] = refreshed
            }
        } catch {
            if selectedSnapshotID == id {
                snapshotOpenErrors[id] = error.localizedDescription
            }
        }
        openingSnapshots.remove(id)
    }

    private func loadWorkspace() async {
        guard let store else { return }
        encryptionLoadCount += 1
        defer { encryptionLoadCount -= 1 }
        workspaceLoaded = false
        await secretVault.setAllowsKeyCreation(false)
        do {
            if keyPreparationTask == nil {
                keyPreparationTask = Task { [keyRotation] in try await keyRotation?.prepareWorkspace() }
            }
            try await keyPreparationTask?.value
            encryptionRecoveryRequired = false
        } catch {
            encryptionRecoveryRequired = true
            startupError = "Encryption-key recovery could not finish. " + error.localizedDescription
            return
        }
        while true {
            let revision = workspaceRevision
            do {
                let loaded = try await store.load()
                let snapshotLoad: SnapshotLoad?
                let snapshotError: String?
                do {
                    snapshotLoad = try await snapshotStore?.load()
                    snapshotError = nil
                } catch {
                    snapshotLoad = nil
                    snapshotError = error.localizedDescription
                }
                let tokenKeyStateIsSafe: Bool
                do {
                    if let mcpTokenStore {
                        tokenKeyStateIsSafe = try await mcpTokenStore.storedEnvelope() == nil
                    } else {
                        tokenKeyStateIsSafe = false
                    }
                } catch {
                    tokenKeyStateIsSafe = false
                }
                guard revision == workspaceRevision else { continue }
                let available = Dictionary(
                    uniqueKeysWithValues: loaded.collections.flatMap { collection in
                        collection.requests.map { (RequestIdentity(collectionID: collection.id, requestID: $0.id), $0) }
                    })
                let indexedIssues = Self.indexedIssueIdentities(loaded.issues)
                let tracked = trackedRequestIdentities()
                let unindexedIssues = Self.unindexedIssueIdentities(loaded.issues)
                let readOnlyCollectionIDs = Set(loaded.collections.filter(\.isReadOnly).map(\.id))
                let readOnlyMembers = Set(
                    tracked.filter {
                        readOnlyCollectionIDs.contains($0.collectionID) && !unindexedIssues.contains($0)
                    })
                let workspaceMembers = Set(available.keys)
                    .union(indexedIssues)
                    .union(readOnlyMembers)
                    .subtracting(unindexedIssues)
                let unavailable = tracked.subtracting(workspaceMembers)
                reconcilingRequests.formUnion(unavailable)
                for identity in unavailable {
                    await cancelAndWait(for: identity)
                    await waitForSaves(for: identity)
                }
                guard revision == workspaceRevision else { continue }

                let retainedCollections = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
                let nextCollections = Self.ordered(
                    loaded.collections.map { collection in
                        var collection = collection
                        if dirtyVariableOwners.contains(.collection(collection.id)),
                            let retained = retainedCollections[collection.id]
                        {
                            collection.variables = retained.variables
                            collection.headers = retained.headers
                            collection.authentication = retained.authentication
                        }
                        return collection
                    }, by: loaded.workspaceIndex)
                let nextGlobals = dirtyVariableOwners.contains(.global) ? globalVariables : loaded.globalVariables
                var nextDrafts = drafts.filter { !unavailable.contains($0.key) }
                for (identity, request) in available where nextDrafts[identity] == nil {
                    nextDrafts[identity] = request
                }
                let hasCiphertext =
                    nextGlobals.values.contains(where: \.isEncrypted)
                    || loaded.globalVariables.values.contains(where: \.isEncrypted)
                    || nextCollections.contains(where: Self.containsCiphertext)
                    || loaded.collections.contains(where: Self.containsCiphertext)
                    || available.values.contains(where: Self.containsCiphertext)
                    || nextDrafts.values.contains(where: Self.containsCiphertext)
                let snapshotKeyStateIsSafe =
                    snapshotError == nil && snapshotLoad?.containsEncryptedData == false
                    && snapshotLoad?.issues.isEmpty == true
                await secretVault.setAllowsKeyCreation(
                    !hasCiphertext && snapshotKeyStateIsSafe && tokenKeyStateIsSafe && loaded.issues.isEmpty
                        && !loaded.globalVariablesAreReadOnly && !loaded.collections.contains(where: \.isReadOnly))
                guard revision == workspaceRevision else {
                    await secretVault.setAllowsKeyCreation(false)
                    continue
                }
                workspaceRevision &+= 1
                for identity in unavailable {
                    removeLocalRequestState(for: identity)
                }
                workspaceIndex = loaded.workspaceIndex
                workspaceIndexIsReadOnly = loaded.workspaceIndexIsReadOnly
                globalMCPResponseViewing = loaded.globalMCPResponseViewing
                collections = nextCollections
                snapshotLoadError = snapshotError
                if let snapshotLoad {
                    snapshots = Self.sortedSnapshots(snapshotLoad.snapshots)
                    snapshotStorageIssues = snapshotLoad.issues
                    let loadedIDs = Set(snapshotLoad.snapshots.map(\.id))
                    openedSnapshots = openedSnapshots.filter { loadedIDs.contains($0.key) }
                    openingSnapshots.formIntersection(loadedIDs)
                    snapshotOpenErrors = snapshotOpenErrors.filter { loadedIDs.contains($0.key) }
                    if let selectedSnapshotID, !loadedIDs.contains(selectedSnapshotID) {
                        self.selectedSnapshotID = nil
                    }
                }
                if let selectedCollectionID, !nextCollections.contains(where: { $0.id == selectedCollectionID }) {
                    self.selectedCollectionID = nil
                }
                requestEditorSections = requestEditorSections.filter { workspaceMembers.contains($0.key) }
                requestEditorExpansionStates = requestEditorExpansionStates.filter { workspaceMembers.contains($0.key) }
                globalVariables = nextGlobals
                globalVariablesAreReadOnly = loaded.globalVariablesAreReadOnly
                if !dirtyVariableOwners.contains(.global) { globalOptions = loaded.globalOptions }
                globalOptionsAreReadOnly = loaded.globalOptionsAreReadOnly
                storageIssues = loaded.issues
                for identity in nextDrafts.keys where drafts[identity] == nil {
                    editVersions[identity] = 0
                }
                drafts = nextDrafts
                workspaceLoaded = true
                if selectedIdentity.map({ !workspaceMembers.contains($0) }) ?? true {
                    selectFirstRequest()
                }
                reconcilingRequests.removeAll()
                startupError = nil
                return
            } catch {
                guard revision == workspaceRevision else { continue }
                startupError = error.localizedDescription
                return
            }
        }
    }

    private func trackedRequestIdentities() -> Set<RequestIdentity> {
        var identities = Set(drafts.keys)
        identities.formUnion(activeRuns.keys)
        identities.formUnion(latestResponses.keys)
        identities.formUnion(runErrors.keys)
        identities.formUnion(cancelledRequests)
        identities.formUnion(autosaveErrors.keys)
        identities.formUnion(dirtyDrafts)
        identities.formUnion(pendingSaveTasks.keys)
        identities.formUnion(saveChains.keys)
        identities.formUnion(previewTasks.keys)
        identities.formUnion(settlementWaiters.keys)
        if let selectedIdentity { identities.insert(selectedIdentity) }
        return identities
    }

    private static func indexedIssueIdentities(_ issues: [StorageIssue]) -> Set<RequestIdentity> {
        Set(
            issues.compactMap { issue in
                guard let collectionID = issue.collectionID,
                    let requestID = issue.requestID,
                    !isUnindexedRequestIssue(issue)
                else { return nil }
                return RequestIdentity(collectionID: collectionID, requestID: requestID)
            })
    }

    private static func unindexedIssueIdentities(_ issues: [StorageIssue]) -> Set<RequestIdentity> {
        Set(
            issues.compactMap { issue in
                guard isUnindexedRequestIssue(issue),
                    let collectionID = issue.collectionID,
                    let requestID = issue.requestID
                else { return nil }
                return RequestIdentity(collectionID: collectionID, requestID: requestID)
            })
    }

    private static func isUnindexedRequestIssue(_ issue: StorageIssue) -> Bool {
        let issueKind = issue.id.split(separator: ":").dropFirst().first
        return issue.canRecover || issueKind?.hasPrefix("request-orphan") == true
            || issue.message.localizedCaseInsensitiveContains("unindexed")
    }

    private static func containsCiphertext(_ request: HTTPRequestConfiguration) -> Bool {
        request.variables.values.contains(where: \.isEncrypted) || request.authentication.password != nil
            || request.authentication.token != nil || request.authentication.apiKey != nil
    }

    private static func containsCiphertext(_ collection: RequestCollection) -> Bool {
        collection.variables.values.contains(where: \.isEncrypted) || collection.authentication.password != nil
            || collection.authentication.token != nil || collection.authentication.apiKey != nil
    }

    private func scheduleVariableSave(_ owner: VariableOwner) {
        dirtyVariableOwners.insert(owner)
        variableVersions[owner, default: 0] &+= 1
        let version = variableVersions[owner, default: 0]
        let values = variables(for: owner)
        scopeSaveErrors.removeValue(forKey: owner)
        refreshVariableError(owner)
        pendingVariableSaves.removeValue(forKey: owner)?.cancel()
        pendingVariableSaves[owner] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch { return }
            guard let self, self.variableVersions[owner] == version else { return }
            self.pendingVariableSaves.removeValue(forKey: owner)
            self.enqueueVariableSave(values, owner: owner, version: version)
        }
    }

    private func enqueueVariableSave(_ values: VariableValues, owner: VariableOwner, version: UInt64) {
        guard let store else { return }
        let options = globalOptions
        let saveOptions = !globalOptionsAreReadOnly
        let saveVariables = !globalVariablesAreReadOnly
        let defaults: CollectionRequestDefaults?
        if case let .collection(id) = owner, let collection = collection(id: id) {
            defaults = CollectionRequestDefaults(headers: collection.headers, authentication: collection.authentication)
        } else {
            defaults = nil
        }
        let previous = variableSaveChains[owner]
        variableSaveChains[owner] = Task { [weak self] in
            await previous?.value
            do {
                switch owner {
                case .global:
                    if saveVariables { try await store.saveGlobalVariables(values) }
                    if saveOptions { try await store.saveGlobalOptions(options) }
                case let .collection(id):
                    guard let defaults else { return }
                    try await store.saveCollectionConfiguration(defaults, variables: values, in: id)
                case .request: return
                }
                guard let self, self.variableVersions[owner] == version else { return }
                self.dirtyVariableOwners.remove(owner)
                self.scopeSaveErrors.removeValue(forKey: owner)
                self.refreshVariableError(owner)
            } catch {
                guard let self, self.variableVersions[owner] == version else { return }
                self.scopeSaveErrors[owner] = error.localizedDescription
                self.refreshVariableError(owner)
            }
        }
    }

    private func waitForVariableSaves(_ owner: VariableOwner) async {
        pendingVariableSaves.removeValue(forKey: owner)?.cancel()
        variableVersions[owner, default: 0] &+= 1
        await variableSaveChains[owner]?.value
        variableSaveChains.removeValue(forKey: owner)
    }

    private func removeVariableOwnerState(_ owner: VariableOwner) {
        pendingVariableSaves.removeValue(forKey: owner)?.cancel()
        variableSaveChains.removeValue(forKey: owner)
        variableVersions.removeValue(forKey: owner)
        dirtyVariableOwners.remove(owner)
        scopeSaveErrors.removeValue(forKey: owner)
        for target in Array(secretEditTokens.keys) where target.owner == owner { discardSecretEdit(target) }
        for target in Array(secretCommitErrors.keys) where target.owner == owner { discardSecretEdit(target) }
        variableSaveErrors.removeValue(forKey: owner)
    }

    private func scheduleAutosave(for identity: RequestIdentity, delayNanoseconds: UInt64 = 400_000_000) {
        guard let draft = drafts[identity] else { return }
        dirtyDrafts.insert(identity)
        let version = (editVersions[identity] ?? 0) &+ 1
        editVersions[identity] = version
        autosaveErrors.removeValue(forKey: identity)
        refreshVariableError(.request(identity))
        pendingSaveTasks[identity]?.cancel()
        pendingSaveTasks[identity] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, self.editVersions[identity] == version else { return }
            self.pendingSaveTasks.removeValue(forKey: identity)
            self.enqueueSave(draft, for: identity, version: version)
        }
    }

    private func enqueueSave(_ draft: HTTPRequestConfiguration, for identity: RequestIdentity, version: UInt64) {
        guard let store else { return }
        let previousSave = saveChains[identity]
        saveChains[identity] = Task { [weak self] in
            await previousSave?.value
            do {
                try await store.saveRequest(draft, in: identity.collectionID)
                guard let self, self.editVersions[identity] == version else { return }
                self.autosaveErrors.removeValue(forKey: identity)
                self.dirtyDrafts.remove(identity)
                self.refreshVariableError(.request(identity))
            } catch {
                guard let self, self.editVersions[identity] == version else { return }
                self.autosaveErrors[identity] = error.localizedDescription
                self.refreshVariableError(.request(identity))
            }
        }
    }

    private func waitForSaves(for identity: RequestIdentity) async {
        pendingSaveTasks.removeValue(forKey: identity)?.cancel()
        editVersions[identity, default: 0] &+= 1
        await saveChains[identity]?.value
        saveChains.removeValue(forKey: identity)
    }

    private func receive(_ event: HTTPExecutionEvent, for identity: RequestIdentity, token: UUID, runID: UUID) async
        -> Bool
    {
        guard var active = activeRuns[identity], active.token == token, active.runID == runID else { return true }
        switch event {
        case let .progress(progress):
            active.progress = progress
            activeRuns[identity] = active
            sessionHistory.update(active)
            return false
        case let .redirect(redirect):
            if !active.redirects.contains(where: { $0.id == redirect.id }) {
                active.redirects.append(redirect)
            }
            activeRuns[identity] = active
            sessionHistory.update(active)
            return false
        case let .completed(response):
            guard response.runID == runID else { return false }
            if !isTerminating { await sessionHistory.retainResponse(response, for: token) }
            guard activeRuns[identity]?.token == token, activeRuns[identity]?.runID == runID else { return true }
            replaceLatestResponse(response, for: identity, source: active.snapshotSource)
            activeRuns[identity]?.redirects = response.redirects
            settleRun(identity, token: token, terminal: .completed(response, active.snapshotSource))
            return true
        case let .failed(message):
            finishRun(identity, token: token, runID: runID, error: message)
            return true
        case .cancelled:
            cancelledRequests.insert(identity)
            settleRun(identity, token: token, terminal: .cancelled)
            return true
        }
    }

    private func finishRun(_ identity: RequestIdentity, token: UUID, runID: UUID? = nil, error: String) {
        guard let active = activeRuns[identity],
            active.token == token,
            runID == nil || active.runID == runID
        else { return }
        runErrors[identity] = error
        settleRun(identity, token: token, terminal: .failed(error))
    }

    private func settleRun(_ identity: RequestIdentity, token: UUID, terminal: AutomationRunTerminal? = nil) {
        guard let active = activeRuns[identity], active.token == token else { return }
        let result = terminal ?? (cancelledRequests.contains(identity) ? .cancelled : nil)
        if let result {
            switch result {
            case let .completed(response, _):
                sessionHistory.finish(token: token, phase: .completed, response: response)
            case let .failed(message):
                sessionHistory.finish(token: token, phase: .failed, error: message)
            case .cancelled:
                sessionHistory.finish(token: token, phase: .cancelled)
            }
            retainAutomationRunOutcome(
                AutomationRunOutcome(
                    token: token,
                    identity: identity,
                    terminal: result,
                    finishedAt: Date(),
                    mcpAccessExcluded: (drafts[identity]?.mcpPolicy.excluded ?? active.request.mcpPolicy.excluded)
                        || collection(for: identity)?.mcpPolicy.excluded == true
                )
            )
        }
        preparationTasks.removeValue(forKey: identity)
        activeRuns.removeValue(forKey: identity)
        let waiters = settlementWaiters.removeValue(forKey: identity) ?? []
        waiters.forEach { $0.resume() }
    }

    private func retainAutomationRunOutcome(_ outcome: AutomationRunOutcome) {
        automationRunOutcomes[outcome.identity] = outcome
        automationRunOutcomeOrder.removeAll { $0 == outcome.identity }
        automationRunOutcomeOrder.append(outcome.identity)
        while automationRunOutcomeOrder.count > maximumAutomationRunOutcomes {
            let expired = automationRunOutcomeOrder.removeFirst()
            automationRunOutcomes.removeValue(forKey: expired)
        }
    }

    private func replaceLatestResponse(
        _ response: HTTPResponseRecord,
        for identity: RequestIdentity,
        source: SnapshotSource?
    ) {
        if let previous = latestResponses[identity] {
            discardBody(previous.response.bodyFileURL, for: identity, after: previous.response.runID)
        }
        previewTasks.removeValue(forKey: identity)
        latestResponses[identity] = LatestResponse(
            response: response,
            snapshotSource: source,
            preview: nil,
            previewError: nil,
            isLoadingPreview: false
        )
        cancelledRequests.remove(identity)
        runErrors.removeValue(forKey: identity)
    }

    private func finishPreview(_ preview: BodyPreview, for identity: RequestIdentity, runID: UUID) {
        guard previewTasks[identity]?.runID == runID else { return }
        previewTasks.removeValue(forKey: identity)
        guard var latest = latestResponses[identity], latest.response.runID == runID else { return }
        latest.preview = preview
        latest.previewError = nil
        latest.isLoadingPreview = false
        latestResponses[identity] = latest
    }

    private func failPreview(_ message: String, for identity: RequestIdentity, runID: UUID) {
        guard previewTasks[identity]?.runID == runID else { return }
        previewTasks.removeValue(forKey: identity)
        guard var latest = latestResponses[identity], latest.response.runID == runID else { return }
        latest.previewError = message
        latest.isLoadingPreview = false
        latestResponses[identity] = latest
    }

    private func performRenameCollection(id: UUID, name: String) async {
        guard let store, collections.contains(where: { $0.id == id }) else { return }
        do {
            try await store.renameCollection(id: id, name: name)
            markWorkspaceChanged()
            guard var current = collections.first(where: { $0.id == id }) else {
                await loadWorkspace()
                return
            }
            current.name = name
            replaceCollection(current)
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performDeleteCollection(id: UUID) async {
        guard let store, let collection = collections.first(where: { $0.id == id }), !collection.isReadOnly else {
            return
        }
        var requestIdentities = collection.requests.map {
            RequestIdentity(collectionID: id, requestID: $0.id)
        }
        var includedIdentities = Set(requestIdentities)
        let retainedIdentities = trackedRequestIdentities()
            .filter { $0.collectionID == id }
            .sorted { $0.requestID.uuidString < $1.requestID.uuidString }
        requestIdentities.append(contentsOf: retainedIdentities.filter { includedIdentities.insert($0).inserted })

        await waitForVariableSaves(.collection(id))
        for identity in requestIdentities {
            await cancelAndWait(for: identity)
            await waitForSaves(for: identity)
        }
        await waitForSnapshotSaves()

        await withWorkspaceIndexMutation { [weak self] in
            guard let self else { return }
            guard self.snapshotInventoryAllowsSourceMutation else {
                self.operationError = "Collections cannot be deleted until snapshot storage is fully available."
                return
            }
            do {
                let retainedSnapshots = self.snapshots.filter {
                    self.snapshotGrouping(for: $0).identity.collectionID == id
                }
                try await self.persistMCPExclusions(for: retainedSnapshots, using: store)
                try await store.deleteCollection(id: id)
                self.markWorkspaceChanged()
                self.workspaceIndex = try await store.reorderCollections(
                    ids: self.collections.map(\.id).filter { $0 != id })
                for identity in requestIdentities {
                    self.removeLocalRequestState(for: identity)
                }
                self.collections.removeAll { $0.id == id }
                if self.selectedCollectionID == id { self.selectedCollectionID = nil }
                self.removeVariableOwnerState(.collection(id))
                if self.selectedIdentity?.collectionID == id {
                    self.selectFirstRequest()
                }
            } catch {
                self.operationError = error.localizedDescription
                await self.loadWorkspace()
            }
        }
    }

    private func performCreateRequest(in collectionID: UUID, name: String) async {
        guard let store, collections.contains(where: { $0.id == collectionID && !$0.isReadOnly }) else { return }
        var request = HTTPRequestConfiguration()
        request.name = name
        request.inheritsCollectionAuthentication = true
        request.optionOverrides = HTTPOptionsOverrides()

        do {
            try await store.createRequest(request, in: collectionID)
            markWorkspaceChanged()
            guard var current = collections.first(where: { $0.id == collectionID }) else {
                await loadWorkspace()
                return
            }
            current.requests.append(request)
            replaceCollection(current)
            let identity = RequestIdentity(collectionID: collectionID, requestID: request.id)
            drafts[identity] = request
            editVersions[identity] = 0
            select(identity)
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performDuplicateRequest(_ identity: RequestIdentity) async {
        guard let store,
            collections.contains(where: { $0.id == identity.collectionID && !$0.isReadOnly }),
            var duplicate = drafts[identity]
        else { return }

        duplicate.id = UUID()
        duplicate.name = "\(duplicate.name) copy"
        do {
            try await store.createRequest(duplicate, in: identity.collectionID)
            markWorkspaceChanged()
            guard var current = collections.first(where: { $0.id == identity.collectionID }) else {
                await loadWorkspace()
                return
            }
            current.requests.append(duplicate)
            replaceCollection(current)
            let duplicateIdentity = RequestIdentity(collectionID: identity.collectionID, requestID: duplicate.id)
            drafts[duplicateIdentity] = duplicate
            editVersions[duplicateIdentity] = 0
            select(duplicateIdentity)
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performDeleteRequest(_ identity: RequestIdentity) async {
        guard let store,
            collections.contains(where: { $0.id == identity.collectionID && !$0.isReadOnly })
        else { return }
        await cancelAndWait(for: identity)
        await waitForSaves(for: identity)
        await waitForSnapshotSaves()

        await withWorkspaceIndexMutation { [weak self] in
            guard let self else { return }
            guard self.snapshotInventoryAllowsSourceMutation else {
                self.operationError = "Requests cannot be deleted until snapshot storage is fully available."
                return
            }
            do {
                try await self.persistMCPExclusions(for: self.snapshots(for: identity), using: store)
                try await store.deleteRequest(id: identity.requestID, in: identity.collectionID)
                self.markWorkspaceChanged()
                guard var current = self.collections.first(where: { $0.id == identity.collectionID }) else {
                    self.removeLocalRequestState(for: identity)
                    await self.loadWorkspace()
                    return
                }
                current.requests.removeAll { $0.id == identity.requestID }
                self.replaceCollection(current)
                self.removeLocalRequestState(for: identity)
                if self.selectedIdentity == identity {
                    self.selectFirstRequest()
                }
            } catch {
                self.operationError = error.localizedDescription
                await self.loadWorkspace()
            }
        }
    }

    private func persistMCPExclusions(for snapshots: [SavedSnapshot], using store: CollectionStore) async throws {
        let excludedSnapshots = snapshots.filter {
            workspaceIndex.mcpExcludedSnapshotIDs.contains($0.id) || snapshotPolicyIsMCPExcluded($0)
        }
        guard !excludedSnapshots.isEmpty else { return }
        guard !workspaceIndexIsReadOnly else { throw CollectionStoreError.workspaceIndexIsReadOnly }

        for snapshot in excludedSnapshots {
            workspaceIndex = try await store.setSnapshotMCPExcluded(id: snapshot.id, isExcluded: true)
        }
    }

    private func performReorderRequests(_ requestedIDs: [UUID], in collectionID: UUID) async {
        guard let store,
            let collection = collections.first(where: { $0.id == collectionID && !$0.isReadOnly })
        else { return }
        let availableIDs = Set(collection.requests.map(\.id))
        var seen = Set<UUID>()
        var orderedIDs = requestedIDs.filter { availableIDs.contains($0) && seen.insert($0).inserted }
        orderedIDs.append(contentsOf: collection.requests.map(\.id).filter { seen.insert($0).inserted })

        do {
            try await store.reorderRequests(ids: orderedIDs, in: collectionID)
            markWorkspaceChanged()
            guard var current = collections.first(where: { $0.id == collectionID }) else {
                await loadWorkspace()
                return
            }
            let positions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
            current.requests.sort { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
            replaceCollection(current)
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performReorderCollections(_ requestedIDs: [UUID]) async {
        guard let store, !workspaceIndexIsReadOnly else { return }
        let availableIDs = collections.map(\.id)
        let availableSet = Set(availableIDs)
        var seen = Set<UUID>()
        var orderedIDs = requestedIDs.filter { availableSet.contains($0) && seen.insert($0).inserted }
        orderedIDs.append(contentsOf: availableIDs.filter { seen.insert($0).inserted })

        do {
            workspaceIndex = try await store.reorderCollections(ids: orderedIDs)
            markWorkspaceChanged()
            collections = Self.ordered(collections, by: workspaceIndex)
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performMoveRequest(
        _ identity: RequestIdentity,
        toCollectionID: UUID,
        beforeRequestID: UUID?
    ) async {
        do {
            try await flushRequestSaves(for: identity)
            await waitForVariableSaves(.request(identity))
            await waitForSnapshotSaves()
            await finishPendingPreview(for: identity)
        } catch {
            operationError = error.localizedDescription
            return
        }

        await withWorkspaceIndexMutation { [weak self] in
            guard let self,
                let store = self.store,
                self.movingRequests.contains(identity)
            else { return }
            guard self.snapshotInventoryAllowsSourceMutation else {
                self.operationError =
                    "Requests cannot move between collections until snapshot storage is fully available."
                return
            }
            guard self.activeRuns[identity] == nil else {
                self.operationError = "Stop the request before moving it to another collection."
                return
            }
            guard let source = self.collections.first(where: { $0.id == identity.collectionID && !$0.isReadOnly }),
                source.requests.contains(where: { $0.id == identity.requestID })
            else {
                self.operationError = "The request is no longer available to move."
                return
            }
            guard self.collections.contains(where: { $0.id == toCollectionID && !$0.isReadOnly }) else {
                self.operationError = "The destination collection is no longer available."
                return
            }

            let snapshotIDs = self.snapshots
                .filter { self.snapshotGrouping(for: $0).identity == identity }
                .map(\.id)
            do {
                let result = try await store.moveRequest(
                    identity,
                    toCollectionID: toCollectionID,
                    beforeRequestID: beforeRequestID,
                    snapshotIDs: snapshotIDs
                )
                self.markWorkspaceChanged()
                self.workspaceIndex = result.workspaceIndex
                self.installMovedRequest(result.newIdentity, from: result.oldIdentity, beforeRequestID: beforeRequestID)
                self.remapRequestState(from: result.oldIdentity, to: result.newIdentity)
            } catch {
                self.operationError = error.localizedDescription
                await self.loadWorkspace()
            }
        }
    }

    private func flushRequestSaves(for identity: RequestIdentity) async throws {
        guard self.store != nil else { throw SaveFlushError.workspaceUnavailable }
        let needsSave = dirtyDrafts.contains(identity) || autosaveErrors[identity] != nil
        if needsSave {
            pendingSaveTasks.removeValue(forKey: identity)?.cancel()
            let version = (editVersions[identity] ?? 0) &+ 1
            editVersions[identity] = version
            autosaveErrors.removeValue(forKey: identity)
            guard let draft = drafts[identity] else { throw SaveFlushError.workspaceUnavailable }
            enqueueSave(draft, for: identity, version: version)
        }
        await saveChains[identity]?.value
        saveChains.removeValue(forKey: identity)
        guard !dirtyDrafts.contains(identity) else {
            let name = drafts[identity]?.name ?? "Request"
            throw SaveFlushError.failed([
                "\(name): \(autosaveErrors[identity] ?? "The latest change is still unsaved.")"
            ])
        }
    }

    private func finishPendingPreview(for identity: RequestIdentity) async {
        guard let pending = previewTasks[identity] else { return }
        do {
            finishPreview(try await pending.task.value, for: identity, runID: pending.runID)
        } catch {
            failPreview(error.localizedDescription, for: identity, runID: pending.runID)
        }
    }

    private func installMovedRequest(
        _ newIdentity: RequestIdentity,
        from oldIdentity: RequestIdentity,
        beforeRequestID: UUID?
    ) {
        guard let request = drafts[oldIdentity],
            let sourceIndex = collections.firstIndex(where: { $0.id == oldIdentity.collectionID }),
            let destinationIndex = collections.firstIndex(where: { $0.id == newIdentity.collectionID })
        else {
            Task { await loadWorkspace() }
            return
        }

        collections[sourceIndex].requests.removeAll { $0.id == oldIdentity.requestID }
        let insertionIndex =
            beforeRequestID
            .flatMap { id in collections[destinationIndex].requests.firstIndex(where: { $0.id == id }) }
            ?? collections[destinationIndex].requests.endIndex
        collections[destinationIndex].requests.insert(request, at: insertionIndex)
        collections = Self.ordered(collections, by: workspaceIndex)
    }

    private func remapRequestState(from oldIdentity: RequestIdentity, to newIdentity: RequestIdentity) {
        guard oldIdentity != newIdentity else { return }
        sessionHistory.remapSource(from: oldIdentity, to: newIdentity)
        removeVariableOwnerState(.request(oldIdentity))
        moveValue(in: &drafts, from: oldIdentity, to: newIdentity)
        moveValue(in: &editVersions, from: oldIdentity, to: newIdentity)
        moveValue(in: &pendingSaveTasks, from: oldIdentity, to: newIdentity)
        moveValue(in: &saveChains, from: oldIdentity, to: newIdentity)
        moveValue(in: &latestResponses, from: oldIdentity, to: newIdentity) { response in
            guard response.snapshotSource != nil,
                let collection = collections.first(where: { $0.id == newIdentity.collectionID }),
                let request = collection.requests.first(where: { $0.id == newIdentity.requestID })
            else { return }
            response = LatestResponse(
                response: response.response,
                snapshotSource: SnapshotSource(
                    identity: newIdentity, collectionName: collection.name, requestName: request.name),
                preview: response.preview,
                previewError: response.previewError,
                isLoadingPreview: response.isLoadingPreview
            )
        }
        moveValue(in: &automationRunOutcomes, from: oldIdentity, to: newIdentity) { outcome in
            outcome.identity = newIdentity
            outcome.mcpAccessExcluded =
                collections.first(where: { $0.id == newIdentity.collectionID })?.mcpPolicy.excluded == true
                || drafts[newIdentity]?.mcpPolicy.excluded == true
        }
        if let index = automationRunOutcomeOrder.firstIndex(of: oldIdentity) {
            automationRunOutcomeOrder[index] = newIdentity
        }
        moveValue(in: &runErrors, from: oldIdentity, to: newIdentity)
        moveValue(in: &cancelledRequests, from: oldIdentity, to: newIdentity)
        moveValue(in: &autosaveErrors, from: oldIdentity, to: newIdentity)
        moveValue(in: &previewTasks, from: oldIdentity, to: newIdentity)
        moveValue(in: &requestEditorSections, from: oldIdentity, to: newIdentity)
        moveValue(in: &requestEditorExpansionStates, from: oldIdentity, to: newIdentity)
        if dirtyDrafts.remove(oldIdentity) != nil { dirtyDrafts.insert(newIdentity) }
        if reconcilingRequests.remove(oldIdentity) != nil { reconcilingRequests.insert(newIdentity) }
        navigationHistory.remapRequest(from: oldIdentity, to: newIdentity)
        if selectedIdentity == oldIdentity { selectedIdentity = newIdentity }
        if let definition = variableDefinitionRequest,
            case let .request(identity) = definition.owner,
            identity == oldIdentity
        {
            variableDefinitionRequest = nil
        }
        refreshVariableError(.request(newIdentity))
    }

    private func moveValue<Value>(
        in values: inout [RequestIdentity: Value],
        from oldIdentity: RequestIdentity,
        to newIdentity: RequestIdentity,
        transform: (inout Value) -> Void = { _ in }
    ) {
        guard var value = values.removeValue(forKey: oldIdentity) else { return }
        transform(&value)
        values[newIdentity] = value
    }

    private func moveValue(
        in values: inout Set<RequestIdentity>, from oldIdentity: RequestIdentity, to newIdentity: RequestIdentity
    ) {
        if values.remove(oldIdentity) != nil { values.insert(newIdentity) }
    }

    private func withCollectionMutation(_ collectionID: UUID, operation: @escaping @MainActor () async -> Void) async {
        let token = UUID()
        let previous = collectionMutationTasks[collectionID]
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        collectionMutationTasks[collectionID] = task
        collectionMutationTokens[collectionID] = token
        acceptedMutationTasks[token] = task
        await task.value
        finishAcceptedMutation(token)
        if collectionMutationTokens[collectionID] == token {
            collectionMutationTasks.removeValue(forKey: collectionID)
            collectionMutationTokens.removeValue(forKey: collectionID)
        }
    }

    private func withCollectionMutations(_ collectionIDs: [UUID], operation: @escaping @MainActor () async -> Void)
        async
    {
        let orderedIDs = Array(Set(collectionIDs)).sorted { $0.uuidString < $1.uuidString }
        let previousTasks = orderedIDs.compactMap { collectionMutationTasks[$0] }
        let token = UUID()
        let task = Task { @MainActor in
            for previous in previousTasks { await previous.value }
            await operation()
        }
        for id in orderedIDs {
            collectionMutationTasks[id] = task
            collectionMutationTokens[id] = token
        }
        acceptedMutationTasks[token] = task
        await task.value
        finishAcceptedMutation(token)
        for id in orderedIDs where collectionMutationTokens[id] == token {
            collectionMutationTasks.removeValue(forKey: id)
            collectionMutationTokens.removeValue(forKey: id)
        }
    }

    private func withWorkspaceIndexMutation(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = workspaceIndexMutationTask
        let token = UUID()
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        workspaceIndexMutationTask = task
        workspaceIndexMutationToken = token
        acceptedMutationTasks[token] = task
        await task.value
        finishAcceptedMutation(token)
        if workspaceIndexMutationToken == token {
            workspaceIndexMutationTask = nil
            workspaceIndexMutationToken = nil
        }
    }

    private func withAcceptedMutation(_ operation: @escaping @MainActor () async -> Void) async {
        let token = UUID()
        let task = Task { @MainActor in await operation() }
        acceptedMutationTasks[token] = task
        await task.value
        finishAcceptedMutation(token)
    }

    private func drainAcceptedMutations() async throws {
        guard !acceptedMutationTasks.isEmpty else { return }
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            mutationDrainWaiters[waiterID] = continuation
            mutationDrainTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard let self,
                    let continuation = self.mutationDrainWaiters.removeValue(forKey: waiterID)
                else { return }
                self.mutationDrainTimeoutTasks.removeValue(forKey: waiterID)
                continuation.resume(throwing: MutationDrainError.timedOut)
            }
        }
    }

    private func finishAcceptedMutation(_ token: UUID) {
        acceptedMutationTasks.removeValue(forKey: token)
        guard acceptedMutationTasks.isEmpty else { return }
        let waiters = mutationDrainWaiters
        mutationDrainWaiters.removeAll()
        for (id, continuation) in waiters {
            mutationDrainTimeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume()
        }
    }

    private func discardBody(_ url: URL, for identity: RequestIdentity, after runID: UUID?) {
        guard let executionManager else { return }
        let pending = previewTasks[identity].flatMap { $0.runID == runID ? $0.task : nil }
        let pendingSnapshotSaves = runID.flatMap { snapshotSaveTasks[$0].map { Array($0.values) } } ?? []
        Task { [weak self] in
            if let pending {
                _ = try? await pending.value
            }
            for save in pendingSnapshotSaves {
                await save.value
            }
            do {
                try await executionManager.discardBody(at: url)
            } catch {
                self?.operationError = error.localizedDescription
            }
        }
    }

    private func removeLocalRequestState(for identity: RequestIdentity) {
        sessionHistory.removeSource(identity)
        removeVariableOwnerState(.request(identity))
        automationRunOutcomes.removeValue(forKey: identity)
        automationRunOutcomeOrder.removeAll { $0 == identity }
        pendingSaveTasks.removeValue(forKey: identity)?.cancel()
        saveChains.removeValue(forKey: identity)?.cancel()
        editVersions.removeValue(forKey: identity)
        dirtyDrafts.remove(identity)
        drafts.removeValue(forKey: identity)
        autosaveErrors.removeValue(forKey: identity)
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)
        reconcilingRequests.remove(identity)
        if let latest = latestResponses.removeValue(forKey: identity) {
            discardBody(latest.response.bodyFileURL, for: identity, after: latest.response.runID)
        }
        previewTasks.removeValue(forKey: identity)
        requestEditorSections.removeValue(forKey: identity)
        requestEditorExpansionStates.removeValue(forKey: identity)
    }

    private func replaceCollection(_ collection: RequestCollection) {
        collections = collections.map { $0.id == collection.id ? collection : $0 }
    }

    private func markWorkspaceChanged() {
        workspaceRevision &+= 1
    }

    private func selectFirstRequest() {
        selectedIdentity = collections.first.flatMap { collection in
            collection.requests.first.map { RequestIdentity(collectionID: collection.id, requestID: $0.id) }
        }
        if let selectedIdentity,
            selectedCollectionID == nil,
            selectedSnapshotID == nil,
            !showsGlobalVariables,
            !showsGlobalSettings,
            !showsOngoingRequests
        {
            recordNavigation(.request(selectedIdentity, section: requestEditorSection(for: selectedIdentity)))
        }
    }

    private func ordered(_ collections: [RequestCollection]) -> [RequestCollection] {
        Self.ordered(collections, by: workspaceIndex)
    }

    private static func ordered(_ collections: [RequestCollection], by index: WorkspaceIndex) -> [RequestCollection] {
        let positions = Dictionary(
            uniqueKeysWithValues: index.collectionOrder.enumerated().map { ($0.element, $0.offset) })
        return collections.enumerated().sorted { left, right in
            let leftPosition = positions[left.element.id, default: Int.max]
            let rightPosition = positions[right.element.id, default: Int.max]
            return leftPosition == rightPosition ? left.offset < right.offset : leftPosition < rightPosition
        }.map(\.element)
    }

    private static func directories(from arguments: [String]) throws -> Directories {
        var dataDirectory: URL?
        var bodyDirectory: URL?
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            guard argument == "--data-directory" || argument == "--body-directory" else {
                index += 1
                continue
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                throw ArgumentError.missingPath(argument)
            }
            let path = arguments[index + 1]
            guard !path.hasPrefix("--") else {
                throw ArgumentError.missingPath(argument)
            }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if argument == "--data-directory" {
                guard dataDirectory == nil else { throw ArgumentError.duplicate(argument) }
                dataDirectory = url
            } else {
                guard bodyDirectory == nil else { throw ArgumentError.duplicate(argument) }
                bodyDirectory = url
            }
            index += 2
        }

        let defaultDataDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("postie", isDirectory: true)
        return Directories(
            data: dataDirectory ?? defaultDataDirectory,
            body: bodyDirectory
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("Postie", isDirectory: true)
        )
    }

    private enum ConfigurationEditError: LocalizedError {
        case invalidName
        case duplicateName
        case readOnly
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidName: "Use an ASCII letter or underscore, followed by letters, digits or underscores."
            case .duplicateName: "A variable with this name already exists in this scope."
            case .readOnly: "This configuration cannot currently be edited."
            case .unavailable: "This configuration value is no longer available."
            }
        }
    }

    private enum ArgumentError: LocalizedError {
        case missingPath(String)
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case let .missingPath(argument): "\(argument) requires a path."
            case let .duplicate(argument): "\(argument) may be provided only once."
            }
        }
    }

    private enum SaveFlushError: LocalizedError {
        case workspaceUnavailable
        case failed([String])

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                "Postie could not save pending request changes because its workspace is unavailable."
            case let .failed(requests):
                "Postie could not save pending changes. The app will stay open.\n\(requests.joined(separator: "\n"))"
            }
        }
    }

    private enum MutationDrainError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "Postie could not finish accepted workspace changes within 10 seconds. The app will stay open."
        }
    }
}
