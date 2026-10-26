import AppKit
import PostieCore
import SwiftUI
import XCTest
@testable import PostieApp

@MainActor
final class ResponseTextViewportTests: XCTestCase {
    func testWrappedDocumentKeepsNativeViewportHeightIndependentOfSource() async throws {
        let window = makeWindow(text: "[]", syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeInitialTextView = await waitForTextView(in: window, matching: "[]")
        let initialTextView = try XCTUnwrap(maybeInitialTextView)
        let initialScrollView = try XCTUnwrap(findScrollView(containing: initialTextView, in: hostingView))
        let viewportHeight = initialScrollView.contentView.bounds.height

        let text = Self.largePrettyJSON
        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .json, wrapsText: true)
        let maybeTextView = await waitForTextView(in: window, matching: text)
        let textView = try XCTUnwrap(maybeTextView)
        layout(window)

        let scrollView = try XCTUnwrap(findScrollView(containing: textView, in: hostingView))
        let documentView = try XCTUnwrap(scrollView.documentView)
        XCTAssertNotNil(textView.textLayoutManager)
        XCTAssertEqual(scrollView.contentView.bounds.height, viewportHeight, accuracy: 1)
        XCTAssertGreaterThan(documentView.bounds.height, viewportHeight * 8)
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.textStorage?.length, (text as NSString).length)
    }

    func testMinifiedLongLineKeepsAstralUTF16OffsetsAndSyntaxColor() async throws {
        let prefix = "{\"payload\":\""
        let astral = "🙂"
        let marker = "visible-string-marker"
        let suffix = astral + marker + "\"}"
        let boundaryLength = ResponseTextInputPolicy.maximumLogicalLineUTF16Length
        let payloadLength = boundaryLength - ((prefix + suffix) as NSString).length
        let text = prefix + String(repeating: "x", count: payloadLength) + suffix
        let source = text as NSString
        let astralRange = source.range(of: astral)
        let markerRange = source.range(of: marker)
        XCTAssertNotEqual(astralRange.location, NSNotFound)
        XCTAssertNotEqual(markerRange.location, NSNotFound)
        XCTAssertEqual(NSMaxRange(astralRange), markerRange.location)
        XCTAssertEqual(source.length, boundaryLength)
        XCTAssertLessThan(text.utf8.count, SyntaxHighlighting.maximumInputBytes)

        let window = makeWindow(text: text, syntax: .json, wrapsText: false)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: text)
        let textView = try XCTUnwrap(maybeTextView)
        let scrollView = try XCTUnwrap(findScrollView(containing: textView, in: hostingView))
        XCTAssertTrue(hasHorizontalOverflow(for: textView, in: hostingView))
        XCTAssertEqual(textView.textStorage?.length, source.length)

        let expectedColor = SyntaxHighlighting.Color.jsonString.appKitColor
        let actualColor = await waitForForegroundColor(
            expectedColor,
            atUTF16Offset: markerRange.location,
            in: textView
        )
        XCTAssertTrue(actualColor?.isEqual(expectedColor) == true)
        XCTAssertTrue(hasForegroundColor(expectedColor, atUTF16Offset: markerRange.location, in: textView))
        XCTAssertTrue(
            hasForegroundColor(
                expectedColor,
                atUTF16Offset: NSMaxRange(astralRange),
                in: textView
            ),
            "Expected the syntax color to remain correct after the astral UTF-16 range \(NSStringFromRange(astralRange))"
        )

        let initialOrigin = scrollView.contentView.bounds.origin.x
        textView.scrollRangeToVisible(NSRange(location: markerRange.location, length: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(window, milliseconds: 250)
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, initialOrigin + 100)
        XCTAssertEqual(textView.string, text)
        XCTAssertTrue(hasForegroundColor(expectedColor, atUTF16Offset: markerRange.location, in: textView))
    }

    func testOverlongLineStaysPlainAndReadableThenSmallReplacementResumesHighlighting() async throws {
        let marker = "🙂scroll-marker"
        let text = "{\"payload\":\"" + String(repeating: "x", count: 40_000) + marker + "\"}"
        let source = text as NSString
        let selection = source.range(of: marker)
        let scrollTarget = source.range(of: "scroll-marker")
        XCTAssertGreaterThan(source.length, ResponseTextInputPolicy.maximumLogicalLineUTF16Length)
        XCTAssertLessThan(text.utf8.count, SyntaxHighlighting.maximumInputBytes)
        guard selection.location != NSNotFound, scrollTarget.location != NSNotFound else {
            XCTFail("Expected the astral selection and scroll marker in the long response")
            return
        }

        let window = makeWindow(text: text, syntax: .json, wrapsText: false)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: text)
        let textView = try XCTUnwrap(maybeTextView)
        let scrollView = try XCTUnwrap(findScrollView(containing: textView, in: hostingView))
        let pauseLabel = "Syntax highlighting paused because a line exceeds 20,000 UTF-16 code units."
        let pauseLabelIsVisible = await waitForAccessibilityLabel(
            pauseLabel,
            in: try XCTUnwrap(window.contentView)
        )
        XCTAssertTrue(pauseLabelIsVisible)
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.textStorage?.string, text)
        XCTAssertEqual(textView.textStorage?.length, source.length)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(hasHorizontalOverflow(for: textView, in: hostingView))
        XCTAssertTrue(coloredForegroundRanges(in: textView).isEmpty)
        XCTAssertTrue(hasForegroundColor(NSColor.textColor, atUTF16Offset: selection.location, in: textView))

        textView.setSelectedRange(selection)
        XCTAssertEqual(textView.selectedRange(), selection)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        let copiedText =
            pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        XCTAssertEqual(copiedText, source.substring(with: selection))

        let initialHorizontalOrigin = scrollView.contentView.bounds.origin.x
        textView.scrollRangeToVisible(scrollTarget)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        await settle(window, milliseconds: 250)
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, initialHorizontalOrigin + 100)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertEqual(textView.string, text)

        let recoveredText = "{\n  \"recovered\": true,\n  \"astral\": \"🙂\"\n}"
        let recoveredSource = recoveredText as NSString
        let recoveredKey = recoveredSource.range(of: "\"recovered\"")
        hostingView.rootView = ResponseTextViewportFixture(
            text: recoveredText,
            syntax: .json,
            wrapsText: true
        )
        layout(window)
        let maybeRecoveredTextView = await waitForTextView(in: window, matching: recoveredText)
        let recoveredTextView = try XCTUnwrap(maybeRecoveredTextView)
        let recoveredKeyColor = SyntaxHighlighting.Color.jsonKey.appKitColor
        let contentView = try XCTUnwrap(window.contentView)
        let replacementRecovered = await waitForCondition(timeoutSeconds: 5) {
            hasForegroundColor(recoveredKeyColor, atUTF16Offset: recoveredKey.location, in: recoveredTextView)
                && !hasVisibleAccessibilityLabel(pauseLabel, in: contentView)
        }
        XCTAssertTrue(replacementRecovered)
        XCTAssertEqual(recoveredTextView.string, recoveredText)
        XCTAssertEqual(recoveredTextView.textStorage?.string, recoveredText)
        XCTAssertTrue(hasForegroundColor(NSColor.textColor, atUTF16Offset: 0, in: recoveredTextView))
    }

    func testHighlightingPreservesAstralSelectionAndExactPlainCopyAcrossWrapChange() async throws {
        let repeatedText = String(repeating: "long-response-token ", count: 40)
        let text = "{\"message\":\"🙂 copy-marker \(repeatedText) selection-marker\", \"value\":1}"
        let selection = (text as NSString).range(of: "🙂 copy-marker long-response-token ")
        XCTAssertNotEqual(selection.location, NSNotFound)

        let window = makeWindow(text: "[]", syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: "[]")
        let textView = try XCTUnwrap(maybeTextView)
        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .json, wrapsText: true)
        layout(window)
        XCTAssertEqual(textView.string, text)
        textView.setSelectedRange(selection)

        let expectedColor = SyntaxHighlighting.Color.jsonString.appKitColor
        let actualColor = await waitForForegroundColor(
            expectedColor,
            atUTF16Offset: selection.location,
            in: textView
        )
        XCTAssertTrue(actualColor?.isEqual(expectedColor) == true)
        await settle(window, milliseconds: 200)
        XCTAssertEqual(textView.selectedRange(), selection)

        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .json, wrapsText: false)
        let maybeUnwrappedTextView = await waitForTextView(in: window, matching: text)
        let unwrappedTextView = try XCTUnwrap(maybeUnwrappedTextView)
        XCTAssertEqual(unwrappedTextView.string, text)
        XCTAssertEqual(unwrappedTextView.selectedRange(), selection)
        XCTAssertTrue(hasHorizontalOverflow(for: unwrappedTextView, in: hostingView))
        XCTAssertTrue(hasForegroundColor(expectedColor, atUTF16Offset: selection.location, in: unwrappedTextView))

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(
            unwrappedTextView.writeSelection(to: pasteboard, types: unwrappedTextView.writablePasteboardTypes)
        )
        let copiedText =
            pasteboard.string(forType: .string)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
        XCTAssertEqual(copiedText, (text as NSString).substring(with: selection))
    }

    func testHighlightingResumesAfterContinualViewportResizesStop() async throws {
        let rows = (0..<1_000).map { "{\"key-\($0)\":\($0)}" }
        let text = "[\n" + rows.joined(separator: ",\n") + "\n]"
        let lastKey = (text as NSString).range(of: "\"key-999\"")

        let window = makeWindow(text: "[]", syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: "[]")
        let textView = try XCTUnwrap(maybeTextView)
        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .json, wrapsText: true)
        layout(window)

        let keyColor = SyntaxHighlighting.Color.jsonKey.appKitColor
        let deadline = Date(timeIntervalSinceNow: 0.4)
        var resizeCount = 0
        while Date() < deadline {
            let width: CGFloat = resizeCount.isMultiple(of: 2) ? 440 : 460
            window.setContentSize(NSSize(width: width, height: 240))
            layout(window)
            resizeCount += 1
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(15))
        }

        XCTAssertGreaterThan(resizeCount, 10)
        let lateTokenColor = await waitForForegroundColor(
            keyColor,
            atUTF16Offset: lastKey.location,
            in: textView,
            timeoutSeconds: 2
        )
        XCTAssertTrue(lateTokenColor?.isEqual(keyColor) == true)
        XCTAssertEqual(textView.string, text)
    }

    func testSyntaxNoneClearsRetainedColorsWithoutReplacingText() async throws {
        let text = "\"quoted response string 🙂\""
        let window = makeWindow(text: text, syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: text)
        let textView = try XCTUnwrap(maybeTextView)
        let stringColor = SyntaxHighlighting.Color.jsonString.appKitColor
        let initialColor = await waitForForegroundColor(stringColor, atUTF16Offset: 0, in: textView)
        XCTAssertTrue(initialColor?.isEqual(stringColor) == true)

        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .none, wrapsText: true)
        layout(window)
        let cleared = await waitForCondition(timeoutSeconds: 5) {
            coloredForegroundRanges(in: textView).isEmpty
        }
        XCTAssertTrue(cleared)
        XCTAssertTrue(hasForegroundColor(NSColor.textColor, atUTF16Offset: 0, in: textView))
        await settle(window, milliseconds: 200)
        XCTAssertTrue(coloredForegroundRanges(in: textView).isEmpty)
        XCTAssertEqual(textView.string, text)
    }

    func testRapidReplacementCancelsUnfinishedBatchesAndRestoresBaseColor() async throws {
        let rows = (0..<1_500).map { "{\"key-\($0)\":\($0)}" }
        let initialText = "\"seed\"\n[\n" + rows.joined(separator: ",\n") + "\n]"
        let initialSource = initialText as NSString
        let firstKey = initialSource.range(of: "\"key-0\"")
        let lastKey = initialSource.range(of: "\"key-1499\"")
        XCTAssertNotEqual(firstKey.location, NSNotFound)
        XCTAssertNotEqual(lastKey.location, NSNotFound)

        let window = makeWindow(text: "[]", syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: "[]")
        let textView = try XCTUnwrap(maybeTextView)
        hostingView.rootView = ResponseTextViewportFixture(text: initialText, syntax: .json, wrapsText: true)
        layout(window)

        let keyColor = SyntaxHighlighting.Color.jsonKey.appKitColor
        let stringColor = SyntaxHighlighting.Color.jsonString.appKitColor
        let baseColor = NSColor.textColor
        let observedPartialApplication = await waitForCondition(timeoutSeconds: 5) {
            hasForegroundColor(stringColor, atUTF16Offset: 0, in: textView)
                && hasForegroundColor(keyColor, atUTF16Offset: firstKey.location, in: textView)
                && hasForegroundColor(baseColor, atUTF16Offset: lastKey.location, in: textView)
        }
        XCTAssertTrue(
            observedPartialApplication,
            "Expected production highlighting to yield with an early token applied and a late token pending"
        )
        XCTAssertTrue(hasForegroundColor(stringColor, atUTF16Offset: 0, in: textView))

        let replacementText = String(repeating: "x", count: initialSource.length)
        XCTAssertEqual((replacementText as NSString).length, initialSource.length)
        hostingView.rootView = ResponseTextViewportFixture(text: replacementText, syntax: .none, wrapsText: true)
        layout(window)
        XCTAssertEqual(textView.string, replacementText)

        let cleared = await waitForCondition(timeoutSeconds: 5) {
            coloredForegroundRanges(in: textView).isEmpty
        }
        XCTAssertTrue(cleared, "Expected syntax replacement to restore base color across the current document")
        await settle(window, milliseconds: 450)
        XCTAssertTrue(
            coloredForegroundRanges(in: textView).isEmpty,
            "Expected cancelled JSON batches to remain cancelled after their original work interval"
        )
        XCTAssertTrue(hasForegroundColor(NSColor.textColor, atUTF16Offset: 0, in: textView))
        XCTAssertEqual(textView.string, replacementText)
    }

    func testOversizedResponseRemainsReadableWhenHighlightingPauses() async throws {
        let line = String(repeating: "x", count: 512) + "\n"
        let text = String(repeating: line, count: SyntaxHighlighting.maximumInputBytes / line.utf8.count + 2)
        XCTAssertGreaterThan(text.utf8.count, SyntaxHighlighting.maximumInputBytes)

        let window = makeWindow(text: text, syntax: .xml, wrapsText: true)
        defer { window.close() }
        await activate(window)

        let maybeTextView = await waitForTextView(in: window, matching: text)
        let textView = try XCTUnwrap(maybeTextView)
        let pausedLabelIsVisible = await waitForAccessibilityLabel(
            "Syntax highlighting paused because the text exceeds 1 MiB",
            in: try XCTUnwrap(window.contentView)
        )
        XCTAssertTrue(pausedLabelIsVisible)
        XCTAssertEqual(textView.string, text)
        XCTAssertTrue(coloredForegroundRanges(in: textView).isEmpty)
        XCTAssertTrue(hasForegroundColor(NSColor.textColor, atUTF16Offset: 0, in: textView))
    }

    func testDismantlingDuringHighlightingReleasesViewportTextView() async throws {
        let textViewReference = try await closeWindowDuringPartialHighlighting()
        let released = await waitForRelease(of: textViewReference, timeoutSeconds: 5)
        XCTAssertTrue(released, "Expected dismantled highlighting work not to retain the native text view")
    }

    private func closeWindowDuringPartialHighlighting() async throws -> WeakViewReference {
        let rows = (0..<1_000).map { "{\"key-\($0)\":\($0)}" }
        let text = "[\n" + rows.joined(separator: ",\n") + "\n]"
        let source = text as NSString
        let firstKey = source.range(of: "\"key-0\"")
        let lastKey = source.range(of: "\"key-999\"")

        let window = makeWindow(text: "[]", syntax: .json, wrapsText: true)
        defer { window.close() }
        await activate(window)
        let hostingView = try XCTUnwrap(window.contentView as? NSHostingView<ResponseTextViewportFixture>)
        let maybeTextView = await waitForTextView(in: window, matching: "[]")
        let textView = try XCTUnwrap(maybeTextView)
        hostingView.rootView = ResponseTextViewportFixture(text: text, syntax: .json, wrapsText: true)
        layout(window)

        let keyColor = SyntaxHighlighting.Color.jsonKey.appKitColor
        let baseColor = NSColor.textColor
        let observedPartialApplication = await waitForCondition(timeoutSeconds: 5) {
            hasForegroundColor(keyColor, atUTF16Offset: firstKey.location, in: textView)
                && hasForegroundColor(baseColor, atUTF16Offset: lastKey.location, in: textView)
        }
        XCTAssertTrue(observedPartialApplication)

        let reference = WeakViewReference(textView)
        window.contentView = nil
        window.close()
        return reference
    }

    private func makeWindow(text: String, syntax: BodySyntax, wrapsText: Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ResponseTextViewportFixture(text: text, syntax: syntax, wrapsText: wrapsText)
        )
        window.makeKeyAndOrderFront(nil)
        return window
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

    private func waitForForegroundColor(
        _ expectedColor: NSColor,
        atUTF16Offset offset: Int,
        in textView: NSTextView,
        timeoutSeconds: TimeInterval = 5
    ) async -> NSColor? {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            let actualColor = foregroundColor(atUTF16Offset: offset, in: textView)
            if actualColor?.isEqual(expectedColor) == true { return actualColor }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return foregroundColor(atUTF16Offset: offset, in: textView)
    }

    private func waitForAccessibilityLabel(_ label: String, in view: NSView) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if hasVisibleAccessibilityLabel(label, in: view) { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hasVisibleAccessibilityLabel(label, in: view)
    }

    private func hasVisibleAccessibilityLabel(
        _ label: String,
        in view: NSView,
        ancestorsAreVisible: Bool = true
    ) -> Bool {
        let viewIsVisible = ancestorsAreVisible && !view.isHidden
        if viewIsVisible, view.accessibilityLabel() == label { return true }
        return view.subviews.contains {
            hasVisibleAccessibilityLabel(label, in: $0, ancestorsAreVisible: viewIsVisible)
        }
    }

    private func waitForRelease(of reference: WeakViewReference, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            if reference.view == nil { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return reference.view == nil
    }

    private func activate(_ window: NSWindow) async {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle(window, milliseconds: 100)
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

    private func foregroundColor(atUTF16Offset offset: Int, in textView: NSTextView) -> NSColor? {
        guard let storage = textView.textStorage, offset >= 0, offset < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    private func hasForegroundColor(
        _ expectedColor: NSColor,
        atUTF16Offset offset: Int,
        in textView: NSTextView
    ) -> Bool {
        foregroundColor(atUTF16Offset: offset, in: textView)?.isEqual(expectedColor) == true
    }

    private func coloredForegroundRanges(in textView: NSTextView) -> [NSRange] {
        guard let storage = textView.textStorage else { return [] }
        let baseColor = NSColor.textColor
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let color = value as? NSColor, !color.isEqual(baseColor) else { return }
            ranges.append(range)
        }
        return ranges
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

    private func findScrollView(containing textView: NSTextView, in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
            let documentView = scrollView.documentView,
            contains(textView, in: documentView)
        {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(containing: textView, in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func contains(_ target: NSView, in view: NSView) -> Bool {
        if view === target { return true }
        return view.subviews.contains { contains(target, in: $0) }
    }

    private func hasHorizontalOverflow(for textView: NSTextView, in view: NSView) -> Bool {
        if let scrollView = view as? NSScrollView,
            let documentView = scrollView.documentView,
            contains(textView, in: documentView),
            documentView.bounds.width > scrollView.contentView.bounds.width + 1
        {
            return true
        }
        return view.subviews.contains { hasHorizontalOverflow(for: textView, in: $0) }
    }

    private static let largePrettyJSON: String = {
        let rows = (0..<1_500).map { index in
            "  { \"index\": \(index), \"message\": \"synthetic response row\" }"
        }
        return "[\n" + rows.joined(separator: ",\n") + "\n]"
    }()
}

@MainActor
private final class WeakViewReference {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}

@MainActor
private struct ResponseTextViewportFixture: View {
    let text: String
    let syntax: BodySyntax
    let wrapsText: Bool

    var body: some View {
        BodySourceTextDisplay(text: text, syntax: syntax, wrapsText: wrapsText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
