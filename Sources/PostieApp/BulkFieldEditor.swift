import SwiftUI
import PostieCore

struct BulkFieldEditor: View {
    @Binding var text: String
    let validationError: String?
    let conflictMessage: String?
    let onApply: () -> Void
    let onCancel: () -> Void
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("One name: value per line. Start disabled rows with # followed by a space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Bulk field escaping")
                    .help("Backslash escapes \\\\, \\: in names, \\n, \\r, \\t, edge whitespace, and leading #.")
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180, maxHeight: 320)
                .accessibilityLabel("Bulk field text")
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary, lineWidth: 1)
                }

            if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if conflictMessage != nil {
                    Button("Discard draft and reload", action: onReload)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .disabled(conflictMessage != nil)
            }
        }
        .padding(8)
    }
}
