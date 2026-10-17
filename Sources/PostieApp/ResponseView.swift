import SwiftUI
import PostieCore

struct ResponseView: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Response")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                if let response = model.response(for: identity) {
                    Text("\(response.response.bodyByteCount.formatted(.byteCount(style: .file))) received")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.canFollowRedirect(identity) {
                        HStack {
                            Spacer(minLength: 0)
                            Button("Follow redirect") {
                                model.followRedirect(identity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.activeRuns[identity] != nil)
                        }
                    }

                    if let active = model.activeRuns[identity] {
                        ActiveResponseStatus(identity: identity, active: active)
                    }

                    if let error = model.runErrors[identity] {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Retry") { model.startRequest(identity) }
                                .buttonStyle(.bordered)
                                .disabled(model.activeRuns[identity] != nil)
                        }
                        .font(.callout)
                        .padding(11)
                        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let latest = model.response(for: identity) {
                        ResponseExchangeView(identity: identity, latest: latest)
                            .id(latest.response.runID)
                    } else if model.cancelledRequests.contains(identity) {
                        ContentUnavailableView(
                            "Request cancelled",
                            systemImage: "xmark.circle",
                            description: Text("The request ended before a response was completed.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else if model.activeRuns[identity] == nil {
                        ContentUnavailableView(
                            "No response yet",
                            systemImage: "arrow.down.left.square",
                            description: Text("Send this request to inspect its response.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .padding(16)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background)
    }
}

private struct ActiveResponseStatus: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    let active: AppModel.ActiveRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(active.phase == .cancelling ? "Cancelling request" : active.runID == nil ? "Preparing request" : "Request in progress")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0)
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f s", model.elapsed(for: identity) ?? 0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelRequest(identity) }
                        .disabled(active.phase == .cancelling)
                }

                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(active.phase == .cancelling ? "Cancelling" : active.runID == nil ? "Preparing" : "Running")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f s", model.elapsed(for: identity) ?? 0))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelRequest(identity) }
                        .disabled(active.phase == .cancelling)
                }
            }

            if let progress = active.progress {
                HStack(spacing: 8) {
                    if let expected = progress.expectedBytes, expected > 0 {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(expected))
                    }
                    Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) received")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(active.redirects) { redirect in
                RedirectDisclosure(redirect: redirect)
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct ResponseExchangeView: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    let latest: AppModel.LatestResponse
    @State private var expandedRedirectIDs: Set<UUID> = []
    @State private var isFinalExpanded = true

    private var response: HTTPResponseRecord { latest.response }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previousResponseMessage = model.previousResponseMessage(for: identity) {
                Label(previousResponseMessage, systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if response.redirectLimitReached {
                Label(
                    "Stopped after 10 redirects. The destination was not reached; the final redirect response is shown below.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            ForEach(response.redirects) { redirect in
                RedirectDisclosure(
                    redirect: redirect,
                    isExpanded: Binding(
                        get: { expandedRedirectIDs.contains(redirect.id) },
                        set: { expanded in
                            if expanded {
                                expandedRedirectIDs.insert(redirect.id)
                            } else {
                                expandedRedirectIDs.remove(redirect.id)
                            }
                        }
                    )
                )
            }

            DisclosureGroup(isExpanded: $isFinalExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup("Request headers (\(response.requestHeaders.count))") {
                        HeaderTable(fields: response.requestHeaders)
                            .padding(.top, 7)
                    }
                    .disclosureGroupStyle(PaddedDisclosureGroupStyle())

                    ExchangeHeaderGroup(title: "Response headers", fields: response.responseHeaders)

                    ResponseBodyPreview(identity: identity, latest: latest)
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(statusColor(response.statusCode))
                        .frame(width: 10, height: 10)
                    Text("\(response.statusCode) \(statusReasonPhrase(response.statusCode))")
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor(response.statusCode))
                    Text("· \(response.effectiveMethod.uppercased()) \(response.finalURL.absoluteString)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f s", response.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .disclosureGroupStyle(PaddedDisclosureGroupStyle())
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .task(id: response.runID) {
            model.loadPreview(for: identity)
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }
}

private struct RedirectDisclosure: View {
    let redirect: HTTPRedirect
    @State private var localExpanded = false
    private var expansion: Binding<Bool>?

    init(redirect: HTTPRedirect, isExpanded: Binding<Bool>? = nil) {
        self.redirect = redirect
        expansion = isExpanded
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $localExpanded) {
            VStack(alignment: .leading, spacing: 13) {
                ExchangeHeaderGroup(title: "Request headers", fields: redirect.requestHeaders)
                ExchangeHeaderGroup(title: "Response headers", fields: redirect.responseHeaders)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("\(redirect.statusCode) \(statusReasonPhrase(redirect.statusCode))")
                    .fontWeight(.medium)
                Text("· \(redirect.method) \(redirect.url.absoluteString) → \(redirect.nextMethod) \(redirect.nextURL.absoluteString)")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(PaddedDisclosureGroupStyle())
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private func statusReasonPhrase(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 204: "No Content"
    case 206: "Partial Content"
    case 300: "Multiple Choices"
    case 301: "Moved Permanently"
    case 302: "Found"
    case 303: "See Other"
    case 304: "Not Modified"
    case 307: "Temporary Redirect"
    case 308: "Permanent Redirect"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 408: "Request Timeout"
    case 409: "Conflict"
    case 410: "Gone"
    case 413: "Content Too Large"
    case 415: "Unsupported Media Type"
    case 416: "Range Not Satisfiable"
    case 422: "Unprocessable Content"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    case 501: "Not Implemented"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    default: "HTTP response"
    }
}

private struct ExchangeHeaderGroup: View {
    let title: String
    let fields: [HTTPField]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            HeaderTable(fields: fields)
                .padding(.top, 7)
        } label: {
            HStack {
                Text("\(title) (\(fields.count))")
                    .font(.headline)
                Spacer(minLength: 0)
            }
        }
        .disclosureGroupStyle(PaddedDisclosureGroupStyle())
    }
}

private struct HeaderTable: View {
    let fields: [HTTPField]

    var body: some View {
        VStack(spacing: 0) {
            if fields.isEmpty {
                Text("No headers exposed by URLSession")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            ForEach(fields) { field in
                HStack(alignment: .top, spacing: 10) {
                    Text(field.name)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 110, alignment: .leading)
                    Text(field.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                if field.id != fields.last?.id {
                    Divider()
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResponseBodyPreview: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    let latest: AppModel.LatestResponse
    @State private var syntax: BodySyntax
    @State private var pretty: Bool
    @State private var formatted: String?
    @State private var formatError: String?
    @State private var isFormatting = false

    init(identity: RequestIdentity, latest: AppModel.LatestResponse) {
        self.identity = identity
        self.latest = latest

        let initialSyntax = Self.syntax(for: latest.response.responseHeaders)
        _syntax = State(initialValue: initialSyntax)
        _pretty = State(initialValue: initialSyntax == .json && latest.preview?.isBinary != true)
    }

    private var shouldFormatJSON: Bool {
        pretty && syntax == .json && latest.preview?.isBinary == false
    }

    private var isPrettyJSON: Bool {
        shouldFormatJSON && formatted != nil
    }

    private func highlightedText(for preview: BodyPreview) -> HighlightedResponseText {
        HighlightedResponseText(
            text: displayedText(preview),
            syntax: syntax,
            wrapsToWidth: !isPrettyJSON
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Body")
                    .font(.headline)
                Spacer()
                Text(latest.response.bodyByteCount.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Response syntax", selection: $syntax) {
                    Text("None").tag(BodySyntax.none)
                    Text("JSON").tag(BodySyntax.json)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)
                Picker("Response presentation", selection: $pretty) {
                    Text("Raw").tag(false)
                    Text("Pretty").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .disabled(syntax != .json || latest.preview?.isBinary != false)
            }
            .fixedSize(horizontal: false, vertical: true)

            if isFormatting { ProgressView("Formatting JSON…").controlSize(.small) }
            if let formatError {
                Text(formatError).font(.caption).foregroundStyle(.secondary)
            }

            if latest.isLoadingPreview {
                ProgressView("Loading bounded preview…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let error = latest.previewError {
                HStack {
                    Text("Preview could not be loaded: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.retryPreview(for: identity) }
                }
            } else if let preview = latest.preview {
                if preview.isBinary {
                    Label("Binary body; text preview is unavailable.", systemImage: "doc.zipper")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    Group {
                        if isPrettyJSON {
                            ScrollView(.horizontal) {
                                highlightedText(for: preview)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .padding(10)
                            }
                        } else {
                            highlightedText(for: preview)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
                    }
                    if preview.isTruncated && !(pretty && formatted != nil) {
                        Label("Preview limited to the first 1 MiB. The saved response file is complete.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Loading bounded preview…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task(id: shouldFormatJSON) {
            formatted = nil
            formatError = nil
            guard shouldFormatJSON else { isFormatting = false; return }
            isFormatting = true
            let url = latest.response.bodyFileURL
            let result = await Task.detached(priority: .userInitiated) {
                Result { try JSONPresentation.pretty(at: url) }
            }.value
            guard !Task.isCancelled else { return }
            isFormatting = false
            switch result {
            case let .success(text): formatted = text
            case let .failure(error): formatError = error.localizedDescription
            }
        }
        .onChange(of: latest.preview?.isBinary) { _, isBinary in
            if isBinary == true { pretty = false }
        }
    }

    private static func syntax(for headers: [HTTPField]) -> BodySyntax {
        let contentType = headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        return mediaType == "application/json" || mediaType.hasSuffix("+json") ? .json : .none
    }

    private func displayedText(_ preview: BodyPreview) -> String {
        let text = pretty && syntax == .json ? (formatted ?? preview.text) : preview.text
        return text.isEmpty ? "(empty body)" : text
    }
}
