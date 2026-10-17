import AppKit
import PostieCore
import SwiftUI

struct GrowingBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let isActive: Bool
    let syntax: BodySyntax
    let availableVariables: Set<String>

    init(
        text: Binding<String>,
        isEditable: Bool,
        isActive: Bool,
        syntax: BodySyntax = .none,
        availableVariables: Set<String> = []
    ) {
        _text = text
        self.isEditable = isEditable
        self.isActive = isActive
        self.syntax = syntax
        self.availableVariables = availableVariables
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isActive: isActive,
            syntax: syntax,
            availableVariables: availableVariables
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
            availableVariables: availableVariables
        )
        context.coordinator.attach(hostView)
        context.coordinator.updateActivity(isActive, in: textView)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable && isActive
        context.coordinator.updateTextIfNeeded(text, in: textView)
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
            return CGSize(width: max(0, width), height: Self.minimumHeight)
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
            Self.minimumHeight,
            ceil(contentBottom + textView.textContainerInset.height * 2)
        )
        return CGSize(width: width, height: height)
    }

    private static let minimumHeight: CGFloat = 180

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var syntax: BodySyntax
        private var availableVariables: Set<String>
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

        init(
            text: Binding<String>,
            isActive: Bool,
            syntax: BodySyntax,
            availableVariables: Set<String>
        ) {
            self.text = text
            self.isActive = isActive
            self.syntax = syntax
            self.availableVariables = availableVariables
        }

        func attach(_ hostView: NativeHighlightingHostView) {
            self.hostView = hostView
        }

        func updateHighlighting(syntax: BodySyntax, availableVariables: Set<String>) {
            guard self.syntax != syntax || self.availableVariables != availableVariables else {
                return
            }
            self.syntax = syntax
            self.availableVariables = availableVariables
            lastScheduledRequest = nil
            lastAppliedRequest = nil
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
            if let hostView {
                scheduleHighlighting(in: hostView)
            }
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
