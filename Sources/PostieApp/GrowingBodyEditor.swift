import AppKit
import PostieCore
import SwiftUI

struct GrowingBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let isActive: Bool
    let syntax: BodySyntax
    let availableVariables: Set<String>
    let completionVariables: [VariableCompletion]

    init(
        text: Binding<String>,
        isEditable: Bool,
        isActive: Bool,
        syntax: BodySyntax = .none,
        availableVariables: Set<String> = [],
        completionVariables: [VariableCompletion] = []
    ) {
        _text = text
        self.isEditable = isEditable
        self.isActive = isActive
        self.syntax = syntax
        self.availableVariables = availableVariables
        self.completionVariables = completionVariables
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isActive: isActive,
            syntax: syntax,
            availableVariables: availableVariables,
            completionVariables: completionVariables
        )
    }

    func makeNSView(context: Context) -> NativeHighlightingHostView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isSelectable = isActive
        textView.isEditable = isEditable && isActive
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.drawsBackground = false
        textView.string = text

        let hostView = NativeHighlightingHostView(textView: textView)
        context.coordinator.attach(hostView)
        return hostView
    }

    func updateNSView(_ hostView: NativeHighlightingHostView, context: Context) {
        let textView = hostView.textView
        context.coordinator.text = $text
        context.coordinator.updateHighlighting(
            syntax: syntax,
            availableVariables: availableVariables,
            completionVariables: completionVariables
        )
        context.coordinator.attach(hostView)
        context.coordinator.updateActivity(isActive, in: textView)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable && isActive
        context.coordinator.updateTextIfNeeded(text, in: textView)
        context.coordinator.refreshCompletion(in: textView)
        context.coordinator.scheduleHighlighting(in: hostView)
        context.coordinator.revealCaretAfterLayoutIfNeeded(in: textView)
    }

    static func dismantleNSView(_ hostView: NativeHighlightingHostView, coordinator: Coordinator) {
        hostView.textView.delegate = nil
        coordinator.cancelHighlighting()
        coordinator.clearUndoActions()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView hostView: NativeHighlightingHostView,
        context: Context
    ) -> CGSize? {
        let textView = hostView.textView
        let width = proposal.width ?? textView.bounds.width
        guard width > 0,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return CGSize(width: max(0, width), height: Self.minimumHeight(for: textView))
        }

        textContainer.containerSize = NSSize(
            width: max(1, width - textView.textContainerInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineRect = layoutManager.extraLineFragmentRect
        let contentBottom = max(usedRect.maxY, extraLineRect.maxY)
        let height = max(
            Self.minimumHeight(for: textView),
            ceil(contentBottom + textView.textContainerInset.height * 2)
        )
        return CGSize(width: width, height: height)
    }

    private static func minimumHeight(for textView: NSTextView) -> CGFloat {
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: font)
            ?? ceil(font.ascender - font.descender + font.leading)
        return ceil(lineHeight + textView.textContainerInset.height * 2)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var syntax: BodySyntax
        private var availableVariables: Set<String>
        private var completionVariables: [VariableCompletion]
        private var highlightTask: Task<SyntaxHighlighting.Result, Never>?
        private var presentationTask: Task<Void, Never>?
        private var highlightGeneration = 0
        private var lastScheduledRequest: SyntaxHighlighting.Request?
        private var lastAppliedRequest: SyntaxHighlighting.Request?
        private weak var hostView: NativeHighlightingHostView?
        private let bodyUndoManager = UndoManager()
        private var isUpdatingFromBinding = false
        private var needsCaretReveal = false
        private var isActive: Bool
        private var selectionWhenInactive: NSRange?
        private let completionPopover = VariableCompletionPopover()
        private var completionContext: VariableCompletionContext?
        private var completionSuggestions: [VariableCompletion] = []
        private var selectedCompletionIndex = 0
        private var isApplyingPairEdit = false
        private var jsonStringStateCache = JSONBodyStringStateCache()

        init(
            text: Binding<String>,
            isActive: Bool,
            syntax: BodySyntax,
            availableVariables: Set<String>,
            completionVariables: [VariableCompletion]
        ) {
            self.text = text
            self.isActive = isActive
            self.syntax = syntax
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            super.init()
            completionPopover.onSelection = { [weak self] index in
                self?.acceptCompletion(at: index)
            }
        }

        func attach(_ hostView: NativeHighlightingHostView) {
            self.hostView = hostView
        }

        func updateHighlighting(
            syntax: BodySyntax,
            availableVariables: Set<String>,
            completionVariables: [VariableCompletion]
        ) {
            let completionVariablesChanged = self.completionVariables != completionVariables
            guard self.syntax != syntax ||
                  self.availableVariables != availableVariables ||
                  completionVariablesChanged else {
                return
            }
            self.syntax = syntax
            self.availableVariables = availableVariables
            self.completionVariables = completionVariables
            lastScheduledRequest = nil
            lastAppliedRequest = nil
            if completionVariablesChanged {
                dismissCompletion()
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            bodyUndoManager
        }

        func clearUndoActions() {
            bodyUndoManager.removeAllActions()
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            presentationTask?.cancel()
            highlightTask = nil
            presentationTask = nil
            dismissCompletion()
            hostView = nil
        }

        func updateActivity(_ isActive: Bool, in textView: NSTextView) {
            guard self.isActive != isActive else { return }

            if isActive {
                textView.isSelectable = true
                if let selectionWhenInactive {
                    let newLength = (textView.string as NSString).length
                    let location = min(selectionWhenInactive.location, newLength)
                    let length = min(selectionWhenInactive.length, newLength - location)
                    textView.setSelectedRange(NSRange(location: location, length: length))
                    self.selectionWhenInactive = nil
                }
            } else {
                dismissCompletion()
                selectionWhenInactive = textView.selectedRange()
                textView.isEditable = false
                if textView.window?.firstResponder === textView {
                    textView.window?.makeFirstResponder(nil)
                }
                textView.isSelectable = false
            }

            self.isActive = isActive
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromBinding,
                  let textView = notification.object as? NSTextView,
                  text.wrappedValue != textView.string else { return }
            needsCaretReveal = true
            text.wrappedValue = textView.string
            refreshCompletion(in: textView)
            if let hostView {
                scheduleHighlighting(in: hostView)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            refreshCompletion(in: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completionPopover.isShown, !completionSuggestions.isEmpty {
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
                    break
                }
            }

            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.command) != true,
                  syntax == .json,
                  isActive,
                  textView.isEditable,
                  !textView.hasMarkedText(),
                  case let .replace(range, replacement, selection) = JSONBodyEditing.edit(
                    in: textView.string,
                    range: textView.selectedRange(),
                    replacement: "\n",
                    inputKind: .newline,
                    stringStateCache: &jsonStringStateCache
                  ) else {
                return false
            }

            applyJSONBodyEdit(
                .replace(range: range, with: replacement, selection: selection),
                in: textView
            )
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            jsonStringStateCache.invalidate(from: affectedCharRange.location)
            guard !isApplyingPairEdit,
                  syntax == .json,
                  isActive,
                  !textView.hasMarkedText(),
                  let replacementString else {
                return true
            }

            let inputKind = pairingInputKind(for: replacementString)
            guard inputKind != .other,
                  let edit = JSONBodyEditing.edit(
                    in: textView.string,
                    range: affectedCharRange,
                    replacement: replacementString,
                    inputKind: inputKind,
                    stringStateCache: &jsonStringStateCache
                  ) else {
                return true
            }

            applyJSONBodyEdit(edit, in: textView)
            return false
        }

        private func applyJSONBodyEdit(_ edit: JSONBodyEditing.Edit, in textView: NSTextView) {
            switch edit {
            case let .moveCaret(to: location):
                textView.setSelectedRange(NSRange(location: location, length: 0))
            case let .replace(range, replacement, selection):
                isApplyingPairEdit = true
                defer { isApplyingPairEdit = false }
                textView.insertText(replacement as NSString, replacementRange: range)
                textView.setSelectedRange(selection)
            }
        }

        func refreshCompletion(in textView: NSTextView) {
            guard isActive,
                  textView.isEditable,
                  textView.window?.firstResponder === textView,
                  !textView.hasMarkedText(),
                  !completionVariables.isEmpty,
                  let context = VariableCompletionMatcher.bodyContext(
                    in: textView.string,
                    selection: textView.selectedRange()
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
                relativeTo: completionAnchorRect(in: textView),
                of: textView,
                preferredEdge: .minY,
                suggestions: completionSuggestions,
                selectedIndex: selectedCompletionIndex
            )
        }

        private func completionAnchorRect(in textView: NSTextView) -> NSRect {
            let sourceLength = (textView.string as NSString).length
            let location = min(max(0, textView.selectedRange().location), sourceLength)
            let characterRange = NSRange(location: location, length: 0)

            if let window = textView.window {
                let screenRect = textView.firstRect(
                    forCharacterRange: characterRange,
                    actualRange: nil
                )
                if !screenRect.isNull, !screenRect.isInfinite, !screenRect.isEmpty {
                    let windowRect = window.convertFromScreen(screenRect)
                    let viewRect = textView.convert(windowRect, from: nil)
                    return boundedCaretRect(viewRect, in: textView.visibleRect)
                }
            }

            return boundedCaretRect(layoutCaretRect(in: textView, at: location), in: textView.visibleRect)
        }

        private func layoutCaretRect(in textView: NSTextView, at location: Int) -> NSRect {
            let origin = textView.textContainerOrigin
            let lineHeight = textView.font?.pointSize ?? NSFont.systemFontSize
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return NSRect(x: origin.x, y: origin.y, width: 1, height: lineHeight)
            }

            layoutManager.ensureLayout(for: textContainer)
            if location >= (textView.string as NSString).length {
                let extraLine = layoutManager.extraLineFragmentRect
                if !extraLine.isEmpty {
                    return NSRect(
                        x: extraLine.minX + origin.x,
                        y: extraLine.minY + origin.y,
                        width: 1,
                        height: max(lineHeight, extraLine.height)
                    )
                }
            }

            let characterLength = (textView.string as NSString).length
            guard characterLength > 0 else {
                return NSRect(x: origin.x, y: origin.y, width: 1, height: lineHeight)
            }
            let characterIndex = min(location, characterLength - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            return NSRect(
                x: glyphRect.minX + origin.x,
                y: glyphRect.minY + origin.y,
                width: 1,
                height: max(lineHeight, glyphRect.height)
            )
        }

        private func boundedCaretRect(_ rect: NSRect, in bounds: NSRect) -> NSRect {
            let width = max(1, min(rect.width, max(1, bounds.width)))
            let height = max(1, min(rect.height, max(1, bounds.height)))
            let maxX = max(bounds.minX, bounds.maxX - width)
            let maxY = max(bounds.minY, bounds.maxY - height)
            let x = min(max(rect.midX - width / 2, bounds.minX), maxX)
            let y = min(max(rect.midY - height / 2, bounds.minY), maxY)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        private func pairingInputKind(for replacement: String) -> JSONBodyEditing.InputKind {
            guard let event = NSApp.currentEvent, event.type == .keyDown else {
                return .other
            }

            let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
                return .other
            }
            if replacement.isEmpty, event.keyCode == 51 {
                return .backspace
            }

            guard !replacement.isEmpty,
                  event.characters == replacement else {
                return .other
            }
            return .typing
        }

        private func updateCompletionPopoverSelection() {
            completionPopover.update(suggestions: completionSuggestions, selectedIndex: selectedCompletionIndex)
        }

        private func acceptCompletion(at index: Int) {
            guard completionSuggestions.indices.contains(index),
                  let context = completionContext,
                  let textView = hostView?.textView,
                  isActive,
                  textView.isEditable,
                  textView.window?.firstResponder === textView,
                  !textView.hasMarkedText(),
                  VariableCompletionMatcher.bodyContext(
                    in: textView.string,
                    selection: textView.selectedRange()
                  ) == context else {
                dismissCompletion()
                return
            }

            let replacement = VariableCompletionMatcher.replacement(for: completionSuggestions[index])
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: context.replacementRange, replacementString: replacement) else {
                return
            }
            dismissCompletion()
            textView.insertText(replacement as NSString, replacementRange: context.replacementRange)
            textView.breakUndoCoalescing()
        }

        private func dismissCompletion() {
            completionPopover.dismiss()
            completionContext = nil
            completionSuggestions = []
            selectedCompletionIndex = 0
            completionPopover.update(suggestions: [], selectedIndex: 0)
        }

        func revealCaretAfterLayoutIfNeeded(in textView: NSTextView) {
            guard needsCaretReveal else { return }
            needsCaretReveal = false

            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func updateTextIfNeeded(_ value: String, in textView: NSTextView) {
            guard textView.string != value, !textView.hasMarkedText() else { return }

            let selection = textView.selectedRange()
            let newLength = (value as NSString).length
            let location = min(selection.location, newLength)
            let length = min(selection.length, newLength - location)

            bodyUndoManager.removeAllActions()
            jsonStringStateCache = JSONBodyStringStateCache()
            isUpdatingFromBinding = true
            bodyUndoManager.disableUndoRegistration()
            defer {
                bodyUndoManager.enableUndoRegistration()
                isUpdatingFromBinding = false
            }
            textView.string = value
            textView.setSelectedRange(NSRange(location: location, length: length))
        }

        func scheduleHighlighting(in hostView: NativeHighlightingHostView) {
            let request = SyntaxHighlighting.Request(
                text: hostView.textView.string,
                syntax: syntax,
                availableVariables: availableVariables,
                validPathParameters: [],
                isURL: false
            )
            guard request != lastAppliedRequest, request != lastScheduledRequest else {
                return
            }

            lastScheduledRequest = request
            highlightGeneration += 1
            let generation = highlightGeneration
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
            presentationTask = Task { @MainActor [weak self, weak hostView] in
                let result = await task.value
                guard let self,
                      let hostView,
                      !result.isCancelled,
                      generation == self.highlightGeneration,
                      hostView.textView.string == request.text else {
                    return
                }
                guard !hostView.textView.hasMarkedText() else {
                    self.lastScheduledRequest = nil
                    return
                }

                self.lastAppliedRequest = request
                hostView.setHighlightingPaused(result.isPaused)
                SyntaxHighlighting.apply(result, to: hostView.textView)
            }
        }
    }
}
