import Foundation
import Dispatch
import Network
import XCTest
@testable import PostieApp

@MainActor
final class HTMLBodyPreviewTests: XCTestCase {
    func testCapturedHTMLIsBoundedAndOnlyAcceptsHTTPBaseURLs() throws {
        XCTAssertEqual(HTMLBodyPreviewPolicy.maximumCapturedHTMLBytes, 5 * 1024 * 1024)

        let httpURL = try XCTUnwrap(URL(string: "http://example.test/captured/final.html"))
        let httpsURL = try XCTUnwrap(URL(string: "https://example.test/captured/final.html"))
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/captured.html"))
        let credentialURL = try XCTUnwrap(URL(string: "https://user:password@example.test/final.html"))

        XCTAssertEqual(HTMLBodyPreviewPolicy.acceptsBaseURL(httpURL), httpURL)
        XCTAssertEqual(HTMLBodyPreviewPolicy.acceptsBaseURL(httpsURL), httpsURL)
        XCTAssertNil(HTMLBodyPreviewPolicy.acceptsBaseURL(fileURL))
        XCTAssertNil(HTMLBodyPreviewPolicy.acceptsBaseURL(credentialURL))
    }

    func testOversizedCapturedHTMLDoesNotCreateAWebView() {
        let controller = HTMLBodyPreviewController()
        let oversizedHTML = String(repeating: "x", count: HTMLBodyPreviewPolicy.maximumCapturedHTMLBytes + 1)

        controller.load(html: oversizedHTML, baseURL: nil, allowsExternalResources: false)

        XCTAssertEqual(controller.state, .tooLarge(byteCount: oversizedHTML.utf8.count))
        XCTAssertNil(controller.webView)
    }

    func testCapturedDocumentAndExternalResourcesAreNotFetchedByDefault() async throws {
        let fixture = try HTMLPreviewLoopbackServer()
        defer { fixture.stop() }

        let controller = HTMLBodyPreviewController()
        controller.load(
            html: Self.fixtureHTML,
            baseURL: try XCTUnwrap(fixture.baseURL),
            allowsExternalResources: false
        )

        try await waitUntilReady(controller)
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(controller.state, .ready)
        XCTAssertFalse(
            try XCTUnwrap(controller.webView).configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(fixture.count(for: "/captured/final.html"), 0)
        XCTAssertEqual(fixture.count(for: "/captured/style.css"), 0)
        XCTAssertEqual(fixture.count(for: "/fixture.png"), 0)
        XCTAssertEqual(fixture.count(for: "/captured/fixture.woff2"), 0)
        XCTAssertEqual(fixture.count(for: "/script.js"), 0)
        XCTAssertEqual(fixture.count(for: "/inline-script-ran"), 0)
        XCTAssertEqual(fixture.count(for: "/submit"), 0)
        XCTAssertEqual(fixture.count(for: "/frame.html"), 0)
        XCTAssertEqual(fixture.count(for: "/navigate"), 0)
        XCTAssertGreaterThan(controller.blockedNavigationCount, 0)
    }

    func testOptInLoadsOnlyImagesStylesheetsAndFontsFromCapturedFinalURL() async throws {
        let fixture = try HTMLPreviewLoopbackServer()
        defer { fixture.stop() }

        let controller = HTMLBodyPreviewController()
        controller.load(
            html: Self.fixtureHTML,
            baseURL: try XCTUnwrap(fixture.baseURL),
            allowsExternalResources: true
        )

        try await waitUntil(controller) {
            fixture.count(for: "/captured/style.css") > 0
                && fixture.count(for: "/fixture.png") > 0
                && fixture.count(for: "/captured/fixture.woff2") > 0
                && controller.blockedNavigationCount > 0
        }

        XCTAssertEqual(controller.state, .ready)
        XCTAssertFalse(
            try XCTUnwrap(controller.webView).configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(fixture.count(for: "/captured/final.html"), 0)
        XCTAssertEqual(fixture.count(for: "/script.js"), 0)
        XCTAssertEqual(fixture.count(for: "/inline-script-ran"), 0)
        XCTAssertEqual(fixture.count(for: "/submit"), 0)
        XCTAssertEqual(fixture.count(for: "/frame.html"), 0)
        XCTAssertEqual(fixture.count(for: "/navigate"), 0)
        XCTAssertGreaterThan(controller.blockedNavigationCount, 0)
    }

    func testExternalResourceHintsDoNotReachLoopbackNetwork() async throws {
        let fixture = try HTMLPreviewLoopbackServer()
        defer { fixture.stop() }

        let controller = HTMLBodyPreviewController()
        controller.load(
            html: Self.resourceHintsHTML(origin: try XCTUnwrap(fixture.originURL)),
            baseURL: try XCTUnwrap(fixture.baseURL)
        )

        try await waitUntilReady(controller)
        try await Task.sleep(for: .seconds(1))

        XCTAssertFalse(
            try XCTUnwrap(controller.webView).configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(fixture.count(for: "/resource-hint-prefetch"), 0)
        XCTAssertEqual(fixture.totalRequestCount, 0)
        XCTAssertEqual(fixture.connectionCount, 0)
    }

    func testControllerReloadForNewPreviewIdentityDefaultsToBlockedResources() async throws {
        let fixture = try HTMLPreviewLoopbackServer()
        defer { fixture.stop() }

        let controller = HTMLBodyPreviewController()
        let firstBaseURL = try XCTUnwrap(fixture.baseURL)
        controller.load(
            html: Self.fixtureHTML,
            baseURL: firstBaseURL,
            allowsExternalResources: true
        )

        try await waitUntil(controller) {
            controller.state == .ready
                && fixture.count(for: "/captured/style.css") > 0
                && fixture.count(for: "/fixture.png") > 0
                && fixture.count(for: "/captured/fixture.woff2") > 0
        }

        let firstWebView = try XCTUnwrap(controller.webView)
        XCTAssertFalse(firstWebView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let secondBaseURL = try XCTUnwrap(fixture.url(path: "/second/final.html"))
        controller.load(
            html: Self.secondPreviewHTML,
            baseURL: secondBaseURL
        )

        try await waitUntilReady(controller)
        try await Task.sleep(for: .seconds(1))

        let secondWebView = try XCTUnwrap(controller.webView)
        XCTAssertFalse(firstWebView === secondWebView)
        XCTAssertFalse(secondWebView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertEqual(fixture.count(for: "/second/style.css"), 0)
        XCTAssertEqual(fixture.count(for: "/second/image.png"), 0)
        XCTAssertEqual(fixture.count(for: "/second/font.woff2"), 0)
    }

    func testOptInKeepsScriptsFramesAndFormsRestrictedByContentPolicy() throws {
        let defaultRules = try HTMLBodyPreviewPolicy.contentRuleListJSON(allowsExternalResources: false)
        let enabledRules = try HTMLBodyPreviewPolicy.contentRuleListJSON(allowsExternalResources: true)
        let defaultCSP = HTMLBodyPreviewPolicy.contentSecurityPolicy(allowsExternalResources: false)
        let enabledCSP = HTMLBodyPreviewPolicy.contentSecurityPolicy(allowsExternalResources: true)

        for type in ["script", "child-document", "popup", "raw"] {
            XCTAssertTrue(defaultRules.contains("\"\(type)\""))
            XCTAssertTrue(enabledRules.contains("\"\(type)\""))
        }
        for type in ["image", "style-sheet", "font"] {
            XCTAssertTrue(defaultRules.contains("\"\(type)\""))
            XCTAssertFalse(enabledRules.contains("\"\(type)\""))
        }
        for directive in [
            "default-src 'none'",
            "script-src 'none'",
            "frame-src 'none'",
            "form-action 'none'",
            "connect-src 'none'",
            "base-uri 'none'",
        ] {
            XCTAssertTrue(defaultCSP.contains(directive))
            XCTAssertTrue(enabledCSP.contains(directive))
        }
        XCTAssertFalse(defaultCSP.contains("img-src data: http:"))
        XCTAssertFalse(defaultCSP.contains("http:"))
        XCTAssertTrue(enabledCSP.contains("img-src data: http: https:"))
        XCTAssertTrue(enabledCSP.contains("style-src 'unsafe-inline' http: https:"))
        XCTAssertTrue(enabledCSP.contains("font-src data: http: https:"))
    }

    private static let fixtureHTML = """
        <!doctype html>
        <html>
          <head>
            <link rel="stylesheet" href="style.css">
            <script src="../script.js"></script>
            <script>new Image().src = '../inline-script-ran'; document.forms[0]?.submit();</script>
            <meta http-equiv="refresh" content="0;url=../navigate">
          </head>
          <body>
            <img src="../fixture.png" alt="fixture">
            <iframe src="../frame.html"></iframe>
            <form action="../submit" method="post"><button type="submit">Submit</button></form>
            <a href="../navigate">Navigate</a>
            <p>Captured response body</p>
          </body>
        </html>
        """

    private static func resourceHintsHTML(origin: URL) -> String {
        let prefetchURL = origin.appendingPathComponent("resource-hint-prefetch")
        return """
            <!doctype html>
            <html>
              <head>
                <link rel="dns-prefetch" href="\(origin.absoluteString)">
                <link rel="preconnect" href="\(origin.absoluteString)" crossorigin>
                <link rel="prefetch" href="\(prefetchURL.absoluteString)">
              </head>
              <body><p>Resource hint fixture</p></body>
            </html>
            """
    }

    private static let secondPreviewHTML = """
        <!doctype html>
        <html>
          <head><link rel="stylesheet" href="style.css"></head>
          <body><img src="image.png" alt="second preview"></body>
        </html>
        """

    private func waitUntilReady(_ controller: HTMLBodyPreviewController) async throws {
        try await waitUntil(controller) { controller.state == .ready }
    }

    private func waitUntil(
        _ controller: HTMLBodyPreviewController,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            if controller.state == .failed {
                XCTFail(
                    "HTML preview failed before reaching the expected state: \(controller.failureDescription ?? "unknown failure")."
                )
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTFail("HTML preview did not reach the expected state. Current state: \(controller.state).")
    }
}

private final class HTMLPreviewLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "postie.html-preview-loopback")
    private let lock = NSLock()
    private var requestCounts: [String: Int] = [:]
    private var acceptedConnectionCount = 0
    private(set) var baseURL: URL?
    private(set) var originURL: URL?

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let startup = ListenerStartup()

        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else {
                    startup.complete(.failure(FixtureError.missingPort))
                    return
                }
                startup.complete(.success(port))
            case .failed:
                startup.complete(.failure(FixtureError.listenerFailed))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.recordConnection()
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, accumulatedData: Data())
        }
        listener.start(queue: queue)
        let port = try startup.wait()
        guard let originURL = URL(string: "http://127.0.0.1:\(port)/") else {
            throw FixtureError.invalidBaseURL
        }
        self.originURL = originURL
        self.baseURL = originURL.appendingPathComponent("captured").appendingPathComponent("final.html")
    }

    func count(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path, default: 0]
    }

    var totalRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts.values.reduce(0, +)
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedConnectionCount
    }

    func url(path: String) -> URL? {
        guard let originURL else { return nil }
        return URL(string: path, relativeTo: originURL)?.absoluteURL
    }

    func stop() {
        listener.cancel()
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }

            let requestData = accumulatedData + (data ?? Data())
            let headerEnd = Data("\r\n\r\n".utf8)
            guard let range = requestData.range(of: headerEnd) else {
                guard !isComplete else {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, accumulatedData: requestData)
                return
            }

            let header = String(decoding: requestData[..<range.lowerBound], as: UTF8.self)
            let requestLine = header.components(separatedBy: "\r\n").first ?? ""
            let pathAndQuery = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            self.record(path: path)
            self.sendResponse(for: path, on: connection)
        }
    }

    private func record(path: String) {
        lock.lock()
        requestCounts[path, default: 0] += 1
        lock.unlock()
    }

    private func recordConnection() {
        lock.lock()
        acceptedConnectionCount += 1
        lock.unlock()
    }

    private func sendResponse(for path: String, on connection: NWConnection) {
        let contentType: String
        let body: Data
        switch path {
        case "/captured/style.css":
            contentType = "text/css; charset=utf-8"
            body = Data(
                "@font-face{font-family:PreviewFixture;src:url('fixture.woff2') format('woff2')}body{font-family:PreviewFixture}"
                    .utf8)
        case "/second/style.css":
            contentType = "text/css; charset=utf-8"
            body = Data(
                "@font-face{font-family:SecondPreview;src:url('font.woff2') format('woff2')}body{font-family:SecondPreview}"
                    .utf8)
        case "/fixture.png":
            contentType = "image/png"
            body = Data([137, 80, 78, 71, 13, 10, 26, 10])
        case "/captured/fixture.woff2":
            contentType = "font/woff2"
            body = Data([0, 1, 2, 3])
        case "/second/image.png":
            contentType = "image/png"
            body = Data([137, 80, 78, 71, 13, 10, 26, 10])
        case "/second/font.woff2":
            contentType = "font/woff2"
            body = Data([0, 1, 2, 3])
        case "/script.js":
            contentType = "text/javascript; charset=utf-8"
            body = Data("document.body.dataset.executed = 'true';".utf8)
        default:
            contentType = "text/html; charset=utf-8"
            body = Data("<!doctype html><p>Loopback fixture</p>".utf8)
        }

        let headers = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8
        )
        connection.send(content: headers + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum FixtureError: Error {
        case missingPort
        case listenerFailed
        case startupTimedOut
        case invalidBaseURL
    }

    private final class ListenerStartup: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<UInt16, FixtureError>?

        func complete(_ result: Result<UInt16, FixtureError>) {
            lock.lock()
            guard case nil = self.result else {
                lock.unlock()
                return
            }
            self.result = result
            lock.unlock()
            semaphore.signal()
        }

        func wait() throws -> UInt16 {
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                throw FixtureError.startupTimedOut
            }

            lock.lock()
            defer { lock.unlock() }
            guard let result else { throw FixtureError.listenerFailed }
            return try result.get()
        }
    }
}
