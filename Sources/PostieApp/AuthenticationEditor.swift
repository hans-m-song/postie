import SwiftUI
import PostieCore

struct AuthenticationEditor: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    @State private var isEditingPassword = false
    @State private var isEditingToken = false
    @State private var isPasswordBusy = false
    @State private var isTokenBusy = false

    private var authentication: RequestAuthentication {
        model.request(for: identity)?.authentication ?? RequestAuthentication()
    }

    private var availableVariables: Set<String> {
        let context = model.variableContext(for: identity)
        return Set(context.global.keys)
            .union(context.collection.keys)
            .union(context.request.keys)
    }

    private var kindBinding: Binding<AuthenticationKind> {
        Binding(
            get: { authentication.kind },
            set: { model.setAuthenticationKind($0, for: identity) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Authentication")
                    .font(.headline)

                Picker("Authentication", selection: kindBinding) {
                    Text("None").tag(AuthenticationKind.none)
                    Text("Basic").tag(AuthenticationKind.basic)
                    Text("Bearer").tag(AuthenticationKind.bearer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canEdit(identity) || activeSecretIsEditing || activeSecretIsBusy)
            }

            switch authentication.kind {
            case .none:
                Label("Manual Authorization headers remain available in Request.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .basic:
                basicFields
            case .bearer:
                AuthenticationSecretEditor(
                    identity: identity,
                    field: .token,
                    title: "Bearer token",
                    availableVariables: availableVariables,
                    isEditing: $isEditingToken,
                    isBusy: $isTokenBusy
                )
            }
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
                .disabled(!model.canEdit(identity))
            }

            AuthenticationSecretEditor(
                identity: identity,
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
            set: { model.updateAuthenticationUsername($0, for: identity) }
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
    let identity: RequestIdentity
    let field: AuthenticationSecretField
    let title: String
    let availableVariables: Set<String>
    @Binding var isEditing: Bool
    @Binding var isBusy: Bool

    @State private var secretDraft = ""
    @State private var isRevealed = false
    @State private var errorMessage: String?

    private var hasSavedSecret: Bool {
        let authentication = model.request(for: identity)?.authentication
        switch field {
        case .password:
            return authentication?.password != nil
        case .token:
            return authentication?.token != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            if isEditing {
                secretInput
                    .disabled(isBusy)

                Text("Secret changes are saved with Save. Leaving this request discards unsaved secret edits.")
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
                        .disabled(isBusy || !model.canEdit(identity))
                        Button("Replace") {
                            beginReplacement()
                        }
                        .disabled(isBusy || !model.canEdit(identity))
                    } else {
                        Button("Set secret") {
                            beginReplacement()
                        }
                        .disabled(isBusy || !model.canEdit(identity))
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
                secretDraft = try await model.revealAuthenticationSecret(field: field, for: identity)
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
                try await model.setAuthenticationSecret(secretDraft, field: field, for: identity)
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
        model.discardAuthenticationSecretEdit(field: field, for: identity)
        secretDraft = ""
        isRevealed = false
        isEditing = false
        errorMessage = nil
    }
}
