import AppKit
import SwiftUI
import PostieCore

struct SnapshotDetailView: View {
    @EnvironmentObject private var model: AppModel
    let snapshotID: UUID
    let layout: RequestResponseLayout

    @State private var isRenameSheetPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isCopyingJSON = false
    @State private var copyJSONError: String?

    private var summary: SavedSnapshot? {
        model.snapshots.first { $0.id == snapshotID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            detail
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            if let summary {
                SnapshotNameSheet(title: "Rename Snapshot", initialValue: summary.name) { name in
                    Task { await model.renameSnapshot(id: snapshotID, name: name) }
                }
            }
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Snapshot", role: .destructive) {
                Task { await model.deleteSnapshot(id: snapshotID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved request and response snapshot.")
        }
        .alert("Could not copy snapshot JSON", isPresented: Binding(
            get: { copyJSONError != nil },
            set: { if !$0 { copyJSONError = nil } }
        )) {
            Button("OK") { copyJSONError = nil }
        } message: {
            Text(copyJSONError ?? "The snapshot could not be copied.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary?.name ?? "Snapshot")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary {
                    Text("\(summary.source.collectionName) / \(summary.source.requestName) · \(summary.capturedAt.formatted(date: .long, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Button {
                guard let opened = model.openedSnapshots[snapshotID] else { return }
                copyJSON(opened)
            } label: {
                Label(isCopyingJSON ? "Preparing…" : "Copy as JSON", systemImage: "doc.on.doc")
            }
            .help("Copies captured secrets and up to 1 MiB of the response body.")
            .disabled(model.openedSnapshots[snapshotID] == nil || isCopyingJSON || model.isTerminating)
            Button("Rename…") { isRenameSheetPresented = true }
                .disabled(summary == nil || model.isTerminating)
            Button(role: .destructive) { isDeleteConfirmationPresented = true } label: {
                Image(systemName: "trash")
            }
            .help("Delete snapshot")
            .accessibilityLabel("Delete snapshot")
            .disabled(summary == nil || model.isTerminating)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func copyJSON(_ opened: OpenedSnapshot) {
        guard !isCopyingJSON else { return }
        isCopyingJSON = true
        copyJSONError = nil

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SnapshotJSONExporter.encode(opened) }
            }.value

            isCopyingJSON = false
            switch result {
            case let .success(json):
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.setString(json, forType: .string) {
                    copyJSONError = "The snapshot JSON was prepared but could not be placed on the clipboard."
                }
            case let .failure(error):
                copyJSONError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.openingSnapshots.contains(snapshotID) {
            ProgressView("Opening snapshot…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.snapshotOpenError(for: snapshotID) {
            ContentUnavailableView(
                "Snapshot could not be opened",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let opened = model.openedSnapshots[snapshotID] {
            splitView(opened)
        } else if summary == nil {
            ContentUnavailableView(
                "Snapshot unavailable",
                systemImage: "doc.questionmark",
                description: Text("This snapshot is no longer in the workspace.")
            )
        } else {
            ProgressView("Loading snapshot…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: snapshotID) { model.selectSnapshot(snapshotID) }
        }
    }

    @ViewBuilder
    private func splitView(_ opened: OpenedSnapshot) -> some View {
        SnapshotRequestResponseSplit(opened: opened, layout: layout)
    }
}

@MainActor
private struct SnapshotRequestResponseSplit: NSViewControllerRepresentable {
    let opened: OpenedSnapshot
    let layout: RequestResponseLayout

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitController = NSSplitViewController()
        splitController.splitView.dividerStyle = .thin

        let requestController = NSHostingController(rootView: SnapshotRequestPane(opened: opened))
        requestController.sizingOptions = []
        let requestItem = NSSplitViewItem(viewController: requestController)
        requestItem.preferredThicknessFraction = 0.5
        requestItem.canCollapse = false
        requestItem.canCollapseFromWindowResize = false

        let responseController = NSHostingController(rootView: SnapshotResponsePane(opened: opened))
        responseController.sizingOptions = []
        let responseItem = NSSplitViewItem(viewController: responseController)
        responseItem.preferredThicknessFraction = 0.5
        responseItem.canCollapse = false
        responseItem.canCollapseFromWindowResize = false

        splitController.addSplitViewItem(requestItem)
        splitController.addSplitViewItem(responseItem)
        configure(splitController)

        context.coordinator.requestController = requestController
        context.coordinator.responseController = responseController
        return splitController
    }

    func updateNSViewController(_ splitController: NSSplitViewController, context: Context) {
        context.coordinator.requestController?.rootView = SnapshotRequestPane(opened: opened)
        context.coordinator.responseController?.rootView = SnapshotResponsePane(opened: opened)
        configure(splitController)
    }

    private func configure(_ splitController: NSSplitViewController) {
        let splitItems = splitController.splitViewItems
        guard splitItems.count == 2 else { return }

        let splitView = splitController.splitView
        let layoutChanged = splitView.isVertical != layout.isVertical
        splitItems[0].minimumThickness = layout.requestMinimumThickness
        splitItems[1].minimumThickness = layout.responseMinimumThickness
        if layoutChanged {
            splitItems.forEach { $0.preferredThicknessFraction = 0.5 }
        }
        splitView.isVertical = layout.isVertical
    }

    @MainActor
    final class Coordinator {
        fileprivate var requestController: NSHostingController<SnapshotRequestPane>?
        fileprivate var responseController: NSHostingController<SnapshotResponsePane>?
    }
}

private struct SnapshotRequestPane: View {
    let opened: OpenedSnapshot

    private var submitted: SnapshotTransportRequest? {
        opened.context?.preparation.submitted
    }

    private var observed: SnapshotTransportRequest? {
        opened.context?.observedTransport
    }

    private var requestTemplateSensitiveNames: Set<String> {
        guard let submitted else {
            return Self.standardSensitiveHeaderNames
        }
        return Self.standardSensitiveHeaderNames
            .union(submitted.sensitiveNames)
            .union(opened.response.sensitiveRequestHeaderNames)
    }

    private var requestTemplateSecretNames: Set<String> {
        submitted?.secretNames.union(opened.response.secretRequestHeaderNames) ?? []
    }

    private static let standardSensitiveHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie"
    ]

    var body: some View {
        VStack(spacing: 0) {
            paneHeader("Request", symbol: "arrow.up.right.square")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let contextError = opened.contextError {
                        Label(contextError, systemImage: "lock.slash")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }

                    SnapshotInformationSection(title: "Request template") {
                        SnapshotValueLine(label: "Method", value: opened.template.method)
                        SnapshotValueLine(label: "URL template", value: opened.template.url)
                        SnapshotFieldList(title: "Path parameters", fields: opened.template.pathParameters)
                        SnapshotFieldList(title: "Query parameters", fields: opened.template.query)
                        SnapshotFieldList(
                            title: "Header templates",
                            fields: opened.template.headers,
                            sensitiveNames: requestTemplateSensitiveNames,
                            secretNames: requestTemplateSecretNames
                        )
                        if opened.template.bodyEnabled {
                            SnapshotValueLine(label: "Body syntax", value: opened.template.bodySyntax.rawValue.uppercased())
                            SnapshotLongValue(label: "Body template", value: opened.template.body)
                        } else {
                            SnapshotValueLine(label: "Body", value: "Disabled")
                        }
                        SnapshotValueLine(label: "Follow redirects", value: opened.template.options.followRedirects ? "On" : "Off")
                    }

                    if let submitted {
                        SnapshotInformationSection(title: "Submitted request") {
                            SnapshotValueLine(label: "Method", value: submitted.method)
                            SnapshotValueLine(label: "URL", value: submitted.url.absoluteString)
                            SnapshotTransportBody(requestBody: submitted.body)
                            SnapshotHeaderList(
                                title: "Submitted headers",
                                fields: submitted.headers,
                                sensitiveNames: submitted.sensitiveNames,
                                secretNames: submitted.secretNames,
                                sources: submitted.headerSources
                            )
                        }
                    }

                    if let observed {
                        SnapshotInformationSection(title: "Observed final request") {
                            SnapshotValueLine(label: "Method", value: observed.method)
                            SnapshotValueLine(label: "URL", value: observed.url.absoluteString)
                            SnapshotTransportBody(requestBody: observed.body)
                            SnapshotHeaderList(
                                title: "Final request headers",
                                fields: observed.headers,
                                sensitiveNames: observed.sensitiveNames,
                                secretNames: observed.secretNames,
                                sources: observed.headerSources
                            )
                        }
                    }

                    if let context = opened.context {
                        if !context.preparation.referencedInputs.isEmpty {
                            SnapshotInformationSection(title: "Captured inputs") {
                                ForEach(context.preparation.referencedInputs.keys.sorted(), id: \.self) { name in
                                    if let input = context.preparation.referencedInputs[name] {
                                        SnapshotInputRow(name: name, input: input)
                                    }
                                }
                            }
                        }
                        SnapshotAuthenticationSection(authentication: context.preparation.authentication)
                    } else if submitted == nil {
                        SnapshotInformationSection(title: "Recorded request") {
                            SnapshotValueLine(label: "Method", value: opened.template.method)
                            SnapshotHeaderList(
                                title: "Recorded request headers",
                                fields: opened.response.requestHeaders,
                                sensitiveNames: opened.response.sensitiveRequestHeaderNames,
                                secretNames: opened.response.secretRequestHeaderNames,
                                sources: opened.response.requestHeaderSources
                            )
                        }
                    }
                }
                .padding(16)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .background(.background)
    }
}

private struct SnapshotResponsePane: View {
    let opened: OpenedSnapshot
    @State private var expandedRedirectIDs: Set<UUID> = []

    private var response: HTTPResponseRecord { opened.response }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Response")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(response.bodyByteCount.formatted(.byteCount(style: .file))) received")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(snapshotStatusColor(response.statusCode))
                            .frame(width: 10, height: 10)
                        Text("\(response.statusCode) \(snapshotStatusReason(response.statusCode))")
                            .fontWeight(.semibold)
                            .foregroundStyle(snapshotStatusColor(response.statusCode))
                        Spacer(minLength: 0)
                        Text(opened.summary.capturedAt.formatted(date: .numeric, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(11)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    if response.redirectLimitReached {
                        Label("Stopped after 10 redirects. The final redirect response is shown below.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }

                    ForEach(response.redirects) { redirect in
                        SnapshotRedirectDisclosure(
                            redirect: redirect,
                            showsResolvedRequest: opened.context != nil,
                            isExpanded: Binding(
                                get: { expandedRedirectIDs.contains(redirect.id) },
                                set: { expanded in
                                    if expanded { expandedRedirectIDs.insert(redirect.id) }
                                    else { expandedRedirectIDs.remove(redirect.id) }
                                }
                            )
                        )
                    }

                    SnapshotInformationSection(title: "Final response") {
                        if opened.context != nil {
                            SnapshotValueLine(label: "Method", value: response.effectiveMethod.uppercased())
                            SnapshotValueLine(label: "URL", value: response.finalURL.absoluteString)
                        }
                        SnapshotHeaderList(title: "Request headers", fields: response.requestHeaders,
                                           sensitiveNames: response.sensitiveRequestHeaderNames,
                                           secretNames: response.secretRequestHeaderNames,
                                           sources: response.requestHeaderSources)
                        SnapshotHeaderList(title: "Response headers", fields: response.responseHeaders)
                        SnapshotResponseBodyPreview(response: response)
                    }
                }
                .padding(16)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .background(.background)
    }
}

private struct SnapshotInformationSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SnapshotValueLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value.isEmpty ? "(empty)" : value)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SnapshotLongValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "(empty body)" : value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct SnapshotTransportBody: View {
    let requestBody: String?

    var body: some View {
        if let requestBody {
            SnapshotLongValue(label: "Submitted body", value: requestBody)
        } else {
            SnapshotValueLine(label: "Body", value: "No request body")
        }
    }
}

private struct SnapshotFieldList: View {
    let title: String
    let fields: [HTTPField]
    var sensitiveNames: Set<String> = []
    var secretNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) (\(fields.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)
            if fields.isEmpty {
                Text("None")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields) { field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.name.isEmpty ? "(empty name)" : field.name)
                            .frame(width: 112, alignment: .leading)
                        if sensitiveNames.contains(field.name.lowercased()) || secretNames.contains(field.name.lowercased()) {
                            SnapshotSensitiveValue(value: field.value)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(field.value.isEmpty ? "(empty)" : field.value)
                                .textSelection(.enabled)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        }
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
    }
}

private struct SnapshotHeaderList: View {
    let title: String
    let fields: [HTTPField]
    var sensitiveNames: Set<String> = []
    var secretNames: Set<String> = []
    var sources: [String: HTTPHeaderSource] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) (\(fields.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)
            if fields.isEmpty {
                Text("No headers recorded")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields) { field in
                    ResponseHeaderRow(
                        field: field,
                        isSensitive: sensitiveNames.contains(field.name.lowercased()),
                        isNameSecret: secretNames.contains(field.name.lowercased()),
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

private struct SnapshotInputRow: View {
    let name: String
    let input: SnapshotInput
    @State private var isRevealed = false
    @State private var copied = false

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
            VStack(alignment: .leading, spacing: 5) {
                if input.isSecret && !isRevealed {
                    Text("••••••••")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Captured secret hidden")
                } else {
                    Text(input.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if input.isSecret {
                    HStack(spacing: 10) {
                        Button(isRevealed ? "Hide" : "Reveal") { isRevealed.toggle() }
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(input.value, forType: .string)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            isRevealed = false
            copied = false
        }
    }
}

private struct SnapshotAuthenticationSection: View {
    let authentication: SnapshotAuthenticationInput

    var body: some View {
        SnapshotInformationSection(title: "Captured authentication") {
            SnapshotValueLine(label: "Kind", value: authentication.kind.rawValue.capitalized)
            if !authentication.username.isEmpty {
                SnapshotValueLine(label: "Username", value: authentication.username)
            }
            if let apiKeyHeaderName = authentication.apiKeyHeaderName {
                SnapshotValueLine(label: "API key header", value: apiKeyHeaderName)
            }
            if let resolvedSecret = authentication.resolvedSecret {
                SnapshotSensitiveValue(value: resolvedSecret)
            }
        }
    }
}

private struct SnapshotSensitiveValue: View {
    let value: String
    @State private var isRevealed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
        .onDisappear {
            isRevealed = false
            copied = false
        }
    }
}

private struct SnapshotRedirectDisclosure: View {
    let redirect: HTTPRedirect
    let showsResolvedRequest: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if showsResolvedRequest {
                    SnapshotHeaderList(title: "Request headers", fields: redirect.requestHeaders,
                                       sensitiveNames: redirect.sensitiveRequestHeaderNames,
                                       secretNames: redirect.secretRequestHeaderNames,
                                       sources: redirect.requestHeaderSources)
                }
                SnapshotHeaderList(title: "Response headers", fields: redirect.responseHeaders)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Text("\(redirect.statusCode) \(snapshotStatusReason(redirect.statusCode))")
                    .fontWeight(.medium)
                if showsResolvedRequest {
                    Text("· \(redirect.method) \(redirect.url.absoluteString) → \(redirect.nextMethod) \(redirect.nextURL.absoluteString)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("· \(redirect.method) → \(redirect.nextMethod)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disclosureGroupStyle(PaddedDisclosureGroupStyle())
    }
}

private struct SnapshotResponseBodyPreview: View {
    let response: HTTPResponseRecord

    @State private var preview: BodyPreview?
    @State private var previewError: String?
    @State private var isLoadingPreview = true
    @State private var syntax: BodySyntax
    @State private var pretty: Bool
    @State private var formatted: String?
    @State private var formatError: String?
    @State private var isFormatting = false

    init(response: HTTPResponseRecord) {
        self.response = response
        let syntax = Self.syntax(for: response.responseHeaders)
        _syntax = State(initialValue: syntax)
        _pretty = State(initialValue: syntax == .json)
    }

    private var shouldFormatJSON: Bool {
        pretty && syntax == .json && preview?.isBinary == false
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
                .disabled(syntax != .json || preview?.isBinary != false)
            }
            .fixedSize(horizontal: false, vertical: true)
            if isFormatting { ProgressView("Formatting JSON…").controlSize(.small) }
            if let formatError {
                Text(formatError).font(.caption).foregroundStyle(.secondary)
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
                        if shouldFormatJSON, let formatted {
                            ScrollView(.horizontal) {
                                HighlightedResponseText(text: displayedText(preview, formatted: formatted), syntax: syntax, wrapsToWidth: false)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .padding(10)
                            }
                        } else {
                            HighlightedResponseText(text: displayedText(preview, formatted: nil), syntax: syntax, wrapsToWidth: true)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1) }
                    if preview.isTruncated && formatted == nil {
                        Label("Preview limited to the first 1 MiB. The saved response body is complete.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: response.bodyFileURL) { await loadPreview() }
        .task(id: shouldFormatJSON) { await formatJSONIfNeeded() }
        .onChange(of: preview?.isBinary) { _, isBinary in
            if isBinary == true { pretty = false }
        }
    }

    private func loadPreview() async {
        isLoadingPreview = true
        previewError = nil
        let url = response.bodyFileURL
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ResponseBodyReader.preview(at: url, maximumBytes: 1_048_576) }
        }.value
        guard !Task.isCancelled else { return }
        isLoadingPreview = false
        switch result {
        case let .success(value): preview = value
        case let .failure(error): previewError = error.localizedDescription
        }
    }

    private func formatJSONIfNeeded() async {
        formatted = nil
        formatError = nil
        guard shouldFormatJSON else { isFormatting = false; return }
        isFormatting = true
        let url = response.bodyFileURL
        let result = await Task.detached(priority: .userInitiated) {
            Result { try JSONPresentation.pretty(at: url) }
        }.value
        guard !Task.isCancelled else { return }
        isFormatting = false
        switch result {
        case let .success(value): formatted = value
        case let .failure(error): formatError = error.localizedDescription
        }
    }

    private static func syntax(for headers: [HTTPField]) -> BodySyntax {
        let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let mediaType = contentType?
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

private func paneHeader(_ title: String, symbol: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol).foregroundStyle(.secondary)
        Text(title).font(.title3.weight(.semibold))
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
}

private func snapshotStatusColor(_ code: Int) -> Color {
    switch code {
    case 200..<300: .green
    case 300..<400: .orange
    default: .red
    }
}

private func snapshotStatusReason(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 204: "No Content"
    case 206: "Partial Content"
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
    case 408: "Request Timeout"
    case 413: "Content Too Large"
    case 422: "Unprocessable Content"
    case 429: "Too Many Requests"
    case 500: "Internal Server Error"
    case 502: "Bad Gateway"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    default: "HTTP response"
    }
}
