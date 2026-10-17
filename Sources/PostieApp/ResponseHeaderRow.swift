import AppKit
import PostieCore
import SwiftUI

struct ResponseHeaderRow: View {
    let field: HTTPField
    let isSensitive: Bool
    let isNameSecret: Bool
    @State private var isRevealed = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(isNameSecret && !isRevealed ? "Secret header" : field.name)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if (isSensitive || isNameSecret) && !isRevealed {
                    Text("••••••••")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Sensitive header value hidden")
                } else {
                    Text(field.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isSensitive || isNameSecret {
                    HStack(spacing: 10) {
                        Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(field.value, forType: .string)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: field) { _, _ in reset() }
        .onChange(of: isSensitive) { _, _ in reset() }
        .onChange(of: isNameSecret) { _, _ in reset() }
        .onDisappear(perform: reset)
    }

    private func reset() {
        isRevealed = false
        copied = false
    }
}
