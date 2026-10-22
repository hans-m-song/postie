import SwiftUI
import AppKit

@MainActor
private final class PostieAppDelegate: NSObject, NSApplicationDelegate {
    private var isPreparingForTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingForTermination else { return .terminateLater }
        isPreparingForTermination = true
        Task { @MainActor [weak self] in
            let automationStopped = await AutomationService.shared.stop()
            let mayTerminate = automationStopped ? await AppModel.shared.prepareForTermination() : false
            if !mayTerminate { await AutomationService.shared.start() }
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
    @AppStorage(AppTheme.preferenceKey) private var theme = AppTheme.system

    init() {
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await AutomationService.shared.start() }
                .preferredColorScheme(theme.colorScheme)
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showGlobalSettings() }
                    .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button("Back") { model.navigateBack() }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!model.canNavigateBack)
                Button("Forward") { model.navigateForward() }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!model.canNavigateForward)
                Divider()
                Button("Search Workspace…") { model.showRequestSearch() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("Workspace Commands…") { model.showRequestSearch(query: ">") }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Search Requests…") { model.showRequestSearch(query: "@") }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Requests") { model.showRequests() }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Request History") { model.showOngoingRequests() }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Global Variables") { model.showGlobalVariables() }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }
    }
}
