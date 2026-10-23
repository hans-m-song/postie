import SwiftUI
import PostieCore

struct AutomationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var service = AutomationService.shared
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automation").font(.headline)
            Toggle(
                "Enable MCP server",
                isOn: Binding(
                    get: { service.enabled }, set: { value in Task { await service.setEnabled(value) } }
                )
            )
            .disabled(service.isChanging)
            Text(service.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text("Local port")
                TextField("49157", text: $port).frame(width: 90)
                Button("Apply") {
                    guard let port = Int(port) else { return }
                    Task { await service.setPort(port) }
                }
                .disabled(service.isChanging || (Int(port).map { !(1024...65535).contains($0) } ?? true))
            }
            Button("Copy Codex configuration (includes access token)") {
                Task { await service.copyCodexConfiguration() }
            }
            .disabled(!service.enabled || service.isChanging)
            Picker(
                "MCP response viewing",
                selection: Binding(
                    get: { model.globalMCPResponseViewing },
                    set: { value in Task { await model.saveGlobalMCPResponseViewing(value) } }
                )
            ) {
                Text(MCPResponseViewPolicy.block.displayName).tag(MCPResponseViewPolicy.block)
                Text(MCPResponseViewPolicy.allow.displayName).tag(MCPResponseViewPolicy.allow)
                Text(MCPResponseViewPolicy.unredacted.displayName).tag(MCPResponseViewPolicy.unredacted)
            }
            .disabled(model.globalOptionsAreReadOnly)
            Text(service.localStatus).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { port = String(service.port) }
    }
}

struct MCPResourceSettingsView: View {
    let policy: MCPResourcePolicy
    let inheritedDescription: String
    let isReadOnly: Bool
    let onChange: (MCPResourcePolicy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP access").font(.headline)
            Toggle(
                "Exclude from MCP",
                isOn: Binding(
                    get: { policy.excluded },
                    set: { value in
                        var changed = policy; changed.excluded = value; onChange(changed)
                    }
                ))
            Picker(
                "Response viewing",
                selection: Binding(
                    get: { policy.responseViewing },
                    set: { value in
                        var changed = policy; changed.responseViewing = value; onChange(changed)
                    }
                )
            ) {
                Text("Inherit (\(inheritedDescription))").tag(MCPResponseViewPolicy.inherit)
                Text(MCPResponseViewPolicy.block.displayName).tag(MCPResponseViewPolicy.block)
                Text(MCPResponseViewPolicy.allow.displayName).tag(MCPResponseViewPolicy.allow)
                Text(MCPResponseViewPolicy.unredacted.displayName).tag(MCPResponseViewPolicy.unredacted)
            }
            Text("An excluded collection also excludes its requests and snapshots.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(isReadOnly)
    }
}
