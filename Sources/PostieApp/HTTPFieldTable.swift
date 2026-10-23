import AppKit
import SwiftUI
import PostieCore

struct FieldTable: View {
    let title: String
    var showsTitle = true
    @Binding var fields: [HTTPField]
    @Binding var presentation: HTTPFieldDisplayMode
    let keyPlaceholder: String
    let valuePlaceholder: String
    let availableVariables: Set<String>
    var completionVariables: [VariableCompletion] = []
    var inheritedFields: [HTTPField] = []
    var inheritedFieldStatus: (HTTPField) -> String = { _ in "Inherited" }
    var inheritedFieldSourceLabel = "Collection"
    var onOpenInheritedSource: (() -> Void)?
    var derivedRows: [DerivedHeaderRowPresentation] = []
    var derivedRowsResetKey: UUID?
    var parameterWrapping = false
    @State private var trailingField = HTTPField()
    @State private var focusedField: FieldFocus?
    @State private var bulkDraftText = ""
    @State private var bulkBaselineFields: [HTTPField] = []
    @State private var bulkDraftInitialized = false
    @State private var bulkValidationError: String?
    @State private var bulkConflictMessage: String?

    private enum FieldFocus: Hashable {
        case name(UUID)
        case value(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)

                    Spacer(minLength: 0)

                    HTTPFieldDisplayPicker(mode: $presentation)
                }
            }

            VStack(spacing: 0) {
                if presentation == .table {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 26)
                        Text(keyPlaceholder)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Divider().frame(height: 19)
                        Text(valuePlaceholder)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 26)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(.quaternary)
                }

                switch presentation {
                case .table:
                    ForEach(inheritedFields) { field in
                        inheritedRow(field)
                    }
                case .bulk:
                    if !inheritedFields.isEmpty {
                        ReadOnlyBulkFieldText(
                            title: "\(inheritedFieldSourceLabel) headers (read only)",
                            fields: inheritedFields,
                            onOpenSource: onOpenInheritedSource
                        )
                    }
                }

                ForEach(derivedRows) { row in
                    DerivedHeaderRow(presentation: row, resetKey: derivedRowsResetKey?.uuidString ?? row.id)
                }

                switch presentation {
                case .table:
                    ForEach(fields + [trailingField]) { field in
                        editableRow(field, isTrailingField: field.id == trailingField.id)
                    }
                case .bulk:
                    BulkFieldEditor(
                        text: $bulkDraftText,
                        validationError: bulkValidationError,
                        conflictMessage: bulkConflictMessage,
                        onApply: applyBulkDraft,
                        onCancel: cancelBulkDraft,
                        onReload: reloadBulkDraft
                    )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .onAppear {
            guard !bulkDraftInitialized else { return }
            resetBulkDraft(to: fields)
        }
        .onChange(of: fields) { _, updatedFields in
            handleExternalFieldChange(updatedFields)
        }
        .onChange(of: bulkDraftText) { _, _ in
            bulkValidationError = nil
        }
        .onDisappear {
            guard bulkDraftText == HTTPFieldBulkText.encode(bulkBaselineFields) else { return }
            resetBulkDraft(to: fields)
            presentation = .table
        }
    }

    @ViewBuilder
    private func editableRow(_ field: HTTPField, isTrailingField: Bool = false) -> some View {
        HStack(alignment: parameterWrapping ? .top : .center, spacing: 8) {
            if isTrailingField {
                Color.clear.frame(width: 26, height: parameterWrapping ? 22 : nil)
            } else {
                Toggle("Enabled", isOn: enabledBinding(for: field.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 26)
                    .help("Enable this row")
            }
            editableField(
                keyPlaceholder,
                fieldID: field.id,
                keyPath: \.name,
                focus: .name(field.id)
            )
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 22)
            editableField(
                valuePlaceholder,
                fieldID: field.id,
                keyPath: \.value,
                focus: .value(field.id)
            )
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if isTrailingField {
                Color.clear.frame(width: 26, height: parameterWrapping ? 22 : nil)
            } else {
                Button(role: .destructive) {
                    fields.removeAll { $0.id == field.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .frame(width: 26)
                .help("Remove row")
                .focusable(false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        Divider()
    }

    @ViewBuilder
    private func editableField(
        _ placeholder: String,
        fieldID: UUID,
        keyPath: WritableKeyPath<HTTPField, String>,
        focus: FieldFocus
    ) -> some View {
        if parameterWrapping {
            ParameterTextField(
                placeholder,
                text: textBinding(for: fieldID, keyPath: keyPath),
                availableVariables: availableVariables,
                completionVariables: completionVariables,
                focused: focusBinding(for: focus)
            )
        } else {
            HighlightedTextField(
                placeholder,
                text: textBinding(for: fieldID, keyPath: keyPath),
                availableVariables: availableVariables,
                completionVariables: completionVariables,
                focused: focusBinding(for: focus)
            )
        }
    }

    @ViewBuilder
    private func inheritedRow(_ field: HTTPField) -> some View {
        let status = inheritedFieldStatus(field)

        HStack(alignment: parameterWrapping ? .top : .center, spacing: 8) {
            Image(systemName: inheritedStatusSymbol(status))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .help(status)
                .accessibilityLabel(status)
            VStack(alignment: .leading, spacing: 2) {
                ReadOnlyHighlightedText(
                    "Inherited header name",
                    text: field.name,
                    availableVariables: availableVariables,
                    wrapping: parameterWrapping ? .unbounded : .singleLine
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(HeaderPresentation.sourceStatusLabel(source: inheritedFieldSourceLabel, status: status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: NSFont.systemFontSize, design: .monospaced))
            Divider().frame(height: 30)
            ReadOnlyHighlightedText(
                "Inherited header value",
                text: field.value,
                availableVariables: availableVariables,
                wrapping: parameterWrapping ? .unbounded : .singleLine
            )
            .font(.system(size: NSFont.systemFontSize, design: .monospaced))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let onOpenInheritedSource {
                Button(action: onOpenInheritedSource) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .frame(width: 26)
                .accessibilityLabel("Open collection headers")
                .help("Open collection headers")
                .environment(\.isEnabled, true)
                .focusable(false)
            } else {
                Color.clear.frame(width: 26, height: parameterWrapping ? 22 : nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .font(.system(.body, design: .monospaced))
        Divider()
    }

    private func inheritedStatusSymbol(_ status: String) -> String {
        switch status {
        case "Disabled": "minus.circle"
        case "Overridden": "arrow.uturn.backward.circle"
        case "Suppressed": "eye.slash"
        case "Variable dependent": "questionmark.circle"
        case "Inactive": "circle.dashed"
        default: "checkmark.circle"
        }
    }

    private func textBinding(
        for id: UUID,
        keyPath: WritableKeyPath<HTTPField, String>
    ) -> Binding<String> {
        Binding(
            get: { field(for: id)?[keyPath: keyPath] ?? "" },
            set: { value in
                updateField(id) { $0[keyPath: keyPath] = value }
                guard trailingField.id == id,
                    !trailingField.name.isEmpty || !trailingField.value.isEmpty
                else { return }
                fields.append(trailingField)
                trailingField = HTTPField()
            }
        )
    }

    private func enabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { field(for: id)?.isEnabled ?? true },
            set: { isEnabled in updateField(id) { $0.isEnabled = isEnabled } }
        )
    }

    private func field(for id: UUID) -> HTTPField? {
        fields.first { $0.id == id } ?? (trailingField.id == id ? trailingField : nil)
    }

    private func updateField(_ id: UUID, update: (inout HTTPField) -> Void) {
        if let index = fields.firstIndex(where: { $0.id == id }) {
            update(&fields[index])
        } else if trailingField.id == id {
            update(&trailingField)
        }
    }

    private func focusBinding(for field: FieldFocus) -> Binding<Bool> {
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

    private func handleExternalFieldChange(_ updatedFields: [HTTPField]) {
        guard bulkDraftInitialized else { return }
        if updatedFields == bulkBaselineFields {
            bulkConflictMessage = nil
            return
        }
        guard bulkDraftText == HTTPFieldBulkText.encode(bulkBaselineFields) else {
            bulkConflictMessage = "Fields changed elsewhere. Your draft is preserved, but Apply is paused."
            return
        }

        resetBulkDraft(to: updatedFields)
    }

    private func resetBulkDraft(to updatedFields: [HTTPField]) {
        bulkBaselineFields = updatedFields
        bulkDraftText = HTTPFieldBulkText.encode(updatedFields)
        bulkDraftInitialized = true
        bulkValidationError = nil
        bulkConflictMessage = nil
    }

    private func applyBulkDraft() {
        guard bulkConflictMessage == nil else { return }
        guard fields == bulkBaselineFields else {
            bulkConflictMessage = "Fields changed elsewhere. Your draft is preserved, but Apply is paused."
            return
        }

        do {
            let decodedFields = try HTTPFieldBulkText.decode(bulkDraftText)
            fields = HTTPFieldBulkText.reconcile(decodedFields, against: bulkBaselineFields)
            resetBulkDraft(to: fields)
            presentation = .table
        } catch let error as LocalizedError {
            bulkValidationError = error.errorDescription ?? "The bulk field text is invalid."
        } catch {
            bulkValidationError = "The bulk field text is invalid."
        }
    }

    private func cancelBulkDraft() {
        resetBulkDraft(to: fields)
        presentation = .table
    }

    private func reloadBulkDraft() {
        resetBulkDraft(to: fields)
    }
}

private struct ReadOnlyBulkFieldText: View {
    let title: String
    let fields: [HTTPField]
    let onOpenSource: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if let onOpenSource {
                    Button("Open collection headers", action: onOpenSource)
                        .buttonStyle(.borderless)
                }
            }

            Text(HTTPFieldBulkText.encode(fields))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .padding(8)
    }
}

private struct ReadOnlyHighlightedText: View {
    let accessibilityLabel: String
    let text: String
    let availableVariables: Set<String>
    let wrapping: HighlightedTextFieldWrapping

    init(
        _ accessibilityLabel: String,
        text: String,
        availableVariables: Set<String>,
        wrapping: HighlightedTextFieldWrapping = .singleLine
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.text = text
        self.availableVariables = availableVariables
        self.wrapping = wrapping
    }

    var body: some View {
        HighlightedTextField(
            accessibilityLabel,
            text: .constant(text),
            availableVariables: availableVariables,
            isReadOnly: true,
            truncationMode: .byTruncatingMiddle,
            wrapping: wrapping
        )
        .environment(\.isEnabled, true)
    }
}
