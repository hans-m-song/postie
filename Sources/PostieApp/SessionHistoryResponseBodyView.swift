import SwiftUI
import PostieCore

struct SessionHistoryResponseBodyView: View {
    @EnvironmentObject private var model: AppModel
    let token: UUID
    let response: HTTPResponseRecord

    @State private var preview: BodyPreview?
    @State private var previewError: String?
    @State private var isLoadingPreview = true

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

            ResponseBodyPresentation(
                source: .history(token, response),
                preview: preview,
                previewError: previewError,
                isLoadingPreview: isLoadingPreview,
                truncationMessage: "Preview limited to the first 1 MiB. The retained response body is complete.",
                onRetry: { Task { await loadPreview() } },
                withBodyURL: { operation in
                    try await model.withRetainedResponse(for: token) { retainedResponse, bodyURL in
                        guard retainedResponse.runID == response.runID else {
                            throw SessionExecutionStore.InspectionError.unavailable(
                                "The retained response changed before body formatting could finish."
                            )
                        }
                        return try await operation(bodyURL)
                    }
                }
            )
        }
        .task(id: response.runID) { await loadPreview() }
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
}
