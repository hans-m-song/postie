import AppKit
import PostieCore
import SwiftUI

@MainActor
struct HighlightedResponseText: NSViewRepresentable {
    let text: String
    let syntax: BodySyntax

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, syntax: syntax)
    }

    func makeNSView(context: Context) -> NativeHighlightingHostView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.drawsBackground = false
        textView.string = text

        let hostView = NativeHighlightingHostView(textView: textView)
        context.coordinator.attach(hostView)
        return hostView
    }

    func updateNSView(_ hostView: NativeHighlightingHostView, context: Context) {
        let textView = hostView.textView
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.update(text: text, syntax: syntax)
        context.coordinator.attach(hostView)
        context.coordinator.scheduleHighlighting(in: hostView)
    }

    static func dismantleNSView(_ hostView: NativeHighlightingHostView, coordinator: Coordinator) {
        coordinator.cancelHighlighting()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView hostView: NativeHighlightingHostView,
        context: Context
    ) -> CGSize? {
        let textView = hostView.textView
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return nil
        }

        textContainer.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineRect = layoutManager.extraLineFragmentRect
        let inset = textView.textContainerInset
        let width = ceil(max(usedRect.maxX, extraLineRect.maxX) + inset.width * 2)
        let fontHeight = textView.font?.boundingRectForFont.height ?? NSFont.systemFontSize
        let height = ceil(max(max(usedRect.maxY, extraLineRect.maxY), fontHeight) + inset.height * 2)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    @MainActor
    final class Coordinator {
        private var text: String
        private var syntax: BodySyntax
        private var highlightTask: Task<SyntaxHighlighting.Result, Never>?
        private var presentationTask: Task<Void, Never>?
        private var highlightGeneration = 0
        private var lastScheduledRequest: SyntaxHighlighting.Request?
        private var lastAppliedRequest: SyntaxHighlighting.Request?
        private weak var hostView: NativeHighlightingHostView?

        init(text: String, syntax: BodySyntax) {
            self.text = text
            self.syntax = syntax
        }

        func attach(_ hostView: NativeHighlightingHostView) {
            self.hostView = hostView
        }

        func update(text: String, syntax: BodySyntax) {
            guard self.text != text || self.syntax != syntax else {
                return
            }
            self.text = text
            self.syntax = syntax
            lastScheduledRequest = nil
            lastAppliedRequest = nil
        }

        func cancelHighlighting() {
            highlightTask?.cancel()
            presentationTask?.cancel()
            highlightTask = nil
            presentationTask = nil
            hostView = nil
        }

        func scheduleHighlighting(in hostView: NativeHighlightingHostView) {
            let request = SyntaxHighlighting.Request(
                text: text,
                syntax: syntax,
                availableVariables: [],
                validPathParameters: [],
                isURL: false,
                highlightsTemplates: false
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

                self.lastAppliedRequest = request
                hostView.setHighlightingPaused(result.isPaused)
                SyntaxHighlighting.apply(result, to: hostView.textView)
            }
        }
    }
}
