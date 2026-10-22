import SwiftUI
import PostieCore

struct CollectionEditorView: View {
    @EnvironmentObject private var model: AppModel
    let collectionID: UUID
    private var section: CollectionEditorSection { model.collectionEditorSection }

    private var owner: VariableOwner { .collection(collectionID) }
    private var availableVariables: Set<String> {
        Set(model.globalVariables.keys).union(model.variables(for: owner).keys)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let collection = model.collection(id: collectionID) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.name).font(.title2.weight(.semibold))
                    Text("Browse requests and configure shared variables, headers, authentication, and MCP access.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker(
                        "Collection section",
                        selection: Binding(
                            get: { model.collectionEditorSection },
                            set: { model.setCollectionEditorSection($0) }
                        )
                    ) {
                        Text("Requests").tag(CollectionEditorSection.requests)
                        Text("Variables").tag(CollectionEditorSection.variables)
                        Text("Headers").tag(CollectionEditorSection.headers)
                        Text("Auth").tag(CollectionEditorSection.authentication)
                        Text("Settings").tag(CollectionEditorSection.settings)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                .padding(18)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if section != .variables, let error = model.variableSaveErrors[owner] {
                            Label("Changes were not saved: \(error)", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ZStack(alignment: .topLeading) {
                            retained(
                                CollectionRequestsView(collectionID: collectionID),
                                active: section == .requests,
                                requiresEditableOwner: false
                            )
                            retained(
                                VariableEditorView(owner: owner, isActive: section == .variables),
                                active: section == .variables)
                            retained(
                                FieldTable(
                                    title: "Collection headers",
                                    fields: Binding(
                                        get: { model.collection(id: collectionID)?.headers ?? [] },
                                        set: { model.updateCollectionHeaders($0, in: collectionID) }
                                    ), keyPlaceholder: "Header", valuePlaceholder: "Value",
                                    availableVariables: availableVariables,
                                    completionVariables: model.variableCompletions(for: owner), parameterWrapping: true),
                                active: section == .headers)
                            retained(
                                AuthenticationEditor(collectionID: collectionID), active: section == .authentication)
                            retained(
                                VStack(alignment: .leading, spacing: 12) {
                                    MCPResourceSettingsView(
                                        policy: collection.mcpPolicy,
                                        inheritedDescription: MCPResponseViewPolicy.resolveMode(
                                            global: model.globalMCPResponseViewing
                                        ).displayName,
                                        isReadOnly: collection.isReadOnly
                                    ) { policy in
                                        Task { await model.updateCollectionMCPPolicy(policy, for: collectionID) }
                                    }
                                }, active: section == .settings, requiresEditableOwner: false)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Collection unavailable", systemImage: "folder.badge.questionmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .onDisappear {
            model.discardAuthenticationSecretEdit(field: .password, owner: owner)
            model.discardAuthenticationSecretEdit(field: .token, owner: owner)
        }
    }

    private func retained<Content: View>(
        _ content: Content,
        active: Bool,
        requiresEditableOwner: Bool = true
    ) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!active || (requiresEditableOwner && !model.canEditVariables(owner)))
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .frame(height: active ? nil : 0, alignment: .top)
            .clipped()
    }
}
