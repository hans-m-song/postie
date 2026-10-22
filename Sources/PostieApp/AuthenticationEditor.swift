import SwiftUI
import PostieCore

struct AuthenticationEditor: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    @State private var isEditingPassword = false
    @State private var isEditingToken = false
    @State private var isEditingAPIKey = false
    @State private var isPasswordBusy = false
    @State private var isTokenBusy = false
    @State private var isAPIKeyBusy = false

    private var authentication: RequestAuthentication {
        model.authentication(for: owner)
    }

    init(identity: RequestIdentity) { owner = .request(identity) }
    init(collectionID: UUID) { owner = .collection(collectionID) }

    private enum Choice: String, Hashable {
        case inherit, none, basic, bearer, apiKey
    }

    private var requestIdentity: RequestIdentity? {
        if case let .request(identity) = owner { return identity }
        return nil
    }

    private var inherits: Bool {
        requestIdentity.flatMap { model.request(for: $0)?.inheritsCollectionAuthentication } ?? false
    }

    private var availableVariables: Set<String> {
        switch owner {
        case let .request(identity):
            let context = model.variableContext(for: identity)
            return Set(context.global.keys).union(context.collection.keys).union(context.request.keys)
        case let .collection(id):
            return Set(model.globalVariables.keys).union(model.variables(for: .collection(id)).keys)
        case .global:
            return []
        }
    }

    private var kindBinding: Binding<Choice> {
        Binding(
            get: { inherits ? .inherit : Choice(rawValue: authentication.kind.rawValue) ?? .none },
            set: { choice in
                if let requestIdentity {
                    model.setInheritsCollectionAuthentication(choice == .inherit, for: requestIdentity)
                }
                guard let kind = AuthenticationKind(rawValue: choice.rawValue) else { return }
                model.setAuthenticationKind(kind, owner: owner)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(.headline)

                Picker("Authentication", selection: kindBinding) {
                    if requestIdentity != nil { Text("Inherit").tag(Choice.inherit) }
                    Text("None").tag(Choice.none)
                    Text("Basic").tag(Choice.basic)
                    Text("Bearer").tag(Choice.bearer)
                    Text("API Key").tag(Choice.apiKey)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!model.canEditVariables(owner) || activeSecretIsEditing || activeSecretIsBusy)
            }

            if inherits {
                Label(
                    "Uses collection authentication, resolved with this request’s variables.",
                    systemImage: "arrow.turn.down.right"
                )
                .font(.callout).foregroundStyle(.secondary)
                if let requestIdentity {
                    Button("Edit collection authentication") {
                        model.showCollection(requestIdentity.collectionID, section: .authentication)
                    }
                    InheritedAuthenticationSummary(identity: requestIdentity)
                }
            } else {
                authenticationFields
            }
        }
        .onDisappear {
            discardSecretEdits()
        }
        .onChange(of: isAuthenticationSectionActive) { _, isActive in
            if !isActive { discardSecretEdits() }
        }
    }

    private var isAuthenticationSectionActive: Bool {
        switch owner {
        case let .request(identity):
            return model.selectedIdentity == identity && model.selectedCollectionID == nil
                && !model.showsGlobalVariables && !model.showsGlobalSettings && !model.showsOngoingRequests
                && model.requestEditorSection(for: identity) == .authentication
        case let .collection(id):
            return model.selectedCollectionID == id && model.collectionEditorSection == .authentication
                && !model.showsGlobalVariables && !model.showsGlobalSettings && !model.showsOngoingRequests
        case .global:
            return false
        }
    }

    private func discardSecretEdits() {
        model.discardAuthenticationSecretEdit(field: .password, owner: owner)
        model.discardAuthenticationSecretEdit(field: .token, owner: owner)
        model.discardAuthenticationSecretEdit(field: .apiKey, owner: owner)
    }

    @ViewBuilder
    private var authenticationFields: some View {
        switch authentication.kind {
        case .none:
            Label("Authorization headers can be configured in Headers.", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .basic:
            basicFields
        case .bearer:
            AuthenticationSecretEditor(
                owner: owner, field: .token, title: "Bearer token",
                availableVariables: availableVariables,
                isSectionActive: isAuthenticationSectionActive,
                isEditing: $isEditingToken, isBusy: $isTokenBusy)
        case .apiKey:
            apiKeyFields
        }
    }

    private var apiKeyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Header name")
                    .font(.subheadline.weight(.medium))
                TextField("X-API-Key", text: apiKeyHeaderNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!model.canEditVariables(owner))
                Text("Request headers with the same name take precedence over this key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AuthenticationSecretEditor(
                owner: owner,
                field: .apiKey,
                title: "API key",
                availableVariables: availableVariables,
                isSectionActive: isAuthenticationSectionActive,
                isEditing: $isEditingAPIKey,
                isBusy: $isAPIKeyBusy
            )
        }
    }

    private var basicFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Username")
                    .font(.subheadline.weight(.medium))
                HighlightedTextField(
                    "Username",
                    text: usernameBinding,
                    availableVariables: availableVariables,
                    completionVariables: model.variableCompletions(for: owner)
                )
                .font(.system(.body, design: .monospaced))
                .disabled(!model.canEditVariables(owner))
            }

            AuthenticationSecretEditor(
                owner: owner,
                field: .password,
                title: "Password",
                availableVariables: availableVariables,
                isSectionActive: isAuthenticationSectionActive,
                isEditing: $isEditingPassword,
                isBusy: $isPasswordBusy
            )
        }
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { authentication.username },
            set: { model.updateAuthenticationUsername($0, owner: owner) }
        )
    }

    private var apiKeyHeaderNameBinding: Binding<String> {
        Binding(
            get: { authentication.apiKeyHeaderName ?? "" },
            set: { model.updateAPIKeyHeaderName($0, owner: owner) }
        )
    }

    private var activeSecretIsEditing: Bool {
        switch authentication.kind {
        case .none:
            false
        case .basic:
            isEditingPassword
        case .bearer:
            isEditingToken
        case .apiKey:
            isEditingAPIKey
        }
    }

    private var activeSecretIsBusy: Bool {
        switch authentication.kind {
        case .none:
            false
        case .basic:
            isPasswordBusy
        case .bearer:
            isTokenBusy
        case .apiKey:
            isAPIKeyBusy
        }
    }
}

private struct AuthenticationSecretEditor: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    let field: AuthenticationSecretField
    let title: String
    let availableVariables: Set<String>
    let isSectionActive: Bool
    @Binding var isEditing: Bool
    @Binding var isBusy: Bool

    @State private var secretDraft = ""
    @State private var isRevealed = false
    @State private var errorMessage: String?
    @State private var secretOperationID = UUID()

    private var hasSavedSecret: Bool {
        let authentication = model.authentication(for: owner)
        switch field {
        case .password:
            return authentication.password != nil
        case .token:
            return authentication.token != nil
        case .apiKey:
            return authentication.apiKey != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            if isEditing {
                HStack(spacing: 8) {
                    secretInput
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .disabled(isBusy)

                    if hasSavedSecret {
                        Button("Reveal saved") {
                            revealSavedSecret()
                        }
                        .fixedSize()
                        .disabled(isBusy)
                    }

                    Button("Cancel", action: cancel)
                        .fixedSize()
                        .disabled(isBusy)
                    Button("Save", action: save)
                        .fixedSize()
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }

                Text("Secret changes are saved with Save. Leaving this editor discards unsaved secret edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Label(
                        hasSavedSecret ? "Secret stored" : "No secret saved",
                        systemImage: hasSavedSecret ? "key.fill" : "key"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if hasSavedSecret {
                        Button("Reveal & edit") {
                            revealSavedSecret()
                        }
                        .disabled(isBusy || !model.canEditVariables(owner))
                        Button("Replace") {
                            beginReplacement()
                        }
                        .disabled(isBusy || !model.canEditVariables(owner))
                    } else {
                        Button("Set secret") {
                            beginReplacement()
                        }
                        .disabled(isBusy || !model.canEditVariables(owner))
                    }
                }
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.system(.body, design: .monospaced))
        .onChange(of: isSectionActive) { _, isActive in
            if !isActive { cancel() }
        }
        .onDisappear { cancel() }
    }

    @ViewBuilder
    private var secretInput: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    HighlightedTextField(
                        "Secret value",
                        text: $secretDraft,
                        availableVariables: availableVariables,
                        rounded: true,
                        completionVariables: model.variableCompletions(for: owner)
                    )
                } else {
                    SecureField("Secret value", text: $secretDraft)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            Button(isRevealed ? "Hide" : "Show") {
                isRevealed.toggle()
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
        }
    }

    private func beginReplacement() {
        secretOperationID = UUID()
        secretDraft = ""
        isRevealed = false
        errorMessage = nil
        isEditing = true
    }

    private func revealSavedSecret() {
        guard hasSavedSecret else { return }
        let operationID = UUID()
        secretOperationID = operationID
        isBusy = true
        errorMessage = nil

        Task {
            do {
                let revealed = try await model.revealAuthenticationSecret(field: field, owner: owner)
                if secretOperationID == operationID && isSectionActive {
                    secretDraft = revealed
                    isRevealed = true
                    isEditing = true
                } else if secretOperationID == operationID {
                    secretDraft = ""
                }
            } catch {
                if secretOperationID == operationID && isSectionActive {
                    errorMessage = error.localizedDescription
                }
            }
            isBusy = false
        }
    }

    private func save() {
        guard isEditing else { return }
        let operationID = UUID()
        secretOperationID = operationID
        isBusy = true
        errorMessage = nil

        Task {
            do {
                try await model.setAuthenticationSecret(secretDraft, field: field, owner: owner)
                if secretOperationID == operationID { cancelLocalEdit() }
            } catch {
                if secretOperationID == operationID && isSectionActive {
                    errorMessage = error.localizedDescription
                }
            }
            isBusy = false
        }
    }

    private func cancel() {
        model.discardAuthenticationSecretEdit(field: field, owner: owner)
        cancelLocalEdit()
    }

    private func cancelLocalEdit() {
        secretOperationID = UUID()
        secretDraft = ""
        isRevealed = false
        isEditing = false
        errorMessage = nil
    }
}
