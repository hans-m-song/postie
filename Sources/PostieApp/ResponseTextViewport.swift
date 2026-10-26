import AppKit
import PostieCore
import SwiftUI

@MainActor
struct ResponseTextViewport: NSViewRepresentable {
    let text: String
    let syntax: BodySyntax
    let wrapsToWidth: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: text, syntax: syntax)
    }

    func makeNSView(context: Context) -> ResponseTextViewportHostView {
        let textView = NSTextView(usingTextLayoutManager: true)
        configureTextView(textView)
        textView.string = text

        let hostView = ResponseTextViewportHostView(textView: textView, wrapsToWidth: wrapsToWidth)
        context.coordinator.attach(hostView)
        return hostView
    }

    func updateNSView(_ hostView: ResponseTextViewportHostView, context: Context) {
        context.coordinator.attach(hostView)
        hostView.replaceText(text)
        context.coordinator.update(text: text, syntax: syntax)
        hostView.configure(wrapsToWidth: wrapsToWidth)
        context.coordinator.scheduleHighlighting(in: hostView)
    }

    static func dismantleNSView(_ hostView: ResponseTextViewportHostView, coordinator: Coordinator) {
        coordinator.cancelHighlighting()
    }

    private func configureTextView(_ textView: NSTextView) {
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = false
        if let textContainer = textView.textContainer {
            textContainer.lineFragmentPadding = 0
            textContainer.heightTracksTextView = false
        }
    }

    @MainActor
    final class Coordinator {
        private var text: String
        private var syntax: BodySyntax
        private var highlightTask: Task<PreparedResponseHighlighting, Never>?
        private var presentationTask: Task<Void, Never>?
        private var highlightGeneration: UInt64 = 0
        private var lastScheduledRequest: SyntaxHighlighting.Request?
        private var lastAppliedRequest: SyntaxHighlighting.Request?
        private weak var hostView: ResponseTextViewportHostView?

        init(text: String, syntax: BodySyntax) {
            self.text = text
            self.syntax = syntax
        }

        func attach(_ hostView: ResponseTextViewportHostView) {
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
            highlightGeneration &+= 1
            highlightTask?.cancel()
            presentationTask?.cancel()
            hostView?.cancelHighlightingApplication()
        }

        func cancelHighlighting() {
            highlightGeneration &+= 1
            highlightTask?.cancel()
            presentationTask?.cancel()
            highlightTask = nil
            presentationTask = nil
            hostView?.cancelHighlightingApplication()
            hostView = nil
        }

        func scheduleHighlighting(in hostView: ResponseTextViewportHostView) {
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
            highlightGeneration &+= 1
            let generation = highlightGeneration
            highlightTask?.cancel()
            presentationTask?.cancel()

            let task = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else {
                    return PreparedResponseHighlighting.cancelled
                }

                switch ResponseTextInputPolicy.inspect(request.text) {
                case .cancelled:
                    return PreparedResponseHighlighting.cancelled
                case .paused(let reason):
                    return .paused(reason)
                case .ready(let textUTF16Length):
                    let result = SyntaxHighlighting.result(for: request)
                    guard !Task.isCancelled, !result.isCancelled else {
                        return PreparedResponseHighlighting.cancelled
                    }

                    guard !result.isPaused else {
                        return .paused(.byteLimit)
                    }

                    return .ready(spans: result.spans, textUTF16Length: textUTF16Length)
                }
            }
            highlightTask = task
            presentationTask = Task { @MainActor [weak self, weak hostView] in
                let prepared = await task.value
                guard let self,
                    let hostView,
                    generation == self.highlightGeneration,
                    self.hostView === hostView
                else {
                    return
                }

                self.lastAppliedRequest = request
                switch prepared {
                case .cancelled:
                    return
                case .paused(let reason):
                    hostView.setHighlightingPaused(reason: reason)
                case .ready(let spans, let textUTF16Length):
                    hostView.setHighlightingPaused(reason: nil)
                    hostView.replaceHighlightingSpans(spans: spans, textUTF16Length: textUTF16Length)
                }
            }
        }
    }
}

private enum PreparedResponseHighlighting: Sendable {
    case ready(spans: [SyntaxHighlighting.Span], textUTF16Length: Int)
    case paused(ResponseTextInputPolicy.PauseReason)
    case cancelled
}
