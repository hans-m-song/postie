import AppKit
import PostieCore
import SwiftUI

struct HighlightedTextField: View {
    @Environment(\.isEnabled) private var isEnabled

    private let placeholder: String
    @Binding private var text: String
    private let availableVariables: Set<String>
    private let completionVariables: [VariableCompletion]
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
        completionVariables: [VariableCompletion] = [],
        focused: Binding<Bool>? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.availableVariables = availableVariables
        self.completionVariables = completionVariables
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
            completionVariables: completionVariables,
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
    let completionVariables: [VariableCompletion]
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
            completionVariables: completionVariables,
            validPathParameters: validPathParameters,
            isURL: isURL,
            isEnabled: isEnabled
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
            completionVariables: completionVariables,
            validPathParameters: validPathParameters,
            isURL: isURL,
            isEnabled: isEnabled
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
        private var completionVariables: [VariableCompletion]
        private var validPathParameters: Set<String>
        private var isURL: Bool
        private var isEnabled: Bool
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
        private let completionPopover = NSPopover()
        private let completionPopoverController = VariableCompletionPopoverController()
        private var completionContext: VariableCompletionContext?
        private var completionSuggestions: [VariableCompletion] = []
        private var selectedCompletionIndex = 0

        init(
            text: Binding<String>,
            focused: Binding<Bool>?,
            availableVariables: Set<String>,
            completionVariables: [VariableCompletion],
            validPathParameters: Set<String>,
            isURL: Bool,
            isEnabled: Bool
        ) {
            self.text = text
            self.focused = focused
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
            self.isEnabled = isEnabled
            super.init()
            completionPopover.behavior = .transient
            completionPopover.animates = false
            completionPopover.contentViewController = completionPopoverController
            completionPopoverController.listView.onSelection = { [weak self] index in
                self?.acceptCompletion(at: index)
            }
        }

        func attach(_ textField: SyntaxHighlightedTextField) {
            self.textField = textField
        }

        func update(
            text: Binding<String>,
            focused: Binding<Bool>?,
            availableVariables: Set<String>,
            completionVariables: [VariableCompletion],
            validPathParameters: Set<String>,
            isURL: Bool,
            isEnabled: Bool
        ) {
            self.text = text
            self.focused = focused
            let completionContextChanged = self.completionVariables != completionVariables || self.isURL != isURL
            let wasEnabled = self.isEnabled
            let inputsChanged = self.availableVariables != availableVariables ||
                    self.validPathParameters != validPathParameters ||
                    completionContextChanged ||
                    wasEnabled != isEnabled
            guard inputsChanged else {
                return
            }
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
            self.isEnabled = isEnabled
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            if completionContextChanged || !isEnabled {
                dismissCompletion()
            }
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            presentationTask?.cancel()
            editSession += 1
            stopObservingSelectionChanges()
            dismissCompletion()
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
                observeSelectionChanges(in: fieldEditor)
                SyntaxHighlighting.clearTemporaryAttributes(from: fieldEditor)
                fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
                fieldEditor.isAutomaticDashSubstitutionEnabled = false
                fieldEditor.isAutomaticTextReplacementEnabled = false
                fieldEditor.isAutomaticSpellingCorrectionEnabled = false
                fieldEditor.smartInsertDeleteEnabled = false
            }
            scheduleHighlighting(in: textField)
            refreshCompletion(in: textField, fieldEditor: textField.currentEditor() as? NSTextView)
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
            refreshCompletion(in: textField, fieldEditor: fieldEditor)
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
                stopObservingSelectionChanges(in: endingFieldEditor)
            }
            dismissCompletion()
            activeFieldEditor = nil
            editSession += 1
            focusGeneration += 1
            lastFocusRequest = false
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            focused?.wrappedValue = false
            scheduleHighlighting(in: textField)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let textField,
                  control === textField,
                  completionPopover.isShown,
                  !completionSuggestions.isEmpty else {
                return false
            }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                selectedCompletionIndex = max(0, selectedCompletionIndex - 1)
                updateCompletionPopoverSelection()
                return true
            case #selector(NSResponder.moveDown(_:)):
                selectedCompletionIndex = min(completionSuggestions.count - 1, selectedCompletionIndex + 1)
                updateCompletionPopoverSelection()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard NSApp.currentEvent?.modifierFlags.contains(.command) != true else {
                    return false
                }
                acceptCompletion(at: selectedCompletionIndex)
                return true
            case #selector(NSResponder.insertTab(_:)):
                acceptCompletion(at: selectedCompletionIndex)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissCompletion()
                return true
            default:
                return false
            }
        }

        func refreshCompletion(in textField: SyntaxHighlightedTextField, fieldEditor: NSTextView?) {
            guard isURL,
                  isEnabled,
                  textField.isEnabled,
                  !completionVariables.isEmpty,
                  let fieldEditor,
                  activeFieldEditor === fieldEditor,
                  !fieldEditor.hasMarkedText(),
                  let context = VariableCompletionMatcher.context(
                    in: fieldEditor.string,
                    selection: fieldEditor.selectedRange()
                  ) else {
                dismissCompletion()
                return
            }

            let suggestions = VariableCompletionMatcher.suggestions(for: context, from: completionVariables)
            guard !suggestions.isEmpty else {
                dismissCompletion()
                return
            }

            if completionContext != context || completionSuggestions != suggestions {
                selectedCompletionIndex = 0
            }
            completionContext = context
            completionSuggestions = suggestions
            updateCompletionPopoverSelection()

            guard !completionPopover.isShown,
                  let window = textField.window,
                  window.isVisible else {
                return
            }
            completionPopover.show(relativeTo: textField.bounds, of: textField, preferredEdge: .minY)
        }

        private func observeSelectionChanges(in fieldEditor: NSTextView) {
            stopObservingSelectionChanges()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fieldEditorSelectionDidChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: fieldEditor
            )
        }

        private func stopObservingSelectionChanges(in fieldEditor: NSTextView? = nil) {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextView.didChangeSelectionNotification,
                object: fieldEditor
            )
        }

        @objc private func fieldEditorSelectionDidChange(_ notification: Notification) {
            guard let fieldEditor = notification.object as? NSTextView,
                  activeFieldEditor === fieldEditor,
                  let textField else {
                return
            }
            refreshCompletion(in: textField, fieldEditor: fieldEditor)
        }

        private func updateCompletionPopoverSelection() {
            completionPopoverController.listView.update(
                suggestions: completionSuggestions,
                selectedIndex: selectedCompletionIndex
            )
            completionPopover.contentSize = completionPopoverController.listView.intrinsicContentSize
        }

        private func acceptCompletion(at index: Int) {
            guard completionSuggestions.indices.contains(index),
                  let fieldEditor = activeFieldEditor,
                  let context = completionContext,
                  let textField,
                  let currentEditor = textField.currentEditor() as? NSTextView,
                  currentEditor === fieldEditor else {
                dismissCompletion()
                return
            }

            let replacement = VariableCompletionMatcher.replacement(for: completionSuggestions[index])
            fieldEditor.breakUndoCoalescing()
            guard fieldEditor.shouldChangeText(in: context.replacementRange, replacementString: replacement) else {
                return
            }
            dismissCompletion()
            fieldEditor.insertText(replacement as NSString, replacementRange: context.replacementRange)
            fieldEditor.breakUndoCoalescing()
        }

        private func dismissCompletion() {
            if completionPopover.isShown {
                completionPopover.performClose(nil)
            }
            completionContext = nil
            completionSuggestions = []
            selectedCompletionIndex = 0
            completionPopoverController.listView.update(suggestions: [], selectedIndex: 0)
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
private final class VariableCompletionPopoverController: NSViewController {
    let listView = VariableCompletionListView()

    override func loadView() {
        view = listView
    }
}

@MainActor
private final class VariableCompletionListView: NSView {
    private let rowHeight: CGFloat = 26
    private var suggestions: [VariableCompletion] = []
    private var selectedIndex = 0
    var onSelection: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: rowHeight * CGFloat(max(1, suggestions.count)))
    }

    func update(suggestions: [VariableCompletion], selectedIndex: Int) {
        self.suggestions = suggestions
        self.selectedIndex = suggestions.isEmpty ? 0 : min(max(0, selectedIndex), suggestions.count - 1)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        for (index, suggestion) in suggestions.enumerated() {
            let rowRect = NSRect(x: 0, y: rowHeight * CGFloat(index), width: bounds.width, height: rowHeight)
            let isSelected = index == selectedIndex
            if isSelected {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
            }

            let textColor = isSelected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
            let metadataColor = isSelected ? textColor : NSColor.secondaryLabelColor
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textColor
            ]
            let metadataAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: metadataColor
            ]
            let metadata = suggestion.isSecret
                ? "\(scopeLabel(suggestion.scope)) · 🔒 Secret"
                : scopeLabel(suggestion.scope)
            let metadataSize = (metadata as NSString).size(withAttributes: metadataAttributes)
            let metadataWidth = min(metadataSize.width, bounds.width * 0.52)
            let metadataRect = NSRect(
                x: bounds.width - metadataWidth - 10,
                y: rowRect.minY + 3,
                width: metadataWidth,
                height: rowHeight - 6
            )
            let nameRect = NSRect(
                x: 10,
                y: rowRect.minY + 3,
                width: max(0, metadataRect.minX - 18),
                height: rowHeight - 6
            )
            (suggestion.name as NSString).draw(in: nameRect, withAttributes: nameAttributes)
            (metadata as NSString).draw(in: metadataRect, withAttributes: metadataAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / rowHeight)
        guard suggestions.indices.contains(index) else {
            return
        }
        onSelection?(index)
    }

    private func scopeLabel(_ scope: VariableScope) -> String {
        switch scope {
        case .global: return "Global"
        case .collection: return "Collection"
        case .request: return "Request"
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
