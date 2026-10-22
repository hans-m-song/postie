import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PostieApp

@MainActor
final class WorkspacePaletteSearchFieldTests: XCTestCase {
    func testPrefilledPrefixStartsWithCaretAtEndAndAcceptsTypingAfterIt() async throws {
        let state = SearchTextState("@")
        let callbacks = SearchCallbacks()
        let mounted = makeMountedField(state: state, callbacks: callbacks)
        defer { mounted.close() }

        let editor = try await waitForCaret(in: mounted, atUTF16Offset: 1, text: "@")
        editor.insertText("requests" as NSString, replacementRange: editor.selectedRange())

        XCTAssertEqual(editor.string, "@requests")
        XCTAssertEqual(state.value, "@requests")
    }

    func testNewFocusRevisionReplacesQueryAndMovesCaretWhileAlreadyFocused() async throws {
        let state = SearchTextState("@requests")
        let callbacks = SearchCallbacks()
        let mounted = makeMountedField(state: state, callbacks: callbacks)
        defer { mounted.close() }
        _ = try await waitForCaret(in: mounted, atUTF16Offset: 9, text: "@requests")

        let nextFocusRequestID = UUID()
        state.value = ">"
        mounted.update(text: state.binding, focusRequestID: nextFocusRequestID, callbacks: callbacks)

        let editor = try await waitForCaret(in: mounted, atUTF16Offset: 1, text: ">")
        editor.insertText("settings" as NSString, replacementRange: editor.selectedRange())

        XCTAssertEqual(editor.string, ">settings")
        XCTAssertEqual(state.value, ">settings")
    }

    func testOrdinaryRepresentableUpdatePreservesEditingSelection() async throws {
        let state = SearchTextState("request")
        let callbacks = SearchCallbacks()
        let mounted = makeMountedField(state: state, callbacks: callbacks)
        defer { mounted.close() }
        let editor = try await waitForCaret(in: mounted, atUTF16Offset: 7, text: "request")

        let selection = NSRange(location: 1, length: 3)
        editor.setSelectedRange(selection)
        mounted.update(
            text: state.binding,
            focusRequestID: mounted.focusRequestID,
            callbacks: callbacks
        )
        XCTAssertEqual(editor.selectedRange(), selection)

        editor.insertText("X" as NSString, replacementRange: editor.selectedRange())
        mounted.update(
            text: state.binding,
            focusRequestID: mounted.focusRequestID,
            callbacks: callbacks
        )

        XCTAssertEqual(editor.string, "rXest")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(state.value, "rXest")
    }

    func testCaretUsesUtf16LengthForEmojiQuery() async throws {
        let state = SearchTextState("$🚀")
        let callbacks = SearchCallbacks()
        let mounted = makeMountedField(state: state, callbacks: callbacks)
        defer { mounted.close() }

        let editor = try await waitForCaret(in: mounted, atUTF16Offset: state.value.utf16.count, text: "$🚀")

        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testPaletteKeysDelegateCallbacksAndMarkedTextKeepsInputMethodControl() async throws {
        let state = SearchTextState("query")
        let callbacks = SearchCallbacks()
        let mounted = makeMountedField(state: state, callbacks: callbacks)
        defer { mounted.close() }
        let editor = try await waitForCaret(in: mounted, atUTF16Offset: 5, text: "query")

        XCTAssertTrue(
            mounted.coordinator.control(
                mounted.textField,
                textView: editor,
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            ))
        XCTAssertTrue(
            mounted.coordinator.control(
                mounted.textField,
                textView: editor,
                doCommandBy: #selector(NSResponder.moveUp(_:))
            ))
        XCTAssertTrue(
            mounted.coordinator.control(
                mounted.textField,
                textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:))
            ))
        XCTAssertTrue(
            mounted.coordinator.control(
                mounted.textField,
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ))
        XCTAssertFalse(
            mounted.coordinator.control(
                mounted.textField,
                textView: editor,
                doCommandBy: NSSelectorFromString("moveToBeginningOfLine:")
            ))
        XCTAssertEqual(callbacks.submitCount, 1)
        XCTAssertEqual(callbacks.moves, [-1, 1])
        XCTAssertEqual(callbacks.cancelCount, 1)

        editor.setMarkedText(
            "候補" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.cancelOperation(_:)),
        ] {
            XCTAssertFalse(
                mounted.coordinator.control(
                    mounted.textField,
                    textView: editor,
                    doCommandBy: selector
                ))
        }
        XCTAssertEqual(callbacks.submitCount, 1)
        XCTAssertEqual(callbacks.moves, [-1, 1])
        XCTAssertEqual(callbacks.cancelCount, 1)
    }

    func testArrowFunctionFlagsStayWithPaletteAndTextSelectionShortcutsPassThrough() {
        XCTAssertTrue(
            WorkspacePaletteSearchField.Coordinator.shouldHandlePaletteCommand(
                #selector(NSResponder.moveUp(_:)),
                modifiers: [.function, .numericPad]
            ))
        XCTAssertTrue(
            WorkspacePaletteSearchField.Coordinator.shouldHandlePaletteCommand(
                #selector(NSResponder.moveDown(_:)),
                modifiers: .function
            ))
        XCTAssertFalse(
            WorkspacePaletteSearchField.Coordinator.shouldHandlePaletteCommand(
                #selector(NSResponder.moveUp(_:)),
                modifiers: .shift
            ))
        XCTAssertFalse(
            WorkspacePaletteSearchField.Coordinator.shouldHandlePaletteCommand(
                #selector(NSResponder.insertNewline(_:)),
                modifiers: .command
            ))
    }

    private func makeMountedField(state: SearchTextState, callbacks: SearchCallbacks) -> MountedSearchField {
        _ = NSApplication.shared
        let focusRequestID = UUID()
        let field = WorkspacePaletteSearchField(
            text: state.binding,
            focusRequestID: focusRequestID,
            onSubmit: { callbacks.submitCount += 1 },
            onMove: { callbacks.moves.append($0) },
            onCancel: { callbacks.cancelCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let textField = coordinator.makeNativeTextField()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        textField.frame = NSRect(x: 0, y: 0, width: 420, height: 36)
        window.contentView = textField
        return MountedSearchField(
            state: state,
            callbacks: callbacks,
            focusRequestID: focusRequestID,
            coordinator: coordinator,
            textField: textField,
            window: window
        )
    }

    private func waitForCaret(
        in mounted: MountedSearchField,
        atUTF16Offset offset: Int,
        text expectedText: String
    ) async throws -> NSTextView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let editor = mounted.textField.currentEditor() as? NSTextView,
                mounted.window.firstResponder === editor,
                editor.string == expectedText,
                editor.selectedRange() == NSRange(location: offset, length: 0)
            {
                return editor
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SearchFieldTestError.caretDidNotReachExpectedPosition
    }
}

@MainActor
private final class SearchTextState {
    var value: String

    init(_ value: String) {
        self.value = value
    }

    var binding: Binding<String> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private final class SearchCallbacks {
    var submitCount = 0
    var moves: [Int] = []
    var cancelCount = 0
}

@MainActor
private struct MountedSearchField {
    let state: SearchTextState
    let callbacks: SearchCallbacks
    private(set) var focusRequestID: UUID
    let coordinator: WorkspacePaletteSearchField.Coordinator
    let textField: WorkspacePaletteSearchNSTextField
    let window: NSWindow

    func update(text: Binding<String>, focusRequestID: UUID, callbacks: SearchCallbacks) {
        coordinator.update(
            text: text,
            focusRequestID: focusRequestID,
            onSubmit: { callbacks.submitCount += 1 },
            onMove: { callbacks.moves.append($0) },
            onCancel: { callbacks.cancelCount += 1 },
            in: textField
        )
    }

    func close() {
        window.close()
        coordinator.detach(from: textField)
    }
}

private enum SearchFieldTestError: Error {
    case caretDidNotReachExpectedPosition
}
