import AppKit
import SwiftUI
import PostieCore

struct ReferencedVariableDetails: Equatable {
    let owner: VariableOwner
    let value: VariableValue

    var scopeName: String {
        switch owner {
        case .global: return "Global"
        case .collection(_): return "Collection"
        case .request(_): return "Request"
        }
    }

    static func resolve(name: String, identity: RequestIdentity, context: VariableContext) -> Self? {
        if let value = context.request[name] {
            return Self(owner: .request(identity), value: value)
        }
        if let value = context.collection[name] {
            return Self(owner: .collection(identity.collectionID), value: value)
        }
        if let value = context.global[name] {
            return Self(owner: .global, value: value)
        }
        return nil
    }
}

struct ReferencedVariableRowIdentity: Hashable {
    let identity: RequestIdentity
    let name: String
}

struct ReferencedVariableRow: View {
    @EnvironmentObject private var model: AppModel

    let identity: RequestIdentity
    let name: String
    let details: ReferencedVariableDetails?
    @Binding var isActive: Bool

    @State private var isPopoverPresented = false
    @State private var revealedValue: String?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var didCopy = false
    @State private var operationID = UUID()
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("{{\(name)}}")
                    .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                    .foregroundStyle(details == nil ? Color.red : Color.teal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help("{{\(name)}}")
                if let details {
                    Text(details.scopeName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 66, alignment: .leading)
                    if details.value.isEncrypted {
                        Label("Secret", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .lineLimit(1)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    } else if case let .plain(value) = details.value {
                        Text(value.isEmpty ? "(empty)" : value)
                            .font(.system(size: NSFont.systemFontSize, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 8) {
                        actionButton(title: details.value.isEncrypted ? "Reveal" : "View") {
                            if details.value.isEncrypted { reveal(details) }
                            else { showPlainValue(details) }
                        }
                        actionButton(title: didCopy ? "Copied" : "Copy") { copy(details) }
                    }
                    .frame(width: 90, alignment: .trailing)
                } else {
                    Text("—").foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Text("Missing").foregroundStyle(.red)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 90)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .padding(8)
        .overlay(alignment: .bottom) { Divider() }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
            fullValuePopover
        }
        .onChange(of: isPopoverPresented) { _, isPresented in
            if !isPresented { clearTransientState() }
        }
        .onChange(of: isActive) { _, active in
            if !active { clearTransientState() }
        }
        .onChange(of: identity) { _, _ in clearTransientState() }
        .onChange(of: name) { _, _ in clearTransientState() }
        .onChange(of: details) { _, _ in clearTransientState() }
        .onDisappear { clearTransientState() }
    }

    @ViewBuilder
    private var fullValuePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(details?.value.isEncrypted == true ? "Secret value" : "Variable value")
                    .font(.headline)
                Spacer()
                if details?.value.isEncrypted == true {
                    Button("Hide") { isPopoverPresented = false }
                        .buttonStyle(.borderless)
                }
            }
            if let value = popoverValue {
                ScrollView([.horizontal, .vertical]) {
                    Text(value.isEmpty ? "(empty)" : value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .frame(minWidth: 320, idealWidth: 440, maxWidth: 600, minHeight: 120, maxHeight: 360)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }

    private var popoverValue: String? {
        guard let details,
              isCurrent(details, identity: identity, name: name) else { return nil }
        switch details.value {
        case let .plain(value): return value
        case .encrypted: return revealedValue
        }
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!isActive || isBusy)
    }

    private func showPlainValue(_ target: ReferencedVariableDetails) {
        guard isActive, !isBusy, isCurrent(target, identity: identity, name: name) else { return }
        errorMessage = nil
        didCopy = false
        revealedValue = nil
        isPopoverPresented = true
    }

    private func reveal(_ target: ReferencedVariableDetails) {
        guard isActive, !isBusy, isCurrent(target, identity: identity, name: name) else { return }
        errorMessage = nil
        didCopy = false
        revealedValue = nil
        let capturedIdentity = identity
        let capturedName = name
        let actionID = UUID()
        operationID = actionID
        isBusy = true
        operationTask = Task { @MainActor in
            do {
                guard self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                let value = try await self.model.revealVariable(named: capturedName, owner: target.owner)
                guard !Task.isCancelled,
                      self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                self.revealedValue = value
                self.isBusy = false
                self.operationTask = nil
                self.isPopoverPresented = true
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                self.errorMessage = error.localizedDescription
                self.isBusy = false
                self.operationTask = nil
            }
        }
    }

    private func copy(_ target: ReferencedVariableDetails) {
        guard isActive, !isBusy, isCurrent(target, identity: identity, name: name) else { return }
        errorMessage = nil
        didCopy = false

        switch target.value {
        case let .plain(value):
            guard isCurrent(target, identity: identity, name: name) else { return }
            didCopy = writeToPasteboard(value)
            if !didCopy { errorMessage = "Unable to copy the variable." }
        case .encrypted:
            let capturedIdentity = identity
            let capturedName = name
            let actionID = UUID()
            operationID = actionID
            isBusy = true
            operationTask = Task { @MainActor in
                do {
                    guard self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                    let value = try await self.model.revealVariable(named: capturedName, owner: target.owner)
                    guard !Task.isCancelled,
                          self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                    self.didCopy = self.writeToPasteboard(value)
                    if !self.didCopy { self.errorMessage = "Unable to copy the variable." }
                    self.isBusy = false
                    self.operationTask = nil
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrent(target, identity: capturedIdentity, name: capturedName, operationID: actionID) else { return }
                    self.errorMessage = error.localizedDescription
                    self.isBusy = false
                    self.operationTask = nil
                }
            }
        }
    }

    private func writeToPasteboard(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }

    private func isCurrent(
        _ expected: ReferencedVariableDetails,
        identity expectedIdentity: RequestIdentity,
        name expectedName: String,
        operationID expectedOperationID: UUID? = nil
    ) -> Bool {
        guard isActive,
              identity == expectedIdentity,
              name == expectedName,
              model.selectedIdentity == expectedIdentity,
              model.selectedCollectionID == nil,
              !model.showsGlobalVariables,
              !model.showsOngoingRequests,
              !model.isTerminating,
              model.request(for: expectedIdentity) != nil,
              expectedOperationID.map({ $0 == operationID }) ?? true else { return false }
        let current = ReferencedVariableDetails.resolve(
            name: expectedName,
            identity: expectedIdentity,
            context: model.variableContext(for: expectedIdentity)
        )
        return current == expected
    }

    private func clearTransientState() {
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        revealedValue = nil
        errorMessage = nil
        didCopy = false
        if isPopoverPresented { isPopoverPresented = false }
    }
}
