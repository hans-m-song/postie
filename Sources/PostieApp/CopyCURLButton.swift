import AppKit
import PostieCore
import SwiftUI

struct CopyCURLButton: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    @State private var copyTask: Task<Void, Never>?
    @State private var isCopying = false
    @State private var didCopy = false
    @State private var copyError: String?

    var body: some View {
        Button(action: copy) {
            Label(didCopy ? "Copied cURL" : "Copy as cURL", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Copy as cURL (includes resolved secrets)")
        .disabled(isCopying || model.request(for: identity) == nil)
        .onChange(of: identity) { _, _ in reset() }
        .onDisappear(perform: reset)
        .alert(
            "Could not copy cURL",
            isPresented: Binding(
                get: { copyError != nil }, set: { if !$0 { copyError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { copyError = nil }
        } message: {
            Text(copyError ?? "The request could not be prepared.")
        }
    }

    private func copy() {
        copyTask?.cancel()
        isCopying = true
        didCopy = false
        copyError = nil
        let requestedIdentity = identity
        copyTask = Task { @MainActor in
            do {
                let command = try await model.curlCommand(for: requestedIdentity)
                guard !Task.isCancelled, model.selectedIdentity == requestedIdentity else { return }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(command, forType: .string) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                isCopying = false
                didCopy = true
                try await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                didCopy = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isCopying = false
                copyError = error.localizedDescription
            }
        }
    }

    private func reset() {
        copyTask?.cancel()
        copyTask = nil
        isCopying = false
        didCopy = false
        copyError = nil
    }
}
