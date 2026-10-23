import SwiftUI
import AppKit
import PostieCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(RequestResponseLayout.preferenceKey) private var requestResponseLayout = RequestResponseLayout
        .sideBySide
    @AppStorage("sidebarVisibility") private var sidebarIsVisible = false
    @State private var namePrompt: NamePrompt?
    @State private var deletionTarget: DeletionTarget?
    @State private var searchResponder: NSResponder?
    @State private var searchWindow: NSWindow?
    @State private var searchOpenedRequest = false
    @State private var pendingWorkspaceCreation: WorkspaceCreation?

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            SidebarView(namePrompt: $namePrompt, deletionTarget: $deletionTarget)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.navigateBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .help("Back")
                .accessibilityLabel("Back")
                .disabled(!model.canNavigateBack)

                Button {
                    model.navigateForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .help("Forward")
                .accessibilityLabel("Forward")
                .disabled(!model.canNavigateForward)
            }
            ToolbarItem(placement: .principal) {
                Button {
                    model.showRequestSearch()
                } label: {
                    HStack(spacing: 6) {
                        Text(breadcrumbTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 420)
                }
                .help(breadcrumbTitle)
                .accessibilityLabel(breadcrumbTitle)
                .popover(isPresented: $model.showsRequestSearch) {
                    WorkspaceSwitcherView(
                        opened: { searchOpenedRequest = true },
                        createCollection: { pendingWorkspaceCreation = .collection },
                        createRequest: { pendingWorkspaceCreation = .request($0) }
                    )
                    .onDisappear { presentWorkspaceCreation() }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !sidebarIsVisible {
                    Button {
                        model.showOngoingRequests()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "clock.arrow.circlepath")
                            if model.activeRunCount > 0 {
                                Text(model.activeRunCount > 99 ? "99+" : "\(model.activeRunCount)")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Color.accentColor, in: Capsule())
                                    .offset(x: 9, y: -8)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .help("Request History (\(model.activeRunCount) active)")
                    .accessibilityLabel("Request History")
                    .accessibilityValue("\(model.activeRunCount) active")

                    Button {
                        model.showGlobalVariables()
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .help("Global Variables")
                    .accessibilityLabel("Global Variables")
                }

                Button {
                    requestResponseLayout = requestResponseLayout.toggled
                } label: {
                    Image(systemName: requestResponseLayout.symbolName)
                }
                .help("Toggle request and response layout")
                .accessibilityLabel("Toggle request and response layout")
                .accessibilityValue(requestResponseLayout.title)

                if !sidebarIsVisible {
                    Button {
                        model.showGlobalSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                }
            }
        }
        .disabled(model.workspaceMutationIsBlocked)
        .sheet(item: $namePrompt) { prompt in
            NameInputSheet(prompt: prompt)
        }
        .onChange(of: model.showsRequestSearch) { _, visible in
            if visible {
                searchWindow = NSApp.keyWindow
                searchResponder = searchWindow?.firstResponder
                searchOpenedRequest = false
            } else {
                restoreSearchFocusIfNeeded()
            }
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
        .alert(
            "Postie",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.operationError = nil }
        } message: {
            Text(model.operationError ?? "An unexpected error occurred.")
        }
    }

    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarIsVisible ? .all : .detailOnly },
            set: { sidebarIsVisible = $0 != .detailOnly }
        )
    }

    private func presentWorkspaceCreation() {
        guard let creation = pendingWorkspaceCreation else { return }
        pendingWorkspaceCreation = nil
        guard !model.isTerminating else { return }
        switch creation {
        case .collection:
            guard !model.workspaceIndexIsReadOnly else { return }
            namePrompt = NamePrompt(
                title: "New Collection", initialValue: "", placeholder: "Collection name", submitTitle: "Create"
            ) { name in
                Task { await model.createCollection(name: name) }
            }
        case let .request(id):
            guard let collection = model.collection(id: id), !collection.isReadOnly else { return }
            namePrompt = NamePrompt(
                title: "New Request", initialValue: "New request", placeholder: "Request name", submitTitle: "Create"
            ) { name in
                Task { await model.createRequest(in: id, name: name) }
            }
        }
    }

    private func restoreSearchFocusIfNeeded() {
        if !searchOpenedRequest, let searchResponder {
            searchWindow?.makeFirstResponder(searchResponder)
        }
        searchResponder = nil
        searchWindow = nil
    }

    private var breadcrumbTitle: String {
        if model.startupError != nil { return "Workspace" }
        if model.showsOngoingRequests { return "Request History" }
        if let snapshotID = model.selectedSnapshotID {
            guard let snapshot = model.snapshots.first(where: { $0.id == snapshotID }) else {
                return "Snapshot"
            }
            let grouping = model.snapshotGrouping(for: snapshot)
            return "\(grouping.collectionName) › \(grouping.requestName) › \(snapshot.name)"
        }
        if model.showsGlobalVariables { return "Global Variables" }
        if model.showsGlobalSettings { return "Settings" }
        if let collectionID = model.selectedCollectionID,
            let collection = model.collections.first(where: { $0.id == collectionID })
        {
            return collection.name
        }
        if let identity = model.selectedIdentity,
            let collection = model.collections.first(where: { $0.id == identity.collectionID }),
            let request = model.request(for: identity)
        {
            return "\(collection.name) › \(request.name)"
        }
        return "Requests"
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
            SessionHistoryView(history: model.sessionHistory)
        } else if let snapshotID = model.selectedSnapshotID {
            SnapshotDetailView(snapshotID: snapshotID, layout: requestResponseLayout)
                .id(snapshotID)
        } else if model.showsGlobalVariables {
            VStack(alignment: .leading, spacing: 0) {
                Text("Global Variables").font(.title3.weight(.semibold)).padding(18)
                Divider()
                ScrollView { VariableEditorView(owner: .global).padding(18) }
            }
        } else if model.showsGlobalSettings {
            GlobalSettingsPage()
        } else if let collectionID = model.selectedCollectionID {
            CollectionEditorView(collectionID: collectionID).id(collectionID)
                .environment(\.variableInspectionOwner, .collection(collectionID))
        } else if let identity = model.selectedIdentity {
            VStack(spacing: 0) {
                RequestToolbar(identity: identity)
                Divider()
                RequestResponseSplit(model: model, identity: identity, layout: requestResponseLayout)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.variableInspectionOwner, .request(identity))
            .id(identity)
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
    @StateObject private var dragFeedback = SidebarDragFeedback()
    @StateObject private var snapshotSidebarExpansion = SnapshotSidebarExpansion()
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: sidebarIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("Postie")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Button {
                model.showOngoingRequests()
            } label: {
                HStack {
                    Label("Request History", systemImage: "clock.arrow.circlepath")
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
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                model.showsOngoingRequests ? Color.accentColor.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 7))

            Button {
                model.showGlobalVariables()
            } label: {
                Label("Global Variables", systemImage: "curlybraces")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                model.showsGlobalVariables ? Color.accentColor.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 7))

            Button {
                model.showGlobalSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                model.showsGlobalSettings ? Color.accentColor.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 7))

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

                    HistoricalSnapshotCollectionsSidebar(
                        snapshots: model.snapshots,
                        liveCollectionIDs: Set(model.collections.map(\.id))
                    )

                    if model.snapshotLoadError != nil || !model.snapshotStorageIssues.isEmpty {
                        SnapshotStorageIssuesSection(
                            loadError: model.snapshotLoadError,
                            issues: model.snapshotStorageIssues
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
        .environmentObject(dragFeedback)
        .environmentObject(snapshotSidebarExpansion)
        .onDragSessionUpdated { session in
            dragFeedback.sessionUpdated(session.phase)
        }
        .onDisappear { dragFeedback.clear() }
    }

    private var sidebarIcon: NSImage {
        guard let iconURL = Bundle.main.url(forResource: "Postie", withExtension: "icns"),
            let image = NSImage(contentsOf: iconURL)
        else {
            return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 28, height: 28))
        }

        return image
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
    @EnvironmentObject private var dragFeedback: SidebarDragFeedback
    let collection: RequestCollection
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?
    @State private var isExpanded = true
    private var dropEdge: SidebarDropEdge? { dragFeedback.edge(for: .collection(collection.id)) }
    private var dropEdgeBinding: Binding<SidebarDropEdge?> {
        Binding(get: { dropEdge }, set: { dragFeedback.setEdge($0, for: .collection(collection.id)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            collectionHeader

            if isExpanded {
                if collection.requests.isEmpty {
                    Text("No requests")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.leading, 7).padding(.vertical, 5)
                }
                ForEach(Array(collection.requests.enumerated()), id: \.element.id) { index, request in
                    let identity = RequestIdentity(collectionID: collection.id, requestID: request.id)
                    RequestSidebarRow(
                        request: request, identity: identity,
                        canMoveUp: index > 0, canMoveDown: index + 1 < collection.requests.count,
                        canEdit: model.canEdit(identity), namePrompt: $namePrompt,
                        deletionTarget: $deletionTarget)
                }
                let liveRequestIDs = Set(collection.requests.map(\.id))
                let deletedRequestSnapshots = model.snapshots.filter {
                    let grouping = model.snapshotGrouping(for: $0)
                    return grouping.identity.collectionID == collection.id
                        && !liveRequestIDs.contains(grouping.identity.requestID)
                }
                DeletedRequestSnapshotGroups(snapshots: deletedRequestSnapshots)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var collectionHeader: some View {
        let header = HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse collection" : "Expand collection")
            Button {
                model.showCollection(collection.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(collection.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .background(
            model.selectedCollectionID == collection.id ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu { collectionActions }
        .overlay {
            GeometryReader { geometry in
                Color.clear.onDrop(
                    of: [UTType.plainText],
                    delegate: CollectionSidebarDropDelegate(
                        model: model,
                        targetCollectionID: collection.id,
                        targetIsReadOnly: collection.isReadOnly,
                        targetHeight: geometry.size.height,
                        edge: dropEdgeBinding
                    )
                )
            }
        }
        .overlay(alignment: dropEdge == .before ? .top : .bottom) {
            if dropEdge != nil {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }

        if model.canReorderCollections {
            header.onDrag { NSItemProvider(object: SidebarDragPayload.collection(collection.id).encoded as NSString) }
        } else {
            header
        }
    }

    @ViewBuilder
    private var collectionActions: some View {
        Button("Collection settings") { model.showCollection(collection.id, section: .settings) }
        Button("New request") {
            namePrompt = NamePrompt(
                title: "New Request", initialValue: "New request",
                placeholder: "Request name", submitTitle: "Create"
            ) { name in
                Task { await model.createRequest(in: collection.id, name: name) }
            }
        }
        .disabled(collection.isReadOnly)
        Button("Rename collection") {
            namePrompt = NamePrompt(
                title: "Rename Collection", initialValue: collection.name,
                placeholder: "Collection name", submitTitle: "Save"
            ) { name in
                Task { await model.renameCollection(id: collection.id, name: name) }
            }
        }
        .disabled(collection.isReadOnly)
        Divider()
        Button("Delete collection", role: .destructive) { deletionTarget = .collection(collection.id) }
            .disabled(collection.isReadOnly)
    }
}

private struct RequestSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dragFeedback: SidebarDragFeedback
    @EnvironmentObject private var snapshotSidebarExpansion: SnapshotSidebarExpansion
    let request: HTTPRequestConfiguration
    let identity: RequestIdentity
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canEdit: Bool
    @Binding var namePrompt: NamePrompt?
    @Binding var deletionTarget: DeletionTarget?
    private var dropEdge: SidebarDropEdge? { dragFeedback.edge(for: .request(identity)) }
    private var dropEdgeBinding: Binding<SidebarDropEdge?> {
        Binding(get: { dropEdge }, set: { dragFeedback.setEdge($0, for: .request(identity)) })
    }

    private var currentRequest: HTTPRequestConfiguration {
        model.request(for: identity) ?? request
    }

    private var isSelected: Bool {
        model.selectedIdentity == identity && model.selectedCollectionID == nil && model.selectedSnapshotID == nil
            && !model.showsOngoingRequests && !model.showsGlobalVariables && !model.showsGlobalSettings
    }

    var body: some View {
        let snapshots = model.snapshots(for: identity)
        let snapshotsExpanded = snapshotSidebarExpansion.isExpanded(identity: identity)

        VStack(alignment: .leading, spacing: 2) {
            liveRequestRow(snapshotCount: snapshots.count, snapshotsExpanded: snapshotsExpanded)

            if snapshotsExpanded {
                ForEach(snapshots) { snapshot in
                    SnapshotSidebarRow(snapshot: snapshot)
                }
            }
        }
    }

    @ViewBuilder
    private func liveRequestRow(snapshotCount: Int, snapshotsExpanded: Bool) -> some View {
        let row = HStack(spacing: 0) {
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
                .padding(.leading, 7)
                .padding(.trailing, 7)
                .padding(.vertical, 6)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .overlay {
                GeometryReader { geometry in
                    Color.clear.onDrop(
                        of: [UTType.plainText],
                        delegate: RequestSidebarDropDelegate(
                            model: model,
                            targetIdentity: identity,
                            targetHeight: geometry.size.height,
                            edge: dropEdgeBinding
                        )
                    )
                }
            }

            if snapshotCount > 0 {
                snapshotDisclosureButton(count: snapshotCount, isExpanded: snapshotsExpanded)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
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
        .overlay(alignment: dropEdge == .before ? .top : .bottom) {
            if dropEdge != nil {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, 25)
            }
        }

        if canEdit {
            row.onDrag { NSItemProvider(object: SidebarDragPayload.request(identity).encoded as NSString) }
        } else {
            row
        }
    }

    private func snapshotDisclosureButton(count: Int, isExpanded: Bool) -> some View {
        Button {
            snapshotSidebarExpansion.toggle(identity: identity)
        } label: {
            HStack(spacing: 5) {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(isExpanded ? "Hide" : "Show") \(count) snapshots")
        .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(count) snapshots for \(currentRequest.name)")
        .accessibilityHint("Expands or collapses saved snapshots for this request.")
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

private enum SidebarDragPayload {
    case collection(UUID)
    case request(RequestIdentity)

    init?(_ encoded: String) {
        let parts = encoded.split(separator: "/")
        guard parts.count >= 3, parts[0] == "postie" else { return nil }
        switch parts[1] {
        case "collection":
            guard parts.count == 3, let id = UUID(uuidString: String(parts[2])) else { return nil }
            self = .collection(id)
        case "request":
            guard parts.count == 4,
                let collectionID = UUID(uuidString: String(parts[2])),
                let requestID = UUID(uuidString: String(parts[3]))
            else { return nil }
            self = .request(RequestIdentity(collectionID: collectionID, requestID: requestID))
        default:
            return nil
        }
    }

    var encoded: String {
        switch self {
        case let .collection(id): "postie/collection/\(id.uuidString)"
        case let .request(identity):
            "postie/request/\(identity.collectionID.uuidString)/\(identity.requestID.uuidString)"
        }
    }
}

@MainActor
private struct RequestSidebarDropDelegate: DropDelegate {
    let model: AppModel
    let targetIdentity: RequestIdentity
    let targetHeight: CGFloat
    @Binding var edge: SidebarDropEdge?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        edge = edge(at: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = edge(at: info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        edge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            edge = nil
            return false
        }
        let insertion = edge(at: info.location.y)
        edge = nil
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let encoded = item as? String,
                let payload = SidebarDragPayload(encoded),
                case let .request(sourceIdentity) = payload,
                sourceIdentity != targetIdentity
            else { return }
            Task { @MainActor in
                guard let collection = model.collections.first(where: { $0.id == targetIdentity.collectionID }),
                    let targetIndex = collection.requests.firstIndex(where: { $0.id == targetIdentity.requestID })
                else { return }
                let beforeRequestID: UUID?
                if insertion == .before {
                    beforeRequestID = targetIdentity.requestID
                } else {
                    let nextIndex = targetIndex + 1
                    beforeRequestID =
                        collection.requests.indices.contains(nextIndex) ? collection.requests[nextIndex].id : nil
                }
                await model.moveRequest(
                    sourceIdentity,
                    toCollectionID: targetIdentity.collectionID,
                    beforeRequestID: beforeRequestID
                )
            }
        }
        return true
    }

    private func edge(at y: CGFloat) -> SidebarDropEdge {
        y < targetHeight / 2 ? .before : .after
    }
}

@MainActor
private struct CollectionSidebarDropDelegate: DropDelegate {
    let model: AppModel
    let targetCollectionID: UUID
    let targetIsReadOnly: Bool
    let targetHeight: CGFloat
    @Binding var edge: SidebarDropEdge?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropEntered(info: DropInfo) {
        edge = edge(at: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = edge(at: info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        edge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            edge = nil
            return false
        }
        let insertion = edge(at: info.location.y)
        edge = nil
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let encoded = item as? String,
                let payload = SidebarDragPayload(encoded)
            else { return }
            Task { @MainActor in
                switch payload {
                case let .request(identity):
                    guard !targetIsReadOnly else {
                        model.operationError = "Requests cannot be moved into a read-only collection."
                        return
                    }
                    await model.moveRequest(identity, toCollectionID: targetCollectionID)
                case let .collection(sourceCollectionID):
                    guard model.canReorderCollections, sourceCollectionID != targetCollectionID else { return }
                    var orderedIDs = model.collections.map(\.id).filter { $0 != sourceCollectionID }
                    guard let targetIndex = orderedIDs.firstIndex(of: targetCollectionID) else { return }
                    let insertionIndex = insertion == .before ? targetIndex : targetIndex + 1
                    orderedIDs.insert(sourceCollectionID, at: insertionIndex)
                    await model.reorderCollections(orderedIDs)
                }
            }
        }
        return true
    }

    private func edge(at y: CGFloat) -> SidebarDropEdge {
        y < targetHeight / 2 ? .before : .after
    }
}

private enum WorkspaceCreation {
    case collection
    case request(UUID)
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
