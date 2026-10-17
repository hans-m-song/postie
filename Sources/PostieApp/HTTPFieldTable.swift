import SwiftUI
import PostieCore

struct FieldTable: View {
    let title: String
    @Binding var fields: [HTTPField]
    let keyPlaceholder: String
    let valuePlaceholder: String
    let availableVariables: Set<String>
    @State private var trailingField = HTTPField()
    @State private var focusedField: FieldFocus?

    private enum FieldFocus: Hashable {
        case name(UUID)
        case value(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
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

                ForEach(fields + [trailingField]) { field in
                    let isTrailingField = field.id == trailingField.id
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
                            focused: focusBinding(for: .name(field.id))
                        )
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 0, maxWidth: .infinity)
                        Divider().frame(height: 22)
                        HighlightedTextField(
                            valuePlaceholder,
                            text: textBinding(for: field.id, keyPath: \.value),
                            availableVariables: availableVariables,
                            focused: focusBinding(for: .value(field.id))
                        )
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 0, maxWidth: .infinity)
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

            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
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
