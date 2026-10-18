import AppKit
import SwiftUI
import PostieCore

private struct VariableInspectionOwnerKey: EnvironmentKey {
    static let defaultValue: VariableOwner? = nil
}

extension EnvironmentValues {
    var variableInspectionOwner: VariableOwner? {
        get { self[VariableInspectionOwnerKey.self] }
        set { self[VariableInspectionOwnerKey.self] = newValue }
    }
}

struct VariableInspection: Equatable {
    let origin: VariableOwner
    let owner: VariableOwner
    let name: String
    let value: VariableValue

    var scopeName: String {
        switch owner {
        case .global: "Global"
        case .collection: "Collection"
        case .request: "Request"
        }
    }
}

enum VariableInspectionMatcher {
    static func reference(in value: String, selection: NSRange, definedNames: Set<String>? = nil) -> TemplateReference? {
        guard value.utf16.prefix(VariableCompletionMatcher.maximumInputLength + 1).count <= VariableCompletionMatcher.maximumInputLength,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        return TemplateEngine.scan(value).references.first {
            (definedNames?.contains($0.name) ?? true) &&
                selection.location >= $0.range.location &&
                selection.location < NSMaxRange($0.range) &&
                NSMaxRange(selection) <= NSMaxRange($0.range)
        }
    }
}

@MainActor
final class VariableInspectionPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var target: VariableInspection?
    private(set) var isPresenting = false
    var isShown: Bool { popover.isShown }
    var isHandlingCurrentEvent: Bool {
        guard let window = popover.contentViewController?.view.window else { return false }
        return NSApp.currentEvent?.window === window
    }

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func show(
        _ inspection: VariableInspection,
        model: AppModel,
        relativeTo rect: NSRect,
        of view: NSView,
        isCurrent: @escaping () -> Bool
    ) {
        guard view.window?.isVisible == true else { return }
        isPresenting = true
        defer { isPresenting = false }
        if target != inspection || !popover.isShown {
            target = inspection
            let controller = NSViewController()
            let hostingView = VariableInspectionHostingView(rootView: VariableInspectionView(
                model: model,
                inspection: inspection,
                isCurrent: isCurrent,
                dismiss: { [weak self] in self?.dismiss() },
                onContentSizeChange: { [weak self] size in
                    guard let self, self.target == inspection else { return }
                    self.updateContentSize(size)
                }
            ))
            hostingView.sizingOptions = [.intrinsicContentSize]
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            hostingView.setFrameSize(fittingSize)
            controller.view = hostingView
            controller.preferredContentSize = fittingSize
            popover.contentViewController = controller
        }
        if popover.isShown {
            popover.positioningRect = rect
        } else {
            popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        }
    }

    func dismiss() {
        if popover.isShown { popover.performClose(nil) }
        target = nil
        popover.contentViewController = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        target = nil
        popover.contentViewController = nil
    }

    private func updateContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let contentSize = NSSize(width: size.width, height: size.height)
        guard abs(popover.contentSize.width - contentSize.width) > 0.5 ||
                abs(popover.contentSize.height - contentSize.height) > 0.5 else { return }
        popover.contentSize = contentSize
    }
}

private final class VariableInspectionHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private struct VariableInspectionValueField: NSViewRepresentable {
    let value: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> VariableInspectionNativeValueField {
        let textField = VariableInspectionNativeValueField(frame: .zero)
        textField.isEnabled = true
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.textColor = .labelColor
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.focusRingType = .none
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.stringValue = value
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ textField: VariableInspectionNativeValueField, context: Context) {
        if textField.stringValue != value { textField.stringValue = value }
        textField.setAccessibilityLabel(accessibilityLabel)
    }
}

private final class VariableInspectionNativeValueField: NSTextField {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
private struct VariableInspectionView: View {
    @ObservedObject var model: AppModel
    let inspection: VariableInspection
    let isCurrent: () -> Bool
    let dismiss: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    @State private var revealedValue: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VariableInspectionValueField(
                    value: isSecretHidden ? "••••••••" : displayValue,
                    accessibilityLabel: isSecretHidden ? "Secret value hidden" : "Variable value"
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)

                if inspection.value.isEncrypted {
                    Button {
                        if revealedValue == nil { reveal() } else { clear() }
                    } label: {
                        Image(systemName: revealedValue == nil ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(isBusy || !model.isCurrent(inspection))
                    .accessibilityLabel(revealedValue == nil ? "Reveal secret" : "Hide secret")
                    .help(revealedValue == nil ? "Reveal secret" : "Hide secret")
                    if isBusy { ProgressView().controlSize(.small) }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            HStack {
                Text(inspection.scopeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    guard isCurrent(), model.isCurrent(inspection) else { return }
                    clear()
                    dismiss()
                    model.showVariableDefinition(inspection)
                } label: {
                    HStack(spacing: 4) {
                        Text("Go to definition")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(!model.isCurrent(inspection))
                .accessibilityLabel("Go to definition")
                .help("Go to definition")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            onContentSizeChange(size)
        }
        .onChange(of: model.isCurrent(inspection)) { _, current in
            if !current { clear(); dismiss() }
        }
        .onDisappear { clear() }
    }

    private var displayValue: String {
        guard model.isCurrent(inspection) else { return "Variable changed" }
        if case let .plain(value) = inspection.value { return value.isEmpty ? "(empty)" : value }
        return revealedValue.map { $0.isEmpty ? "(empty)" : $0 } ?? "Secret value hidden"
    }

    private var isSecretHidden: Bool {
        inspection.value.isEncrypted && revealedValue == nil
    }

    private func reveal() {
        guard isCurrent(), model.isCurrent(inspection), !isBusy else { return }
        clear()
        let id = operationID
        isBusy = true
        revealTask = Task { @MainActor in
            do {
                let value = try await model.revealVariable(named: inspection.name, owner: inspection.owner)
                guard !Task.isCancelled, operationID == id,
                      isCurrent(), model.isCurrent(inspection) else { return }
                revealedValue = value
                isBusy = false
                revealTask = nil
            } catch {
                guard !Task.isCancelled, operationID == id,
                      isCurrent(), model.isCurrent(inspection) else { return }
                errorMessage = error.localizedDescription
                isBusy = false
                revealTask = nil
            }
        }
    }

    private func clear() {
        operationID = UUID()
        revealTask?.cancel()
        revealTask = nil
        revealedValue = nil
        errorMessage = nil
        isBusy = false
    }
}
