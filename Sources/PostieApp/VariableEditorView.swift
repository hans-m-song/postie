import SwiftUI
import PostieCore

struct VariableEditorView: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    var isActive: Bool = true

    @State private var isAdding = false
    @State private var newVariableName = ""
    @State private var newVariableValue = ""
    @State private var newVariableIsSecret = false
    @State private var isNewSecretRevealed = false
    @State private var isSavingNewVariable = false
    @State private var addError: String?

    private var variables: VariableValues {
        model.variables(for: owner)
    }

    private var variableNames: [String] {
        variables.keys.sorted()
    }

    private var isEditable: Bool {
        isActive && model.canEditVariables(owner)
    }

    private var title: String {
        switch owner {
        case .global:
            "Global variables"
        case .collection:
            "Collection variables"
        case .request:
            "Request variables"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                if !model.canEditVariables(owner) {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isAdding {
                    Button {
                        beginAdding()
                    } label: {
                        Label("Add variable", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isEditable)
                }
            }

            if let error = model.variableSaveErrors[owner] {
                Label("Changes were not saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if variables.isEmpty && !isAdding {
                Text("No variables")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(variableNames, id: \.self) { name in
                        if let value = variables[name] {
                            VariableEditorRow(
                                name: name,
                                value: value,
                                owner: owner,
                                isEditable: isEditable
                            )
                            .id(owner)
                            if name != variableNames.last {
                                Divider()
                            }
                        }
                    }

                    if isAdding {
                        if !variables.isEmpty {
                            Divider()
                        }
                        newVariableEditor
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .id(owner)
        .onChange(of: owner) { oldOwner, _ in
            discardSecretEdits(for: oldOwner)
            resetNewVariableDraft()
            isAdding = false
        }
        .onDisappear {
            discardSecretEdits(for: owner)
        }
    }

    private var newVariableEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TextField("Variable name", text: $newVariableName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isSavingNewVariable)
                Toggle("Secret", isOn: $newVariableIsSecret)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(isSavingNewVariable)
            }

            HStack(spacing: 8) {
                SecretValueInput(
                    placeholder: "Variable value",
                    value: $newVariableValue,
                    isRevealed: $isNewSecretRevealed,
                    isSecret: newVariableIsSecret
                )
                .disabled(isSavingNewVariable)
                Button("Cancel", action: cancelAdding)
                    .disabled(isSavingNewVariable)
                Button(newVariableIsSecret ? "Save" : "Add", action: saveNewVariable)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEditable || isSavingNewVariable || variableNameError(newVariableName) != nil)
            }

            if let validationError = variableNameError(newVariableName) {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSavingNewVariable {
                ProgressView()
                    .controlSize(.small)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if newVariableIsSecret {
                Text("Secret changes are saved with Save. Leaving this scope discards unsaved secret edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .font(.system(.body, design: .monospaced))
    }

    private func beginAdding() {
        resetNewVariableDraft()
        isAdding = true
    }

    private func saveNewVariable() {
        guard isEditable,
              variableNameError(newVariableName) == nil else { return }
        isSavingNewVariable = true
        addError = nil

        Task {
            do {
                try await model.setVariable(
                    name: newVariableName,
                    value: newVariableValue,
                    isSecret: newVariableIsSecret,
                    owner: owner
                )
                resetNewVariableDraft()
                isAdding = false
            } catch {
                addError = error.localizedDescription
            }
            isSavingNewVariable = false
        }
    }

    private func cancelAdding() {
        if newVariableIsSecret, TemplateEngine.isValidVariableName(newVariableName) {
            model.discardVariableSecretEdit(named: newVariableName, owner: owner)
        }
        resetNewVariableDraft()
        isAdding = false
    }

    private func discardSecretEdits(for owner: VariableOwner) {
        if newVariableIsSecret, TemplateEngine.isValidVariableName(newVariableName) {
            model.discardVariableSecretEdit(named: newVariableName, owner: owner)
        }
        for name in model.variables(for: owner).keys {
            model.discardVariableSecretEdit(named: name, owner: owner)
        }
    }

    private func resetNewVariableDraft() {
        newVariableName = ""
        newVariableValue = ""
        newVariableIsSecret = false
        isNewSecretRevealed = false
        addError = nil
    }

    private func variableNameError(_ name: String) -> String? {
        guard !name.isEmpty else { return "Enter a variable name." }
        guard TemplateEngine.isValidVariableName(name) else {
            return "Use ASCII letters, digits, and underscores; the first character must be a letter or underscore."
        }
        guard variables[name] == nil else { return "A variable with this name already exists." }
        return nil
    }
}

private struct VariableEditorRow: View {
    @EnvironmentObject private var model: AppModel
    let name: String
    let value: VariableValue
    let owner: VariableOwner
    let isEditable: Bool

    @State private var plainDraft = ""
    @State private var secretDraft = ""
    @State private var renameDraft = ""
    @State private var isEditingSecret = false
    @State private var isRenaming = false
    @State private var isSecretRevealed = false
    @State private var isBusy = false
    @State private var hasUnsavedPlainValue = false
    @State private var errorMessage: String?

    private var storedSecret: Bool {
        if case .encrypted = value { return true }
        return false
    }

    private var storedPlainValue: String? {
        if case .plain(let value) = value { return value }
        return nil
    }

    private var renameError: String? {
        guard !renameDraft.isEmpty else { return "Enter a variable name." }
        guard TemplateEngine.isValidVariableName(renameDraft) else {
            return "Use ASCII letters, digits, and underscores; the first character must be a letter or underscore."
        }
        guard renameDraft == name || model.variables(for: owner)[renameDraft] == nil else {
            return "A variable with this name already exists."
        }
        return nil
    }

    private var plainValueBinding: Binding<String> {
        Binding(
            get: { plainDraft },
            set: { updatedValue in
                plainDraft = updatedValue
                updatePlainValue(updatedValue)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                if storedSecret {
                    Label("Secret", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !isEditingSecret && !isRenaming && !isBusy {
                    Button("Rename") {
                        renameDraft = name
                        errorMessage = nil
                        isRenaming = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isEditable)
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove variable")
                    .disabled(!isEditable)
                }
            }

            if isRenaming {
                renameEditor
            } else if isEditingSecret {
                secretEditor
            } else if storedPlainValue != nil {
                plainValueEditor
            } else {
                storedSecretEditor
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .onAppear(perform: syncPlainDraft)
        .onChange(of: value) { _, newValue in
            if case .plain(let plainValue) = newValue {
                guard !hasUnsavedPlainValue else { return }
                plainDraft = plainValue
            } else {
                plainDraft = ""
                hasUnsavedPlainValue = false
            }
        }
    }

    private var plainValueEditor: some View {
        HStack(spacing: 8) {
            TextField("Value", text: plainValueBinding)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .disabled(!isEditable)

            if !isEditingSecret && isEditable {
                Button("Mark secret") {
                    beginSecretEdit(with: plainDraft)
                }
                .buttonStyle(.borderless)
            }

        }
    }

    private var storedSecretEditor: some View {
        HStack(spacing: 8) {
            Label("Encrypted value stored", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isEditable {
                Button("Reveal & edit", action: revealSecret)
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                Button("Replace") {
                    beginSecretEdit(with: "")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
            }
        }
    }

    private var secretEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecretValueInput(
                    placeholder: "Secret value",
                    value: $secretDraft,
                    isRevealed: $isSecretRevealed,
                    isSecret: true
                )
                .disabled(isBusy)
                if storedSecret {
                    Button("Reveal saved", action: revealSecret)
                        .buttonStyle(.borderless)
                        .disabled(isBusy)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancelSecretEdit)
                    .disabled(isBusy)
                Button("Save", action: saveSecret)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
            }

            Text("Secret changes are saved with Save. Leaving this scope discards unsaved secret edits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Variable name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isBusy)
                Button("Cancel") {
                    isRenaming = false
                    errorMessage = nil
                }
                    .disabled(isBusy)
                Button("Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEditable || isBusy || hasUnsavedPlainValue || renameError != nil)
            }
            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func syncPlainDraft() {
        guard let storedPlainValue else { return }
        plainDraft = storedPlainValue
    }

    private func updatePlainValue(_ updatedValue: String) {
        guard isEditable,
              !isEditingSecret,
              !isBusy,
              !isRenaming,
              storedPlainValue != nil else { return }
        guard updatedValue != storedPlainValue else {
            hasUnsavedPlainValue = false
            return
        }
        errorMessage = nil
        do {
            try model.setPlainVariable(name: name, value: updatedValue, owner: owner)
            hasUnsavedPlainValue = false
        } catch {
            hasUnsavedPlainValue = true
            errorMessage = error.localizedDescription
        }
    }

    private func beginSecretEdit(with value: String) {
        secretDraft = value
        isSecretRevealed = false
        errorMessage = nil
        isEditingSecret = true
    }

    private func revealSecret() {
        guard storedSecret else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                secretDraft = try await model.revealVariable(named: name, owner: owner)
                isSecretRevealed = true
                isEditingSecret = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func saveSecret() {
        guard isEditable else { return }
        isBusy = true
        errorMessage = nil

        Task {
            do {
                try await model.setVariable(name: name, value: secretDraft, isSecret: true, owner: owner)
                secretDraft = ""
                plainDraft = ""
                isSecretRevealed = false
                isEditingSecret = false
                hasUnsavedPlainValue = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func cancelSecretEdit() {
        model.discardVariableSecretEdit(named: name, owner: owner)
        secretDraft = ""
        isSecretRevealed = false
        isEditingSecret = false
        errorMessage = nil
        if let storedPlainValue, plainDraft != storedPlainValue {
            updatePlainValue(plainDraft)
        }
    }

    private func rename() {
        guard isEditable, !hasUnsavedPlainValue, renameError == nil else { return }
        errorMessage = nil
        do {
            try model.renameVariable(from: name, to: renameDraft, owner: owner)
            isRenaming = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove() {
        if isEditingSecret {
            model.discardVariableSecretEdit(named: name, owner: owner)
        }
        model.removeVariable(named: name, owner: owner)
    }
}

private struct SecretValueInput: View {
    let placeholder: String
    @Binding var value: String
    @Binding var isRevealed: Bool
    let isSecret: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isSecret && !isRevealed {
                    SecureField(placeholder, text: $value)
                } else {
                    TextField(placeholder, text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            if isSecret {
                Button(isRevealed ? "Hide" : "Show") {
                    isRevealed.toggle()
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
