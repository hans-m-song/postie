import SwiftUI
import PostieCore

struct VariableEditorView: View {
    @EnvironmentObject private var model: AppModel
    let owner: VariableOwner
    let isActive: Bool

    @State private var rows: [VariableEditorRowState] = []
    @State private var trailingRow = VariableEditorRowState(name: "", isTrailing: true)
    @State private var activeOwner: VariableOwner
    @State private var isVisible = false
    @State private var focusedField: VariableFieldFocus?
    @State private var activeSession = UUID()

    init(owner: VariableOwner, isActive: Bool = true) {
        self.owner = owner
        self.isActive = isActive
        _activeOwner = State(initialValue: owner)
    }

    private var variables: VariableValues {
        model.variables(for: owner)
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

    private var tableRows: [VariableEditorRowState] {
        rows + [trailingRow]
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
            }

            if let error = model.variableSaveErrors[owner] {
                Label("Changes were not saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            table
        }
        .onAppear {
            isVisible = isActive
            if activeOwner != owner {
                changeOwner(to: owner)
            } else {
                reconcileRows(with: variables)
            }
        }
        .onDisappear(perform: editorDidDisappear)
        .onChange(of: isActive) { _, active in
            if active {
                isVisible = true
            } else {
                editorBecameInactive()
            }
        }
        .onChange(of: owner) { _, newOwner in
            changeOwner(to: newOwner)
        }
        .onChange(of: variables) { _, updatedVariables in
            if activeOwner != owner {
                changeOwner(to: owner)
            } else {
                reconcileRows(with: updatedVariables)
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 19)
                Text("Value")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Divider().frame(height: 19)
                Text("Secret")
                    .frame(width: 56, alignment: .center)
                Color.clear.frame(width: 26)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.quaternary)

            ForEach(tableRows) { row in
                variableRow(row)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func variableRow(_ row: VariableEditorRowState) -> some View {
        let nameError = nameError(for: row)
        let canEditValue = row.isTrailing
            ? isEditable && !row.isBusy
            : isEditable && nameError == nil && row.nameDraft == row.name && !row.isBusy

        return VStack(spacing: 0) {
            if row.isEditingSecret || (row.isTrailing && row.isSecretDraft) {
                HStack(spacing: 8) {
                    secretEditingNameCell(for: row)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Divider().frame(height: 22)

                    SecretValueInput(
                        placeholder: row.isTrailing ? "Value" : "Secret value",
                        value: row.isTrailing ? valueBinding(for: row.id) : secretDraftBinding(for: row.id),
                        isRevealed: secretRevealedBinding(for: row.id),
                        isSecret: true
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .disabled(!canEditValue)

                    Divider().frame(height: 22)

                    HStack(spacing: 6) {
                        Button("Cancel") {
                            cancelSecretEdit(for: row)
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .disabled(row.isTrailing ? row.isBusy : !canEditValue)

                        Button("Save") {
                            saveSecretEdit(for: row)
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()
                        .disabled(row.isTrailing ? !isEditable || row.isBusy || nameError != nil : !canEditValue)
                    }
                    .frame(width: 90, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    nameField(for: row)
                        .frame(minWidth: 0, maxWidth: .infinity)

                    Divider().frame(height: 22)

                    valueCell(for: row, canEditRow: canEditValue)
                        .frame(minWidth: 0, maxWidth: .infinity)

                    Divider().frame(height: 22)

                    Toggle("Secret", isOn: secretBinding(for: row.id))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .frame(width: 56)
                        .help("Store this variable as a secret")
                        .disabled(
                            !isEditable
                                || row.isBusy
                                || (!row.isTrailing && (!canEditValue || row.isEditingSecret))
                        )

                    if row.isTrailing {
                        Color.clear.frame(width: 26)
                    } else {
                        Button(role: .destructive) {
                            removeRow(row)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 26)
                        .help("Remove variable")
                        .focusable(false)
                        .disabled(!canEditValue || row.isEditingSecret)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if let message = nameError ?? row.errorMessage {
                inlineError(message)
            }

            if row.isTrailing && row.isSecretDraft {
                Text("Secret values are saved only after encryption succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Divider()
        }
    }

    @ViewBuilder
    private func secretEditingNameCell(for row: VariableEditorRowState) -> some View {
        if row.isTrailing {
            HStack(spacing: 6) {
                nameField(for: row)
                    .frame(minWidth: 0, maxWidth: .infinity)

                Toggle("Secret", isOn: secretBinding(for: row.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 16)
                    .help("Store this variable as a secret")
                    .disabled(!isEditable || row.isBusy)
            }
        } else {
            Text(row.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.name)
        }
    }

    private func nameField(for row: VariableEditorRowState) -> some View {
        HighlightedTextField(
            "Name",
            text: nameBinding(for: row.id),
            focused: focusBinding(for: .name(row.id))
        )
        .font(.system(.body, design: .monospaced))
        .disabled(!isEditable || row.isBusy || (!row.isTrailing && row.isEditingSecret))
    }

    @ViewBuilder
    private func valueCell(for row: VariableEditorRowState, canEditRow: Bool) -> some View {
        if !row.isTrailing,
           let value = variables[row.name],
           case .encrypted = value {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Label("Encrypted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    Button("Reveal") {
                        revealSecret(for: row)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Reveal secret")
                    .disabled(!canEditRow)

                    Button("Replace") {
                        beginSecretEdit(for: row, with: "", revealed: false)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Replace secret")
                    .disabled(!canEditRow)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Encrypted")
                    Spacer(minLength: 4)
                    Button {
                        revealSecret(for: row)
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Reveal secret")
                    .help("Reveal secret")
                    .disabled(!canEditRow)

                    Button {
                        beginSecretEdit(for: row, with: "", revealed: false)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Replace secret")
                    .help("Replace secret")
                    .disabled(!canEditRow)
                }
            }
        } else {
            HighlightedTextField(
                "Value",
                text: valueBinding(for: row.id),
                focused: focusBinding(for: .value(row.id))
            )
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 0, maxWidth: .infinity)
            .disabled(!canEditRow)
        }
    }

    private func nameError(for row: VariableEditorRowState) -> String? {
        if row.isTrailing,
           row.secretSaveInFlightName == row.nameDraft,
           !row.nameDraft.isEmpty,
           TemplateEngine.isValidVariableName(row.nameDraft) {
            return nil
        }
        if row.isTrailing && row.nameDraft.isEmpty && row.valueDraft.isEmpty && !row.isSecretDraft {
            return nil
        }
        return variableNameError(row.nameDraft, excluding: row.isTrailing ? nil : row.name)
    }

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { rowState(for: id)?.nameDraft ?? "" },
            set: { updateName($0, id: id) }
        )
    }

    private func valueBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                guard let row = rowState(for: id) else { return "" }
                if row.isTrailing { return row.valueDraft }
                if row.isEditingSecret { return row.secretDraft }
                guard case let .plain(value) = variables[row.name] else { return "" }
                return value
            },
            set: { value in
                guard let row = rowState(for: id) else { return }
                if row.isTrailing {
                    updateRow(id) {
                        $0.valueDraft = value
                        $0.errorMessage = nil
                    }
                    if !row.isSecretDraft, variableNameError(row.nameDraft) == nil {
                        promoteTrailingPlainVariable(id)
                    }
                    return
                }
                if row.isEditingSecret {
                    updateRow(id) {
                        $0.secretDraft = value
                        $0.errorMessage = nil
                    }
                    return
                }
                updatePlainValue(value, id: id)
            }
        )
    }

    private func secretDraftBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { rowState(for: id)?.secretDraft ?? "" },
            set: { value in
                updateRow(id) {
                    $0.secretDraft = value
                    $0.errorMessage = nil
                }
            }
        )
    }

    private func secretRevealedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { rowState(for: id)?.isSecretRevealed ?? false },
            set: { isRevealed in updateRow(id) { $0.isSecretRevealed = isRevealed } }
        )
    }

    private func secretBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard let row = rowState(for: id) else { return false }
                if row.isTrailing { return row.isSecretDraft }
                return variables[row.name]?.isEncrypted ?? false
            },
            set: { setSecret($0, for: id) }
        )
    }

    private func focusBinding(for field: VariableFieldFocus) -> Binding<Bool> {
        Binding(
            get: { focusedField == field },
            set: { isFocused in
                if isFocused {
                    focusedField = field
                } else if focusedField == field {
                    focusedField = nil
                }
            }
        )
    }

    private func updateName(_ name: String, id: UUID) {
        guard isEditable,
              let row = rowState(for: id),
              !row.isBusy else { return }

        if row.isTrailing {
            if row.secretSaveTargetName != nil && row.secretSaveTargetName != name {
                clearFailedSecretSaveTarget(for: id)
            }
            updateRow(id) {
                $0.nameDraft = name
                $0.errorMessage = nil
            }
            guard !row.isSecretDraft, variableNameError(name) == nil else { return }
            promoteTrailingPlainVariable(id)
            return
        }

        updateRow(id) {
            $0.nameDraft = name
            $0.errorMessage = nil
        }
        guard variableNameError(name, excluding: row.name) == nil, name != row.name else { return }

        do {
            try model.renameVariable(from: row.name, to: name, owner: activeOwner)
            updateRow(id) {
                $0.name = name
                $0.nameDraft = name
                $0.secretDraft = ""
                $0.isEditingSecret = false
                $0.isSecretRevealed = false
                $0.secretSaveTargetName = nil
                $0.secretSaveTargetOwner = nil
            }
            sortRows()
        } catch {
            updateRow(id) { $0.errorMessage = error.localizedDescription }
        }
    }

    private func promoteTrailingPlainVariable(_ id: UUID) {
        guard trailingRow.id == id,
              !trailingRow.isSecretDraft,
              variableNameError(trailingRow.nameDraft) == nil else { return }

        clearFailedSecretSaveTarget(for: id)
        let name = trailingRow.nameDraft
        do {
            try model.setPlainVariable(name: name, value: trailingRow.valueDraft, owner: activeOwner)
            promoteTrailingRow(id: id, name: name)
        } catch {
            updateRow(id) { $0.errorMessage = error.localizedDescription }
        }
    }

    private func updatePlainValue(_ value: String, id: UUID) {
        guard isEditable,
              let row = rowState(for: id),
              !row.isTrailing,
              variableNameError(row.nameDraft, excluding: row.name) == nil,
              row.nameDraft == row.name,
              !row.isBusy,
              !row.isEditingSecret,
              case .plain = variables[row.name] else { return }

        do {
            try model.setPlainVariable(name: row.name, value: value, owner: activeOwner)
            updateRow(id) { $0.errorMessage = nil }
        } catch {
            updateRow(id) { $0.errorMessage = error.localizedDescription }
        }
    }

    private func setSecret(_ isSecret: Bool, for id: UUID) {
        guard isEditable, let row = rowState(for: id), !row.isBusy else { return }
        if row.isTrailing {
            updateRow(id) {
                $0.isSecretDraft = isSecret
                $0.errorMessage = nil
            }
            guard !isSecret, variableNameError(row.nameDraft) == nil else { return }
            promoteTrailingPlainVariable(id)
            return
        }

        guard variableNameError(row.nameDraft, excluding: row.name) == nil,
              row.nameDraft == row.name,
              !row.isEditingSecret,
              let currentValue = variables[row.name],
              currentValue.isEncrypted != isSecret else { return }

        let targetOwner = activeOwner
        let session = activeSession
        updateRow(id) { $0.isBusy = true; $0.errorMessage = nil }

        Task { @MainActor in
            do {
                try await model.setVariableSecret(isSecret, named: row.name, owner: targetOwner)
                guard activeOwner == targetOwner, rowState(for: id) != nil else { return }
                guard isVisible, activeSession == session else {
                    updateRow(id) { $0.isBusy = false; $0.errorMessage = nil }
                    return
                }
                updateRow(id) {
                    $0.isBusy = false
                    $0.errorMessage = nil
                    if !isSecret {
                        $0.secretDraft = ""
                        $0.isEditingSecret = false
                        $0.isSecretRevealed = false
                    }
                }
            } catch {
                guard activeOwner == targetOwner, rowState(for: id) != nil else { return }
                guard isVisible, activeSession == session else {
                    updateRow(id) { $0.isBusy = false; $0.errorMessage = nil }
                    return
                }
                updateRow(id) {
                    $0.isBusy = false
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func revealSecret(for row: VariableEditorRowState) {
        guard isEditable, !row.isBusy, row.nameDraft == row.name else { return }
        let targetOwner = activeOwner
        let session = activeSession
        updateRow(row.id) { $0.isBusy = true; $0.errorMessage = nil }

        Task { @MainActor in
            do {
                let value = try await model.revealVariable(named: row.name, owner: targetOwner)
                guard activeOwner == targetOwner, rowState(for: row.id) != nil else { return }
                guard isVisible, activeSession == session else {
                    updateRow(row.id) { $0.isBusy = false }
                    return
                }
                updateRow(row.id) {
                    $0.secretDraft = value
                    $0.isSecretRevealed = true
                    $0.isEditingSecret = true
                    $0.isBusy = false
                    $0.errorMessage = nil
                }
            } catch {
                guard activeOwner == targetOwner, rowState(for: row.id) != nil else { return }
                guard isVisible, activeSession == session else {
                    updateRow(row.id) { $0.isBusy = false }
                    return
                }
                updateRow(row.id) {
                    $0.isBusy = false
                    $0.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func beginSecretEdit(for row: VariableEditorRowState, with value: String, revealed: Bool) {
        guard isEditable, !row.isBusy, row.nameDraft == row.name else { return }
        updateRow(row.id) {
            $0.secretDraft = value
            $0.isSecretRevealed = revealed
            $0.isEditingSecret = true
            $0.errorMessage = nil
        }
    }

    private func saveSecretEdit(for row: VariableEditorRowState) {
        guard isEditable,
              row.isSecretDraft || row.isEditingSecret,
              !row.isBusy,
              let name = validSaveName(for: row) else { return }

        let value = row.isTrailing ? row.valueDraft : row.secretDraft
        let targetOwner = activeOwner
        let session = activeSession
        let operationID = UUID()
        updateRow(row.id) {
            $0.isBusy = true
            $0.errorMessage = nil
            $0.secretSaveInFlightName = name
            $0.secretSaveTargetName = nil
            $0.secretSaveTargetOwner = nil
            $0.secretSaveTargetOperationID = nil
        }

        Task { @MainActor in
            discardFailedSecretSaveTarget(row)
            do {
                try await model.setVariable(
                    name: name,
                    value: value,
                    isSecret: true,
                    owner: targetOwner,
                    operationID: operationID
                )
                guard activeOwner == targetOwner, rowState(for: row.id) != nil else { return }
                guard isVisible, activeSession == session else {
                    finishInactiveSecretSave(for: row.id, name: name, didSave: true)
                    return
                }
                if row.isTrailing {
                    promoteTrailingRow(id: row.id, name: name)
                } else {
                    updateRow(row.id) {
                        $0.secretDraft = ""
                        $0.isSecretRevealed = false
                        $0.isEditingSecret = false
                        $0.isBusy = false
                        $0.errorMessage = nil
                        $0.secretSaveInFlightName = nil
                        $0.secretSaveTargetName = nil
                        $0.secretSaveTargetOwner = nil
                        $0.secretSaveTargetOperationID = nil
                    }
                }
            } catch {
                guard isVisible,
                      activeSession == session,
                      activeOwner == targetOwner,
                      rowState(for: row.id) != nil else {
                    model.discardVariableSecretEdit(
                        named: name,
                        owner: targetOwner,
                        operationID: operationID
                    )
                    if activeOwner == targetOwner {
                        finishInactiveSecretSave(for: row.id, name: name, didSave: false)
                    }
                    return
                }
                updateRow(row.id) {
                    $0.isBusy = false
                    $0.errorMessage = error.localizedDescription
                    $0.secretSaveInFlightName = nil
                    $0.secretSaveTargetName = name
                    $0.secretSaveTargetOwner = targetOwner
                    $0.secretSaveTargetOperationID = operationID
                }
            }
        }
    }

    private func finishInactiveSecretSave(for id: UUID, name: String, didSave: Bool) {
        guard let row = rowState(for: id) else { return }
        if didSave, row.isTrailing, variables[name] != nil {
            promoteTrailingRow(id: id, name: name)
            return
        }
        updateRow(id) {
            $0.secretDraft = ""
            $0.isSecretRevealed = false
            $0.isEditingSecret = false
            $0.isBusy = false
            $0.errorMessage = nil
            $0.secretSaveInFlightName = nil
            $0.secretSaveTargetName = nil
            $0.secretSaveTargetOwner = nil
            $0.secretSaveTargetOperationID = nil
        }
    }

    private func validSaveName(for row: VariableEditorRowState) -> String? {
        let name = row.isTrailing ? row.nameDraft : row.name
        guard variableNameError(name, excluding: row.isTrailing ? nil : row.name) == nil else { return nil }
        return name
    }

    private func cancelSecretEdit(for row: VariableEditorRowState) {
        if row.isTrailing {
            resetTrailingRow()
            return
        }
        discardFailedSecretSaveTarget(row)
        if row.secretSaveTargetName == nil {
            model.discardVariableSecretEdit(named: row.name, owner: activeOwner)
        }

        updateRow(row.id) {
            $0.secretDraft = ""
            $0.isSecretRevealed = false
            $0.isEditingSecret = false
            $0.errorMessage = nil
            $0.secretSaveTargetName = nil
            $0.secretSaveTargetOwner = nil
            $0.secretSaveTargetOperationID = nil
        }
    }

    private func removeRow(_ row: VariableEditorRowState) {
        guard isEditable, !row.isTrailing, row.nameDraft == row.name, !row.isBusy else { return }
        discardFailedSecretSaveTarget(row)
        model.removeVariable(named: row.name, owner: activeOwner)
        rows.removeAll { $0.id == row.id }
        if focusedField == .name(row.id) || focusedField == .value(row.id) {
            focusedField = nil
        }
    }

    private func promoteTrailingRow(id: UUID, name: String) {
        guard trailingRow.id == id else { return }
        var promoted = trailingRow
        promoted.name = name
        promoted.nameDraft = name
        promoted.isTrailing = false
        promoted.valueDraft = ""
        promoted.secretDraft = ""
        promoted.isSecretDraft = false
        promoted.isEditingSecret = false
        promoted.isSecretRevealed = false
        promoted.isBusy = false
        promoted.errorMessage = nil
        promoted.secretSaveInFlightName = nil
        promoted.secretSaveTargetName = nil
        promoted.secretSaveTargetOwner = nil
        promoted.secretSaveTargetOperationID = nil
        rows.removeAll { $0.name == name }
        rows.append(promoted)
        sortRows()
        resetTrailingRow(keepPromotedFocus: true)
        reconcileRows(with: variables)
    }

    private func resetTrailingRow(keepPromotedFocus: Bool = false) {
        discardFailedSecretSaveTarget(trailingRow)
        let previousID = trailingRow.id
        if !keepPromotedFocus &&
            (focusedField == .name(previousID) || focusedField == .value(previousID)) {
            focusedField = nil
        }
        trailingRow = VariableEditorRowState(name: "", isTrailing: true)
    }

    private func reconcileRows(with variables: VariableValues) {
        let existingRows = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingTrailingName = trailingRow.secretSaveInFlightName

        rows = variables.keys.sorted().compactMap { name in
            guard name != pendingTrailingName else { return nil }
            return existingRows[name] ?? VariableEditorRowState(name: name)
        }
    }

    private func variableNameError(_ name: String, excluding currentName: String? = nil) -> String? {
        guard !name.isEmpty else { return "Enter a variable name." }
        guard TemplateEngine.isValidVariableName(name) else {
            return "Use ASCII letters, digits, and underscores; the first character must be a letter or underscore."
        }
        guard name == currentName || variables[name] == nil else {
            return "A variable with this name already exists."
        }
        return nil
    }

    private func sortRows() {
        rows.sort { $0.name < $1.name }
    }

    private func rowState(for id: UUID) -> VariableEditorRowState? {
        rows.first { $0.id == id } ?? (trailingRow.id == id ? trailingRow : nil)
    }

    private func updateRow(_ id: UUID, update: (inout VariableEditorRowState) -> Void) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            update(&rows[index])
        } else if trailingRow.id == id {
            update(&trailingRow)
        }
    }

    private func changeOwner(to newOwner: VariableOwner) {
        guard activeOwner != newOwner else { return }
        discardFailedSecretEdits()
        rows = []
        trailingRow = VariableEditorRowState(name: "", isTrailing: true)
        focusedField = nil
        activeOwner = newOwner
        reconcileRows(with: model.variables(for: newOwner))
    }

    private func editorDidDisappear() {
        isVisible = false
        activeSession = UUID()
        discardFailedSecretEdits()
        rows = []
        trailingRow = VariableEditorRowState(name: "", isTrailing: true)
        focusedField = nil
    }

    private func editorBecameInactive() {
        guard isVisible else { return }
        isVisible = false
        activeSession = UUID()
        focusedField = nil
        discardFailedSecretEdits()

        for index in rows.indices {
            let row = rows[index]
            if row.isEditingSecret && row.secretSaveInFlightName == nil && row.secretSaveTargetOperationID == nil {
                model.discardVariableSecretEdit(named: row.name, owner: activeOwner)
            }
            rows[index].secretDraft = ""
            rows[index].isEditingSecret = false
            rows[index].isSecretRevealed = false
            rows[index].errorMessage = nil
            rows[index].secretSaveTargetName = nil
            rows[index].secretSaveTargetOwner = nil
            rows[index].secretSaveTargetOperationID = nil
        }

        if trailingRow.isSecretDraft {
            trailingRow.valueDraft = ""
            trailingRow.isSecretDraft = false
        }
        trailingRow.secretDraft = ""
        trailingRow.isEditingSecret = false
        trailingRow.isSecretRevealed = false
        trailingRow.errorMessage = nil
        trailingRow.secretSaveTargetName = nil
        trailingRow.secretSaveTargetOwner = nil
        trailingRow.secretSaveTargetOperationID = nil
    }

    private func discardFailedSecretEdits() {
        for row in tableRows where row.secretSaveInFlightName == nil {
            discardFailedSecretSaveTarget(row)
        }
    }

    private func clearFailedSecretSaveTarget(for id: UUID) {
        guard let row = rowState(for: id), row.secretSaveTargetName != nil else { return }
        discardFailedSecretSaveTarget(row)
        updateRow(id) {
            $0.secretSaveTargetName = nil
            $0.secretSaveTargetOwner = nil
            $0.secretSaveTargetOperationID = nil
        }
    }

    private func discardFailedSecretSaveTarget(_ row: VariableEditorRowState) {
        guard let name = row.secretSaveTargetName,
              let targetOwner = row.secretSaveTargetOwner else { return }
        model.discardVariableSecretEdit(
            named: name,
            owner: targetOwner,
            operationID: row.secretSaveTargetOperationID
        )
    }

    private func inlineError(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 5)
    }
}

private struct VariableEditorRowState: Identifiable {
    let id: UUID
    var name: String
    var nameDraft: String
    var isTrailing: Bool
    var valueDraft = ""
    var isSecretDraft = false
    var secretDraft = ""
    var isEditingSecret = false
    var isSecretRevealed = false
    var isBusy = false
    var errorMessage: String?
    var secretSaveInFlightName: String?
    var secretSaveTargetName: String?
    var secretSaveTargetOwner: VariableOwner?
    var secretSaveTargetOperationID: UUID?

    init(id: UUID = UUID(), name: String, isTrailing: Bool = false) {
        self.id = id
        self.name = name
        nameDraft = name
        self.isTrailing = isTrailing
    }
}

private enum VariableFieldFocus: Hashable {
    case name(UUID)
    case value(UUID)
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
            .frame(minWidth: 0, maxWidth: .infinity)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))

            if isSecret {
                Button(isRevealed ? "Hide" : "Show") {
                    isRevealed.toggle()
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }
}
