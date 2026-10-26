import AppKit
import PostieCore
import SwiftUI
import XCTest
@testable import PostieApp

@MainActor
final class BodySourceTextDisplayTests: XCTestCase {
    func testWrapPreferenceChangesHostedNativeLineLayout() throws {
        let wrappedWindow = makeWindow(wrapsText: true)
        defer { wrappedWindow.close() }
        layout(wrappedWindow)

        let wrappedContentView = try XCTUnwrap(wrappedWindow.contentView)
        let wrappedTextView = try XCTUnwrap(findTextView(in: wrappedContentView))
        XCTAssertNotNil(wrappedTextView.textLayoutManager)
        XCTAssertGreaterThan(lineCount(in: wrappedTextView), 1)

        let unwrappedWindow = makeWindow(wrapsText: false)
        defer { unwrappedWindow.close() }
        layout(unwrappedWindow)

        let unwrappedContentView = try XCTUnwrap(unwrappedWindow.contentView)
        let unwrappedTextView = try XCTUnwrap(findTextView(in: unwrappedContentView))
        XCTAssertNotNil(unwrappedTextView.textLayoutManager)
        XCTAssertEqual(lineCount(in: unwrappedTextView), 1)

        let overflowingScrollView = try XCTUnwrap(findOverflowingScrollView(in: unwrappedContentView))
        let documentView = try XCTUnwrap(overflowingScrollView.documentView)
        XCTAssertGreaterThan(
            documentView.frame.width,
            overflowingScrollView.contentView.bounds.width
        )
    }

    private func makeWindow(wrapsText: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: BodySourceTextDisplay(
                text: String(repeating: "word ", count: 100),
                syntax: .none,
                wrapsText: wrapsText
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func lineCount(in textView: NSTextView) -> Int {
        guard let textLayoutManager = textView.textLayoutManager else {
            return 0
        }

        var count = 0
        _ = textLayoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            count += fragment.textLineFragments.count
            return true
        }
        return count
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func findOverflowingScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
            let documentView = scrollView.documentView,
            documentView.frame.width > scrollView.contentView.bounds.width + 1
        {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = findOverflowingScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func layout(_ window: NSWindow) {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
