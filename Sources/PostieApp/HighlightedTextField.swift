import AppKit
import PostieCore
import SwiftUI

enum HighlightedTextFieldWrapping: Equatable {
    case singleLine
    case unbounded

    var isWrapped: Bool {
        if case .singleLine = self { return false }
        return true
    }
}

struct HighlightedTextField: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.variableInspectionOwner) private var inspectionOwner
    @EnvironmentObject private var model: AppModel

    private let placeholder: String
    @Binding private var text: String
    private let availableVariables: Set<String>
    private let completionVariables: [VariableCompletion]
    private let validPathParameters: Set<String>
    private let isURL: Bool
    private let isReadOnly: Bool
    private let truncationMode: NSLineBreakMode
    private let rounded: Bool
    private let wrapping: HighlightedTextFieldWrapping
    private let foregroundColor: NSColor?
    private let focused: Binding<Bool>?

    init(
        _ placeholder: String,
        text: Binding<String>,
        availableVariables: Set<String> = [],
        validPathParameters: Set<String> = [],
        isURL: Bool = false,
        isReadOnly: Bool = false,
        truncationMode: NSLineBreakMode = .byTruncatingTail,
        rounded: Bool = false,
        completionVariables: [VariableCompletion] = [],
        focused: Binding<Bool>? = nil,
        wrapping: HighlightedTextFieldWrapping = .singleLine,
        foregroundColor: NSColor? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.availableVariables = availableVariables
        self.completionVariables = completionVariables
        self.validPathParameters = validPathParameters
        self.isURL = isURL
        self.isReadOnly = isReadOnly
        self.truncationMode = truncationMode
        self.rounded = rounded
        self.wrapping = wrapping
        self.foregroundColor = foregroundColor
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
            isReadOnly: isReadOnly,
            truncationMode: truncationMode,
            rounded: rounded,
            wrapping: wrapping,
            foregroundColor: foregroundColor,
            focused: focused,
            isEnabled: isEnabled,
            model: model,
            inspectionOwner: inspectionOwner
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
    let isReadOnly: Bool
    let truncationMode: NSLineBreakMode
    let rounded: Bool
    let wrapping: HighlightedTextFieldWrapping
    let foregroundColor: NSColor?
    let focused: Binding<Bool>?
    let isEnabled: Bool
    let model: AppModel
    let inspectionOwner: VariableOwner?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focused: focused,
            availableVariables: availableVariables,
            completionVariables: completionVariables,
            validPathParameters: validPathParameters,
            isURL: isURL,
            isReadOnly: isReadOnly,
            wrapping: wrapping,
            isEnabled: isEnabled,
            model: model,
            inspectionOwner: inspectionOwner
        )
    }

    func makeNSView(context: Context) -> SyntaxHighlightedTextField {
        let textField = SyntaxHighlightedTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.isEnabled = isEnabled
        textField.isEditable = isEnabled && !isReadOnly
        textField.isSelectable = true
        textField.allowsEditingTextAttributes = false
        configureWrapping(on: textField)
        textField.isBordered = rounded
        textField.isBezeled = rounded
        updateHorizontalPriorities(of: textField)
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
            isReadOnly: isReadOnly,
            wrapping: wrapping,
            isEnabled: isEnabled,
            inspectionOwner: inspectionOwner
        )
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isEnabled = isEnabled
        textField.isEditable = isEnabled && !isReadOnly
        configureWrapping(on: textField)
        updateHorizontalPriorities(of: textField)
        context.coordinator.updateTextIfNeeded(text, in: textField)
        context.coordinator.scheduleHighlighting(in: textField)
        context.coordinator.updateFocus(in: textField)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textField: SyntaxHighlightedTextField,
        context: Context
    ) -> CGSize? {
        guard wrapping.isWrapped else { return nil }

        let width = proposal.width ?? textField.bounds.width
        guard width.isFinite, width > 0 else { return nil }

        let font = textField.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let sampleHeight = lineHeight + 6
        let textRect = textField.highlightedCell.titleRect(
            forBounds: NSRect(x: 0, y: 0, width: width, height: sampleHeight)
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textField.alignment
        paragraphStyle.lineBreakMode = .byCharWrapping
        let measuredText = text.isEmpty ? placeholder : text
        let attributedText = NSAttributedString(
            string: measuredText,
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        let textBounds = attributedText.boundingRect(
            with: NSSize(width: max(1, textRect.width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let measuredHeight = max(lineHeight, ceil(textBounds.height))
        return CGSize(width: width, height: measuredHeight + 6)
    }

    private func configureWrapping(on textField: SyntaxHighlightedTextField) {
        let wraps = wrapping.isWrapped
        let lineBreakMode: NSLineBreakMode = wraps ? .byCharWrapping : truncationMode
        textField.usesSingleLineMode = !wraps
        textField.lineBreakMode = lineBreakMode
        textField.highlightedCell.wraps = wraps
        textField.highlightedCell.lineBreakMode = lineBreakMode
        textField.highlightedCell.wrapping = wrapping
        textField.highlightedCell.foregroundColor = foregroundColor
    }

    private func updateHorizontalPriorities(of textField: NSTextField) {
        let priority: NSLayoutConstraint.Priority = isReadOnly ? .defaultLow : .defaultHigh
        textField.setContentHuggingPriority(priority, for: .horizontal)
        textField.setContentCompressionResistancePriority(priority, for: .horizontal)
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
        private var isReadOnly: Bool
        private var wrapping: HighlightedTextFieldWrapping
        private var isEnabled: Bool
        private let model: AppModel
        private var inspectionOwner: VariableOwner?
        private let inspectionPopover = VariableInspectionPopover()
        private var inspectedVariable: VariableInspection?
        private var inspectionGeneration = 0
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
        private let completionPopover = VariableCompletionPopover()
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
            isReadOnly: Bool,
            wrapping: HighlightedTextFieldWrapping,
            isEnabled: Bool,
            model: AppModel,
            inspectionOwner: VariableOwner?
        ) {
            self.text = text
            self.focused = focused
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
            self.isReadOnly = isReadOnly
            self.wrapping = wrapping
            self.isEnabled = isEnabled
            self.model = model
            self.inspectionOwner = inspectionOwner
            super.init()
            completionPopover.onSelection = { [weak self] index in
                self?.acceptCompletion(at: index)
            }
        }

        func attach(_ textField: SyntaxHighlightedTextField) {
            self.textField = textField
            textField.highlightedCell.onFieldEditorSelected = { [weak self, weak textField] editor in
                guard let self, let textField, let fieldEditor = editor as? NSTextView else {
                    return
                }
                self.adoptFieldEditor(fieldEditor, in: textField)
            }
        }

        func update(
            text: Binding<String>,
            focused: Binding<Bool>?,
            availableVariables: Set<String>,
            completionVariables: [VariableCompletion],
            validPathParameters: Set<String>,
            isURL: Bool,
            isReadOnly: Bool,
            wrapping: HighlightedTextFieldWrapping,
            isEnabled: Bool,
            inspectionOwner: VariableOwner?
        ) {
            self.text = text
            self.focused = focused
            if self.inspectionOwner != inspectionOwner || self.isReadOnly != isReadOnly || !isEnabled ||
                inspectedVariable.map({ !model.isCurrent($0) }) == true {
                dismissInspection()
            }
            self.inspectionOwner = inspectionOwner
            let completionContextChanged = self.completionVariables != completionVariables ||
                self.isURL != isURL || self.isReadOnly != isReadOnly
            let wasEnabled = self.isEnabled
            let wasReadOnly = self.isReadOnly
            let wrappingChanged = self.wrapping != wrapping
            let inputsChanged = self.availableVariables != availableVariables ||
                    self.validPathParameters != validPathParameters ||
                    completionContextChanged ||
                    wrappingChanged ||
                    wasEnabled != isEnabled ||
                    wasReadOnly != isReadOnly
            guard inputsChanged else {
                return
            }
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            self.validPathParameters = validPathParameters
            self.isURL = isURL
            self.isReadOnly = isReadOnly
            self.wrapping = wrapping
            self.isEnabled = isEnabled
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            if wrappingChanged, let activeFieldEditor {
                configureFieldEditor(activeFieldEditor)
            }
            if completionContextChanged || !isEnabled || isReadOnly {
                dismissCompletion()
            }
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            presentationTask?.cancel()
            editSession += 1
            stopObservingSelectionChanges()
            dismissCompletion()
            dismissInspection()
            textField?.highlightedCell.onFieldEditorSelected = nil
            if let activeFieldEditor {
                SyntaxHighlighting.clearTemporaryAttributes(from: activeFieldEditor)
            }
            highlightTask = nil
            presentationTask = nil
            activeFieldEditor = nil
            textField = nil
        }

        func updateTextIfNeeded(_ value: String, in textField: SyntaxHighlightedTextField) {
            if let fieldEditor = textField.currentEditor() as? NSTextView {
                guard isReadOnly,
                      !fieldEditor.hasMarkedText(),
                      fieldEditor.string != value else { return }
                let selection = fieldEditor.selectedRange()
                let length = (value as NSString).length
                let location = min(selection.location, length)
                let end = min(NSMaxRange(selection), length)
                textField.stringValue = value
                fieldEditor.string = value
                fieldEditor.setSelectedRange(NSRange(location: location, length: max(0, end - location)))
                dismissInspection()
            } else {
                guard textField.stringValue != value else { return }
                textField.stringValue = value
            }
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
            guard !isReadOnly else { return }
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
                adoptFieldEditor(fieldEditor, in: textField)
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
            guard !isReadOnly else { return }
            guard let textField = notification.object as? SyntaxHighlightedTextField else {
                return
            }
            let fieldEditor = textField.currentEditor() as? NSTextView
            dismissInspection()
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
            if !isReadOnly, text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
            let endingFieldEditor = activeFieldEditor ?? (textField.currentEditor() as? NSTextView)
            if let endingFieldEditor {
                SyntaxHighlighting.clearTemporaryAttributes(from: endingFieldEditor)
                stopObservingSelectionChanges(in: endingFieldEditor)
            }
            dismissCompletion()
            if !inspectionPopover.isPresenting && !inspectionPopover.isHandlingCurrentEvent { dismissInspection() }
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
            guard !isReadOnly,
                  let textField,
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
            if let fieldEditor, !fieldEditor.hasMarkedText(),
               isEnabled, textField.isEnabled, activeFieldEditor === fieldEditor,
               let reference = VariableInspectionMatcher.reference(
                in: fieldEditor.string, selection: fieldEditor.selectedRange(), definedNames: availableVariables
               ), let inspectionOwner,
               let inspection = model.variableInspection(named: reference.name, in: inspectionOwner) {
                dismissCompletion()
                inspectedVariable = inspection
                inspectionGeneration += 1
                let generation = inspectionGeneration
                DispatchQueue.main.async { [weak self, weak textField, weak fieldEditor] in
                    guard let self, let textField, let fieldEditor,
                          self.inspectionGeneration == generation,
                          self.activeFieldEditor === fieldEditor,
                          textField.currentEditor() === fieldEditor,
                          self.model.isCurrent(inspection),
                          VariableInspectionMatcher.reference(in: fieldEditor.string, selection: fieldEditor.selectedRange()) == reference else { return }
                    self.inspectionPopover.show(
                        inspection, model: self.model,
                        relativeTo: self.tokenRect(reference.range, in: textField, editor: fieldEditor),
                        of: textField,
                        isCurrent: { [weak self, weak textField] in
                            guard let self, let textField,
                                  self.inspectionPopover.isShown,
                                  self.inspectedVariable == inspection,
                                  self.model.isCurrent(inspection) else { return false }
                            let value = (textField.currentEditor() as? NSTextView)?.string ?? textField.stringValue
                            return VariableInspectionMatcher.reference(in: value, selection: reference.range)?.name == reference.name
                        }
                    )
                }
                return
            }
            dismissInspection()
            guard !isReadOnly,
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
            completionPopover.show(
                relativeTo: tokenRect(context.replacementRange, in: textField, editor: fieldEditor),
                of: textField,
                preferredEdge: textField.isFlipped ? .minY : .maxY,
                suggestions: completionSuggestions,
                selectedIndex: selectedCompletionIndex
            )
        }

        private func tokenRect(_ range: NSRange, in textField: NSTextField, editor: NSTextView) -> NSRect {
            guard let window = textField.window else { return textField.bounds }
            let screenRect = editor.firstRect(forCharacterRange: range, actualRange: nil)
            let rect = textField.convert(window.convertFromScreen(screenRect), from: nil)
            let visible = rect.intersection(textField.bounds)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return textField.bounds }
            return visible
        }

        private func dismissInspection() {
            inspectionGeneration += 1
            inspectedVariable = nil
            inspectionPopover.dismiss()
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

        private func adoptFieldEditor(_ fieldEditor: NSTextView, in textField: SyntaxHighlightedTextField) {
            guard self.textField === textField,
                  textField.isEnabled,
                  textField.currentEditor() === fieldEditor,
                  textField.window?.firstResponder === fieldEditor else {
                return
            }
            guard activeFieldEditor !== fieldEditor else {
                return
            }

            stopObservingSelectionChanges()
            activeFieldEditor = fieldEditor
            configureFieldEditor(fieldEditor)
            observeSelectionChanges(in: fieldEditor)
            SyntaxHighlighting.clearTemporaryAttributes(from: fieldEditor)
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            scheduleHighlighting(in: textField)
            refreshCompletion(in: textField, fieldEditor: fieldEditor)
        }

        private func configureFieldEditor(_ fieldEditor: NSTextView) {
            let wraps = wrapping.isWrapped
            fieldEditor.isHorizontallyResizable = !wraps
            fieldEditor.isVerticallyResizable = false
            guard let textContainer = fieldEditor.textContainer else { return }
            textContainer.widthTracksTextView = wraps
            textContainer.heightTracksTextView = false
            textContainer.containerSize = NSSize(
                width: wraps ? max(1, fieldEditor.bounds.width) : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
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
            completionPopover.update(suggestions: completionSuggestions, selectedIndex: selectedCompletionIndex)
        }

        private func acceptCompletion(at index: Int) {
            guard !isReadOnly,
                  completionSuggestions.indices.contains(index),
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
            completionPopover.dismiss()
            completionContext = nil
            completionSuggestions = []
            selectedCompletionIndex = 0
            completionPopover.update(suggestions: [], selectedIndex: 0)
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

                if let currentEditor,
                   self.activeFieldEditor === currentEditor,
                   (requestedFieldEditor !== currentEditor || self.editSession != session) {
                    self.lastScheduledRequest = nil
                    self.lastAppliedRequest = nil
                    self.scheduleHighlighting(in: textField)
                    return
                }

                self.lastAppliedRequest = request
                textField.highlightedCell.spans = result.spans
                textField.toolTip = result.isPaused ? "Highlighting paused over 1 MiB" : nil
                if let currentEditor,
                   let requestedFieldEditor,
                   currentEditor === requestedFieldEditor,
                   self.activeFieldEditor === currentEditor,
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
    var onFieldEditorSelected: ((NSText) -> Void)?
    var wrapping: HighlightedTextFieldWrapping = .singleLine
    var foregroundColor: NSColor?

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
        notifyFieldEditorSelected(textObj, in: controlView)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        notifyFieldEditorSelected(textObj, in: controlView)
    }

    private func notifyFieldEditorSelected(_ editor: NSText, in controlView: NSView) {
        guard let textField = controlView as? SyntaxHighlightedTextField,
              textField.currentEditor() === editor,
              textField.window?.firstResponder === editor else {
            return
        }
        onFieldEditorSelected?(editor)
    }

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
        let foregroundColor = textField.isEnabled
            ? self.foregroundColor ?? .labelColor
            : .disabledControlTextColor
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
        if !wrapping.isWrapped {
            drawRect.origin.y += max(0, (titleRect.height - textBounds.height) / 2)
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: titleRect).addClip()
        text.draw(with: drawRect, options: options, context: nil)
    }
}
