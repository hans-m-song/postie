import AppKit
import Combine

@MainActor
final class ResponseTextViewportHostView: NSView {
    let textView: NSTextView

    private let scrollView = NSScrollView()
    private let clipView = NSClipView(frame: .zero)
    private let pausedLabel = NSTextField(labelWithString: "")
    private let highlightingState: ResponseTextHighlightingState
    private var clipBoundsObserver: AnyCancellable?
    private var wrapsToWidth: Bool
    private var lastLayoutSize: NSSize?

    init(textView: NSTextView, wrapsToWidth: Bool) {
        self.textView = textView
        self.wrapsToWidth = wrapsToWidth
        highlightingState = ResponseTextHighlightingState(textView: textView)
        super.init(frame: .zero)

        scrollView.contentView = clipView
        clipView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.publisher(
            for: NSView.boundsDidChangeNotification,
            object: clipView
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.highlightingState.pausePendingBatchesBriefly()
            }
        }
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsToWidth
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        pausedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pausedLabel.textColor = .secondaryLabelColor
        pausedLabel.backgroundColor = .controlBackgroundColor
        pausedLabel.drawsBackground = true
        pausedLabel.isBordered = false
        pausedLabel.isHidden = true
        addSubview(pausedLabel)

        configure(wrapsToWidth: wrapsToWidth)
        resetTextViewSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(wrapsToWidth: Bool) {
        guard self.wrapsToWidth != wrapsToWidth else {
            return
        }

        self.wrapsToWidth = wrapsToWidth
        highlightingState.pausePendingBatchesBriefly()
        scrollView.hasHorizontalScroller = !wrapsToWidth
        resetTextViewSize()
    }

    func replaceText(_ text: String) {
        guard textView.string != text else {
            return
        }

        let textUTF16Length = (text as NSString).length
        highlightingState.resetForTextReplacement(textUTF16Length: textUTF16Length)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        resetTextViewSize()
    }

    func cancelHighlightingApplication() {
        highlightingState.cancelPendingApplication()
    }

    func replaceHighlightingSpans(spans: [SyntaxHighlighting.Span], textUTF16Length: Int) {
        highlightingState.replace(spans: spans, textUTF16Length: textUTF16Length)
    }

    func setHighlightingPaused(reason: ResponseTextInputPolicy.PauseReason?) {
        guard let reason else {
            pausedLabel.isHidden = true
            needsLayout = true
            return
        }

        pausedLabel.stringValue = reason.message
        pausedLabel.setAccessibilityLabel(reason.message)
        pausedLabel.isHidden = false
        needsLayout = true
    }

    func resetTextViewSize() {
        let viewportSize = scrollView.contentSize
        textView.isHorizontallyResizable = !wrapsToWidth
        textView.autoresizingMask = wrapsToWidth ? [.width] : []
        textView.setFrameSize(
            NSSize(
                width: max(1, viewportSize.width),
                height: max(1, viewportSize.height)
            )
        )

        updateTextContainerGeometry(viewportSize: viewportSize)
    }

    private func updateTextContainerGeometry(viewportSize: NSSize? = nil) {
        let viewportSize = viewportSize ?? scrollView.contentSize
        textView.isHorizontallyResizable = !wrapsToWidth
        textView.autoresizingMask = wrapsToWidth ? [.width] : []
        let textViewSize = NSSize(
            width: wrapsToWidth ? max(1, viewportSize.width) : max(viewportSize.width, textView.frame.width),
            height: max(viewportSize.height, textView.frame.height)
        )
        if textView.frame.size != textViewSize {
            textView.setFrameSize(textViewSize)
        }

        guard let textContainer = textView.textContainer else {
            return
        }

        textContainer.widthTracksTextView = wrapsToWidth
        textContainer.heightTracksTextView = false
        let containerSize =
            wrapsToWidth
            ? NSSize(
                width: max(1, viewportSize.width - textView.textContainerInset.width * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
            : NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        if textContainer.size != containerSize {
            textContainer.size = containerSize
        }
    }

    override func layout() {
        super.layout()
        let resized = lastLayoutSize.map { $0 != bounds.size } ?? true
        lastLayoutSize = bounds.size
        scrollView.frame = bounds
        updateTextContainerGeometry()
        if resized {
            highlightingState.pausePendingBatchesBriefly()
        }

        pausedLabel.sizeToFit()
        pausedLabel.setFrameOrigin(
            NSPoint(
                x: max(4, bounds.maxX - pausedLabel.frame.width - 8),
                y: max(4, bounds.maxY - pausedLabel.frame.height - 8)
            )
        )
    }
}
