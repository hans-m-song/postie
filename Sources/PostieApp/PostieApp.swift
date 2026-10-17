import SwiftUI
import AppKit

@MainActor
private final class PostieAppDelegate: NSObject, NSApplicationDelegate {
    private var isPreparingForTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingForTermination else { return .terminateLater }
        isPreparingForTermination = true
        Task { @MainActor [weak self] in
            let mayTerminate = await AppModel.shared.prepareForTermination()
            self?.isPreparingForTermination = false
            sender.reply(toApplicationShouldTerminate: mayTerminate)
        }
        return .terminateLater
    }
}

@main
struct PostieApp: App {
    @NSApplicationDelegateAdaptor(PostieAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Search Requests…") { model.showRequestSearch() }
                    .keyboardShortcut("k", modifiers: [.command])
                Button("Requests") { model.showRequests() }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Ongoing Requests") { model.showOngoingRequests() }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Global Variables") { model.showGlobalVariables() }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}
