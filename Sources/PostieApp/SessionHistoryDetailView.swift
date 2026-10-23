import AppKit
import SwiftUI
import PostieCore

struct SessionHistoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    let entry: SessionExecutionStore.Entry

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                requestPane
                    .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity)
                responsePane
                    .frame(minWidth: 210, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(entry.method.uppercased())  \(entry.url)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("Started \(entry.startedAt.formatted(date: .long, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Text(entry.phase.historyLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(entry.phase.historyColor)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if entry.phase.isActive {
                    Button(role: .destructive) {
                        model.cancelHistoryRun(token: entry.token)
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(entry.phase == .cancelling || model.isTerminating)
                }

                Button {
                    model.openHistorySource(token: entry.token)
                } label: {
                    Label("Open Request", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .disabled(!canOpenRequest || model.isTerminating)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .textSelection(.enabled)
    }

    private var requestPane: some View {
        VStack(spacing: 0) {
            historyPaneHeader("Request", symbol: "arrow.up.right.square")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let capture {
                        templateSection(capture)
                        submittedSection(capture)
                        capturedInputsSection(capture)
                        authenticationSection(capture.authentication)
                    } else if let request {
                        requestConfigurationSection(request)
                    } else {
                        ContentUnavailableView(
                            "Request details unavailable",
                            systemImage: "doc.questionmark",
                            description: Text(
                                entry.detailsUnavailableReason ?? "No request capture was retained for this run.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }

                    if let detailsUnavailableReason = entry.detailsUnavailableReason {
                        SessionHistoryNotice(
                            title: "Some captured details are unavailable",
                            message: detailsUnavailableReason,
                            symbol: "info.circle"
                        )
                    }
                }
                .padding(14)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .background(.background)
    }

    private var responsePane: some View {
        VStack(spacing: 0) {
            historyPaneHeader("Response", symbol: "arrow.down.left")
            Divider()
            if let response = entry.response {
                ResponseBodyViewportScrollView(contentPadding: 14, previewBottomInset: 12) {
                    VStack(alignment: .leading, spacing: 14) {
                        responseSummary(response)

                        if response.redirectLimitReached {
                            SessionHistoryNotice(
                                title: "Redirect limit reached",
                                message: "Stopped after 10 redirects. The final redirect response is shown below.",
                                symbol: "arrow.triangle.2.circlepath"
                            )
                        }

                        ForEach(response.redirects) { redirect in
                            SessionHistoryRedirectDisclosure(redirect: redirect)
                        }

                        SessionHistoryInformationSection(title: "Final response") {
                            SessionHistoryValueLine(label: "Method", value: response.effectiveMethod.uppercased())
                            SessionHistoryValueLine(label: "URL", value: response.finalURL.absoluteString)
                            SessionHistoryHeaderList(
                                title: "Request headers",
                                fields: response.requestHeaders,
                                sensitiveNames: response.sensitiveRequestHeaderNames,
                                secretNames: response.secretRequestHeaderNames,
                                sources: response.requestHeaderSources
                            )
                            SessionHistoryHeaderList(
                                title: "Response headers",
                                fields: response.responseHeaders
                            )
                            SessionHistoryResponseBodyView(token: entry.token, response: response)
                                .id(response.runID)
                        }
                    }
                    .textSelection(.enabled)
                }
            } else {
                responseUnavailable
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private func templateSection(_ capture: SnapshotPreparationCapture) -> some View {
        let sensitivity = CapturedHeaderSensitivity.resolve(
            fields: capture.template.headers, inputs: capture.referencedInputs,
            sensitiveNames: capture.submitted.sensitiveNames, secretNames: capture.submitted.secretNames)
        return SessionHistoryInformationSection(title: "Request template") {
            SessionHistoryValueLine(label: "Method", value: capture.template.method)
            SessionHistoryValueLine(label: "URL template", value: capture.template.url)
            SessionHistoryFieldList(title: "Path parameters", fields: capture.template.pathParameters)
            SessionHistoryFieldList(
                title: "Query parameters", fields: capture.template.query, supportsBulkView: true)
            SessionHistoryHeaderList(
                title: "Header templates",
                fields: capture.template.headers,
                sensitiveNames: sensitivity.sensitiveNames,
                secretNames: sensitivity.secretNames,
                sources: capture.submitted.headerSources
            )
            if let upload = capture.template.uploadBody {
                UploadMetadataView(upload: upload)
            } else if capture.template.bodyEnabled {
                SessionHistoryValueLine(label: "Body syntax", value: capture.template.bodySyntax.rawValue.uppercased())
                SessionHistoryLongValue(label: "Body template", value: capture.template.body)
            } else {
                SessionHistoryValueLine(label: "Body", value: "Disabled")
            }
            SessionHistoryValueLine(
                label: "Follow redirects",
                value: capture.template.options.followRedirects ? "On" : "Off"
            )
        }
    }

    private func submittedSection(_ capture: SnapshotPreparationCapture) -> some View {
        SessionHistoryInformationSection(title: "Submitted request") {
            SessionHistoryValueLine(label: "Method", value: capture.submitted.method)
            SessionHistoryValueLine(label: "URL", value: capture.submitted.url.absoluteString)
            if let upload = capture.submitted.uploadBody {
                UploadMetadataView(upload: upload)
            } else if let body = capture.submitted.body {
                SessionHistoryLongValue(label: "Submitted body", value: body)
            } else {
                SessionHistoryValueLine(label: "Body", value: "No request body")
            }
            SessionHistoryHeaderList(
                title: "Submitted headers",
                fields: capture.submitted.headers,
                sensitiveNames: capture.submitted.sensitiveNames,
                secretNames: capture.submitted.secretNames,
                sources: capture.submitted.headerSources
            )
        }
    }

    @ViewBuilder
    private func capturedInputsSection(_ capture: SnapshotPreparationCapture) -> some View {
        if !capture.referencedInputs.isEmpty {
            SessionHistoryInformationSection(title: "Captured inputs") {
                ForEach(capture.referencedInputs.keys.sorted(), id: \.self) { name in
                    if let input = capture.referencedInputs[name] {
                        SessionHistoryInputRow(name: name, input: input)
                    }
                }
            }
        }
    }

    private func authenticationSection(_ authentication: SnapshotAuthenticationInput) -> some View {
        SessionHistoryInformationSection(title: "Captured authentication") {
            SessionHistoryValueLine(label: "Kind", value: authentication.kind.rawValue.capitalized)
            if !authentication.username.isEmpty {
                SessionHistoryValueLine(label: "Username", value: authentication.username)
            }
            if let apiKeyHeaderName = authentication.apiKeyHeaderName {
                SessionHistoryValueLine(label: "API key header", value: apiKeyHeaderName)
            }
            if let resolvedSecret = authentication.resolvedSecret {
                SessionHistorySensitiveValue(label: "Resolved credential", value: resolvedSecret)
            }
        }
    }

    private func requestConfigurationSection(_ request: HTTPRequestConfiguration) -> some View {
        let sensitivity = CapturedHeaderSensitivity.resolve(
            fields: request.headers, inputs: nil,
            sensitiveNames: entry.response?.sensitiveRequestHeaderNames ?? [],
            secretNames: entry.response?.secretRequestHeaderNames ?? [])
        return SessionHistoryInformationSection(title: "Request configuration") {
            SessionHistoryValueLine(label: "Method", value: request.method)
            SessionHistoryValueLine(label: "URL template", value: request.url)
            SessionHistoryFieldList(title: "Path parameters", fields: request.pathParameters)
            SessionHistoryFieldList(title: "Query parameters", fields: request.query, supportsBulkView: true)
            SessionHistoryHeaderList(
                title: "Headers",
                fields: request.headers,
                sensitiveNames: sensitivity.sensitiveNames,
                secretNames: sensitivity.secretNames,
                sources: entry.response?.requestHeaderSources ?? [:]
            )
            if request.bodyEnabled && request.bodyKind != .text {
                SessionHistoryValueLine(label: "Body type", value: request.bodyKind.rawValue)
                Text("Upload files remain at their original locations; no upload bytes are retained in history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if request.bodyEnabled {
                SessionHistoryValueLine(label: "Body syntax", value: request.bodySyntax.rawValue.uppercased())
                SessionHistoryLongValue(label: "Body template", value: request.body)
            } else {
                SessionHistoryValueLine(label: "Body", value: "Disabled")
            }
            SessionHistoryValueLine(
                label: "Authentication",
                value: request.authentication.kind.rawValue.capitalized
            )
            if request.authentication.password != nil
                || request.authentication.token != nil
                || request.authentication.apiKey != nil
            {
                SessionHistoryValueLine(label: "Credential", value: "Stored credential value unavailable")
            }
        }
    }

    private func responseSummary(_ response: HTTPResponseRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor(response.statusCode))
                .frame(width: 10, height: 10)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "\(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)"
                )
                .fontWeight(.semibold)
                .foregroundStyle(statusColor(response.statusCode))
                Text(
                    "\(response.bodyByteCount.formatted(.byteCount(style: .file))) received · \(String(format: "%.1f s", response.duration))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text(response.completedAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var responseUnavailable: some View {
        if let detailsUnavailableReason = entry.detailsUnavailableReason {
            ContentUnavailableView(
                "Response details unavailable",
                systemImage: "doc.questionmark",
                description: Text(detailsUnavailableReason)
            )
        } else if let errorMessage = entry.errorMessage {
            ContentUnavailableView(
                "Request failed",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if entry.phase.isActive {
            VStack(spacing: 12) {
                ProgressView()
                Text(activityMessage)
                    .foregroundStyle(.secondary)
                if let progress = entry.progress {
                    if let expectedBytes = progress.expectedBytes, expectedBytes > 0 {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(expectedBytes))
                    }
                    Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) received")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(20)
        } else {
            ContentUnavailableView(
                entry.phase == .cancelled ? "Request cancelled" : "Response unavailable",
                systemImage: entry.phase == .cancelled ? "stop.circle" : "doc.questionmark",
                description: Text("No response details were captured for this run.")
            )
        }
    }

    private var title: String {
        guard let source = entry.source else { return entry.requestName }
        return "\(source.collectionName) › \(source.requestName)"
    }

    private var request: HTTPRequestConfiguration? {
        entry.request ?? entry.response?.request
    }

    private var capture: SnapshotPreparationCapture? {
        entry.capture ?? entry.response?.snapshotCapture
    }

    private var canOpenRequest: Bool {
        guard let identity = entry.liveSourceIdentity else { return false }
        return model.request(for: identity) != nil
    }

    private var activityMessage: String {
        switch entry.phase {
        case .preparing: "Preparing request…"
        case .running: "Waiting for response…"
        case .cancelling: "Cancelling request…"
        case .completed, .failed, .cancelled: "No response details were captured for this run."
        }
    }
}

private struct SessionHistoryRedirectDisclosure: View {
    let redirect: HTTPRedirect
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                SessionHistoryHeaderList(
                    title: "Request headers",
                    fields: redirect.requestHeaders,
                    sensitiveNames: redirect.sensitiveRequestHeaderNames,
                    secretNames: redirect.secretRequestHeaderNames,
                    sources: redirect.requestHeaderSources
                )
                SessionHistoryHeaderList(title: "Response headers", fields: redirect.responseHeaders)
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "\(redirect.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: redirect.statusCode).capitalized)"
                )
                .fontWeight(.medium)
                Text(
                    "\(redirect.method) \(redirect.url.absoluteString) → \(redirect.nextMethod) \(redirect.nextURL.absoluteString)"
                )
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(PaddedDisclosureGroupStyle())
    }
}

private struct SessionHistoryInformationSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .textSelection(.enabled)
    }
}

private struct SessionHistoryValueLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value.isEmpty ? "(empty)" : value)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

private struct SessionHistoryLongValue: View {
    let label: String
    let value: String

    var body: some View {
        let preview = SessionHistoryTextPreview(value)

        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(preview.text.isEmpty ? "(empty body)" : preview.text)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .textSelection(.enabled)
            if preview.isTruncated {
                Label(
                    "Preview limited to the first 1 MiB. Only the preview is truncated; the retained capture is unchanged.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SessionHistoryTextPreview {
    private static let maximumBytes = 1_048_576

    let text: String
    let isTruncated: Bool

    init(_ value: String) {
        let prefix = value.utf8.prefix(Self.maximumBytes + 1)
        isTruncated = prefix.count > Self.maximumBytes
        text = String(decoding: prefix.prefix(Self.maximumBytes), as: UTF8.self)
    }
}

private struct SessionHistoryFieldList: View {
    let title: String
    let fields: [HTTPField]
    var supportsBulkView = false
    @State private var displayMode: HTTPFieldDisplayMode = .table

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if supportsBulkView && !fields.isEmpty {
                HStack {
                    titleLabel
                    Spacer(minLength: 8)
                    HTTPFieldDisplayPicker(mode: $displayMode)
                }
                .padding(.bottom, 5)
            } else {
                titleLabel.padding(.bottom, 5)
            }
            if fields.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if supportsBulkView {
                ReadOnlyHTTPFieldsView(fields: fields, mode: $displayMode) { _, _ in fieldRows }
            } else {
                fieldRows
            }
        }
    }

    private var titleLabel: some View {
        Text("\(title) (\(fields.count))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var fieldRows: some View {
        ForEach(fields) { field in
            HStack(alignment: .top, spacing: 8) {
                Text(field.name.isEmpty ? "(empty name)" : field.name)
                    .frame(width: 112, alignment: .leading)
                Text(field.value.isEmpty ? "(empty)" : field.value)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !field.isEnabled {
                    Text("Disabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 5)
            if field.id != fields.last?.id { Divider() }
        }
    }
}

private struct SessionHistoryHeaderList: View {
    let title: String
    let fields: [HTTPField]
    var sensitiveNames: Set<String> = []
    var secretNames: Set<String> = []
    var sources: [String: HTTPHeaderSource] = [:]
    @State private var displayMode: HTTPFieldDisplayMode = .table

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if fields.isEmpty {
                titleLabel.padding(.bottom, 5)
            } else {
                HStack {
                    titleLabel
                    Spacer(minLength: 8)
                    HTTPFieldDisplayPicker(mode: $displayMode)
                }
                .padding(.bottom, 5)
            }
            if fields.isEmpty {
                Text("No headers recorded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ReadOnlyHTTPFieldsView(
                    fields: fields,
                    mode: $displayMode,
                    sensitiveNames: sensitiveNames,
                    secretNames: secretNames,
                    sources: sources,
                    masksStandardHeaderNames: true,
                    hidesSecretFieldNames: true,
                    sensitiveItemTitle: "headers"
                ) { effectiveSensitiveNames, normalizedSecretNames in
                    ForEach(fields) { field in
                        ResponseHeaderRow(
                            field: field,
                            isSensitive: effectiveSensitiveNames.contains(field.name.lowercased()),
                            isNameSecret: normalizedSecretNames.contains(field.name.lowercased()),
                            source: sources[field.name.lowercased()]
                        )
                        .font(.system(.callout, design: .monospaced))
                        .padding(.vertical, 7)
                        if field.id != fields.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var titleLabel: some View {
        Text("\(title) (\(fields.count))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SessionHistoryInputRow: View {
    let name: String
    let input: SnapshotInput

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .fontWeight(.medium)
                Text("\(input.scope.rawValue.capitalized) scope")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)
            if input.isSecret {
                SessionHistorySensitiveValue(label: "Secret input", value: input.value)
            } else {
                Text(input.value.isEmpty ? "(empty)" : input.value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionHistorySensitiveValue: View {
    let label: String
    let value: String
    @State private var isRevealed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isRevealed {
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("••••••••")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Sensitive value hidden")
            }
            HStack(spacing: 10) {
                Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(value, forType: .string)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onChange(of: value) { _, _ in reset() }
        .onDisappear(perform: reset)
    }

    private func reset() {
        isRevealed = false
        copied = false
    }
}

private struct SessionHistoryNotice: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(message)
                    .font(.callout)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

private func historyPaneHeader(_ title: String, symbol: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
        Text(title)
            .font(.title3.weight(.semibold))
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 15)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func statusColor(_ statusCode: Int) -> Color {
    switch statusCode {
    case 200..<300: .green
    case 300..<400: .orange
    default: .red
    }
}

private extension SessionExecutionStore.Phase {
    var historyLabel: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var historyColor: Color {
        switch self {
        case .preparing, .running, .cancelling: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
