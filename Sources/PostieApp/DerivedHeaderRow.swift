import SwiftUI
import PostieCore

struct DerivedHeaderRow: View {
    let presentation: DerivedHeaderRowPresentation
    let resetKey: String

    @State private var revealedValue: String?
    @State private var revealError: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var revealOperation = UUID()

    private var isRevealed: Bool { revealedValue != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .help(presentation.status)
                .accessibilityLabel(presentation.status)

            VStack(alignment: .leading, spacing: 2) {
                HighlightedTextField(
                    "Derived header name",
                    text: .constant(presentation.name),
                    availableVariables: presentation.availableVariables,
                    isReadOnly: true,
                    truncationMode: .byTruncatingMiddle,
                    wrapping: .unbounded
                )
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .environment(\.isEnabled, true)
                Text(HeaderPresentation.sourceStatusLabel(
                    source: HeaderPresentation.sourceLabel(for: presentation.source),
                    status: presentation.status
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.body, design: .monospaced))

            Divider().frame(height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(revealedValue ?? presentation.maskedValue)
                    .font(.system(.body, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let revealError {
                    Text(revealError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let onReveal = presentation.onReveal {
                    Button(isRevealed ? "Hide" : "Reveal") {
                        isRevealed ? reset() : reveal(using: onReveal)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .environment(\.isEnabled, true)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if let onOpenSource = presentation.onOpenSource {
                Button(action: onOpenSource) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .frame(width: 26)
                .accessibilityLabel("Open \(HeaderPresentation.sourceLabel(for: presentation.source))")
                .help("Open \(HeaderPresentation.sourceLabel(for: presentation.source))")
                .environment(\.isEnabled, true)
                .focusable(false)
            } else {
                Color.clear.frame(width: 26, height: 22)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: resetKey) { _, _ in reset() }
        .onDisappear(perform: reset)
        Divider()
    }

    private var statusSymbol: String {
        switch presentation.status {
        case "Disabled": "minus.circle"
        case "Overridden": "arrow.uturn.backward.circle"
        case "Pending": "hourglass"
        case "Variable dependent": "questionmark.circle"
        default: "checkmark.circle"
        }
    }

    private func reveal(using resolve: @escaping () async throws -> String) {
        reset()
        let operation = UUID()
        revealOperation = operation
        revealTask = Task {
            do {
                let value = try await resolve()
                guard !Task.isCancelled, revealOperation == operation else { return }
                revealedValue = value
            } catch {
                guard !Task.isCancelled, revealOperation == operation else { return }
                revealError = error.localizedDescription
            }
            revealTask = nil
        }
    }

    private func reset() {
        revealOperation = UUID()
        revealTask?.cancel()
        revealTask = nil
        revealedValue = nil
        revealError = nil
    }
}
