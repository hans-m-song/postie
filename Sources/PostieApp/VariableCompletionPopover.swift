import AppKit
import PostieCore

@MainActor
final class VariableCompletionPopover {
    private let popover = NSPopover()
    private let controller = VariableCompletionPopoverController()

    var onSelection: ((Int) -> Void)? {
        didSet {
            controller.listView.onSelection = onSelection
        }
    }

    var isShown: Bool { popover.isShown }

    init() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
    }

    func update(suggestions: [VariableCompletion], selectedIndex: Int) {
        controller.update(suggestions: suggestions, selectedIndex: selectedIndex)
        popover.contentSize = controller.visibleContentSize(for: suggestions.count)
        controller.scrollSelectionIntoView()
    }

    func show(
        relativeTo anchor: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge,
        suggestions: [VariableCompletion],
        selectedIndex: Int
    ) {
        update(suggestions: suggestions, selectedIndex: selectedIndex)
        guard let window = view.window,
              window.isVisible else {
            return
        }
        if popover.isShown {
            popover.positioningRect = anchor
            return
        }
        popover.show(relativeTo: anchor, of: view, preferredEdge: preferredEdge)
    }

    func dismiss() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}

@MainActor
private final class VariableCompletionPopoverController: NSViewController {
    let listView = VariableCompletionListView()
    private let scrollView = VariableCompletionScrollView()

    override func loadView() {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView
        view = scrollView
    }

    func update(suggestions: [VariableCompletion], selectedIndex: Int) {
        loadViewIfNeeded()
        listView.update(suggestions: suggestions, selectedIndex: selectedIndex)
    }

    func visibleContentSize(for suggestionCount: Int) -> NSSize {
        NSSize(
            width: listView.intrinsicContentSize.width,
            height: listView.rowHeight * CGFloat(min(max(1, suggestionCount), listView.maximumVisibleRows))
        )
    }

    func scrollSelectionIntoView() {
        listView.scrollSelectionIntoView()
    }
}

@MainActor
private final class VariableCompletionScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private final class VariableCompletionListView: NSView {
    fileprivate let rowHeight: CGFloat = 44
    fileprivate let maximumVisibleRows = 6
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
        setFrameSize(intrinsicContentSize)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func scrollSelectionIntoView() {
        guard suggestions.indices.contains(selectedIndex) else { return }
        let rowRect = NSRect(
            x: 0,
            y: rowHeight * CGFloat(selectedIndex),
            width: bounds.width,
            height: rowHeight
        )
        _ = scrollToVisible(rowRect)
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
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textColor,
                .paragraphStyle: singleLineParagraphStyle()
            ]
            let detailColor = isSelected ? textColor : NSColor.secondaryLabelColor
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: detailColor,
                .paragraphStyle: singleLineParagraphStyle()
            ]
            let metadata = suggestion.isSecret
                ? "\(scopeLabel(suggestion.scope)) · 🔒 Secret"
                : scopeLabel(suggestion.scope)
            let metadataSize = (metadata as NSString).size(withAttributes: detailAttributes)
            let metadataWidth = min(metadataSize.width, bounds.width * 0.52)
            let detailY = rowRect.minY + 24
            let metadataRect = NSRect(x: bounds.width - metadataWidth - 10, y: detailY, width: metadataWidth, height: 15)
            let nameRect = NSRect(x: 10, y: rowRect.minY + 4, width: bounds.width - 20, height: 17)
            let previewRect = NSRect(x: 10, y: detailY, width: max(0, metadataRect.minX - 18), height: 15)
            (suggestion.name as NSString).draw(in: nameRect, withAttributes: nameAttributes)
            if let preview = suggestion.preview, !suggestion.isSecret {
                (preview as NSString).draw(in: previewRect, withAttributes: detailAttributes)
            }
            (metadata as NSString).draw(in: metadataRect, withAttributes: detailAttributes)
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

    private func singleLineParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }
}
