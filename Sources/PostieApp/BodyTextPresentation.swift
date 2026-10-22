import PostieCore
import SwiftUI

struct BodyPresentationBodyID: Hashable, Sendable {
    let runID: UUID
    let url: URL
}

struct BodyPresentationIdentity: Hashable, Sendable {
    let bodyID: BodyPresentationBodyID
    let syntax: BodySyntax
    let isEligible: Bool

    init(
        bodyID: BodyPresentationBodyID,
        syntax: BodySyntax,
        isPrettySelected: Bool,
        isBinary: Bool?
    ) {
        self.bodyID = bodyID
        self.syntax = syntax
        isEligible = isPrettySelected && syntax != .none && isBinary == false
    }
}

enum BodyPresentationPolicy {
    static func defaultsToPretty(for syntax: BodySyntax) -> Bool {
        syntax != .none
    }

    static func label(for syntax: BodySyntax) -> String {
        switch syntax {
        case .none: "None"
        case .json: "JSON"
        case .html: "HTML"
        case .xml: "XML"
        }
    }
}

struct BodySyntaxPicker: View {
    @Binding var selection: BodySyntax
    let title: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(BodySyntax.allCases, id: \.self) { syntax in
                Text(BodyPresentationPolicy.label(for: syntax)).tag(syntax)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

typealias BodyPresentationURLOperation = @Sendable (URL) async throws -> String
typealias BodyPresentationURLAccess = @MainActor (BodyPresentationURLOperation) async throws -> String

@MainActor
struct BodyTextPresentationView: View {
    let bodyID: BodyPresentationBodyID
    let responseHeaders: [HTTPField]
    let preview: BodyPreview?
    let previewError: String?
    let isLoadingPreview: Bool
    let truncationMessage: String
    let onRetry: (() -> Void)?
    let withBodyURL: BodyPresentationURLAccess

    @State private var syntax: BodySyntax
    @State private var pretty: Bool
    @State private var wrapsText = true
    @State private var formatted: String?
    @State private var formatError: String?
    @State private var isFormatting = false
    @State private var activeIdentity: BodyPresentationIdentity?

    init(
        bodyID: BodyPresentationBodyID,
        responseHeaders: [HTTPField],
        preview: BodyPreview?,
        previewError: String?,
        isLoadingPreview: Bool,
        truncationMessage: String,
        onRetry: (() -> Void)? = nil,
        withBodyURL: @escaping BodyPresentationURLAccess
    ) {
        self.bodyID = bodyID
        self.responseHeaders = responseHeaders
        self.preview = preview
        self.previewError = previewError
        self.isLoadingPreview = isLoadingPreview
        self.truncationMessage = truncationMessage
        self.onRetry = onRetry
        self.withBodyURL = withBodyURL

        let detectedSyntax = BodyMediaType.syntax(for: responseHeaders)
        _syntax = State(initialValue: detectedSyntax)
        _pretty = State(initialValue: BodyPresentationPolicy.defaultsToPretty(for: detectedSyntax))
    }

    private var detectedSyntax: BodySyntax {
        BodyMediaType.syntax(for: responseHeaders)
    }

    private var identity: BodyPresentationIdentity {
        BodyPresentationIdentity(
            bodyID: bodyID,
            syntax: syntax,
            isPrettySelected: pretty,
            isBinary: preview?.isBinary
        )
    }

    private var canSelectPretty: Bool {
        syntax != .none && preview?.isBinary == false
    }

    private var showsPrettyText: Bool {
        identity.isEligible && formatted != nil
    }

    private var hasTextPreview: Bool {
        !isLoadingPreview && previewError == nil && preview?.isBinary == false
    }

    private var syntaxSelection: Binding<BodySyntax> {
        Binding(
            get: { syntax },
            set: { selected in
                guard syntax != selected else { return }
                syntax = selected
                pretty = BodyPresentationPolicy.defaultsToPretty(for: selected)
            }
        )
    }

    private var syntaxPicker: some View {
        BodySyntaxPicker(selection: syntaxSelection, title: "Response syntax")
            .frame(width: 90)
    }

    private var presentationPicker: some View {
        Picker("Response presentation", selection: $pretty) {
            Text("Raw").tag(false)
            Text("Pretty").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .disabled(!canSelectPretty)
    }

    private var presentationSelectors: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                syntaxPicker
                presentationPicker
                if hasTextPreview {
                    wrapTextControl
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    syntaxPicker
                    presentationPicker
                }
                if hasTextPreview {
                    wrapTextControl
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                syntaxPicker
                presentationPicker
                if hasTextPreview {
                    wrapTextControl
                }
            }
        }
    }

    private var wrapTextControl: some View {
        Toggle("Wrap text", isOn: $wrapsText)
            .toggleStyle(.checkbox)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            presentationSelectors

            if isFormatting {
                ProgressView("Formatting \(BodyPresentationPolicy.label(for: syntax))…")
                    .controlSize(.small)
            }

            if let formatError {
                Text(formatError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if syntax == .none && detectedSyntax == .none {
                Label("No supported syntax detected; showing the bounded raw preview.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isLoadingPreview {
                ProgressView("Loading bounded preview…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let previewError {
                HStack {
                    Text("Preview could not be loaded: \(previewError)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let onRetry {
                        Button("Retry", action: onRetry)
                    }
                }
            } else if let preview {
                if preview.isBinary {
                    Label("Binary body; text preview is unavailable.", systemImage: "doc.zipper")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    Group {
                        if showsPrettyText, let formatted {
                            BodySourceTextDisplay(text: formatted, syntax: syntax, wrapsText: wrapsText)
                        } else {
                            BodySourceTextDisplay(text: preview.text, syntax: syntax, wrapsText: wrapsText)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
                    }

                    if preview.isTruncated && !showsPrettyText {
                        Label(truncationMessage, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Loading bounded preview…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: identity) {
            await formatIfNeeded(for: identity)
        }
        .onChange(of: bodyID) { _, _ in
            resetForDetectedSyntax()
        }
        .onChange(of: detectedSyntax) { _, _ in
            resetForDetectedSyntax()
        }
        .onChange(of: preview?.isBinary) { _, isBinary in
            if isBinary == true { pretty = false }
        }
    }

    private func resetForDetectedSyntax() {
        syntax = detectedSyntax
        pretty = BodyPresentationPolicy.defaultsToPretty(for: detectedSyntax)
        formatted = nil
        formatError = nil
        isFormatting = false
    }

    private func formatIfNeeded(for identity: BodyPresentationIdentity) async {
        activeIdentity = identity
        formatted = nil
        formatError = nil
        isFormatting = false
        guard identity.isEligible else { return }

        isFormatting = true
        let operation: BodyPresentationURLOperation = { url in
            let formatter = Task.detached(priority: .userInitiated) {
                try BodyTextFormatting.pretty(at: url, syntax: identity.syntax)
            }
            return try await withTaskCancellationHandler {
                try await formatter.value
            } onCancel: {
                formatter.cancel()
            }
        }

        do {
            let result = try await withBodyURL(operation)
            guard !Task.isCancelled, activeIdentity == identity else { return }
            formatted = result
            isFormatting = false
        } catch {
            guard !Task.isCancelled, activeIdentity == identity else { return }
            formatError = error.localizedDescription
            isFormatting = false
        }
    }
}

enum BodyTextFormatting {
    static func pretty(at url: URL, syntax: BodySyntax) throws -> String {
        switch syntax {
        case .none:
            throw UnsupportedSyntaxError()
        case .json:
            try JSONPresentation.pretty(at: url)
        case .html, .xml:
            try MarkupPresentation.pretty(at: url, syntax: syntax)
        }
    }

    private struct UnsupportedSyntaxError: LocalizedError {
        var errorDescription: String? {
            "Pretty view is unavailable for this syntax. Raw remains available."
        }
    }
}
