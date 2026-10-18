import AppKit
import SwiftUI
import PostieCore

struct FieldTable: View {
    let title: String
    var showsTitle = true
    @Binding var fields: [HTTPField]
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
    @State private var trailingField = HTTPField()
    @State private var focusedField: FieldFocus?

    private enum FieldFocus: Hashable {
        case name(UUID)
        case value(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsTitle {
                Text(title)
                    .font(.headline)
            }

            VStack(spacing: 0) {
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

                ForEach(inheritedFields) { field in
                    inheritedRow(field)
                }

                ForEach(derivedRows) { row in
                    DerivedHeaderRow(presentation: row, resetKey: derivedRowsResetKey?.uuidString ?? row.id)
                }

                ForEach(fields + [trailingField]) { field in
                    editableRow(field, isTrailingField: field.id == trailingField.id)
                }

            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private func editableRow(_ field: HTTPField, isTrailingField: Bool = false) -> some View {
        HStack(spacing: 8) {
            if isTrailingField {
                Color.clear.frame(width: 26)
            } else {
                Toggle("Enabled", isOn: enabledBinding(for: field.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 26)
                    .help("Enable this row")
            }
            HighlightedTextField(
                keyPlaceholder,
                text: textBinding(for: field.id, keyPath: \.name),
                availableVariables: availableVariables,
                completionVariables: completionVariables,
                focused: focusBinding(for: .name(field.id))
            )
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 22)
            HighlightedTextField(
                valuePlaceholder,
                text: textBinding(for: field.id, keyPath: \.value),
                availableVariables: availableVariables,
                completionVariables: completionVariables,
                focused: focusBinding(for: .value(field.id))
            )
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if isTrailingField {
                Color.clear.frame(width: 26)
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
    private func inheritedRow(_ field: HTTPField) -> some View {
        let status = inheritedFieldStatus(field)

        HStack(spacing: 8) {
            Image(systemName: inheritedStatusSymbol(status))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .help(status)
                .accessibilityLabel(status)
            VStack(alignment: .leading, spacing: 2) {
                ReadOnlyHighlightedText(
                    "Inherited header name",
                    text: field.name,
                    availableVariables: availableVariables
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
                availableVariables: availableVariables
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
                Color.clear.frame(width: 26)
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
                      !trailingField.name.isEmpty || !trailingField.value.isEmpty else { return }
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
}

private struct ReadOnlyHighlightedText: View {
    let accessibilityLabel: String
    let text: String
    let availableVariables: Set<String>

    init(_ accessibilityLabel: String, text: String, availableVariables: Set<String>) {
        self.accessibilityLabel = accessibilityLabel
        self.text = text
        self.availableVariables = availableVariables
    }

    var body: some View {
        HighlightedTextField(
            accessibilityLabel,
            text: .constant(text),
            availableVariables: availableVariables,
            isReadOnly: true,
            truncationMode: .byTruncatingMiddle
        )
        .environment(\.isEnabled, true)
    }
}
