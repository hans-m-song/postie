import AppKit
import PDFKit
import SwiftUI

@MainActor
struct PDFBodyPreview: View {
    private let resource: ResponseBodyResource
    private let byteCount: Int64

    init(resource: ResponseBodyResource, byteCount: Int64) {
        self.resource = resource
        self.byteCount = byteCount
    }

    var body: some View {
        PDFBodyPreviewContent(resource: resource, byteCount: byteCount)
            .id(PDFBodyResourceIdentity(id: resource.id, url: resource.url))
            .responseBodyViewportFilling()
    }
}

@MainActor
private struct PDFBodyPreviewContent: View {
    @ObservedObject private var resource: ResponseBodyResource
    @StateObject private var controller = PDFBodyPreviewController()
    @State private var isVisible = false
    @State private var loadAnyway = false
    @State private var password = ""

    private let byteCount: Int64

    init(resource: ResponseBodyResource, byteCount: Int64) {
        self.resource = resource
        self.byteCount = byteCount
    }

    var body: some View {
        Group {
            if !resource.isValid || controller.state == .unavailable {
                message("The response body is no longer available.", symbol: "doc.questionmark")
            } else if !isVisible {
                message("PDF preview loads when this view is visible.", symbol: "doc.richtext")
            } else if PDFBodyPreviewPolicy.requiresExplicitLoad(byteCount: byteCount) && !loadAnyway {
                largeBodyNotice
            } else {
                previewContent
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
        }
        .onDisappear {
            isVisible = false
            password = ""
            controller.tearDown()
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            guard self.isVisible != isVisible else { return }
            self.isVisible = isVisible
            if isVisible {
                loadIfNeeded()
            } else {
                password = ""
                controller.tearDown()
            }
        }
        .onChange(of: byteCount) { _, _ in
            loadIfNeeded()
        }
        .onChange(of: resource.isValid) { _, isValid in
            guard !isValid else { return }
            password = ""
            controller.invalidate()
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch controller.state {
        case .idle, .requiresConfirmation:
            ProgressView("Loading PDF preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .passwordRequired, .incorrectPassword:
            passwordPrompt
        case .ready:
            PDFKitDocumentView(controller: controller)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        case .unreadable:
            message("This file could not be read as a PDF.", symbol: "exclamationmark.triangle")
        case .unavailable:
            message("The response body is no longer available.", symbol: "doc.questionmark")
        }
    }

    private var largeBodyNotice: some View {
        VStack(spacing: 10) {
            Label("Large PDF preview", systemImage: "doc.richtext")
                .font(.headline)
            Text(
                "This response body is \(byteCount.formatted(.byteCount(style: .file))). Load it only if you want to preview it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button("Load anyway") {
                loadAnyway = true
                loadIfNeeded()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var passwordPrompt: some View {
        VStack(spacing: 10) {
            Label("This PDF is password protected", systemImage: "lock")
                .font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit(unlock)
            if controller.state == .incorrectPassword {
                Text("That password did not unlock this PDF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Unlock", action: unlock)
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadIfNeeded() {
        guard isVisible else { return }
        controller.loadIfNeeded(
            resource: resource,
            byteCount: byteCount,
            allowsLargePreview: loadAnyway
        )
    }

    private func unlock() {
        let submittedPassword = password
        password = ""
        controller.unlock(with: submittedPassword)
    }
}

enum PDFBodyPreviewPolicy {
    static let maximumAutomaticPreviewBytes: Int64 = 25_000_000

    static func requiresExplicitLoad(byteCount: Int64) -> Bool {
        byteCount > maximumAutomaticPreviewBytes
    }
}

@MainActor
final class PDFBodyPreviewController: ObservableObject {
    enum State: Equatable {
        case idle
        case requiresConfirmation
        case passwordRequired
        case incorrectPassword
        case ready
        case unreadable
        case unavailable
    }

    @Published private(set) var state = State.idle
    private(set) var document: PDFDocument?

    private weak var resource: ResponseBodyResource?
    private weak var pdfView: PDFView?
    private var resourceIdentity: PDFBodyResourceIdentity?
    private var invalidationHandlerID: UUID?

    func loadIfNeeded(
        resource: ResponseBodyResource,
        byteCount: Int64,
        allowsLargePreview: Bool
    ) {
        let identity = PDFBodyResourceIdentity(id: resource.id, url: resource.url)
        if resourceIdentity != identity || self.resource !== resource {
            tearDown()
        }

        guard resource.isValid else {
            self.resource = resource
            resourceIdentity = identity
            state = .unavailable
            return
        }

        guard byteCount >= 0, resource.url.isFileURL else {
            self.resource = resource
            resourceIdentity = identity
            state = .unreadable
            return
        }

        if PDFBodyPreviewPolicy.requiresExplicitLoad(byteCount: byteCount) && !allowsLargePreview {
            tearDown()
            self.resource = resource
            resourceIdentity = identity
            state = .requiresConfirmation
            return
        }

        guard state == .idle || state == .requiresConfirmation else { return }

        self.resource = resource
        resourceIdentity = identity
        invalidationHandlerID = resource.registerInvalidation { [weak self] in
            self?.invalidate()
        }

        guard resource.isValid else {
            invalidate()
            return
        }

        guard let document = PDFDocument(url: resource.url), document.pageCount > 0 else {
            state = .unreadable
            return
        }

        guard resource.isValid else {
            invalidate()
            return
        }

        self.document = document
        state = document.isLocked ? .passwordRequired : .ready
        if state == .ready {
            pdfView?.document = document
        }
    }

    @discardableResult
    func unlock(with password: String) -> Bool {
        guard state == .passwordRequired || state == .incorrectPassword,
            let document,
            document.unlock(withPassword: password)
        else {
            state = .incorrectPassword
            return false
        }

        state = .ready
        pdfView?.document = document
        return true
    }

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        if state == .ready {
            pdfView.document = document
        }
    }

    func detach(from pdfView: PDFView) {
        guard self.pdfView === pdfView else { return }
        pdfView.document = nil
        self.pdfView = nil
    }

    func invalidate() {
        pdfView?.document = nil
        pdfView = nil
        document = nil
        invalidationHandlerID = nil
        state = .unavailable
    }

    func tearDown() {
        pdfView?.document = nil
        pdfView = nil
        document = nil
        if let invalidationHandlerID {
            resource?.removeInvalidationHandler(invalidationHandlerID)
        }
        invalidationHandlerID = nil
        resource = nil
        resourceIdentity = nil
        state = .idle
    }
}

private struct PDFBodyResourceIdentity: Hashable {
    let id: UUID
    let url: URL
}

private struct PDFKitDocumentView: NSViewRepresentable {
    let controller: PDFBodyPreviewController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.delegate = context.coordinator
        controller.attach(to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.controller !== controller {
            context.coordinator.controller.detach(from: view)
            controller.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.controller.detach(from: view)
        view.delegate = nil
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        let controller: PDFBodyPreviewController

        init(controller: PDFBodyPreviewController) {
            self.controller = controller
        }

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            // Captured PDFs cannot open external URLs.
        }

        func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {
            // Captured PDFs cannot navigate to external documents.
        }
    }
}
