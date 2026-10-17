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
    static func reference(in value: String, selection: NSRange) -> TemplateReference? {
        guard value.utf16.prefix(VariableCompletionMatcher.maximumInputLength + 1).count <= VariableCompletionMatcher.maximumInputLength,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count,
              selection.length <= value.utf16.count - selection.location else { return nil }
        return TemplateEngine.scan(value).references.first {
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
            controller.view = VariableInspectionHostingView(rootView: VariableInspectionView(
                model: model,
                inspection: inspection,
                isCurrent: isCurrent,
                dismiss: { [weak self] in self?.dismiss() }
            ))
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 360, height: 170)
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
}

private final class VariableInspectionHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }
}

private struct VariableInspectionView: View {
    @ObservedObject var model: AppModel
    let inspection: VariableInspection
    let isCurrent: () -> Bool
    let dismiss: () -> Void

    @State private var revealedValue: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("{{\(inspection.name)}}")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(inspection.scopeName).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(displayValue)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            HStack {
                if inspection.value.isEncrypted {
                    Button(revealedValue == nil ? "Reveal" : "Hide") {
                        if revealedValue == nil { reveal() } else { clear() }
                    }
                    .focusable(false)
                    .disabled(isBusy || !model.isCurrent(inspection))
                    if isBusy { ProgressView().controlSize(.small) }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Button("Go to definition") {
                    guard isCurrent(), model.isCurrent(inspection) else { return }
                    clear()
                    dismiss()
                    model.showVariableDefinition(inspection)
                }
                .focusable(false)
                .disabled(!model.isCurrent(inspection))
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360, height: 170)
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
