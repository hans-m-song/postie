import SwiftUI
import PostieCore

struct InheritedAuthenticationSummary: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity

    @State private var revealResetKey = UUID()

    private var authentication: RequestAuthentication {
        model.collection(for: identity)?.authentication ?? .init()
    }

    private var variableContext: VariableContext {
        model.variableContext(for: identity)
    }

    private var availableVariables: Set<String> {
        Set(variableContext.global.keys)
            .union(variableContext.collection.keys)
            .union(variableContext.request.keys)
    }

    private var derivedHeader: DerivedHeaderRowPresentation? {
        HeaderPresentation.authenticationRow(
            authentication: authentication,
            source: .collectionAuth,
            requestHeaders: model.request(for: identity)?.headers ?? [],
            availableVariables: availableVariables,
            onReveal: { try await model.previewAuthenticationHeader(for: identity, source: .collectionAuth) },
            onOpenSource: {
                model.showCollection(identity.collectionID, section: .authentication)
            }
        )
    }

    private var resetScope: RevealResetScope {
        RevealResetScope(
            identity: identity,
            authentication: model.collection(for: identity)?.authentication,
            variableContext: variableContext,
            inheritsCollectionAuthentication: model.request(for: identity)?.inheritsCollectionAuthentication ?? false,
            selectedIdentity: model.selectedIdentity,
            selectedCollectionID: model.selectedCollectionID,
            requestEditorSection: model.requestEditorSection(for: identity),
            showsGlobalVariables: model.showsGlobalVariables,
            showsGlobalSettings: model.showsGlobalSettings,
            showsOngoingRequests: model.showsOngoingRequests
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryField(label: "Type", value: authenticationTypeName)

            switch authentication.kind {
            case .none:
                EmptyView()
            case .basic:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Username")
                        .font(.subheadline.weight(.medium))
                    ReadOnlyHighlightedText(
                        "Username",
                        text: authentication.username,
                        availableVariables: availableVariables
                    )
                    .font(.system(.body, design: .monospaced))
                }
            case .bearer:
                EmptyView()
            case .apiKey:
                summaryField(label: "Header name", value: authentication.apiKeyHeaderName ?? "Not set")
            }

            if let derivedHeader {
                DerivedHeaderRow(presentation: derivedHeader, resetKey: revealResetKey.uuidString)
            } else {
                Label("No authentication header is generated.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: resetScope) { _, _ in revealResetKey = UUID() }
    }

    private var authenticationTypeName: String {
        switch authentication.kind {
        case .none: "None"
        case .basic: "Basic"
        case .bearer: "Bearer"
        case .apiKey: "API key"
        }
    }

    private func summaryField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReadOnlyHighlightedText: View {
    let accessibilityLabel: String
    let text: String
    let availableVariables: Set<String>

    init(_ accessibilityLabel: String, text: String, availableVariables: Set<String>) {
        self.accessibilityLabel = accessibilityLabel
        self.text = text
        self.availableVariables = availableVariables
    }

    var body: some View {
        HighlightedTextField(
            accessibilityLabel,
            text: .constant(text),
            availableVariables: availableVariables,
            isReadOnly: true,
            truncationMode: .byTruncatingMiddle
        )
        .environment(\.isEnabled, true)
    }
}

private struct RevealResetScope: Equatable {
    let identity: RequestIdentity
    let authentication: RequestAuthentication?
    let variableContext: VariableContext
    let inheritsCollectionAuthentication: Bool
    let selectedIdentity: RequestIdentity?
    let selectedCollectionID: UUID?
    let requestEditorSection: RequestEditorSection
    let showsGlobalVariables: Bool
    let showsGlobalSettings: Bool
    let showsOngoingRequests: Bool
}
