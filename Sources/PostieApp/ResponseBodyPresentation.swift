import Foundation
import PostieCore
import SwiftUI

enum ResponseBodyPresentationMode: String, CaseIterable, Hashable, Sendable {
    case text
    case pdf
    case renderedHTML

    var title: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .renderedHTML: "Rendered"
        }
    }
}

enum ResponseBodyPresentationPolicy {
    static func modes(for contentType: String?) -> [ResponseBodyPresentationMode] {
        switch contentType {
        case "application/pdf": [.text, .pdf]
        case "text/html": [.text, .renderedHTML]
        default: [.text]
        }
    }

    static func defaultMode(for contentType: String?) -> ResponseBodyPresentationMode {
        contentType == "application/pdf" ? .pdf : .text
    }

    static func htmlBaseURL(for finalURL: URL) -> URL? {
        guard var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            components.host != nil
        else { return nil }

        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url
    }
}

@MainActor
struct ResponseBodyPresentation: View {
    @EnvironmentObject private var model: AppModel

    let source: ResponseBodySource
    let preview: BodyPreview?
    let previewError: String?
    let isLoadingPreview: Bool
    let truncationMessage: String
    let onRetry: (() -> Void)?
    let withBodyURL: BodyPresentationURLAccess
    private let externalOpeners: ExternalResponseBodyOpeners

    @State private var mode: ResponseBodyPresentationMode
    @State private var bodyResource: ResponseBodyResource?
    @State private var bodyResourceKey: BodyResourceKey?
    @State private var bodyResourceError: String?
    @State private var bodyResourceErrorKey: BodyResourceKey?
    @State private var renderedHTML: String?
    @State private var renderedHTMLValueKey: RenderedHTMLKey?
    @State private var renderedHTMLError: String?
    @State private var renderedHTMLErrorKey: RenderedHTMLKey?
    @State private var isLoadingRenderedHTML = false
    @State private var activeRenderedHTMLKey: RenderedHTMLKey?
    @State private var externalOpenError: String?
    @State private var externalOpenErrorKey: ExternalResponseOpenKey?
    @State private var activeExternalOpenID: UUID?
    @State private var activeExternalOpenKey: ExternalResponseOpenKey?
    @State private var externalOpenTask: Task<Void, Never>?

    init(
        source: ResponseBodySource,
        preview: BodyPreview?,
        previewError: String?,
        isLoadingPreview: Bool,
        truncationMessage: String,
        onRetry: (() -> Void)? = nil,
        withBodyURL: @escaping BodyPresentationURLAccess,
        externalOpeners: ExternalResponseBodyOpeners = .system
    ) {
        self.source = source
        self.preview = preview
        self.previewError = previewError
        self.isLoadingPreview = isLoadingPreview
        self.truncationMessage = truncationMessage
        self.onRetry = onRetry
        self.withBodyURL = withBodyURL
        self.externalOpeners = externalOpeners

        let contentType = BodyMediaType.contentType(for: source.response.responseHeaders)
        _mode = State(initialValue: ResponseBodyPresentationPolicy.defaultMode(for: contentType))
    }

    private var response: HTTPResponseRecord {
        source.response
    }

    private var contentType: String? {
        BodyMediaType.contentType(for: response.responseHeaders)
    }

    private var availableModes: [ResponseBodyPresentationMode] {
        ResponseBodyPresentationPolicy.modes(for: contentType)
    }

    private var activeMode: ResponseBodyPresentationMode {
        availableModes.contains(mode) ? mode : ResponseBodyPresentationPolicy.defaultMode(for: contentType)
    }

    private var sourceIdentity: BodySourceIdentity {
        let origin: BodySourceIdentity.Origin
        switch source {
        case let .live(response):
            origin = .live(response.runID)
        case let .history(token, _):
            origin = .history(token)
        case let .snapshot(snapshotID, _):
            origin = .snapshot(snapshotID)
        }

        return BodySourceIdentity(
            origin: origin,
            bodyID: BodyPresentationBodyID(runID: response.runID, url: response.bodyFileURL),
            contentType: contentType,
            finalURL: response.finalURL
        )
    }

    private var resourceAcquisitionKey: BodyResourceKey? {
        guard activeMode == .pdf else { return nil }
        return BodyResourceKey(source: sourceIdentity)
    }

    private var renderedHTMLKey: RenderedHTMLKey? {
        guard activeMode == .renderedHTML else { return nil }
        return RenderedHTMLKey(
            source: sourceIdentity,
            isLoadingPreview: isLoadingPreview,
            isBinary: preview?.isBinary
        )
    }

    private var presentationModeSelection: Binding<ResponseBodyPresentationMode> {
        Binding(
            get: { activeMode },
            set: { mode = $0 }
        )
    }

    private var currentBodyResource: ResponseBodyResource? {
        guard bodyResourceKey == resourceAcquisitionKey else { return nil }
        return bodyResource
    }

    private var currentBodyResourceError: String? {
        guard resourceAcquisitionKey != nil, bodyResourceErrorKey == resourceAcquisitionKey else { return nil }
        return bodyResourceError
    }

    private var currentRenderedHTML: String? {
        guard renderedHTMLValueKey == renderedHTMLKey else { return nil }
        return renderedHTML
    }

    private var currentRenderedHTMLError: String? {
        guard renderedHTMLErrorKey == renderedHTMLKey else { return nil }
        return renderedHTMLError
    }

    private var renderedHTMLBaseURL: URL? {
        ResponseBodyPresentationPolicy.htmlBaseURL(for: response.finalURL)
    }

    private var externalOpenKind: ExternalResponseBodyExport.Kind? {
        switch contentType {
        case "application/pdf": .pdf
        case "text/html": .html
        default: nil
        }
    }

    private var isOpeningExternalResponse: Bool {
        activeExternalOpenKey?.source == sourceIdentity
    }

    private var currentExternalOpenError: String? {
        guard let externalOpenKind,
            externalOpenErrorKey == ExternalResponseOpenKey(source: sourceIdentity, kind: externalOpenKind)
        else { return nil }
        return externalOpenError
    }

    private var presentationModePicker: some View {
        Picker("Response body presentation", selection: presentationModeSelection) {
            ForEach(availableModes, id: \.self) { presentation in
                Text(presentation.title).tag(presentation)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Response body presentation")
    }

    private var presentationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if availableModes.count > 1 {
                    Text("View")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    presentationModePicker
                }
                Spacer(minLength: 0)
                externalOpenButton
            }
            VStack(alignment: .leading, spacing: 4) {
                if availableModes.count > 1 {
                    HStack(spacing: 8) {
                        Text("View")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        presentationModePicker
                    }
                }
                externalOpenButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var externalOpenButton: some View {
        if let kind = externalOpenKind {
            Button {
                beginExternalOpen(kind, for: sourceIdentity)
            } label: {
                Label(
                    isOpeningExternalResponse ? "Preparing copy…" : kind.buttonTitle,
                    systemImage: isOpeningExternalResponse ? "clock" : "arrow.up.forward.square"
                )
            }
            .disabled(activeExternalOpenID != nil)
            .help(
                kind == .html
                    ? "Opens captured HTML in your default browser, where scripts may run and network requests may occur."
                    : "Copies the captured PDF and opens it in Preview.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if availableModes.count > 1 || externalOpenKind != nil {
                presentationControls
            }

            if let currentExternalOpenError {
                Label(currentExternalOpenError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch activeMode {
            case .text:
                BodyTextPresentationView(
                    bodyID: BodyPresentationBodyID(runID: response.runID, url: response.bodyFileURL),
                    responseHeaders: response.responseHeaders,
                    preview: preview,
                    previewError: previewError,
                    isLoadingPreview: isLoadingPreview,
                    truncationMessage: truncationMessage,
                    onRetry: onRetry,
                    withBodyURL: withBodyURL
                )
            case .pdf:
                pdfContent
            case .renderedHTML:
                renderedHTMLContent
            }
        }
        .task(id: resourceAcquisitionKey) {
            await acquireBodyResource(for: resourceAcquisitionKey)
        }
        .task(id: renderedHTMLKey) {
            await loadRenderedHTML(for: renderedHTMLKey)
        }
        .onChange(of: sourceIdentity) { _, _ in
            mode = ResponseBodyPresentationPolicy.defaultMode(for: contentType)
            bodyResourceError = nil
            bodyResourceErrorKey = nil
            clearRenderedHTML()
            cancelExternalOpen()
        }
        .onDisappear {
            releaseBodyResource()
            cancelExternalOpen()
        }
    }

    @ViewBuilder
    private var pdfContent: some View {
        if let bodyResourceError = currentBodyResourceError {
            Label(bodyResourceError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if let currentBodyResource {
            PDFBodyPreview(resource: currentBodyResource, byteCount: response.bodyByteCount)
        } else {
            ProgressView("Preparing PDF preview…")
                .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    @ViewBuilder
    private var renderedHTMLContent: some View {
        if let renderedHTMLError = currentRenderedHTMLError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Rendered HTML preview is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                Text(renderedHTMLError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show Text") { mode = .text }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        } else if isLoadingPreview {
            ProgressView("Checking response body…")
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if isLoadingRenderedHTML && activeRenderedHTMLKey == renderedHTMLKey {
            ProgressView("Loading complete HTML source…")
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if let renderedHTML = currentRenderedHTML {
            HTMLBodyPreview(html: renderedHTML, baseURL: renderedHTMLBaseURL)
                .id(sourceIdentity)
        } else {
            ProgressView("Loading complete HTML source…")
                .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    private func acquireBodyResource(for key: BodyResourceKey?) async {
        bodyResourceError = nil
        bodyResourceErrorKey = nil

        if let bodyResource, bodyResourceKey != key || !bodyResource.isValid {
            self.bodyResource = nil
            bodyResourceKey = nil
            await model.releaseBodyResource(bodyResource.id)
        }

        guard !Task.isCancelled, let key, activeMode == .pdf, resourceAcquisitionKey == key else { return }
        if bodyResourceKey == key, bodyResource?.isValid == true { return }

        do {
            let acquired = try await model.acquireBodyResource(from: source)
            guard !Task.isCancelled, resourceAcquisitionKey == key else {
                await model.releaseBodyResource(acquired.id)
                return
            }
            bodyResource = acquired
            bodyResourceKey = key
        } catch {
            guard !Task.isCancelled, resourceAcquisitionKey == key else { return }
            bodyResourceError = error.localizedDescription
            bodyResourceErrorKey = key
        }
    }

    private func releaseBodyResource() {
        guard let bodyResource else { return }
        self.bodyResource = nil
        bodyResourceKey = nil
        Task { await model.releaseBodyResource(bodyResource.id) }
    }

    private func loadRenderedHTML(for key: RenderedHTMLKey?) async {
        renderedHTML = nil
        renderedHTMLValueKey = nil
        renderedHTMLError = nil
        renderedHTMLErrorKey = nil
        isLoadingRenderedHTML = false
        activeRenderedHTMLKey = key
        guard let key, activeMode == .renderedHTML else { return }
        guard !isLoadingPreview else { return }
        guard preview?.isBinary != true else {
            renderedHTMLError = "Rendered HTML requires a text response body. Switch to Text to inspect this response."
            renderedHTMLErrorKey = key
            return
        }

        isLoadingRenderedHTML = true
        let operation: BodyPresentationURLOperation = { url in
            let loader = Task.detached(priority: .userInitiated) {
                try CompleteHTMLSource.read(at: url)
            }
            return try await withTaskCancellationHandler {
                try await loader.value
            } onCancel: {
                loader.cancel()
            }
        }

        do {
            let html = try await withBodyURL(operation)
            guard !Task.isCancelled, activeRenderedHTMLKey == key else { return }
            renderedHTML = html
            renderedHTMLValueKey = key
            isLoadingRenderedHTML = false
        } catch {
            guard !Task.isCancelled, activeRenderedHTMLKey == key else { return }
            renderedHTMLError = error.localizedDescription
            renderedHTMLErrorKey = key
            isLoadingRenderedHTML = false
        }
    }

    private func clearRenderedHTML() {
        renderedHTML = nil
        renderedHTMLValueKey = nil
        renderedHTMLError = nil
        renderedHTMLErrorKey = nil
        isLoadingRenderedHTML = false
        activeRenderedHTMLKey = nil
    }

    private func beginExternalOpen(_ kind: ExternalResponseBodyExport.Kind, for identity: BodySourceIdentity) {
        guard identity == sourceIdentity, activeExternalOpenID == nil else { return }
        let key = ExternalResponseOpenKey(source: identity, kind: kind)
        let operationID = UUID()
        let capturedSource = source
        let capturedBaseURL = ResponseBodyPresentationPolicy.htmlBaseURL(for: capturedSource.response.finalURL)
        externalOpenError = nil
        externalOpenErrorKey = nil
        activeExternalOpenID = operationID
        activeExternalOpenKey = key
        externalOpenTask = Task {
            await exportAndOpen(
                kind,
                source: capturedSource,
                baseURL: capturedBaseURL,
                key: key,
                operationID: operationID
            )
        }
    }

    private func exportAndOpen(
        _ kind: ExternalResponseBodyExport.Kind,
        source: ResponseBodySource,
        baseURL: URL?,
        key: ExternalResponseOpenKey,
        operationID: UUID
    ) async {
        do {
            let resource = try await model.acquireBodyResource(from: source)
            let exportedURL: URL
            do {
                try Task.checkCancellation()
                switch kind {
                case .pdf:
                    exportedURL = try await ExternalResponseBodyExport.pdf(from: resource.url)
                case .html:
                    exportedURL = try await ExternalResponseBodyExport.html(from: resource.url, baseURL: baseURL)
                }
            } catch {
                await model.releaseBodyResource(resource.id)
                throw error
            }
            await model.releaseBodyResource(resource.id)
            try Task.checkCancellation()
            guard sourceIdentity == key.source else { finishExternalOpen(operationID); return }

            switch kind {
            case .pdf: try await externalOpeners.preview(exportedURL)
            case .html: try await externalOpeners.browser(exportedURL)
            }
            finishExternalOpen(operationID)
        } catch {
            if !Task.isCancelled, sourceIdentity == key.source, activeExternalOpenID == operationID {
                externalOpenError = error.localizedDescription
                externalOpenErrorKey = key
            }
            finishExternalOpen(operationID)
        }
    }

    private func finishExternalOpen(_ operationID: UUID) {
        guard activeExternalOpenID == operationID else { return }
        externalOpenTask = nil
        activeExternalOpenID = nil
        activeExternalOpenKey = nil
    }

    private func cancelExternalOpen() {
        externalOpenTask?.cancel()
        externalOpenTask = nil
        activeExternalOpenID = nil
        activeExternalOpenKey = nil
        externalOpenError = nil
        externalOpenErrorKey = nil
    }
}

struct CompleteHTMLSource {
    static let maximumBytes = 5 * 1_048_576

    static func read(at url: URL) throws -> String {
        try Task.checkCancellation()
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch {
            throw ReadError.unreadable
        }
        defer { try? file.close() }

        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let readLimit = min(64 * 1_024, maximumBytes + 1 - data.count)
            guard readLimit > 0 else { break }
            let chunk: Data
            do {
                chunk = try file.read(upToCount: readLimit) ?? Data()
            } catch {
                throw ReadError.unreadable
            }
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw ReadError.tooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw ReadError.invalidUTF8 }
        return html
    }

    enum ReadError: LocalizedError {
        case unreadable
        case tooLarge
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .unreadable: "The HTML response body could not be read."
            case .tooLarge:
                "Rendered HTML is limited to complete bodies of 5 MiB or less. Switch to Text for the bounded source preview."
            case .invalidUTF8: "Rendered HTML requires a complete UTF-8 body. Switch to Text for the source preview."
            }
        }
    }
}

private struct BodySourceIdentity: Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case live(UUID)
        case history(UUID)
        case snapshot(UUID)
    }

    let origin: Origin
    let bodyID: BodyPresentationBodyID
    let contentType: String?
    let finalURL: URL
}

private struct BodyResourceKey: Hashable, Sendable {
    let source: BodySourceIdentity
}

private struct RenderedHTMLKey: Hashable, Sendable {
    let source: BodySourceIdentity
    let isLoadingPreview: Bool
    let isBinary: Bool?
}

private struct ExternalResponseOpenKey: Hashable {
    let source: BodySourceIdentity
    let kind: ExternalResponseBodyExport.Kind
}

private extension ExternalResponseBodyExport.Kind {
    var buttonTitle: String {
        switch self {
        case .pdf: "Open in Preview"
        case .html: "Open in Browser"
        }
    }
}
