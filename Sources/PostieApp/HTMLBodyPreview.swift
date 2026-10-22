import SwiftUI
import WebKit

@MainActor
struct HTMLBodyPreview: View {
    let html: String
    let baseURL: URL?

    @StateObject private var controller = HTMLBodyPreviewController()
    @State private var allowsExternalResources = false
    @State private var isVisible = false

    init(html: String, baseURL: URL?) {
        self.html = html
        self.baseURL = baseURL
    }

    var body: some View {
        VStack(spacing: 0) {
            resourceControls
            Divider()
            previewContent
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1)
        }
        .responseBodyViewportFilling()
        .onAppear {
            isVisible = true
            loadPreview()
        }
        .onDisappear {
            isVisible = false
            allowsExternalResources = false
            controller.tearDown()
        }
        .onChange(of: html) { _, _ in
            allowsExternalResources = false
            loadPreview()
        }
        .onChange(of: baseURL) { _, _ in
            allowsExternalResources = false
            loadPreview()
        }
        .onChange(of: allowsExternalResources) { _, _ in
            loadPreview()
        }
    }

    private var resourceControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                resourceNotice
                Spacer(minLength: 8)
                externalResourcesToggle
            }
            VStack(alignment: .leading, spacing: 8) {
                resourceNotice
                externalResourcesToggle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var resourceNotice: some View {
        Text(
            allowsExternalResources
                ? "External images, stylesheets and fonts are enabled for this preview."
                : "External resources are blocked until enabled for this preview."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var externalResourcesToggle: some View {
        Toggle(isOn: $allowsExternalResources) {
            Text("Load images, stylesheets and fonts")
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch controller.state {
        case .idle, .preparing:
            ProgressView("Preparing HTML preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .ready:
            if let webView = controller.webView {
                HTMLWebView(webView: webView)
                    .id(controller.loadGeneration)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            } else {
                ProgressView("Preparing HTML preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .tooLarge(byteCount):
            message(
                "This captured HTML is \(byteCount.formatted(.byteCount(style: .file))), above the 5 MiB preview limit.",
                symbol: "doc.text.magnifyingglass"
            )
        case .failed:
            message("A safe HTML preview could not be prepared.", symbol: "exclamationmark.triangle")
        }
    }

    private func message(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadPreview() {
        guard isVisible else { return }
        controller.load(
            html: html,
            baseURL: baseURL,
            allowsExternalResources: allowsExternalResources
        )
    }
}

@MainActor
final class HTMLBodyPreviewController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case loading
        case ready
        case tooLarge(byteCount: Int)
        case failed
    }

    @Published private(set) var state = State.idle
    private(set) var webView: WKWebView?
    private(set) var loadGeneration = UUID()
    private(set) var blockedNavigationCount = 0
    private(set) var failureDescription: String?
    private var navigationDelegate: HTMLBodyNavigationDelegate?

    func load(html: String, baseURL: URL?, allowsExternalResources: Bool = false) {
        tearDownWebView()
        loadGeneration = UUID()
        blockedNavigationCount = 0
        failureDescription = nil

        let byteCount = html.utf8.count
        guard byteCount <= HTMLBodyPreviewPolicy.maximumCapturedHTMLBytes else {
            state = .tooLarge(byteCount: byteCount)
            return
        }

        state = .preparing
        let generation = loadGeneration
        let safeBaseURL = HTMLBodyPreviewPolicy.acceptsBaseURL(baseURL)

        do {
            let rules = try HTMLBodyPreviewPolicy.contentRuleListJSON(
                allowsExternalResources: allowsExternalResources
            )
            let ruleIdentifier =
                allowsExternalResources
                ? "com.postie.html-preview.external.v1"
                : "com.postie.html-preview.blocked.v1"
            guard let ruleListStore = WKContentRuleListStore.default() else {
                fail("WebKit content rule list store is unavailable.")
                return
            }
            ruleListStore.compileContentRuleList(
                forIdentifier: ruleIdentifier,
                encodedContentRuleList: rules
            ) { [weak self] ruleList, error in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    guard let ruleList else {
                        let diagnostic: String
                        if let error {
                            let failure = error as NSError
                            diagnostic =
                                failure.userInfo[NSHelpAnchorErrorKey] as? String
                                ?? "Content rule compilation failed with \(failure.domain) (\(failure.code))."
                        } else {
                            diagnostic = "Content rule compilation returned no rule list."
                        }
                        self.fail(diagnostic)
                        return
                    }
                    self.install(
                        ruleList: ruleList,
                        html: html,
                        baseURL: safeBaseURL,
                        allowsExternalResources: allowsExternalResources,
                        generation: generation
                    )
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func tearDown() {
        loadGeneration = UUID()
        tearDownWebView()
        state = .idle
    }

    fileprivate func navigationWasBlocked(generation: UUID) {
        guard loadGeneration == generation else { return }
        blockedNavigationCount += 1
    }

    fileprivate func navigationDidFinish(generation: UUID) {
        guard loadGeneration == generation else { return }
        state = .ready
    }

    fileprivate func navigationDidFail(generation: UUID, error: any Error) {
        guard loadGeneration == generation else { return }
        let failure = error as NSError
        fail("Navigation failed with \(failure.domain) (\(failure.code)).")
    }

    private func install(
        ruleList: WKContentRuleList,
        html: String,
        baseURL: URL?,
        allowsExternalResources: Bool,
        generation: UUID
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let contentController = WKUserContentController()
        contentController.add(ruleList)
        configuration.userContentController = contentController

        let delegate = HTMLBodyNavigationDelegate(controller: self, generation: generation)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        self.navigationDelegate = delegate
        self.webView = webView
        state = .loading
        webView.loadHTMLString(
            htmlWithSecurityPolicy(html, allowsExternalResources: allowsExternalResources),
            baseURL: baseURL
        )
    }

    private func tearDownWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        navigationDelegate = nil
    }

    private func fail(_ description: String) {
        failureDescription = description
        state = .failed
    }

    private func htmlWithSecurityPolicy(_ html: String, allowsExternalResources: Bool) -> String {
        let policy = HTMLBodyPreviewPolicy.contentSecurityPolicy(allowsExternalResources: allowsExternalResources)
        return
            "<!doctype html><meta name=\"referrer\" content=\"no-referrer\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\n\(html)"
    }
}

@MainActor
private final class HTMLBodyNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var controller: HTMLBodyPreviewController?
    private let generation: UUID
    private var initialMainFrameNavigationPending = true

    init(controller: HTMLBodyPreviewController, generation: UUID) {
        self.controller = controller
        self.generation = generation
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = false

        guard initialMainFrameNavigationPending,
            navigationAction.targetFrame?.isMainFrame == true,
            !navigationAction.shouldPerformDownload
        else {
            controller?.navigationWasBlocked(generation: generation)
            decisionHandler(.cancel, preferences)
            return
        }

        initialMainFrameNavigationPending = false
        decisionHandler(.allow, preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard !navigationResponse.isForMainFrame || navigationResponse.canShowMIMEType else {
            controller?.navigationWasBlocked(generation: generation)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        initialMainFrameNavigationPending = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        initialMainFrameNavigationPending = false
        controller?.navigationDidFinish(generation: generation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        recordNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        recordNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        controller?.navigationWasBlocked(generation: generation)
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private func recordNavigationFailure(_ error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        controller?.navigationDidFail(generation: generation, error: error)
    }
}

private struct HTMLWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
}
