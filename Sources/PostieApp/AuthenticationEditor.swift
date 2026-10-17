import SwiftUI
import PostieCore

struct AuthenticationEditor: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    @State private var isEditingPassword = false
    @State private var isEditingToken = false
    @State private var isPasswordBusy = false
    @State private var isTokenBusy = false

    private var authentication: RequestAuthentication {
        model.authentication(for: owner)
    }

    init(identity: RequestIdentity) { owner = .request(identity) }
    init(collectionID: UUID) { owner = .collection(collectionID) }

    private enum Choice: String, Hashable {
        case inherit, none, basic, bearer
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
        case .global: return []
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
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canEditVariables(owner) || activeSecretIsEditing || activeSecretIsBusy)
            }

            if inherits {
                Label("Uses collection authentication, resolved with this request’s variables.", systemImage: "arrow.turn.down.right")
                    .font(.callout).foregroundStyle(.secondary)
                if let requestIdentity {
                    Button("Edit collection authentication") { model.showCollection(requestIdentity.collectionID) }
                }
            } else {
                authenticationFields
            }
        }
        .onDisappear {
            model.discardAuthenticationSecretEdit(field: .password, owner: owner)
            model.discardAuthenticationSecretEdit(field: .token, owner: owner)
        }
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
            AuthenticationSecretEditor(owner: owner, field: .token, title: "Bearer token",
                                       availableVariables: availableVariables,
                                       isEditing: $isEditingToken, isBusy: $isTokenBusy)
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
                    availableVariables: availableVariables
                )
                .font(.system(.body, design: .monospaced))
                .disabled(!model.canEditVariables(owner))
            }

            AuthenticationSecretEditor(
                owner: owner,
                field: .password,
                title: "Password",
                availableVariables: availableVariables,
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

    private var activeSecretIsEditing: Bool {
        switch authentication.kind {
        case .none:
            false
        case .basic:
            isEditingPassword
        case .bearer:
            isEditingToken
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
        }
    }
}

private struct AuthenticationSecretEditor: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    let field: AuthenticationSecretField
    let title: String
    let availableVariables: Set<String>
    @Binding var isEditing: Bool
    @Binding var isBusy: Bool

    @State private var secretDraft = ""
    @State private var isRevealed = false
    @State private var errorMessage: String?

    private var hasSavedSecret: Bool {
        let authentication = model.authentication(for: owner)
        switch field {
        case .password:
            return authentication.password != nil
        case .token:
            return authentication.token != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            if isEditing {
                secretInput
                    .disabled(isBusy)

                Text("Secret changes are saved with Save. Leaving this editor discards unsaved secret edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if hasSavedSecret {
                        Button("Reveal saved") {
                            revealSavedSecret()
                        }
                        .disabled(isBusy)
                    }
                    Spacer()
                    Button("Cancel", action: cancel)
                        .disabled(isBusy)
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }
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
                        rounded: true
                    )
                } else {
                    SecureField("Secret value", text: $secretDraft)
                }
            }
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
        secretDraft = ""
        isRevealed = false
        errorMessage = nil
        isEditing = true
    }

    private func revealSavedSecret() {
        guard hasSavedSecret else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                secretDraft = try await model.revealAuthenticationSecret(field: field, owner: owner)
                isRevealed = true
                isEditing = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func save() {
        guard isEditing else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                try await model.setAuthenticationSecret(secretDraft, field: field, owner: owner)
                secretDraft = ""
                isRevealed = false
                isEditing = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func cancel() {
        model.discardAuthenticationSecretEdit(field: field, owner: owner)
        secretDraft = ""
        isRevealed = false
        isEditing = false
        errorMessage = nil
    }
}
