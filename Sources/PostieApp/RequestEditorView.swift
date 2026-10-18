import SwiftUI
import PostieCore

enum InheritedHeaderStatus {
    static func label(for field: HTTPField, requestHeaders: [HTTPField]) -> String {
        guard field.isEnabled else { return "Disabled" }
        guard !(field.name.isEmpty && field.value.isEmpty) else { return "Inactive" }

        let namedRequestHeaders = requestHeaders.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let collectionNameIsTemplated = hasTemplateSyntax(in: field.name)
        let literalMatches = namedRequestHeaders.filter {
            !collectionNameIsTemplated &&
                !hasTemplateSyntax(in: $0.name) &&
                $0.name.lowercased() == field.name.lowercased()
        }

        if literalMatches.contains(where: \.isEnabled) {
            return "Overridden"
        }
        let requestNameIsTemplated = namedRequestHeaders.contains {
            hasTemplateSyntax(in: $0.name)
        }
        if (collectionNameIsTemplated && !namedRequestHeaders.isEmpty) || requestNameIsTemplated {
            return "Variable dependent"
        }
        if !literalMatches.isEmpty {
            return "Suppressed"
        }

        return "Inherited"
    }

    private static func hasTemplateSyntax(in name: String) -> Bool {
        let scan = TemplateEngine.scan(name)
        return !scan.references.isEmpty || !scan.invalidRanges.isEmpty
    }
}

struct RequestToolbar: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity

    private var availableVariables: Set<String> {
        let context = model.variableContext(for: identity)
        return Set(context.global.keys)
            .union(context.collection.keys)
            .union(context.request.keys)
    }

    private var validPathParameters: Set<String> {
        guard let request = model.request(for: identity) else { return [] }
        return Set(RequestPreparer.pathParameterNames(in: request.url).filter { name in
            let matching = request.pathParameters.filter { $0.name == name && $0.isEnabled }
            return matching.count == 1 && matching[0].value.isEmpty == false
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Request name", text: binding(\.name))
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .disabled(!model.canEdit(identity))
                    .frame(minWidth: 0, maxWidth: .infinity)
                Spacer(minLength: 0)
                if let collection = model.collection(for: identity) {
                    Text(collection.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: 200, alignment: .trailing)
                }
            }

            HStack(spacing: 9) {
                TextField("Method", text: binding(\.method))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 100)
                    .accessibilityLabel("HTTP method")
                    .disabled(!model.canEdit(identity))
                HighlightedTextField(
                    "https://example.com",
                    text: binding(\.url),
                    availableVariables: availableVariables,
                    validPathParameters: validPathParameters,
                    isURL: true,
                    rounded: true,
                    completionVariables: model.variableCompletions(for: identity)
                )
                    .id(identity)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Request URL")
                    .disabled(!model.canEdit(identity))
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(1)
                Button {
                    model.startRequest(identity)
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activeRuns[identity] != nil || !model.canEdit(identity))
                .keyboardShortcut(.return, modifiers: [.command])
                if model.activeRuns[identity] != nil {
                    Button {
                        model.cancelRequest(identity)
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cancel request")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HTTPRequestConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { model.request(for: identity)?[keyPath: keyPath] ?? HTTPRequestConfiguration()[keyPath: keyPath] },
            set: { value in model.updateDraft(identity) { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct RequestEditorReferenceSourcesKey: Hashable {
    let identity: RequestIdentity
    let sources: [String]
}

struct RequestEditorView: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    @State private var referencedVariableNames: [String] = []

    private var selectedSection: RequestEditorSection { model.requestEditorSection(for: identity) }

    private var expansionState: RequestEditorExpansionState {
        model.requestEditorExpansionState(for: identity)
    }

    private var expansionContent: RequestEditorContentSnapshot {
        RequestEditorContentSnapshot(
            queryCount: model.request(for: identity)?.query.count ?? 0,
            pathNames: Set(pathParameterNames)
        )
    }

    private var initiallyExpandedSections: Set<RequestEditorAccordion> {
        Set(RequestEditorAccordion.allCases)
    }

    var body: some View {
        Group {
            if model.request(for: identity) != nil {
                editor
            } else {
                ContentUnavailableView("Request unavailable", systemImage: "doc.questionmark")
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: RequestEditorReferenceSourcesKey(identity: identity, sources: referenceSources)) {
            let sources = referenceSources
            let names = await Task.detached(priority: .utility) {
                var remaining = 1_048_576
                var names = Set<String>()
                for source in sources {
                    guard remaining > 0, names.count < 128 else { break }
                    let bytes = Array(source.utf8.prefix(remaining))
                    remaining -= bytes.count
                    let text = String(decoding: bytes, as: UTF8.self)
                    for reference in TemplateEngine.scan(text).references {
                        guard names.count < 128 else { break }
                        names.insert(reference.name)
                    }
                }
                return names.sorted()
            }.value
            guard !Task.isCancelled else { return }
            referencedVariableNames = names
        }
        .onChange(of: identity) { oldIdentity, _ in
            discardSecretEdits(for: oldIdentity)
            referencedVariableNames = []
        }
        .onDisappear {
            discardSecretEdits(for: identity)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let active = model.activeRuns[identity] {
                activeRunSummary(active)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }

            if let error = model.autosaveErrors[identity] {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Changes were not saved: \(error)")
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { model.retryAutosave(for: identity) }
                        .buttonStyle(.bordered)
                        .disabled(!model.canEdit(identity))
                }
                .font(.caption)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            Divider()

            Picker(
                "Request editor section",
                selection: Binding(
                    get: { selectedSection },
                    set: { model.setRequestEditorSection($0, for: identity) }
                )
            ) {
                Text("Request").tag(RequestEditorSection.request)
                Text("Auth").tag(RequestEditorSection.authentication)
                Text("Variables").tag(RequestEditorSection.variables)
                Text("Settings").tag(RequestEditorSection.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    sectionContent(using: proxy)
                        .padding(18)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    reconcileExpansion()
                    scrollToTab(selectedSection, using: proxy, animated: false)
                    consumeVariableDefinitionRequest()
                }
                .onChange(of: identity) { _, _ in
                    reconcileExpansion()
                    referencedVariableNames = []
                    scrollToTab(selectedSection, using: proxy, animated: false)
                    consumeVariableDefinitionRequest()
                }
                .onChange(of: selectedSection) { _, section in
                    scrollToTab(section, using: proxy, animated: false)
                }
                .onChange(of: expansionContent) { _, _ in
                    reconcileExpansion()
                }
                .onChange(of: model.variableDefinitionRequest?.id) { _, _ in
                    selectVariablesForDefinitionRequest(using: proxy)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionContent(using proxy: ScrollViewProxy) -> some View {
        ZStack(alignment: .topLeading) {
            retainedTabContent(.request) {
                requestTabContent(using: proxy)
            }

            if selectedSection == .authentication {
                authenticationTabContent
            }

            retainedTabContent(.variables) {
                variablesTabContent
            }

            retainedTabContent(.settings) {
                settingsTabContent
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private func requestTabContent(using proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            tabAnchor(.request)

            accordion(.query, title: "Query", summary: rowCount(model.request(for: identity)?.query.count ?? 0), using: proxy) {
                FieldTable(
                    title: "Query parameters",
                    showsTitle: false,
                    fields: fieldsBinding(\.query),
                    keyPlaceholder: "Name",
                    valuePlaceholder: "Value",
                    availableVariables: availableVariableNames,
                    completionVariables: model.variableCompletions(for: identity)
                )
                .id(identity)
            }

            accordion(.path, title: "Path", summary: parameterCount(pathParameterNames.count), using: proxy) {
                PathParameterTable(
                    names: pathParameterNames,
                    fields: fieldsBinding(\.pathParameters),
                    availableVariables: availableVariableNames,
                    completionVariables: model.variableCompletions(for: identity)
                )
                .id(identity)
            }

            accordion(
                .headers,
                title: "Headers",
                summary: headerSummary,
                retainsContent: false,
                using: proxy
            ) {
                if selectedSection == .request {
                    FieldTable(
                        title: "Request headers",
                        showsTitle: false,
                        fields: fieldsBinding(\.headers),
                        keyPlaceholder: "Header",
                        valuePlaceholder: "Value",
                        availableVariables: availableVariableNames,
                        completionVariables: model.variableCompletions(for: identity),
                        inheritedFields: model.collection(for: identity)?.headers ?? [],
                        inheritedFieldStatus: { inheritedHeaderStatus(for: $0) },
                        onOpenInheritedSource: {
                            model.showCollection(identity.collectionID, section: .headers)
                        }
                    )
                    .id(identity)
                }
            }

            accordion(.body, title: "Body", summary: bodySummary, using: proxy) {
                bodyEditor
            }
        }
    }

    private var authenticationTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabAnchor(.authentication)
            AuthenticationEditor(identity: identity).id(identity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var variablesTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            tabAnchor(.variables)
            VariableEditorView(
                owner: .request(identity),
                isActive: selectedSection == .variables
            )
            .id(VariableOwner.request(identity))
            referencedVariables
        }
    }

    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabAnchor(.settings)
            settingsEditor
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retainedTabContent<Content: View>(
        _ section: RequestEditorSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isActive = selectedSection == section
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isActive || !model.canEdit(identity))
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .frame(height: isActive ? nil : 0, alignment: .top)
            .clipped()
    }

    private func tabAnchor(_ section: RequestEditorSection) -> some View {
        Color.clear
            .frame(height: 0)
            .id(section)
            .accessibilityHidden(true)
    }

    private func selectVariablesForDefinitionRequest(using proxy: ScrollViewProxy) {
        guard let definitionRequest = model.variableDefinitionRequest,
              definitionRequest.owner == .request(identity) else { return }
        consumeVariableDefinitionRequest()
        scrollToTab(.variables, using: proxy, animated: true)
    }

    private func consumeVariableDefinitionRequest() {
        guard let definitionRequest = model.variableDefinitionRequest,
              definitionRequest.owner == .request(identity) else { return }
        model.consumeVariableDefinitionRequest(definitionRequest.id)
    }

    private func reconcileExpansion() {
        model.reconcileRequestEditorExpansion(
            for: identity,
            initiallyExpanded: initiallyExpandedSections,
            content: expansionContent
        )
    }

    private func scrollToTab(
        _ section: RequestEditorSection,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let targetIdentity = identity
        DispatchQueue.main.async {
            guard model.selectedIdentity == targetIdentity,
                  model.selectedCollectionID == nil,
                  !model.showsGlobalVariables,
                  !model.showsOngoingRequests,
                  model.requestEditorSection(for: targetIdentity) == section else { return }
            if animated {
                withAnimation { proxy.scrollTo(section, anchor: .top) }
            } else {
                proxy.scrollTo(section, anchor: .top)
            }
        }
    }

    private func scrollToAccordion(
        _ section: RequestEditorAccordion,
        using proxy: ScrollViewProxy,
        animated: Bool,
        requireExpanded: Bool
    ) {
        let targetIdentity = identity
        DispatchQueue.main.async {
            guard model.selectedIdentity == targetIdentity,
                  model.selectedCollectionID == nil,
                  !model.showsGlobalVariables,
                  !model.showsOngoingRequests,
                  model.requestEditorSection(for: targetIdentity) == .request else { return }
            if requireExpanded,
               !model.requestEditorExpansionState(for: targetIdentity).isExpanded(section) { return }
            if animated {
                withAnimation { proxy.scrollTo(section, anchor: .top) }
            } else {
                proxy.scrollTo(section, anchor: .top)
            }
        }
    }

    private func toggleAccordion(_ section: RequestEditorAccordion, using proxy: ScrollViewProxy) {
        let isExpanding = !expansionState.isExpanded(section)
        model.setRequestEditorAccordionExpanded(
            section,
            isExpanded: isExpanding,
            for: identity
        )
        guard isExpanding else { return }
        scrollToAccordion(section, using: proxy, animated: true, requireExpanded: true)
    }

    @ViewBuilder
    private func accordion<Content: View>(
        _ section: RequestEditorAccordion,
        title: String,
        summary: String,
        retainsContent: Bool = true,
        using proxy: ScrollViewProxy,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = expansionState.isExpanded(section)
        VStack(spacing: 0) {
            Button { toggleAccordion(section, using: proxy) } label: {
                HStack(spacing: 9) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse section" : "Expand section")
            .id(section)

            if retainsContent || isExpanded {
                content()
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .accessibilityHidden(!isExpanded)
                    .allowsHitTesting(isExpanded)
                    .disabled(!isExpanded || !model.canEdit(identity))
                    .frame(height: isExpanded ? nil : 0, alignment: .top)
                    .clipped()
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1) }
    }

    private var headerSummary: String {
        let ownCount = model.request(for: identity)?.headers.count ?? 0
        let inheritedCount = model.collection(for: identity)?.headers.count ?? 0
        let parts = [
            ownCount > 0 ? "\(ownCount) own" : nil,
            inheritedCount > 0 ? "\(inheritedCount) inherited" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "No headers" : parts.joined(separator: " · ")
    }

    private var bodySummary: String {
        guard let request = model.request(for: identity) else { return "Disabled" }
        if request.bodyEnabled {
            return request.bodySyntax == .json ? "JSON" : "Enabled"
        }
        return request.body.isEmpty ? "Disabled" : "Content saved"
    }

    private func rowCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "row" : "rows")"
    }

    private func parameterCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "parameter" : "parameters")"
    }

    private func inheritedHeaderStatus(for field: HTTPField) -> String {
        InheritedHeaderStatus.label(
            for: field,
            requestHeaders: model.request(for: identity)?.headers ?? []
        )
    }

    @ViewBuilder
    private var referencedVariables: some View {
        if !referencedVariableNames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Referenced variables").font(.headline)
                Text("Up to 128 names from the first 1 MiB of input templates. Secret auth inputs resolve when sending.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Name").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Text("Scope").frame(width: 66, alignment: .leading)
                        Text("Value").frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 90)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8)
                    .background(.quaternary)
                    ForEach(referencedVariableNames, id: \.self) { name in
                        ReferencedVariableRow(
                            identity: identity,
                            name: name,
                            details: variableDetails(name),
                            isActive: Binding(
                                get: { selectedSection == .variables },
                                set: { _ in }
                            )
                        )
                        .id(ReferencedVariableRowIdentity(identity: identity, name: name))
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.quaternary, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var referenceSources: [String] {
        guard let request = model.request(for: identity) else { return [] }
        let pathNames = Set(RequestPreparer.pathParameterNames(in: request.url))
        var sources = [request.url]
        if let collection = model.collection(for: identity) {
            if request.inheritsCollectionAuthentication && collection.authentication.kind == .basic {
                sources.append(collection.authentication.username)
            }
        }
        sources += (request.query + request.headers).filter(\.isEnabled).flatMap { [$0.name, $0.value] }
        sources += request.pathParameters.filter { $0.isEnabled && pathNames.contains($0.name) }.map(\.value)
        if request.bodyEnabled { sources.append(request.body) }
        if !request.inheritsCollectionAuthentication && request.authentication.kind == .basic { sources.append(request.authentication.username) }
        return sources
    }

    private func variableDetails(_ name: String) -> ReferencedVariableDetails? {
        let context = model.variableContext(for: identity)
        return ReferencedVariableDetails.resolve(name: name, identity: identity, context: context)
    }

    private var pathParameterNames: [String] {
        guard let request = model.request(for: identity) else { return [] }
        return RequestPreparer.pathParameterNames(in: request.url)
    }

    private var availableVariableNames: Set<String> {
        let context = model.variableContext(for: identity)
        return Set(context.global.keys)
            .union(context.collection.keys)
            .union(context.request.keys)
    }

    private func discardSecretEdits(for identity: RequestIdentity) {
        model.discardAuthenticationSecretEdit(field: .password, for: identity)
        model.discardAuthenticationSecretEdit(field: .token, for: identity)
        for name in model.variables(for: .request(identity)).keys {
            model.discardVariableSecretEdit(named: name, owner: .request(identity))
        }
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Body", isOn: binding(\.bodyEnabled))
                    .font(.headline)
                Spacer()
                Picker("Body syntax", selection: binding(\.bodySyntax)) {
                    Text("None").tag(BodySyntax.none)
                    Text("JSON").tag(BodySyntax.json)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(!model.canEdit(identity))
            }
            GrowingBodyEditor(
                text: binding(\.body),
                isEditable: model.canEdit(identity) && (model.request(for: identity)?.bodyEnabled ?? false),
                isActive: selectedSection == .request && expansionState.isExpanded(.body),
                syntax: model.request(for: identity)?.bodySyntax ?? .none,
                availableVariables: availableVariableNames,
                completionVariables: model.variableCompletions(for: identity)
            )
                .id(identity)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
    }

    private var settingsEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Follow redirects", isOn: binding(\.options.followRedirects))
                .toggleStyle(.checkbox)
                .disabled(!model.canEdit(identity))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Timeouts and response limit")
                    .font(.headline)

                HStack {
                    Text("Inactivity timeout")
                    Spacer()
                    TextField("Seconds", value: binding(\.options.inactivityTimeout), format: .number.precision(.fractionLength(0...1)))
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 92)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

                Toggle("Overall deadline", isOn: overallTimeoutEnabled)
                if model.request(for: identity)?.options.overallTimeout != nil {
                    HStack {
                        Text("Overall timeout")
                        Spacer()
                        TextField("Seconds", value: overallTimeoutBinding, format: .number.precision(.fractionLength(0...1)))
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 92)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }

                Toggle("Maximum response size", isOn: responseLimitEnabled)
                if model.request(for: identity)?.options.maximumResponseBytes != nil {
                    HStack {
                        Text("Response limit")
                        Spacer()
                        TextField("Bytes", value: responseLimitBinding, format: .number)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                        Text("bytes")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private var overallTimeoutEnabled: Binding<Bool> {
        Binding(
            get: { model.request(for: identity)?.options.overallTimeout != nil },
            set: { enabled in
                model.updateDraft(identity) {
                    $0.options.overallTimeout = enabled ? HTTPOptions().overallTimeout : nil
                }
            }
        )
    }

    private var overallTimeoutBinding: Binding<Double> {
        Binding(
            get: { model.request(for: identity)?.options.overallTimeout ?? HTTPOptions().overallTimeout ?? 1800 },
            set: { value in
                guard value.isFinite, value > 0 else { return }
                model.updateDraft(identity) { $0.options.overallTimeout = value }
            }
        )
    }

    private var responseLimitEnabled: Binding<Bool> {
        Binding(
            get: { model.request(for: identity)?.options.maximumResponseBytes != nil },
            set: { enabled in
                model.updateDraft(identity) {
                    $0.options.maximumResponseBytes = enabled ? HTTPOptions().maximumResponseBytes : nil
                }
            }
        )
    }

    private var responseLimitBinding: Binding<Int64> {
        Binding(
            get: { model.request(for: identity)?.options.maximumResponseBytes ?? HTTPOptions().maximumResponseBytes ?? 1_073_741_824 },
            set: { value in
                guard value >= 0 else { return }
                model.updateDraft(identity) { $0.options.maximumResponseBytes = value }
            }
        )
    }

    private func activeRunSummary(_ active: AppModel.ActiveRun) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(active.phase == .cancelling ? "Cancelling" : active.runID == nil ? "Preparing request" : "Request running")
                    .lineLimit(1)
                Text(formatDuration(model.elapsed(for: identity) ?? 0))
                    .monospacedDigit()
                if let progress = active.progress {
                    if let expected = progress.expectedBytes, expected > 0 {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(expected))
                            .frame(width: 90)
                            .accessibilityLabel("Response download progress")
                    }
                    Text(byteCount(progress.receivedBytes))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                cancelActiveRunButton(active)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(active.phase == .cancelling ? "Cancelling" : active.runID == nil ? "Preparing" : "Running")
                    .lineLimit(1)
                Text(formatDuration(model.elapsed(for: identity) ?? 0))
                    .monospacedDigit()
                Spacer(minLength: 0)
                cancelActiveRunButton(active)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func cancelActiveRunButton(_ active: AppModel.ActiveRun) -> some View {
        Button("Cancel") {
            model.cancelRequest(identity)
        }
        .disabled(active.phase == .cancelling)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HTTPRequestConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { model.request(for: identity)?[keyPath: keyPath] ?? defaultValue(for: keyPath) },
            set: { value in model.updateDraft(identity) { $0[keyPath: keyPath] = value } }
        )
    }

    private func fieldsBinding(_ keyPath: WritableKeyPath<HTTPRequestConfiguration, [HTTPField]>) -> Binding<[HTTPField]> {
        Binding(
            get: { model.request(for: identity)?[keyPath: keyPath] ?? [] },
            set: { value in model.updateDraft(identity) { $0[keyPath: keyPath] = value } }
        )
    }

    private func defaultValue<Value>(for keyPath: WritableKeyPath<HTTPRequestConfiguration, Value>) -> Value {
        HTTPRequestConfiguration()[keyPath: keyPath]
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1f s", duration)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


private struct PathParameterTable: View {
    let names: [String]
    @Binding var fields: [HTTPField]
    let availableVariables: Set<String>
    var completionVariables: [VariableCompletion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Path parameters")
                .font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 26)
                    Text("Name")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 19)
                    Text("Value")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 26)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.quaternary)

                ForEach(names, id: \.self) { name in
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 26)
                        Text(":\(name)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Divider().frame(height: 22)
                        HighlightedTextField(
                            "Value",
                            text: valueBinding(for: name),
                            availableVariables: availableVariables,
                            completionVariables: completionVariables
                        )
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 0, maxWidth: .infinity)
                        Color.clear.frame(width: 26)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    if name != names.last {
                        Divider()
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func valueBinding(for name: String) -> Binding<String> {
        Binding(
            get: {
                fields.first { $0.name == name && $0.isEnabled }?.value
                    ?? fields.first { $0.name == name }?.value
                    ?? ""
            },
            set: { value in
                let matchingIndices = fields.indices.filter { fields[$0].name == name }
                guard let preferredIndex = matchingIndices.first(where: { fields[$0].isEnabled })
                        ?? matchingIndices.first else {
                    fields.append(HTTPField(name: name, value: value))
                    return
                }

                fields[preferredIndex].value = value
                fields[preferredIndex].isEnabled = true
                for index in matchingIndices where index != preferredIndex {
                    fields[index].isEnabled = false
                }
            }
        )
    }
}
