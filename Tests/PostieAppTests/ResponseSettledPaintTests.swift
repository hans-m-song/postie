import AppKit
import PostieCore
import SwiftUI
import XCTest
@testable import PostieApp

@MainActor
final class ResponseSettledPaintTests: XCTestCase {
    func testProductionColorsSurviveScrollSettlementWhileTargetIsOffscreen() async throws {
        let text = Self.prettyJSON
        let source = text as NSString
        let keyRange = source.range(of: "\"settledPaintKey\"")
        let valueRange = source.range(of: "\"visible-after-scroll\"")
        let firstKeyRange = source.range(of: "\"rowKey\"")
        guard keyRange.location != NSNotFound,
            valueRange.location != NSNotFound,
            firstKeyRange.location != NSNotFound,
            keyRange.location > 0
        else {
            XCTFail("Expected synthetic response tokens")
            return
        }
        XCTAssertGreaterThan(keyRange.location, 4 * 1024)
        XCTAssertGreaterThan(text.utf8.count, 64 * 1024)

        let window = makeWindow()
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseSettledPaintFixture>)
        let maybeInitialTextView = await waitForTextView(in: window, matching: "[]")
        _ = try XCTUnwrap(maybeInitialTextView)
        hostingView.rootView = ResponseSettledPaintFixture(text: text)
        let maybeReplacedTextView = await waitForTextView(in: window, matching: text)
        let replacedTextView = try XCTUnwrap(maybeReplacedTextView)
        let scrollView = try XCTUnwrap(replacedTextView.enclosingScrollView)
        XCTAssertEqual(replacedTextView.string, text)
        XCTAssertNotNil(replacedTextView.textLayoutManager)

        let keyColor = SyntaxHighlighting.Color.jsonKey.appKitColor
        let valueColor = SyntaxHighlighting.Color.jsonString.appKitColor
        let baseColor = NSColor.textColor
        let targetColorsAreInstalled = await waitForCondition(timeoutSeconds: 5) {
            hasStorageColor(keyColor, at: keyRange.location, in: replacedTextView)
                && hasStorageColor(valueColor, at: valueRange.location, in: replacedTextView)
                && hasStorageColor(baseColor, at: keyRange.location - 1, in: replacedTextView)
        }
        XCTAssertTrue(targetColorsAreInstalled)

        replacedTextView.scrollRangeToVisible(keyRange)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(window, milliseconds: 300)
        XCTAssertTrue(isRangeVisible(keyRange, in: replacedTextView))
        let visibleOrigin = scrollView.contentView.bounds.origin.y
        await settle(window, milliseconds: 300)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, visibleOrigin, accuracy: 1)
        XCTAssertTrue(hasRenderedPixelClose(to: keyColor, atUTF16Offset: keyRange.location + 1, in: replacedTextView))
        XCTAssertTrue(
            hasRenderedPixelClose(to: valueColor, atUTF16Offset: valueRange.location + 1, in: replacedTextView)
        )

        replacedTextView.scrollRangeToVisible(firstKeyRange)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(window, milliseconds: 300)
        XCTAssertTrue(isRangeVisible(firstKeyRange, in: replacedTextView))
        XCTAssertFalse(isRangeVisible(keyRange, in: replacedTextView))
        let awayOrigin = scrollView.contentView.bounds.origin.y
        await settle(window, milliseconds: 300)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, awayOrigin, accuracy: 1)
        XCTAssertTrue(hasStorageColor(keyColor, at: keyRange.location, in: replacedTextView))
        XCTAssertTrue(hasStorageColor(valueColor, at: valueRange.location, in: replacedTextView))
        XCTAssertTrue(hasStorageColor(baseColor, at: keyRange.location - 1, in: replacedTextView))

        replacedTextView.scrollRangeToVisible(keyRange)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(window, milliseconds: 300)
        XCTAssertTrue(isRangeVisible(keyRange, in: replacedTextView))
        let returnedOrigin = scrollView.contentView.bounds.origin.y
        await settle(window, milliseconds: 300)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, returnedOrigin, accuracy: 1)
        XCTAssertTrue(hasStorageColor(keyColor, at: keyRange.location, in: replacedTextView))
        XCTAssertTrue(hasStorageColor(valueColor, at: valueRange.location, in: replacedTextView))
        XCTAssertTrue(hasRenderedPixelClose(to: keyColor, atUTF16Offset: keyRange.location + 1, in: replacedTextView))
        XCTAssertTrue(
            hasRenderedPixelClose(to: valueColor, atUTF16Offset: valueRange.location + 1, in: replacedTextView)
        )
        XCTAssertEqual(replacedTextView.string, text)
        XCTAssertEqual(replacedTextView.textStorage?.string, text)

        replacedTextView.setSelectedRange(NSRange(location: 0, length: source.length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(
            replacedTextView.writeSelection(to: pasteboard, types: replacedTextView.writablePasteboardTypes)
        )
        let copiedText =
            pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        XCTAssertEqual(copiedText, text)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ResponseSettledPaintFixture(text: "[]"))
        window.setContentSize(NSSize(width: 800, height: 700))
        window.contentView?.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.appearance = NSAppearance(named: .darkAqua)
        return window
    }

    private func activate(_ window: NSWindow) async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle(window, milliseconds: 100)
    }

    private func waitForTextView(in window: NSWindow, matching text: String) async -> NSTextView? {
        await waitFor(in: window) {
            guard let contentView = window.contentView,
                let textView = findTextView(in: contentView),
                textView.string == text,
                textView.textLayoutManager != nil
            else {
                return nil
            }
            return textView
        }
    }

    private func waitFor<Value>(
        in window: NSWindow,
        timeoutSeconds: TimeInterval = 5,
        until value: () -> Value?
    ) async -> Value? {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            layout(window)
            if let current = value() { return current }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value()
    }

    private func waitForCondition(timeoutSeconds: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle(_ window: NSWindow, milliseconds: Int) async {
        let deadline = Date(timeIntervalSinceNow: Double(milliseconds) / 1_000)
        while Date() < deadline {
            layout(window)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
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

    private func hasStorageColor(_ expected: NSColor, at offset: Int, in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage,
            offset >= 0,
            offset < storage.length,
            let actual = storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
        else {
            return false
        }
        return actual.isEqual(expected)
    }

    private func isRangeVisible(_ range: NSRange, in textView: NSTextView) -> Bool {
        guard let window = textView.window else { return false }
        let firstCharacter = NSRange(location: range.location, length: 1)
        let screenRect = textView.firstRect(forCharacterRange: firstCharacter, actualRange: nil)
        guard !screenRect.isEmpty else { return false }
        let windowRect = window.convertFromScreen(screenRect)
        let textViewRect = textView.convert(windowRect, from: nil)
        return textView.visibleRect.intersects(textViewRect)
    }

    private func hasRenderedPixelClose(
        to expectedColor: NSColor,
        atUTF16Offset offset: Int,
        in textView: NSTextView
    ) -> Bool {
        guard let window = textView.window,
            offset >= 0,
            offset < (textView.string as NSString).length
        else {
            return false
        }
        let characterRange = NSRange(location: offset, length: 1)
        let screenRect = textView.firstRect(forCharacterRange: characterRange, actualRange: nil)
        guard !screenRect.isEmpty else { return false }
        let windowRect = window.convertFromScreen(screenRect)
        let glyphRect = textView.convert(windowRect, from: nil).intersection(textView.visibleRect)
        guard !glyphRect.isEmpty,
            let bitmap = textView.bitmapImageRepForCachingDisplay(in: glyphRect)
        else {
            return false
        }
        textView.cacheDisplay(in: glyphRect, to: bitmap)

        var targetColor: NSColor?
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            targetColor = expectedColor.usingColorSpace(.deviceRGB)
        }
        guard let target = targetColor else { return false }

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let distance = max(
                    abs(pixel.redComponent - target.redComponent),
                    abs(pixel.greenComponent - target.greenComponent),
                    abs(pixel.blueComponent - target.blueComponent)
                )
                if distance < 0.22 { return true }
            }
        }

        return false
    }

    private static var prettyJSON: String {
        let payload = String(repeating: "x", count: 72)
        let rows = (0..<900).map { index -> String in
            let object: String
            if index == 450 {
                object = "{\"settledPaintKey\": \"visible-after-scroll\", \"payload\": \"\(payload)\"}"
            } else {
                object = "{\"rowKey\": \"row-\(index)\", \"payload\": \"\(payload)\"}"
            }
            return "    \(object)\(index == 899 ? "" : ",")"
        }
        return (["{", "  \"payload\": ["] + rows + ["  ]", "}"]).joined(separator: "\n")
    }
}

@MainActor
private struct ResponseSettledPaintFixture: View {
    let text: String

    var body: some View {
        ResponseBodyViewportScrollView(contentPadding: 16, previewBottomInset: 11) {
            VStack(alignment: .leading, spacing: 14) {
                BodySourceTextDisplay(text: text, syntax: .json, wrapsText: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
