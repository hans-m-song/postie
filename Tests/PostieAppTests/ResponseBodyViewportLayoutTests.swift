import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import PostieApp

@MainActor
final class ResponseBodyViewportLayoutTests: XCTestCase {
    func testPreviewUsesTheHeightBelowItsContentAndPadding() {
        XCTAssertEqual(
            ResponseBodyViewportSizing.height(
                viewportHeight: 760,
                previewTop: 320,
                contentPadding: 16,
                previewBottomInset: 12
            ),
            396
        )
    }

    func testPreviewRetainsMinimumHeightWhenHeadersCrowdTheViewport() {
        XCTAssertEqual(
            ResponseBodyViewportSizing.height(
                viewportHeight: 480,
                previewTop: 390,
                contentPadding: 16,
                previewBottomInset: 12
            ),
            ResponseBodyViewportSizing.minimumHeight
        )
    }

    func testPreviewHeightGrowsWithViewportHeight() {
        let shorter = ResponseBodyViewportSizing.height(
            viewportHeight: 700,
            previewTop: 220,
            contentPadding: 16,
            previewBottomInset: 12
        )
        let taller = ResponseBodyViewportSizing.height(
            viewportHeight: 900,
            previewTop: 220,
            contentPadding: 16,
            previewBottomInset: 12
        )

        XCTAssertEqual(taller - shorter, 200)
    }

    func testHostedHTMLPreviewGrowsWhenNativeWindowResizes() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: HTMLPreviewWindowFixture())
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let webView = try XCTUnwrap(waitForWebView(in: window))
        let shorterHeight = webView.bounds.height
        XCTAssertGreaterThanOrEqual(shorterHeight, ResponseBodyViewportSizing.minimumHeight)

        window.setContentSize(NSSize(width: 720, height: 1_200))
        layout(window)

        let tallerHeight = webView.bounds.height
        XCTAssertGreaterThan(tallerHeight, shorterHeight + 250)

        let scrollView = try XCTUnwrap(findResponseScrollView(in: hostingView))
        let clipView = scrollView.contentView
        let oldOrigin = clipView.bounds.origin
        clipView.scroll(to: NSPoint(x: oldOrigin.x, y: oldOrigin.y + 60))
        scrollView.reflectScrolledClipView(clipView)
        layout(window)

        XCTAssertGreaterThan(clipView.bounds.origin.y, oldOrigin.y)
        XCTAssertEqual(webView.bounds.height, tallerHeight, accuracy: 1)
        window.setContentSize(NSSize(width: 720, height: 300))
        layout(window)
        XCTAssertGreaterThan(webView.bounds.height, 0)
        XCTAssertLessThan(webView.bounds.height, ResponseBodyViewportSizing.minimumHeight)
    }

    private func waitForWebView(in window: NSWindow) -> WKWebView? {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            layout(window)
            if let contentView = window.contentView, let webView = findWebView(in: contentView) {
                return webView
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return nil
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }

    private func findResponseScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
            let documentView = scrollView.documentView,
            documentView.bounds.height > scrollView.contentView.bounds.height + 60
        {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findResponseScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func layout(_ window: NSWindow) {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }
}

@MainActor
private struct HTMLPreviewWindowFixture: View {
    var body: some View {
        ResponseBodyViewportScrollView(contentPadding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Synthetic response headers")
                    .frame(height: 400)
                HTMLBodyPreview(html: "<!doctype html><title>Preview</title><p>Local fixture</p>", baseURL: nil)
                Color.clear
                    .frame(height: 600)
            }
        }
    }
}
