import SwiftUI
import PostieCore

struct SessionHistoryResponseBodyView: View {
    @EnvironmentObject private var model: AppModel
    let token: UUID
    let response: HTTPResponseRecord

    @State private var preview: BodyPreview?
    @State private var previewError: String?
    @State private var isLoadingPreview = true
    @State private var syntax: BodySyntax
    @State private var pretty: Bool
    @State private var formatted: String?
    @State private var formatError: String?
    @State private var isFormatting = false

    init(token: UUID, response: HTTPResponseRecord) {
        self.token = token
        self.response = response
        let syntax = Self.syntax(for: response.responseHeaders)
        _syntax = State(initialValue: syntax)
        _pretty = State(initialValue: syntax == .json)
    }

    private var shouldFormatJSON: Bool {
        pretty && syntax == .json && preview?.isBinary == false
    }

    private var syntaxPicker: some View {
        Picker("Response syntax", selection: $syntax) {
            Text("None").tag(BodySyntax.none)
            Text("JSON").tag(BodySyntax.json)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 86)
    }

    private var presentationPicker: some View {
        Picker("Response presentation", selection: $pretty) {
            Text("Raw").tag(false)
            Text("Pretty").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .disabled(syntax != .json || preview?.isBinary != false)
    }

    private var isPrettyJSON: Bool {
        shouldFormatJSON && formatted != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Response body")
                    .font(.headline)
                Spacer()
                Text(response.bodyByteCount.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    syntaxPicker
                    presentationPicker
                }

                VStack(alignment: .leading, spacing: 8) {
                    syntaxPicker
                    presentationPicker
                }
            }

            if isFormatting {
                ProgressView("Formatting JSON…")
                    .controlSize(.small)
            }
            if let formatError {
                Text(formatError)
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
                    Button("Retry") { Task { await loadPreview() } }
                }
            } else if let preview {
                if preview.isBinary {
                    Label("Binary body; text preview is unavailable.", systemImage: "doc.zipper")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    Group {
                        if isPrettyJSON, let formatted {
                            ScrollView(.horizontal) {
                                HighlightedResponseText(
                                    text: displayedText(preview, formatted: formatted),
                                    syntax: syntax,
                                    wrapsToWidth: false
                                )
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(10)
                            }
                        } else {
                            HighlightedResponseText(
                                text: displayedText(preview, formatted: nil),
                                syntax: syntax,
                                wrapsToWidth: true
                            )
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
                    }
                    if preview.isTruncated && formatted == nil {
                        Label(
                            "Preview limited to the first 1 MiB. The retained response body is complete.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: response.runID) { await loadPreview() }
        .task(id: shouldFormatJSON) { await formatJSONIfNeeded() }
        .onChange(of: preview?.isBinary) { _, isBinary in
            if isBinary == true { pretty = false }
        }
    }

    private func loadPreview() async {
        isLoadingPreview = true
        previewError = nil
        do {
            let loaded = try await model.withRetainedResponse(for: token) { retainedResponse, bodyURL in
                guard retainedResponse.runID == response.runID else {
                    throw SessionExecutionStore.InspectionError.unavailable(
                        "The retained response changed before its preview could be loaded."
                    )
                }
                return try await Task.detached(priority: .userInitiated) {
                    try ResponseBodyReader.preview(at: bodyURL, maximumBytes: 1_048_576)
                }.value
            }
            guard !Task.isCancelled else { return }
            preview = loaded
            isLoadingPreview = false
        } catch {
            guard !Task.isCancelled else { return }
            isLoadingPreview = false
            previewError = error.localizedDescription
        }
    }

    private func formatJSONIfNeeded() async {
        formatted = nil
        formatError = nil
        guard shouldFormatJSON else {
            isFormatting = false
            return
        }

        isFormatting = true
        do {
            let value = try await model.withRetainedResponse(for: token) { retainedResponse, bodyURL in
                guard retainedResponse.runID == response.runID else {
                    throw SessionExecutionStore.InspectionError.unavailable(
                        "The retained response changed before JSON formatting could finish."
                    )
                }
                return try await Task.detached(priority: .userInitiated) {
                    try JSONPresentation.pretty(at: bodyURL)
                }.value
            }
            guard !Task.isCancelled else { return }
            formatted = value
            isFormatting = false
        } catch {
            guard !Task.isCancelled else { return }
            formatError = error.localizedDescription
            isFormatting = false
        }
    }

    private static func syntax(for headers: [HTTPField]) -> BodySyntax {
        let contentType = headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let mediaType =
            contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        return mediaType == "application/json" || mediaType.hasSuffix("+json") ? .json : .none
    }

    private func displayedText(_ preview: BodyPreview, formatted: String?) -> String {
        let text = pretty && syntax == .json ? (formatted ?? preview.text) : preview.text
        return text.isEmpty ? "(empty body)" : text
    }
}
