import AppKit
import SwiftUI

struct WorkspacePaletteSearchField: NSViewRepresentable {
    private static let placeholder = "Search · @ requests · # collections · > commands · $ variables"

    @Binding private var text: String
    let focusRequestID: UUID
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onCancel: () -> Void

    init(
        text: Binding<String>,
        focusRequestID: UUID,
        onSubmit: @escaping () -> Void,
        onMove: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = text
        self.focusRequestID = focusRequestID
        self.onSubmit = onSubmit
        self.onMove = onMove
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focusRequestID: focusRequestID,
            onSubmit: onSubmit,
            onMove: onMove,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> WorkspacePaletteSearchNSTextField {
        context.coordinator.makeNativeTextField()
    }

    func updateNSView(_ textField: WorkspacePaletteSearchNSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            focusRequestID: focusRequestID,
            onSubmit: onSubmit,
            onMove: onMove,
            onCancel: onCancel,
            in: textField
        )
    }

    static func dismantleNSView(_ textField: WorkspacePaletteSearchNSTextField, coordinator: Coordinator) {
        textField.delegate = nil
        textField.onWindowAttached = nil
        coordinator.detach(from: textField)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var focusRequestID: UUID
        private var onSubmit: () -> Void
        private var onMove: (Int) -> Void
        private var onCancel: () -> Void
        private var lastNativeText: String
        private var isApplyingModelText = false
        private var completedFocusRequestID: UUID?
        private var focusGeneration = 0
        private var focusTask: Task<Void, Never>?
        private weak var textField: WorkspacePaletteSearchNSTextField?

        init(
            text: Binding<String>,
            focusRequestID: UUID,
            onSubmit: @escaping () -> Void,
            onMove: @escaping (Int) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.focusRequestID = focusRequestID
            self.onSubmit = onSubmit
            self.onMove = onMove
            self.onCancel = onCancel
            lastNativeText = text.wrappedValue
        }

        func makeNativeTextField() -> WorkspacePaletteSearchNSTextField {
            let field = WorkspacePaletteSearchNSTextField(frame: .zero)
            field.delegate = self
            field.stringValue = text.wrappedValue
            field.placeholderString = WorkspacePaletteSearchField.placeholder
            field.setAccessibilityLabel(
                "Workspace search: @ requests, # collections, > commands, $ variables"
            )
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = true
            field.isSelectable = true
            field.focusRingType = .default
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.onWindowAttached = { [weak self, weak field] in
                guard let field else { return }
                self?.requestFocusIfNeeded(in: field)
            }
            textField = field
            requestFocusIfNeeded(in: field)
            return field
        }

        func update(
            text: Binding<String>,
            focusRequestID: UUID,
            onSubmit: @escaping () -> Void,
            onMove: @escaping (Int) -> Void,
            onCancel: @escaping () -> Void,
            in textField: WorkspacePaletteSearchNSTextField
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onMove = onMove
            self.onCancel = onCancel
            self.textField = textField
            textField.delegate = self
            textField.placeholderString = WorkspacePaletteSearchField.placeholder

            if self.focusRequestID != focusRequestID {
                self.focusRequestID = focusRequestID
                completedFocusRequestID = nil
                applyModelText(text.wrappedValue, to: textField, selection: .end, force: true)
                requestFocusIfNeeded(in: textField)
                return
            }

            if text.wrappedValue != lastNativeText {
                applyModelText(text.wrappedValue, to: textField, selection: .preserve, force: false)
            }
            requestFocusIfNeeded(in: textField)
        }

        func detach(from textField: WorkspacePaletteSearchNSTextField) {
            guard self.textField === textField else { return }
            focusTask?.cancel()
            focusTask = nil
            focusGeneration += 1
            self.textField = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isApplyingModelText,
                let field = notification.object as? WorkspacePaletteSearchNSTextField
            else {
                return
            }
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            lastNativeText = value
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard !textView.hasMarkedText(),
                Self.shouldHandlePaletteCommand(
                    commandSelector,
                    modifiers: NSApp.currentEvent?.modifierFlags ?? []
                )
            else {
                return false
            }

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                onMove(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMove(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }

        static func shouldHandlePaletteCommand(
            _ commandSelector: Selector,
            modifiers: NSEvent.ModifierFlags
        ) -> Bool {
            let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            guard modifiers.intersection(commandModifiers).isEmpty else { return false }
            let arrowCommands: [Selector] = [
                #selector(NSResponder.moveUp(_:)),
                #selector(NSResponder.moveDown(_:)),
            ]
            if arrowCommands.contains(commandSelector), modifiers.contains(.shift) {
                return false
            }
            return true
        }

        private func requestFocusIfNeeded(in textField: WorkspacePaletteSearchNSTextField) {
            guard textField.window != nil,
                completedFocusRequestID != focusRequestID,
                self.textField === textField
            else {
                return
            }

            focusTask?.cancel()
            focusGeneration += 1
            let generation = focusGeneration
            let requestedFocusID = focusRequestID
            focusTask = Task { @MainActor [weak self, weak textField] in
                await Task.yield()
                guard let self, let textField,
                    self.focusGeneration == generation,
                    self.focusRequestID == requestedFocusID,
                    self.textField === textField,
                    let window = textField.window
                else {
                    return
                }

                if let editor = textField.currentEditor() as? NSTextView {
                    if window.firstResponder !== editor {
                        window.makeFirstResponder(textField)
                    }
                } else {
                    window.makeFirstResponder(textField)
                }

                guard self.focusGeneration == generation,
                    self.focusRequestID == requestedFocusID,
                    let editor = textField.currentEditor() as? NSTextView
                else {
                    return
                }

                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                self.completedFocusRequestID = requestedFocusID
                self.focusTask = nil
            }
        }

        private func applyModelText(
            _ value: String,
            to textField: WorkspacePaletteSearchNSTextField,
            selection: SelectionUpdate,
            force: Bool
        ) {
            let editor = textField.currentEditor() as? NSTextView
            guard force || value != lastNativeText else { return }
            guard editor?.hasMarkedText() != true || selection == .end else { return }

            let oldSelection = editor?.selectedRange()
            isApplyingModelText = true
            if editor?.hasMarkedText() == true {
                editor?.unmarkText()
            }
            textField.stringValue = value
            if let editor, editor.string != value {
                editor.string = value
            }
            isApplyingModelText = false
            lastNativeText = value

            guard let editor else { return }
            switch selection {
            case .end:
                editor.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
            case .preserve:
                guard let oldSelection, oldSelection.location != NSNotFound else { return }
                let length = value.utf16.count
                let location = min(oldSelection.location, length)
                let upperBound = min(NSMaxRange(oldSelection), length)
                editor.setSelectedRange(NSRange(location: location, length: max(0, upperBound - location)))
            }
        }

        private enum SelectionUpdate {
            case end
            case preserve
        }
    }
}

@MainActor
final class WorkspacePaletteSearchNSTextField: NSTextField {
    var onWindowAttached: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onWindowAttached?()
    }
}
