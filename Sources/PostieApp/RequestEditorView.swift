import SwiftUI
import PostieCore

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

struct RequestEditorView: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    @State private var selectedSection: EditorSection = .request
    @State private var referencedVariableNames: [String] = []

    private enum EditorSection: Hashable {
        case request
        case authentication
        case variables
        case settings
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
        .task(id: referenceSources) {
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
        }
        .onDisappear {
            discardSecretEdits(for: identity)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Request editor section", selection: $selectedSection) {
                    Text("Request").tag(EditorSection.request)
                    Text("Auth").tag(EditorSection.authentication)
                    Text("Variables").tag(EditorSection.variables)
                    Text("Settings").tag(EditorSection.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let active = model.activeRuns[identity] {
                    activeRunSummary(active)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

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

            ScrollView {
                sectionContent
                    .padding(18)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!model.canEdit(identity))
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionContent: some View {
        ZStack(alignment: .topLeading) {
            retainedSection(requestContent, isActive: selectedSection == .request)
            retainedSection(AuthenticationEditor(identity: identity).id(identity), isActive: selectedSection == .authentication)
            retainedSection(
                VariableEditorView(owner: .request(identity), isActive: selectedSection == .variables)
                    .id(VariableOwner.request(identity)),
                isActive: selectedSection == .variables
            )
            retainedSection(settingsEditor, isActive: selectedSection == .settings)
        }
    }

    private var requestContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            FieldTable(
                title: "Query parameters",
                fields: fieldsBinding(\.query),
                keyPlaceholder: "Name",
                valuePlaceholder: "Value",
                availableVariables: availableVariableNames
            )
            if !pathParameterNames.isEmpty {
                PathParameterTable(
                    names: pathParameterNames,
                    fields: fieldsBinding(\.pathParameters),
                    availableVariables: availableVariableNames
                )
            }
            FieldTable(
                title: "Headers",
                fields: fieldsBinding(\.headers),
                keyPlaceholder: "Header",
                valuePlaceholder: "Value",
                availableVariables: availableVariableNames
            )
            collectionHeaders
            bodyEditor
            referencedVariables
        }
    }

    @ViewBuilder
    private var collectionHeaders: some View {
        if let collection = model.collection(for: identity), !collection.headers.isEmpty {
            DisclosureGroup("Collection headers (\(collection.headers.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Request header names override these defaults. Disable a matching request row to suppress its collection header.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(collection.headers) { field in
                        HStack(alignment: .top) {
                            Image(systemName: field.isEnabled ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(.secondary)
                            Text(field.name).frame(maxWidth: .infinity, alignment: .leading)
                            Text(field.value).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    Button("Edit collection defaults") { model.showCollection(collection.id) }
                }
                .padding(.top, 8)
            }
            .disclosureGroupStyle(PaddedDisclosureGroupStyle())
        }
    }

    @ViewBuilder
    private var referencedVariables: some View {
        if !referencedVariableNames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Referenced variables").font(.headline)
                Text("Up to 128 names from the first 1 MiB of input templates. Secret auth inputs resolve when sending.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(referencedVariableNames, id: \.self) { name in
                    ReferencedVariableRow(
                        identity: identity,
                        name: name,
                        details: variableDetails(name),
                        isActive: Binding(
                            get: { selectedSection == .request },
                            set: { _ in }
                        )
                    )
                    .id(ReferencedVariableRowIdentity(identity: identity, name: name))
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
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

    private func retainedSection<Content: View>(_ content: Content, isActive: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(!isActive)
            .allowsHitTesting(isActive)
            .disabled(!isActive)
            .frame(height: isActive ? nil : 0, alignment: .top)
            .clipped()
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
                isActive: selectedSection == .request,
                syntax: model.request(for: identity)?.bodySyntax ?? .none,
                availableVariables: availableVariableNames
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Path parameters")
                .font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Name")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 19)
                    Text("Value")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary)

                ForEach(names, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(":\(name)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Divider().frame(height: 22)
                        HighlightedTextField(
                            "Value",
                            text: valueBinding(for: name),
                            availableVariables: availableVariables
                        )
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    .padding(.horizontal, 10)
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
