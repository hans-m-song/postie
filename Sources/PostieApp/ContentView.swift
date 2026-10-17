import SwiftUI
import PostieCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var namePrompt: NamePrompt?
    @State private var deletionTarget: DeletionTarget?

    var body: some View {
        NavigationSplitView {
            SidebarView(namePrompt: $namePrompt, deletionTarget: $deletionTarget)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .disabled(model.isTerminating)
        .sheet(item: $namePrompt) { prompt in
            NameInputSheet(prompt: prompt)
        }
        .confirmationDialog(
            deletionTarget?.title ?? "Delete item?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let deletionTarget else { return }
                Task {
                    switch deletionTarget {
                    case let .collection(id): await model.deleteCollection(id: id)
                    case let .request(identity): await model.deleteRequest(identity)
                    }
                    self.deletionTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("This removes the saved configuration from this workspace.")
        }
        .alert("Postie", isPresented: Binding(
            get: { model.operationError != nil },
            set: { if !$0 { model.operationError = nil } }
        )) {
            Button("OK", role: .cancel) { model.operationError = nil }
        } message: {
            Text(model.operationError ?? "An unexpected error occurred.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.startupError {
            ContentUnavailableView(
                "Postie could not open its workspace",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(error)
            )
        } else if model.showsOngoingRequests {
            OngoingRequestsView()
        } else if let identity = model.selectedIdentity {
            VStack(spacing: 0) {
                RequestToolbar(identity: identity)
                Divider()
                RequestResponseSplit(model: model, identity: identity)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No request selected",
                systemImage: "arrow.up.right.square",
                description: Text("Create a collection and add a request to get started.")
            )
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.tint)
                Text("Postie")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Button {
                model.showRequests()
            } label: {
                Label("Requests", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(!model.showsOngoingRequests ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))

            Button {
                model.showOngoingRequests()
            } label: {
                HStack {
                    Label("Ongoing Requests", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if model.activeRunCount > 0 {
                        Text("\(model.activeRunCount)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(model.showsOngoingRequests ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))

            Divider()
                .padding(.vertical, 12)

            HStack {
                Text("COLLECTIONS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    namePrompt = NamePrompt(
                        title: "New Collection",
                        initialValue: "",
                        placeholder: "Collection name",
                        submitTitle: "Create"
                    ) { name in
                        Task { await model.createCollection(name: name) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Create collection")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.collections) { collection in
                        CollectionSidebarSection(
                            collection: collection,
                            namePrompt: $namePrompt,
                            deletionTarget: $deletionTarget
                        )
                    }

                    if !model.storageIssues.isEmpty {
                        storageIssues
                    }

                    if let error = model.startupError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var storageIssues: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECOVERY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.storageIssues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if issue.canRecover {
                        Button("Recover request") {
                            Task { await model.recover(issue) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct CollectionSidebarSection: View {
    @EnvironmentObject private var model: AppModel
    let collection: RequestCollection
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(collection.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
                if !collection.isReadOnly {
                    Menu {
                        Button("New request") {
                            namePrompt = NamePrompt(
                                title: "New Request",
                                initialValue: "New request",
                                placeholder: "Request name",
                                submitTitle: "Create"
                            ) { name in
                                Task { await model.createRequest(in: collection.id, name: name) }
                            }
                        }
                        Button("Rename collection") {
                            namePrompt = NamePrompt(
                                title: "Rename Collection",
                                initialValue: collection.name,
                                placeholder: "Collection name",
                                submitTitle: "Save"
                            ) { name in
                                Task { await model.renameCollection(id: collection.id, name: name) }
                            }
                        }
                        Divider()
                        Button("Delete collection", role: .destructive) {
                            deletionTarget = .collection(collection.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 6)

            if isExpanded {
                if collection.requests.isEmpty {
                    Text("No requests")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 34)
                        .padding(.vertical, 5)
                }
                ForEach(Array(collection.requests.enumerated()), id: \.element.id) { index, request in
                    let identity = RequestIdentity(collectionID: collection.id, requestID: request.id)
                    RequestSidebarRow(
                        request: request,
                        identity: identity,
                        canMoveUp: index > 0,
                        canMoveDown: index + 1 < collection.requests.count,
                        canEdit: model.canEdit(identity),
                        namePrompt: $namePrompt,
                        deletionTarget: $deletionTarget
                    )
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RequestSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let request: HTTPRequestConfiguration
    let identity: RequestIdentity
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canEdit: Bool
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?

    private var currentRequest: HTTPRequestConfiguration {
        model.request(for: identity) ?? request
    }

    var body: some View {
        Button {
            model.select(identity)
        } label: {
            HStack(spacing: 8) {
                if let active = model.activeRuns[identity] {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14)
                        .accessibilityLabel(active.phase == .cancelling ? "Cancelling" : "Request in progress")
                } else {
                    Text(currentRequest.method.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(methodColor(currentRequest.method))
                        .frame(width: 32, alignment: .leading)
                }
                Text(currentRequest.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
            .padding(.leading, 28)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(model.selectedIdentity == identity && !model.showsOngoingRequests ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canEdit {
                Button("Rename request…") {
                    namePrompt = NamePrompt(
                        title: "Rename Request",
                        initialValue: currentRequest.name,
                        placeholder: "Request name",
                        submitTitle: "Save"
                    ) { name in
                        model.updateDraft(identity) { $0.name = name }
                    }
                }
                Button("Duplicate request") { Task { await model.duplicateRequest(identity) } }
                Button("Move up") { Task { await model.moveRequest(identity, by: -1) } }
                    .disabled(!canMoveUp)
                Button("Move down") { Task { await model.moveRequest(identity, by: 1) } }
                    .disabled(!canMoveDown)
                Divider()
                Button("Delete request", role: .destructive) { deletionTarget = .request(identity) }
            }
        }
        .accessibilityAddTraits(model.selectedIdentity == identity && !model.showsOngoingRequests ? .isSelected : [])
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": .green
        case "POST": .orange
        case "PUT", "PATCH": .blue
        case "DELETE": .red
        default: .secondary
        }
    }
}

private struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let initialValue: String
    let placeholder: String
    let submitTitle: String
    let submit: (String) -> Void
}

private enum DeletionTarget {
    case collection(UUID)
    case request(RequestIdentity)

    var title: String {
        switch self {
        case .collection: "Delete collection and its requests?"
        case .request: "Delete request?"
        }
    }
}

private struct NameInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: NamePrompt
    @State private var value: String

    init(prompt: NamePrompt) {
        self.prompt = prompt
        _value = State(initialValue: prompt.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.title3.weight(.semibold))
            TextField(prompt.placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(prompt.submitTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        prompt.submit(normalized)
        dismiss()
    }
}
