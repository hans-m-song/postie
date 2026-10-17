import Foundation
import Combine
import PostieCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct ActiveRun {
        enum Phase: Equatable {
            case preparing
            case running
            case cancelling
        }

        let token: UUID
        let request: HTTPRequestConfiguration
        let startedAt: Date
        var phase: Phase
        var runID: UUID?
        var progress: HTTPProgress?
        var redirects: [HTTPRedirect]
        var cancelRequested: Bool
    }

    struct LatestResponse {
        let response: HTTPResponseRecord
        var preview: BodyPreview?
        var previewError: String?
        var isLoadingPreview: Bool
    }

    @Published private(set) var collections: [RequestCollection] = []
    @Published private(set) var drafts: [RequestIdentity: HTTPRequestConfiguration] = [:]
    @Published private(set) var activeRuns: [RequestIdentity: ActiveRun] = [:]
    @Published private(set) var latestResponses: [RequestIdentity: LatestResponse] = [:]
    @Published private(set) var runErrors: [RequestIdentity: String] = [:]
    @Published private(set) var cancelledRequests: Set<RequestIdentity> = []
    @Published private(set) var autosaveErrors: [RequestIdentity: String] = [:]
    @Published private(set) var storageIssues: [StorageIssue] = []
    @Published private(set) var selectedIdentity: RequestIdentity?
    @Published private(set) var showsOngoingRequests = false
    @Published private(set) var now = Date()
    @Published private(set) var startupError: String?
    @Published private(set) var isTerminating = false
    @Published private(set) var deletingCollections: Set<UUID> = []
    @Published private(set) var deletingRequests: Set<RequestIdentity> = []
    @Published private(set) var reconcilingRequests: Set<RequestIdentity> = []
    @Published var operationError: String?

    private struct Directories {
        let data: URL
        let body: URL
    }

    private struct PendingPreview {
        let runID: UUID
        let task: Task<BodyPreview, Error>
    }

    private var store: CollectionStore?
    private var executionManager: HTTPExecutionManager?
    private var editVersions: [RequestIdentity: UInt64] = [:]
    private var dirtyDrafts: Set<RequestIdentity> = []
    private var pendingSaveTasks: [RequestIdentity: Task<Void, Never>] = [:]
    private var saveChains: [RequestIdentity: Task<Void, Never>] = [:]
    private var previewTasks: [RequestIdentity: PendingPreview] = [:]
    private var settlementWaiters: [RequestIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var collectionMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var collectionMutationTokens: [UUID: UUID] = [:]
    private var acceptedMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var mutationDrainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var mutationDrainTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var workspaceRevision: UInt64 = 0

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        do {
            let directories = try Self.directories(from: arguments)
            store = try CollectionStore(rootURL: directories.data)
            executionManager = try HTTPExecutionManager(bodyDirectory: directories.body)
            Task { [weak self] in
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

    func request(for identity: RequestIdentity) -> HTTPRequestConfiguration? {
        drafts[identity]
    }

    func collection(for identity: RequestIdentity) -> RequestCollection? {
        collections.first { $0.id == identity.collectionID }
    }

    func canEdit(_ identity: RequestIdentity) -> Bool {
        guard let collection = collection(for: identity), drafts[identity] != nil else { return false }
        return !collection.isReadOnly &&
            !deletingCollections.contains(identity.collectionID) &&
            !deletingRequests.contains(identity) &&
            !reconcilingRequests.contains(identity) &&
            !isTerminating
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
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }

        return response.redirects.last?.id == redirect.id &&
            response.finalURL == redirect.url &&
            redirect.nextURL == url &&
            request.httpMethod?.uppercased() == redirect.nextMethod.uppercased()
    }

    func select(_ identity: RequestIdentity?) {
        selectedIdentity = identity
        showsOngoingRequests = false
    }

    func showOngoingRequests() {
        showsOngoingRequests = true
    }

    func showRequests() {
        showsOngoingRequests = false
        if selectedIdentity == nil {
            selectFirstRequest()
        }
    }

    func openRequest(_ identity: RequestIdentity) {
        guard drafts[identity] != nil, !reconcilingRequests.contains(identity) else { return }
        selectedIdentity = identity
        showsOngoingRequests = false
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
        update(&draft)
        drafts[identity] = draft
        scheduleAutosave(for: identity)
    }

    func createCollection(name: String) async {
        guard !isTerminating, let store else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        await withAcceptedMutation { [weak self] in
            guard let self else { return }
            do {
                let collection = try await store.createCollection(name: normalizedName)
                self.markWorkspaceChanged()
                self.collections = self.sorted(self.collections + [collection])
            } catch {
                self.operationError = error.localizedDescription
            }
        }
    }

    func renameCollection(id: UUID, name: String) async {
        guard !isTerminating,
              !deletingCollections.contains(id),
              store != nil,
              collections.contains(where: { $0.id == id && !$0.isReadOnly }) else { return }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return }

        await withCollectionMutation(id) { [weak self] in
            await self?.performRenameCollection(id: id, name: normalizedName)
        }
    }

    func deleteCollection(id: UUID) async {
        guard !isTerminating,
              !deletingCollections.contains(id),
              !deletingRequests.contains(where: { $0.collectionID == id }),
              collections.contains(where: { $0.id == id && !$0.isReadOnly }) else { return }
        deletingCollections.insert(id)
        await withCollectionMutation(id) { [weak self] in
            await self?.performDeleteCollection(id: id)
        }
        deletingCollections.remove(id)
    }

    func createRequest(in collectionID: UUID, name: String = "New request") async {
        guard !isTerminating,
              !deletingCollections.contains(collectionID),
              collections.contains(where: { $0.id == collectionID && !$0.isReadOnly }) else { return }
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
        guard !isTerminating,
              !deletingCollections.contains(identity.collectionID),
              !deletingRequests.contains(identity),
              canEdit(identity) else { return }
        deletingRequests.insert(identity)
        await withCollectionMutation(identity.collectionID) { [weak self] in
            await self?.performDeleteRequest(identity)
        }
        deletingRequests.remove(identity)
    }

    func reorderRequests(_ requestIDs: [UUID], in collectionID: UUID) async {
        guard !isTerminating,
              !deletingCollections.contains(collectionID),
              collections.contains(where: { $0.id == collectionID && !$0.isReadOnly }) else { return }
        await withCollectionMutation(collectionID) { [weak self] in
            await self?.performReorderRequests(requestIDs, in: collectionID)
        }
    }

    func moveRequest(_ identity: RequestIdentity, by offset: Int) async {
        guard let collection = collections.first(where: { $0.id == identity.collectionID }),
              let currentIndex = collection.requests.firstIndex(where: { $0.id == identity.requestID }) else { return }
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
              !isTerminating,
              !deletingCollections.contains(collectionID),
              let store else { return }

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
        let identities = Array(dirtyDrafts)
        guard !identities.isEmpty else { return }
        guard store != nil else { throw SaveFlushError.workspaceUnavailable }

        for identity in identities {
            pendingSaveTasks.removeValue(forKey: identity)?.cancel()
            let version = (editVersions[identity] ?? 0) &+ 1
            editVersions[identity] = version
            autosaveErrors.removeValue(forKey: identity)
            guard let draft = drafts[identity] else { continue }
            enqueueSave(draft, for: identity, version: version)
        }

        for identity in identities {
            await saveChains[identity]?.value
        }

        let failures = identities.compactMap { identity -> String? in
            guard dirtyDrafts.contains(identity) else { return nil }
            let name = drafts[identity]?.name ?? "Deleted request"
            let detail = autosaveErrors[identity] ?? "The latest change is still unsaved."
            return "\(name): \(detail)"
        }
        guard failures.isEmpty else { throw SaveFlushError.failed(failures) }
    }

    func prepareForTermination() async -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        do {
            try await drainAcceptedMutations()
            try await flushPendingSaves()
            await executionManager?.shutdown()
            return true
        } catch {
            isTerminating = false
            operationError = error.localizedDescription
            return false
        }
    }

    func startRequest(_ identity: RequestIdentity) {
        guard canEdit(identity),
              activeRuns[identity] == nil,
              let configuration = drafts[identity],
              let executionManager else { return }

        let token = UUID()
        activeRuns[identity] = ActiveRun(
            token: token,
            request: configuration,
            startedAt: Date(),
            phase: .preparing,
            runID: nil,
            progress: nil,
            redirects: [],
            cancelRequested: false
        )
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        Task { [weak self] in
            do {
                let run = try await executionManager.start(identity: identity, configuration: configuration)
                guard let self else {
                    await executionManager.cancel(identity: identity)
                    return
                }
                await self.observe(run, for: identity, token: token, using: executionManager)
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
              let executionManager else { return }

        var currentRequest = response.request
        currentRequest.url = redirectURL.absoluteString
        currentRequest.method = redirectRequest.httpMethod ?? response.pendingRedirect?.nextMethod ?? currentRequest.method

        let token = UUID()
        activeRuns[identity] = ActiveRun(
            token: token,
            request: currentRequest,
            startedAt: Date(),
            phase: .preparing,
            runID: nil,
            progress: nil,
            redirects: response.redirects,
            cancelRequested: false
        )
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        Task { [weak self] in
            do {
                let run = try await executionManager.followRedirect(identity: identity, response: response)
                guard let self else {
                    await executionManager.cancel(identity: identity)
                    return
                }
                await self.observe(run, for: identity, token: token, using: executionManager)
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
            await executionManager.cancel(identity: identity)
            return
        }

        active.runID = run.id
        active.phase = active.cancelRequested ? .cancelling : .running
        activeRuns[identity] = active
        if active.cancelRequested {
            await executionManager.cancel(identity: identity)
        }

        var receivedTerminalEvent = false
        for await event in run.events {
            guard activeRuns[identity]?.token == token,
                  activeRuns[identity]?.runID == run.id else { break }
            if receive(event, for: identity, token: token, runID: run.id) {
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
        guard active.runID != nil, let executionManager else { return }
        Task {
            await executionManager.cancel(identity: identity)
        }
    }

    func cancelAndWait(for identity: RequestIdentity) async {
        guard activeRuns[identity] != nil else { return }
        cancelRequest(identity)
        await withCheckedContinuation { continuation in
            settlementWaiters[identity, default: []].append(continuation)
        }
    }

    func loadPreview(for identity: RequestIdentity) {
        guard var latest = latestResponses[identity],
              latest.preview == nil,
              latest.previewError == nil,
              !latest.isLoadingPreview,
              previewTasks[identity] == nil else { return }

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

    func elapsed(for identity: RequestIdentity) -> TimeInterval? {
        activeRuns[identity].map { max(0, now.timeIntervalSince($0.startedAt)) }
    }

    private func loadWorkspace() async {
        guard let store else { return }
        while true {
            let revision = workspaceRevision
            do {
                let loaded = try await store.load()
                guard revision == workspaceRevision else { continue }
                let available = Dictionary(uniqueKeysWithValues: loaded.collections.flatMap { collection in
                    collection.requests.map { (RequestIdentity(collectionID: collection.id, requestID: $0.id), $0) }
                })
                let indexedIssues = Self.indexedIssueIdentities(loaded.issues)
                let tracked = trackedRequestIdentities()
                let unindexedIssues = Self.unindexedIssueIdentities(loaded.issues)
                let readOnlyCollectionIDs = Set(loaded.collections.filter(\.isReadOnly).map(\.id))
                let readOnlyMembers = Set(tracked.filter {
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

                workspaceRevision &+= 1
                for identity in unavailable {
                    removeLocalRequestState(for: identity)
                }
                collections = sorted(loaded.collections)
                storageIssues = loaded.issues
                for (identity, request) in available where drafts[identity] == nil {
                    drafts[identity] = request
                    editVersions[identity] = 0
                }
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
        Set(issues.compactMap { issue in
            guard let collectionID = issue.collectionID,
                  let requestID = issue.requestID,
                  !isUnindexedRequestIssue(issue) else { return nil }
            return RequestIdentity(collectionID: collectionID, requestID: requestID)
        })
    }

    private static func unindexedIssueIdentities(_ issues: [StorageIssue]) -> Set<RequestIdentity> {
        Set(issues.compactMap { issue in
            guard isUnindexedRequestIssue(issue),
                  let collectionID = issue.collectionID,
                  let requestID = issue.requestID else { return nil }
            return RequestIdentity(collectionID: collectionID, requestID: requestID)
        })
    }

    private static func isUnindexedRequestIssue(_ issue: StorageIssue) -> Bool {
        let issueKind = issue.id.split(separator: ":").dropFirst().first
        return issue.canRecover ||
            issueKind?.hasPrefix("request-orphan") == true ||
            issue.message.localizedCaseInsensitiveContains("unindexed")
    }

    private func scheduleAutosave(for identity: RequestIdentity, delayNanoseconds: UInt64 = 400_000_000) {
        guard let draft = drafts[identity] else { return }
        dirtyDrafts.insert(identity)
        let version = (editVersions[identity] ?? 0) &+ 1
        editVersions[identity] = version
        autosaveErrors.removeValue(forKey: identity)
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
            } catch {
                guard let self, self.editVersions[identity] == version else { return }
                self.autosaveErrors[identity] = error.localizedDescription
            }
        }
    }

    private func waitForSaves(for identity: RequestIdentity) async {
        pendingSaveTasks.removeValue(forKey: identity)?.cancel()
        editVersions[identity, default: 0] &+= 1
        await saveChains[identity]?.value
        saveChains.removeValue(forKey: identity)
    }

    private func receive(_ event: HTTPExecutionEvent, for identity: RequestIdentity, token: UUID, runID: UUID) -> Bool {
        guard var active = activeRuns[identity], active.token == token, active.runID == runID else { return true }
        switch event {
        case let .progress(progress):
            active.progress = progress
            activeRuns[identity] = active
            return false
        case let .redirect(redirect):
            if !active.redirects.contains(where: { $0.id == redirect.id }) {
                active.redirects.append(redirect)
            }
            activeRuns[identity] = active
            return false
        case let .completed(response):
            guard response.runID == runID else { return false }
            replaceLatestResponse(response, for: identity)
            activeRuns[identity]?.redirects = response.redirects
            settleRun(identity, token: token)
            return true
        case let .failed(message):
            finishRun(identity, token: token, runID: runID, error: message)
            return true
        case .cancelled:
            cancelledRequests.insert(identity)
            settleRun(identity, token: token)
            return true
        }
    }

    private func finishRun(_ identity: RequestIdentity, token: UUID, runID: UUID? = nil, error: String) {
        guard let active = activeRuns[identity],
              active.token == token,
              runID == nil || active.runID == runID else { return }
        runErrors[identity] = error
        settleRun(identity, token: token)
    }

    private func settleRun(_ identity: RequestIdentity, token: UUID) {
        guard activeRuns[identity]?.token == token else { return }
        activeRuns.removeValue(forKey: identity)
        let waiters = settlementWaiters.removeValue(forKey: identity) ?? []
        waiters.forEach { $0.resume() }
    }

    private func replaceLatestResponse(_ response: HTTPResponseRecord, for identity: RequestIdentity) {
        if let previous = latestResponses[identity] {
            discardBody(previous.response.bodyFileURL, for: identity, after: previous.response.runID)
        }
        previewTasks.removeValue(forKey: identity)
        latestResponses[identity] = LatestResponse(
            response: response,
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
        guard let store, let collection = collections.first(where: { $0.id == id }), !collection.isReadOnly else { return }
        var requestIdentities = collection.requests.map {
            RequestIdentity(collectionID: id, requestID: $0.id)
        }
        var includedIdentities = Set(requestIdentities)
        let retainedIdentities = trackedRequestIdentities()
            .filter { $0.collectionID == id }
            .sorted { $0.requestID.uuidString < $1.requestID.uuidString }
        requestIdentities.append(contentsOf: retainedIdentities.filter { includedIdentities.insert($0).inserted })

        for identity in requestIdentities {
            await cancelAndWait(for: identity)
            await waitForSaves(for: identity)
        }

        do {
            try await store.deleteCollection(id: id)
            markWorkspaceChanged()
            for identity in requestIdentities {
                removeLocalRequestState(for: identity)
            }
            collections.removeAll { $0.id == id }
            if selectedIdentity?.collectionID == id {
                selectFirstRequest()
            }
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performCreateRequest(in collectionID: UUID, name: String) async {
        guard let store, collections.contains(where: { $0.id == collectionID && !$0.isReadOnly }) else { return }
        var request = HTTPRequestConfiguration()
        request.name = name

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
              var duplicate = drafts[identity] else { return }

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
              collections.contains(where: { $0.id == identity.collectionID && !$0.isReadOnly }) else { return }
        await cancelAndWait(for: identity)
        await waitForSaves(for: identity)

        do {
            try await store.deleteRequest(id: identity.requestID, in: identity.collectionID)
            markWorkspaceChanged()
            guard var current = collections.first(where: { $0.id == identity.collectionID }) else {
                removeLocalRequestState(for: identity)
                await loadWorkspace()
                return
            }
            current.requests.removeAll { $0.id == identity.requestID }
            replaceCollection(current)
            removeLocalRequestState(for: identity)
            if selectedIdentity == identity {
                selectFirstRequest()
            }
        } catch {
            operationError = error.localizedDescription
            await loadWorkspace()
        }
    }

    private func performReorderRequests(_ requestedIDs: [UUID], in collectionID: UUID) async {
        guard let store,
              let collection = collections.first(where: { $0.id == collectionID && !$0.isReadOnly }) else { return }
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
                      let continuation = self.mutationDrainWaiters.removeValue(forKey: waiterID) else { return }
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
        Task { [weak self] in
            if let pending {
                _ = try? await pending.value
            }
            do {
                try await executionManager.discardBody(at: url)
            } catch {
                self?.operationError = error.localizedDescription
            }
        }
    }

    private func removeLocalRequestState(for identity: RequestIdentity) {
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
    }

    private func replaceCollection(_ collection: RequestCollection) {
        collections = sorted(collections.map { $0.id == collection.id ? collection : $0 })
    }

    private func markWorkspaceChanged() {
        workspaceRevision &+= 1
    }

    private func selectFirstRequest() {
        selectedIdentity = collections.first.flatMap { collection in
            collection.requests.first.map { RequestIdentity(collectionID: collection.id, requestID: $0.id) }
        }
    }

    private func sorted(_ collections: [RequestCollection]) -> [RequestCollection] {
        collections.sorted {
            let left = $0.name.localizedCaseInsensitiveCompare($1.name)
            return left == .orderedSame ? $0.id.uuidString < $1.id.uuidString : left == .orderedAscending
        }
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
            body: bodyDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("Postie", isDirectory: true)
        )
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
