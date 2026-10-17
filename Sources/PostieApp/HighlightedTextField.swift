import AppKit
import PostieCore
import SwiftUI

struct HighlightedTextField: View {
    @Environment(\.isEnabled) private var isEnabled

    private let placeholder: String
    @Binding private var text: String
    private let availableVariables: Set<String>
    private let validPathParameters: Set<String>
    private let isURL: Bool
    private let rounded: Bool
    private let focused: Binding<Bool>?

    init(
        _ placeholder: String,
        text: Binding<String>,
        availableVariables: Set<String> = [],
        validPathParameters: Set<String> = [],
        isURL: Bool = false,
        rounded: Bool = false,
        focused: Binding<Bool>? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.availableVariables = availableVariables
        self.validPathParameters = validPathParameters
        self.isURL = isURL
        self.rounded = rounded
        self.focused = focused
    }

    var body: some View {
        NativeHighlightedTextField(
            placeholder: placeholder,
            text: $text,
            availableVariables: availableVariables,
            validPathParameters: validPathParameters,
            isURL: isURL,
            rounded: rounded,
            focused: focused,
            isEnabled: isEnabled
        )
        .accessibilityLabel(placeholder)
    }
}

@MainActor
private struct NativeHighlightedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let availableVariables: Set<String>
    let validPathParameters: Set<String>
    let isURL: Bool
    let rounded: Bool
    let focused: Binding<Bool>?
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focused: focused,
            availableVariables: availableVariables,
            validPathParameters: validPathParameters,
            isURL: isURL
        )
    }

    func makeNSView(context: Context) -> SyntaxHighlightedTextField {
        let textField = SyntaxHighlightedTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.isEnabled = isEnabled
        textField.isEditable = isEnabled
        textField.isSelectable = true
        textField.allowsEditingTextAttributes = false
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.isBordered = rounded
        textField.isBezeled = rounded
        if rounded {
            textField.bezelStyle = .roundedBezel
        }
        textField.focusRingType = .default
        textField.stringValue = text
        context.coordinator.attach(textField)
        return textField
    }

    func updateNSView(_ textField: SyntaxHighlightedTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            focused: focused,
            availableVariables: availableVariables,
            validPathParameters: validPathParameters,
            isURL: isURL
        )
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isEnabled = isEnabled
        textField.isEditable = isEnabled
        context.coordinator.updateTextIfNeeded(text, in: textField)
        context.coordinator.scheduleHighlighting(in: textField)
        context.coordinator.updateFocus(in: textField)
    }

    static func dismantleNSView(_ textField: SyntaxHighlightedTextField, coordinator: Coordinator) {
        textField.delegate = nil
        coordinator.cancelHighlighting()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focused: Binding<Bool>?
        private var availableVariables: Set<String>
        private var validPathParameters: Set<String>
        private var isURL: Bool
        private var highlightTask: Task<SyntaxHighlighting.Result, Never>?
        private var presentationTask: Task<Void, Never>?
        private var highlightGeneration = 0
        private var editSession = 0
        private var focusGeneration = 0
        private var lastFocusRequest: Bool?
        private var lastScheduledRequest: SyntaxHighlighting.Request?
        private var lastAppliedRequest: SyntaxHighlighting.Request?
        private weak var textField: SyntaxHighlightedTextField?
        private weak var activeFieldEditor: NSTextView?

        init(
            text: Binding<String>,
            focused: Binding<Bool>?,
            availableVariables: Set<String>,
            validPathParameters: Set<String>,
            isURL: Bool
        ) {
            self.text = text
            self.focused = focused
            self.availableVariables = availableVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
        }

        func attach(_ textField: SyntaxHighlightedTextField) {
            self.textField = textField
        }

        func update(
            text: Binding<String>,
            focused: Binding<Bool>?,
            availableVariables: Set<String>,
            validPathParameters: Set<String>,
            isURL: Bool
        ) {
            self.text = text
            self.focused = focused
            guard self.availableVariables != availableVariables ||
                    self.validPathParameters != validPathParameters ||
                    self.isURL != isURL else {
                return
            }
            self.availableVariables = availableVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
            lastScheduledRequest = nil
            lastAppliedRequest = nil
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            presentationTask?.cancel()
            editSession += 1
            if let activeFieldEditor {
                SyntaxHighlighting.clearTemporaryAttributes(from: activeFieldEditor)
            }
            highlightTask = nil
            presentationTask = nil
            activeFieldEditor = nil
            textField = nil
        }

        func updateTextIfNeeded(_ value: String, in textField: SyntaxHighlightedTextField) {
            guard textField.stringValue != value else {
                return
            }
            if let fieldEditor = textField.currentEditor() as? NSTextView {
                guard !fieldEditor.hasMarkedText() else {
                    return
                }
                return
            }
            textField.stringValue = value
            textField.highlightedCell.spans = []
            lastScheduledRequest = nil
            lastAppliedRequest = nil
        }

        func updateFocus(in textField: SyntaxHighlightedTextField) {
            guard let focused else {
                return
            }
            let shouldFocus = focused.wrappedValue && textField.isEnabled
            guard lastFocusRequest != shouldFocus else {
                return
            }
            lastFocusRequest = shouldFocus
            focusGeneration += 1
            guard shouldFocus else {
                return
            }

            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak textField] in
                guard let self,
                      self.focusGeneration == generation,
                      self.focused?.wrappedValue == true,
                      let textField,
                      textField.isEnabled,
                      textField.currentEditor() == nil,
                      let window = textField.window else {
                    return
                }
                window.makeFirstResponder(textField)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let textField = notification.object as? SyntaxHighlightedTextField else {
                return
            }
            editSession += 1
            focusGeneration += 1
            lastFocusRequest = true
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            focused?.wrappedValue = true
            if let fieldEditor = textField.currentEditor() as? NSTextView {
                activeFieldEditor = fieldEditor
                SyntaxHighlighting.clearTemporaryAttributes(from: fieldEditor)
                fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
                fieldEditor.isAutomaticDashSubstitutionEnabled = false
                fieldEditor.isAutomaticTextReplacementEnabled = false
                fieldEditor.isAutomaticSpellingCorrectionEnabled = false
                fieldEditor.smartInsertDeleteEnabled = false
            }
            scheduleHighlighting(in: textField)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? SyntaxHighlightedTextField else {
                return
            }
            let fieldEditor = textField.currentEditor() as? NSTextView
            let value = fieldEditor?.string ?? textField.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
            scheduleHighlighting(in: textField)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? SyntaxHighlightedTextField else {
                return
            }
            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
            let endingFieldEditor = activeFieldEditor ?? (textField.currentEditor() as? NSTextView)
            if let endingFieldEditor {
                SyntaxHighlighting.clearTemporaryAttributes(from: endingFieldEditor)
            }
            activeFieldEditor = nil
            editSession += 1
            focusGeneration += 1
            lastFocusRequest = false
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            focused?.wrappedValue = false
            scheduleHighlighting(in: textField)
        }

        func scheduleHighlighting(in textField: SyntaxHighlightedTextField) {
            let fieldEditor = textField.currentEditor() as? NSTextView
            guard fieldEditor?.hasMarkedText() != true else {
                lastScheduledRequest = nil
                return
            }
            let request = SyntaxHighlighting.Request(
                text: fieldEditor?.string ?? textField.stringValue,
                syntax: .none,
                availableVariables: availableVariables,
                validPathParameters: validPathParameters,
                isURL: isURL
            )
            guard request != lastAppliedRequest, request != lastScheduledRequest else {
                return
            }

            lastScheduledRequest = request
            highlightGeneration += 1
            let generation = highlightGeneration
            let session = editSession
            let requestedFieldEditor = fieldEditor
            highlightTask?.cancel()
            presentationTask?.cancel()

            let task = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else {
                    return SyntaxHighlighting.Result.cancelled
                }
                return SyntaxHighlighting.result(for: request)
            }
            highlightTask = task
            presentationTask = Task { @MainActor [weak self, weak textField] in
                let result = await task.value
                guard let self,
                      let textField,
                      !result.isCancelled,
                      generation == self.highlightGeneration else {
                    return
                }
                let currentEditor = textField.currentEditor() as? NSTextView
                guard (currentEditor?.string ?? textField.stringValue) == request.text else {
                    return
                }
                guard currentEditor?.hasMarkedText() != true else {
                    self.lastScheduledRequest = nil
                    return
                }

                self.lastAppliedRequest = request
                textField.highlightedCell.spans = result.spans
                textField.toolTip = result.isPaused ? "Highlighting paused over 1 MiB" : nil
                if let currentEditor,
                   let requestedFieldEditor,
                   currentEditor === requestedFieldEditor,
                   let activeFieldEditor = self.activeFieldEditor,
                   activeFieldEditor === currentEditor,
                   self.editSession == session {
                    SyntaxHighlighting.apply(result, to: currentEditor)
                }
                textField.needsDisplay = true
            }
        }
    }
}

@MainActor
private final class SyntaxHighlightedTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = SyntaxHighlightedTextFieldCell(textCell: "")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = SyntaxHighlightedTextFieldCell(textCell: "")
    }

    var highlightedCell: SyntaxHighlightedTextFieldCell {
        cell as! SyntaxHighlightedTextFieldCell
    }
}

@MainActor
private final class SyntaxHighlightedTextFieldCell: NSTextFieldCell {
    var spans: [SyntaxHighlighting.Span] = []

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let textField = controlView as? NSTextField else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        guard textField.currentEditor() == nil else {
            return
        }
        guard !stringValue.isEmpty else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }

        let text = NSMutableAttributedString(string: stringValue)
        let textRange = NSRange(location: 0, length: text.length)
        let foregroundColor = textField.isEnabled ? NSColor.labelColor : .disabledControlTextColor
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = lineBreakMode
        text.addAttributes([
            .font: textField.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraphStyle
        ], range: textRange)
        for span in spans where span.length > 0 && NSMaxRange(span.range) <= text.length {
            text.addAttribute(.foregroundColor, value: span.color.appKitColor, range: span.range)
        }

        let titleRect = titleRect(forBounds: cellFrame)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let textBounds = text.boundingRect(with: titleRect.size, options: options, context: nil)
        var drawRect = titleRect
        drawRect.origin.y += max(0, (titleRect.height - textBounds.height) / 2)
        text.draw(with: drawRect, options: options, context: nil)
    }
}
