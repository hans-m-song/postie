import SwiftUI
import PostieCore

struct RequestToolbar: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity

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
                    .frame(width: 100)
                    .accessibilityLabel("HTTP method")
                    .disabled(!model.canEdit(identity))
                TextField("https://example.com", text: binding(\.url))
                    .textFieldStyle(.roundedBorder)
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

    private enum EditorSection: Hashable {
        case request
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
    }

    private var editor: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Request editor section", selection: $selectedSection) {
                    Text("Request").tag(EditorSection.request)
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
            retainedSection(settingsEditor, isActive: selectedSection == .settings)
        }
    }

    private var requestContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            FieldTable(
                title: "Query parameters",
                fields: fieldsBinding(\.query),
                keyPlaceholder: "Name",
                valuePlaceholder: "Value"
            )
            if !pathParameterNames.isEmpty {
                PathParameterTable(
                    names: pathParameterNames,
                    fields: fieldsBinding(\.pathParameters)
                )
            }
            FieldTable(
                title: "Headers",
                fields: fieldsBinding(\.headers),
                keyPlaceholder: "Header",
                valuePlaceholder: "Value"
            )
            bodyEditor
        }
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

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Body", isOn: binding(\.bodyEnabled))
                    .font(.headline)
            }
            GrowingBodyEditor(
                text: binding(\.body),
                isEditable: model.canEdit(identity) && (model.request(for: identity)?.bodyEnabled ?? false),
                isActive: selectedSection == .request
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
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
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

private struct FieldTable: View {
    let title: String
    @Binding var fields: [HTTPField]
    let keyPlaceholder: String
    let valuePlaceholder: String
    @State private var trailingField = HTTPField()
    @FocusState private var focusedField: FieldFocus?

    private enum FieldFocus: Hashable {
        case name(UUID)
        case value(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.headline)
            }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 26)
                    Text(keyPlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 19)
                    Text(valuePlaceholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 26)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary)

                ForEach(fields + [trailingField]) { field in
                    let isTrailingField = field.id == trailingField.id
                    HStack(spacing: 8) {
                        if isTrailingField {
                            Color.clear.frame(width: 26)
                        } else {
                            Toggle("Enabled", isOn: enabledBinding(for: field.id))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Enable this row")
                        }
                        TextField(keyPlaceholder, text: textBinding(for: field.id, keyPath: \.name))
                            .textFieldStyle(.plain)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .focused($focusedField, equals: .name(field.id))
                        Divider().frame(height: 22)
                        TextField(valuePlaceholder, text: textBinding(for: field.id, keyPath: \.value))
                            .textFieldStyle(.plain)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .focused($focusedField, equals: .value(field.id))
                        if isTrailingField {
                            Color.clear.frame(width: 26)
                        } else {
                            Button(role: .destructive) {
                                fields.removeAll { $0.id == field.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 26)
                            .help("Remove row")
                            .focusable(false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    Divider()
                }

            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func textBinding(
        for id: UUID,
        keyPath: WritableKeyPath<HTTPField, String>
    ) -> Binding<String> {
        Binding(
            get: { field(for: id)?[keyPath: keyPath] ?? "" },
            set: { value in
                updateField(id) { $0[keyPath: keyPath] = value }
                guard trailingField.id == id,
                      !trailingField.name.isEmpty || !trailingField.value.isEmpty else { return }
                fields.append(trailingField)
                trailingField = HTTPField()
            }
        )
    }

    private func enabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { field(for: id)?.isEnabled ?? true },
            set: { isEnabled in updateField(id) { $0.isEnabled = isEnabled } }
        )
    }

    private func field(for id: UUID) -> HTTPField? {
        fields.first { $0.id == id } ?? (trailingField.id == id ? trailingField : nil)
    }

    private func updateField(_ id: UUID, update: (inout HTTPField) -> Void) {
        if let index = fields.firstIndex(where: { $0.id == id }) {
            update(&fields[index])
        } else if trailingField.id == id {
            update(&trailingField)
        }
    }
}

private struct PathParameterTable: View {
    let names: [String]
    @Binding var fields: [HTTPField]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Path parameters")
                .font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 19)
                    Text("Value")
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        TextField("Value", text: valueBinding(for: name))
                            .textFieldStyle(.plain)
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
