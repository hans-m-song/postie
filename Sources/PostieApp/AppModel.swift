import Foundation
import Combine
import PostieCore

enum CollectionEditorSection: Hashable {
    case variables, headers, authentication
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

    struct ActiveRun {
        enum Phase: Equatable {
            case preparing
            case running
            case cancelling
        }

        let token: UUID
        let request: HTTPRequestConfiguration
        let snapshotSource: SnapshotSource?
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

    @Published private(set) var globalVariables: VariableValues = [:]
    @Published private(set) var globalVariablesAreReadOnly = true
    @Published private(set) var globalOptions = HTTPOptions()
    @Published private(set) var globalOptionsAreReadOnly = true
    @Published private(set) var showsGlobalSettings = false
    @Published private(set) var variableSaveErrors: [VariableOwner: String] = [:]
    @Published private(set) var showsGlobalVariables = false
    @Published var showsRequestSearch = false
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
    @Published private(set) var collectionEditorSection: CollectionEditorSection = .variables
    @Published private(set) var requestEditorSections: [RequestIdentity: RequestEditorSection] = [:]
    @Published private(set) var requestEditorExpansionStates: [RequestIdentity: RequestEditorExpansionState] = [:]
    @Published private(set) var variableDefinitionRequest: VariableDefinitionRequest?
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
    private var workspaceLoaded = false
    private var initialWorkspaceLoadTask: Task<Void, Never>?
    private var dirtyVariableOwners: Set<VariableOwner> = []
    private var variableVersions: [VariableOwner: UInt64] = [:]
    private var pendingVariableSaves: [VariableOwner: Task<Void, Never>] = [:]
    private var variableSaveChains: [VariableOwner: Task<Void, Never>] = [:]
    private var scopeSaveErrors: [VariableOwner: String] = [:]
    private var secretEditTokens: [SecretEditTarget: UUID] = [:]
    private var secretCommitErrors: [SecretEditTarget: String] = [:]
    private var preparationTasks: [RequestIdentity: Task<Void, Never>] = [:]
    private var store: CollectionStore?
    private var snapshotStore: SnapshotStore?
    private var executionManager: HTTPExecutionManager?
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
    private var acceptedMutationTasks: [UUID: Task<Void, Never>] = [:]
    private var mutationDrainWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var mutationDrainTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var workspaceRevision: UInt64 = 0

    init(arguments: [String] = ProcessInfo.processInfo.arguments, secretVault: SecretVault? = nil) {
        self.secretVault = secretVault ?? SecretVault(keyStore: KeychainApplicationKeyStore(
            service: (Bundle.main.bundleIdentifier ?? "dev.postie.local") + ".workspace-encryption"
        ))
        do {
            let directories = try Self.directories(from: arguments)
            store = try CollectionStore(rootURL: directories.data)
            snapshotStore = SnapshotStore(
                rootURL: directories.data.appendingPathComponent("snapshots", isDirectory: true),
                vault: self.secretVault
            )
            executionManager = try HTTPExecutionManager(bodyDirectory: directories.body)
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
              !showsGlobalSettings else { return }
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
        guard !isTerminating, snapshots.contains(where: { $0.id == id }) else { return }
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

    func showRequestSearch() {
        guard !isTerminating else { return }
        showsRequestSearch = true
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
        guard workspaceLoaded, !globalOptionsAreReadOnly, !isTerminating else { return }
        globalOptions = options
        markWorkspaceChanged()
        scheduleVariableSave(.global)
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

    func showCollection(_ id: UUID, section: CollectionEditorSection = .variables) {
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
              collectionEditorSection != section else { return }
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
              let collection = collection(id: identity.collectionID) else { return false }
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
        guard canEditVariables(.collection(id)), let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].headers = headers
        markWorkspaceChanged()
        scheduleVariableSave(.collection(id))
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
            variableCompletions(in: VariableContext(global: globalVariables, collection: variables(for: .collection(id))))
        case let .request(identity):
            variableCompletions(for: identity)
        }
    }

    private func variableCompletions(in context: VariableContext) -> [VariableCompletion] {
        let names = Set(context.global.keys).union(context.collection.keys).union(context.request.keys)
        return names.sorted().compactMap { name in
            let resolved: (VariableValue, VariableScope)? =
                context.request[name].map { ($0, .request) } ??
                context.collection[name].map { ($0, .collection) } ??
                context.global[name].map { ($0, .global) }
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
        workspaceLoaded && !isTerminating && canCommitVariables(owner)
    }

    func variableContext(for identity: RequestIdentity) -> VariableContext {
        VariableContext(
            global: globalVariables,
            collection: collection(for: identity)?.variables ?? [:],
            request: drafts[identity]?.variables ?? [:]
        )
    }

    func variableInspection(named name: String, in origin: VariableOwner) -> VariableInspection? {
        guard !isTerminating, activeVariableOwner == origin else { return nil }
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
        case let .collection(id): showCollection(id)
        case let .request(identity):
            guard isAvailableNavigationLocation(.requestVariableDefinition(identity, name: inspection.name)) else { return }
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
        try await commitProtectedValue(target: .variable(owner, name), blocksTerminationOnFailure: false, operation: {
            switch value {
            case let .plain(plain): return VariableValue.encrypted(try await vault.encrypt(plain))
            case let .encrypted(envelope): return VariableValue.plain(try await vault.decrypt(envelope))
            }
        }) { [weak self] converted in
            self?.updateVariables(owner) { $0[name] = converted }
        }
    }

    func setAuthenticationKind(_ kind: AuthenticationKind, for identity: RequestIdentity) {
        setAuthenticationKind(kind, owner: .request(identity))
    }

    func updateAuthenticationUsername(_ username: String, for identity: RequestIdentity) {
        updateAuthenticationUsername(username, owner: .request(identity))
    }

    func setAuthenticationSecret(_ value: String, field: AuthenticationSecretField, for identity: RequestIdentity) async throws {
        try await setAuthenticationSecret(value, field: field, owner: .request(identity))
    }

    func revealAuthenticationSecret(field: AuthenticationSecretField, for identity: RequestIdentity) async throws -> String {
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
              let collection = collection(for: identity) else { throw ConfigurationEditError.unavailable }
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
            decryptor: secretVault
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
              requestEditorSection(for: identity) == .request ||
                  requestEditorSection(for: identity) == .authentication else {
            throw ConfigurationEditError.unavailable
        }
        return value
    }

    func discardAuthenticationSecretEdit(field: AuthenticationSecretField, owner: VariableOwner) {
        discardSecretEdit(.authentication(owner, field))
    }

    private func updateAuthentication(_ owner: VariableOwner, _ update: (inout RequestAuthentication) -> Void) {
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
            return !collection.isReadOnly && !deletingCollections.contains(identity.collectionID) &&
                !deletingRequests.contains(identity) && !reconcilingRequests.contains(identity)
        }
    }

    private func commitSecret(
        _ value: String,
        target: SecretEditTarget,
        operationID: UUID = UUID(),
        apply: @escaping @MainActor (SecretEnvelope) -> Void
    ) async throws {
        let vault = secretVault
        try await commitProtectedValue(target: target, operationID: operationID, operation: {
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
        let result = await task.value
        finishAcceptedMutation(token)
        try result.get()
    }

    private func discardSecretEdit(_ target: SecretEditTarget) {
        secretEditTokens.removeValue(forKey: target)
        secretCommitErrors.removeValue(forKey: target)
        refreshVariableError(target.owner)
    }

    private func refreshVariableError(_ owner: VariableOwner) {
        let requestError: String?
        if case let .request(identity) = owner { requestError = autosaveErrors[identity] } else { requestError = nil }
        variableSaveErrors[owner] = secretCommitErrors.first { $0.key.owner == owner }?.value ?? scopeSaveErrors[owner] ?? requestError
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
            let parsed = QueryParameters.parse(displayURL: url, previousFields: request.query, previousBase: request.url)
            request.url = parsed.baseURL
            request.query = parsed.fields
        }
    }

    func updateQuery(_ fields: [HTTPField], for identity: RequestIdentity) {
        updateDraft(identity) { $0.query = fields }
    }

    func createCollection(name: String) async {
        await initialWorkspaceLoadTask?.value
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
        failures.append(contentsOf: variableOwners.compactMap { owner in
            guard dirtyVariableOwners.contains(owner) else { return nil }
            return scopeSaveErrors[owner] ?? "Variable changes are still unsaved."
        })
        failures.append(contentsOf: secretCommitErrors.values)
        guard failures.isEmpty else { throw SaveFlushError.failed(failures) }
    }

    func prepareForTermination() async -> Bool {
        guard !isTerminating else { return false }
        isTerminating = true
        do {
            try await drainAcceptedMutations()
            try await flushPendingSaves()
            for identity in Array(preparationTasks.keys) where activeRuns[identity]?.runID == nil {
                cancelRequest(identity)
            }
            await waitForSnapshotSaves()
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
              var configuration = drafts[identity],
              let collection = collection(for: identity),
              let executionManager else { return }

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
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        preparationTasks[identity] = Task { [weak self] in
            do {
                let prepared = try await RequestPreparer.prepare(
                    configuration, context: context, decryptor: secretVault,
                    collection: collectionDefaults, captureRedactionInputs: true
                )
                try Task.checkCancellation()
                guard let self, self.activeRuns[identity]?.token == token else { return }
                guard self.canEdit(identity), self.activeRuns[identity]?.cancelRequested == false else {
                    self.cancelledRequests.insert(identity)
                    self.settleRun(identity, token: token)
                    return
                }
                let run = try await executionManager.start(identity: identity, prepared: prepared)
                await self.observe(run, for: identity, token: token, using: executionManager)
            } catch is CancellationError {
                guard let self, self.activeRuns[identity]?.token == token else { return }
                self.cancelledRequests.insert(identity)
                self.settleRun(identity, token: token)
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
            snapshotSource: latestResponses[identity]?.snapshotSource,
            startedAt: Date(),
            phase: .preparing,
            runID: nil,
            progress: nil,
            redirects: response.redirects,
            cancelRequested: false
        )
        runErrors.removeValue(forKey: identity)
        cancelledRequests.remove(identity)

        preparationTasks[identity] = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.activeRuns[identity]?.token == token else { return }
                guard self.canEdit(identity), self.activeRuns[identity]?.cancelRequested == false else {
                    self.cancelledRequests.insert(identity)
                    self.settleRun(identity, token: token)
                    return
                }
                let run = try await executionManager.followRedirect(identity: identity, response: response)
                await self.observe(run, for: identity, token: token, using: executionManager)
            } catch is CancellationError {
                guard let self, self.activeRuns[identity]?.token == token else { return }
                self.cancelledRequests.insert(identity)
                self.settleRun(identity, token: token)
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
        if active.cancelRequested {
            await executionManager.cancel(identity: identity, runID: run.id)
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
        guard active.runID != nil else {
            preparationTasks.removeValue(forKey: identity)?.cancel()
            cancelledRequests.insert(identity)
            settleRun(identity, token: active.token)
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

    func snapshots(for identity: RequestIdentity) -> [SavedSnapshot] {
        snapshots.filter { $0.source.identity == identity }
    }

    func canSaveSnapshot(for identity: RequestIdentity) -> Bool {
        guard !isTerminating,
              snapshotStore != nil,
              executionManager != nil,
              let latest = latestResponses[identity],
              latest.snapshotSource != nil,
              latest.response.snapshotCapture != nil else { return false }
        return !savingSnapshotRunIDs.contains(latest.response.runID)
    }

    func isSavingSnapshot(for identity: RequestIdentity) -> Bool {
        guard let runID = latestResponses[identity]?.response.runID else { return false }
        return savingSnapshotRunIDs.contains(runID)
    }

    func saveSnapshot(for identity: RequestIdentity) {
        guard canSaveSnapshot(for: identity),
              let latest = latestResponses[identity],
              let source = latest.snapshotSource else { return }

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
        guard !isTerminating, let snapshotStore else { return }
        do {
            let saved = try await snapshotStore.rename(id: id, name: name)
            upsertSnapshot(saved)
        } catch {
            operationError = error.localizedDescription
        }
    }

    func deleteSnapshot(id: UUID) async {
        guard !isTerminating, let snapshotStore else { return }
        do {
            try await snapshotStore.delete(id: id)
            markWorkspaceChanged()
            snapshots.removeAll { $0.id == id }
            openedSnapshots.removeValue(forKey: id)
            openingSnapshots.remove(id)
            snapshotOpenErrors.removeValue(forKey: id)
            if selectedSnapshotID == id { selectedSnapshotID = nil }
        } catch {
            operationError = error.localizedDescription
        }
    }

    func snapshotOpenError(for id: UUID) -> String? {
        snapshotOpenErrors[id]
    }

    func exportEncryptionKey() async throws -> Data {
        try await secretVault.exportKey()
    }

    func importEncryptionKey(_ key: Data) async throws -> SecretKeyImportResult {
        let envelopes = try await encryptionEnvelopesForKeyImport()
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
        defer { finishSnapshotSave(runID: runID, operationID: operationID) }
        guard let snapshotStore, let executionManager else { return }

        let lease: HTTPBodyLease
        do {
            lease = try await executionManager.acquireBodyLease(for: response)
        } catch {
            operationError = error.localizedDescription
            return
        }

        do {
            let saved = try await snapshotStore.save(
                response: response,
                source: source,
                name: name,
                bodyLease: lease
            )
            upsertSnapshot(saved)
        } catch {
            operationError = error.localizedDescription
        }
        await executionManager.releaseBodyLease(lease)
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
              let snapshotStore else { return }
        openingSnapshots.insert(id)
        snapshotOpenErrors.removeValue(forKey: id)
        Task { @MainActor [weak self, snapshotStore] in
            do {
                let opened = try await snapshotStore.open(id: id)
                guard let self else { return }
                if self.selectedSnapshotID == id,
                   self.snapshots.contains(where: { $0.id == id }) {
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
        guard workspaceLoaded, !isTerminating, let store, let snapshotStore else {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }

        let currentGlobals = globalVariables
        let currentCollections = collections
        let currentDrafts = drafts
        let currentSnapshots = snapshots
        let currentStorageIssues = storageIssues
        let currentSnapshotStorageIssues = snapshotStorageIssues
        let currentSnapshotLoadError = snapshotLoadError
        guard !globalVariablesAreReadOnly, !globalOptionsAreReadOnly,
              !currentCollections.contains(where: \.isReadOnly), currentStorageIssues.isEmpty,
              currentSnapshotStorageIssues.isEmpty, currentSnapshotLoadError == nil,
              variableSaveErrors.isEmpty, scopeSaveErrors.isEmpty, autosaveErrors.isEmpty else {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        let loaded: WorkspaceLoad
        do {
            loaded = try await store.load()
        } catch {
            throw EncryptionKeyTransferError.workspaceUnavailable
        }
        guard loaded.issues.isEmpty, !loaded.globalVariablesAreReadOnly, !loaded.globalOptionsAreReadOnly,
              !loaded.collections.contains(where: \.isReadOnly) else {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        let snapshotEnvelopes: [SecretEnvelope]
        do {
            snapshotEnvelopes = try await snapshotStore.encryptionEnvelopes()
        } catch {
            throw EncryptionKeyTransferError.storageNeedsRepair
        }

        guard workspaceLoaded, !isTerminating,
              globalVariables == currentGlobals, collections == currentCollections,
              drafts == currentDrafts, snapshots == currentSnapshots,
              storageIssues == currentStorageIssues, snapshotStorageIssues == currentSnapshotStorageIssues,
              snapshotLoadError == currentSnapshotLoadError,
              !globalVariablesAreReadOnly, !globalOptionsAreReadOnly,
              !collections.contains(where: \.isReadOnly), variableSaveErrors.isEmpty,
              scopeSaveErrors.isEmpty, autosaveErrors.isEmpty else {
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
        return envelopes + snapshotEnvelopes
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
              let snapshotStore else { return }

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
        workspaceLoaded = false
        await secretVault.setAllowsKeyCreation(false)
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

                let retainedCollections = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
                let nextCollections = sorted(loaded.collections.map { collection in
                    var collection = collection
                    if dirtyVariableOwners.contains(.collection(collection.id)), let retained = retainedCollections[collection.id] {
                        collection.variables = retained.variables
                        collection.headers = retained.headers
                        collection.authentication = retained.authentication
                    }
                    return collection
                })
                let nextGlobals = dirtyVariableOwners.contains(.global) ? globalVariables : loaded.globalVariables
                var nextDrafts = drafts.filter { !unavailable.contains($0.key) }
                for (identity, request) in available where nextDrafts[identity] == nil {
                    nextDrafts[identity] = request
                }
                let hasCiphertext = nextGlobals.values.contains(where: \.isEncrypted) ||
                    loaded.globalVariables.values.contains(where: \.isEncrypted) ||
                    nextCollections.contains(where: Self.containsCiphertext) ||
                    loaded.collections.contains(where: Self.containsCiphertext) ||
                    available.values.contains(where: Self.containsCiphertext) ||
                    nextDrafts.values.contains(where: Self.containsCiphertext)
                let snapshotKeyStateIsSafe = snapshotError == nil &&
                    snapshotLoad?.containsEncryptedData == false &&
                    snapshotLoad?.issues.isEmpty == true
                await secretVault.setAllowsKeyCreation(!hasCiphertext && snapshotKeyStateIsSafe && loaded.issues.isEmpty &&
                    !loaded.globalVariablesAreReadOnly && !loaded.collections.contains(where: \.isReadOnly))
                guard revision == workspaceRevision else {
                    await secretVault.setAllowsKeyCreation(false)
                    continue
                }
                workspaceRevision &+= 1
                for identity in unavailable {
                    removeLocalRequestState(for: identity)
                }
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

    private static func containsCiphertext(_ request: HTTPRequestConfiguration) -> Bool {
        request.variables.values.contains(where: \.isEncrypted) ||
            request.authentication.password != nil || request.authentication.token != nil ||
            request.authentication.apiKey != nil
    }

    private static func containsCiphertext(_ collection: RequestCollection) -> Bool {
        collection.variables.values.contains(where: \.isEncrypted) ||
            collection.authentication.password != nil || collection.authentication.token != nil ||
            collection.authentication.apiKey != nil
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
        } else { defaults = nil }
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
            replaceLatestResponse(response, for: identity, source: active.snapshotSource)
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
        preparationTasks.removeValue(forKey: identity)
        activeRuns.removeValue(forKey: identity)
        let waiters = settlementWaiters.removeValue(forKey: identity) ?? []
        waiters.forEach { $0.resume() }
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
        guard let store, let collection = collections.first(where: { $0.id == id }), !collection.isReadOnly else { return }
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

        do {
            try await store.deleteCollection(id: id)
            markWorkspaceChanged()
            for identity in requestIdentities {
                removeLocalRequestState(for: identity)
            }
            collections.removeAll { $0.id == id }
            if selectedCollectionID == id { selectedCollectionID = nil }
            removeVariableOwnerState(.collection(id))
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
        removeVariableOwnerState(.request(identity))
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
        collections = sorted(collections.map { $0.id == collection.id ? collection : $0 })
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
           !showsOngoingRequests {
            recordNavigation(.request(selectedIdentity, section: requestEditorSection(for: selectedIdentity)))
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
