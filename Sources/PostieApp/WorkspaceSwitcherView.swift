import SwiftUI
import PostieCore

struct WorkspaceSwitcherView: View {
    @EnvironmentObject private var model: AppModel
    let opened: () -> Void
    let createCollection: () -> Void
    let createRequest: (UUID) -> Void

    @State private var selectedItem: WorkspacePaletteResult.ID?

    private var invocation: WorkspacePaletteInvocation {
        WorkspacePalette.invocation(for: model.workspaceSearchQuery)
    }

    private var isNavigationInvocation: Bool {
        switch invocation {
        case .all, .requests, .collections: true
        case .commands, .variables: false
        }
    }

    private var isSearching: Bool {
        !invocation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationResults: [WorkspaceSearchResult] {
        return WorkspaceSearchResult.matching(
            invocation.query,
            collections: model.collections,
            drafts: model.drafts,
            snapshots: model.snapshots,
            groupingForSnapshot: { model.snapshotGrouping(for: $0) }
        )
    }

    private var commandResults: [WorkspacePaletteCommandResult] {
        return WorkspacePalette.commands(
            matching: invocation.query,
            collections: model.collections,
            workspaceIndexIsReadOnly: model.workspaceIndexIsReadOnly,
            deletingCollections: model.deletingCollections
        )
    }

    private var variableResults: [WorkspacePaletteVariableResult] {
        return WorkspacePalette.variables(
            matching: invocation.query,
            globalVariables: model.globalVariables,
            collections: model.collections,
            drafts: model.drafts
        )
    }

    private var paletteResults: [WorkspacePaletteResult] {
        WorkspacePalette.results(
            for: invocation,
            navigation: navigationResults,
            commands: commandResults,
            variables: variableResults
        )
    }

    private var selectableSelectionIDs: [WorkspacePaletteResult.ID] {
        paletteResults.filter(\.isEnabled).map(\.id)
    }

    private var visibleItemCount: Int {
        paletteResults.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchHeader

            if visibleItemCount == 0 {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if case .all = invocation, !isSearching {
                                unfilteredCatalogRows
                            } else {
                                ForEach(paletteResults) { result in
                                    paletteRow(result)
                                        .id(result.id)
                                }
                            }
                        }
                    }
                    .onChange(of: selectedItem) { _, item in
                        if let item { proxy.scrollTo(item, anchor: .center) }
                    }
                }
            }

            HStack {
                Text("↑ ↓ Select · Return Open · Esc Close")
                Spacer()
                Text("\(visibleItemCount) items")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 480, height: 420)
        .onAppear {
            synchronizeSelection()
        }
        .onChange(of: selectableSelectionIDs) { _, _ in
            synchronizeSelection()
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            WorkspacePaletteSearchField(
                text: $model.workspaceSearchQuery,
                focusRequestID: model.workspaceSearchFocusRequestID,
                onSubmit: activateSelection,
                onMove: moveSelection,
                onCancel: { model.showsRequestSearch = false }
            )

            Button {
                model.showsRequestSearch = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close workspace switcher")
            .accessibilityLabel("Close workspace switcher")
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var unfilteredCatalogRows: some View {
        navigationRows

        if !commandResults.isEmpty {
            sectionHeading("Commands")
            ForEach(commandResults) { result in
                commandRow(result)
                    .id(WorkspacePaletteResult.ID.command(result.id))
            }
        }

        if !variableResults.isEmpty {
            sectionHeading("Variables")
            ForEach(variableResults) { result in
                variableRow(result)
                    .id(WorkspacePaletteResult.ID.variable(result.id))
            }
        }
    }

    @ViewBuilder
    private var navigationRows: some View {
        if isSearching {
            ForEach(navigationResults) { result in
                resultRow(result)
                    .id(WorkspacePaletteResult.ID.destination(result.destination))
            }
        } else {
            resultSection(
                "Collections and Requests",
                results: navigationResults.filter {
                    switch $0.destination {
                    case .collection(_), .request(_): true
                    case .snapshot(_): false
                    }
                },
                marksCurrentCollectionContext: true
            )
            resultSection(
                "Saved snapshots",
                results: navigationResults.filter {
                    if case .snapshot(_) = $0.destination { return true }
                    return false
                }
            )
        }
    }

    @ViewBuilder
    private func resultSection(
        _ title: String,
        results: [WorkspaceSearchResult],
        marksCurrentCollectionContext: Bool = false
    ) -> some View {
        if !results.isEmpty {
            sectionHeading(title)

            ForEach(results) { result in
                resultRow(result, marksCurrentCollectionContext: marksCurrentCollectionContext)
                    .id(WorkspacePaletteResult.ID.destination(result.destination))
            }
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.top, 5)
    }

    @ViewBuilder
    private func paletteRow(_ result: WorkspacePaletteResult) -> some View {
        switch result {
        case let .navigation(navigationResult):
            resultRow(navigationResult)
        case let .command(commandResult):
            commandRow(commandResult)
        case let .variable(variableResult):
            variableRow(variableResult)
        }
    }

    @ViewBuilder
    private func resultRow(
        _ result: WorkspaceSearchResult,
        marksCurrentCollectionContext: Bool = false
    ) -> some View {
        let destinationIsCurrent = isCurrent(
            result.destination,
            marksCurrentCollectionContext: marksCurrentCollectionContext
        )
        HStack(spacing: 4) {
            Button {
                openDestination(result.destination)
            } label: {
                resultLabel(result, isCurrent: destinationIsCurrent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selectedItem == .destination(result.destination) ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: result))
            .accessibilityValue(destinationIsCurrent ? "Current destination" : "")
            .accessibilityAddTraits(selectedItem == .destination(result.destination) ? .isSelected : [])

            if case let .collection(id) = result.destination {
                Button {
                    openCollectionSettings(id)
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collection settings for \(result.name)")
                .accessibilityLabel("Collection settings for \(result.name)")
            }
        }
        .background(.clear)
    }

    private func resultLabel(_ result: WorkspaceSearchResult, isCurrent: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName(for: result.destination))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let method = result.method {
                        Text(method.uppercased())
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Text(result.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }

                switch result.destination {
                case .collection(_):
                    Text("\(result.requestCount ?? 0) requests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .request(_):
                    Text("\(result.collectionName) · \(result.url ?? "")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .snapshot(_):
                    Text("\(result.requestName ?? "") · \(result.collectionName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let capturedAt = result.capturedAt, let statusCode = result.statusCode {
                        Text("\(capturedAt.formatted(date: .numeric, time: .shortened)) · HTTP \(statusCode)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if let identifier = WorkspaceSearchResult.disambiguator(
                    for: result,
                    among: navigationResults
                ) {
                    Text("ID \(identifier)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func commandRow(_ result: WorkspacePaletteCommandResult) -> some View {
        Button {
            activate(result.command)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbolName(for: result.command))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                if let detail = result.detail {
                    Text(detail).fontWeight(.medium).lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(result.title).fontWeight(.medium).lineLimit(1)
                } else {
                    Text(result.title).fontWeight(.medium).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedItem == .command(result.id) ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!result.isEnabled)
        .opacity(result.isEnabled ? 1 : 0.5)
        .accessibilityLabel(result.detail.map { "\($0) → \(result.title)" } ?? result.title)
        .accessibilityAddTraits(selectedItem == .command(result.id) ? .isSelected : [])
    }

    private func variableRow(_ result: WorkspacePaletteVariableResult) -> some View {
        Button {
            activate(result.identity)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result.isSecret ? "lock.fill" : "curlybraces")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.name).fontWeight(.medium).lineLimit(1)
                    Text(result.scope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if result.isSecret {
                        Text("Secret")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let preview = result.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedItem == .variable(result.id) ? Color.accentColor.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [result.name, result.scope, result.isSecret ? "secret" : result.preview]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(selectedItem == .variable(result.id) ? .isSelected : [])
    }

    private var emptyTitle: String {
        switch invocation {
        case .all:
            isSearching ? "No matching workspace items" : "No collections, snapshots, commands, or variables"
        case .requests:
            "No matching requests"
        case .collections:
            "No matching collections"
        case .commands:
            "No matching commands"
        case .variables:
            "No matching variables"
        }
    }

    private var emptySymbol: String {
        switch invocation {
        case .all, .collections:
            isSearching ? "magnifyingglass" : "folder"
        case .requests, .commands, .variables:
            "magnifyingglass"
        }
    }

    private func symbolName(for destination: WorkspaceDestination) -> String {
        switch destination {
        case .collection(_): "folder"
        case .request(_): "arrow.up.right.square"
        case .snapshot(_): "doc.text.magnifyingglass"
        }
    }

    private func symbolName(for command: WorkspacePaletteCommand) -> String {
        switch command {
        case .settings, .collectionSettings(_): "gearshape"
        case .requestHistory: "clock.arrow.circlepath"
        case .globalVariables: "curlybraces"
        case .createCollection: "folder.badge.plus"
        case .createRequest(_): "plus"
        }
    }

    private func accessibilityLabel(for result: WorkspaceSearchResult) -> String {
        let itemLabel: String
        switch result.destination {
        case .collection(_):
            itemLabel = "Collection \(result.name), \(result.requestCount ?? 0) requests"
        case .request(_):
            itemLabel = "\(result.method ?? "Request") \(result.name), in \(result.collectionName), \(result.url ?? "")"
        case .snapshot(_):
            let captureDetails = [
                result.capturedAt.map {
                    "captured \($0.formatted(date: .numeric, time: .shortened))"
                },
                result.statusCode.map { "HTTP \($0)" },
            ].compactMap { $0 }
            let captureContext = captureDetails.isEmpty ? "" : ", \(captureDetails.joined(separator: ", "))"
            let sourceContext = "\(result.requestName ?? "request") in \(result.collectionName)"
            itemLabel = "Snapshot \(result.name), for \(sourceContext)\(captureContext)"
        }
        guard let identifier = WorkspaceSearchResult.disambiguator(for: result, among: navigationResults) else {
            return itemLabel
        }
        return "\(itemLabel), ID \(identifier)"
    }

    private func isCurrent(
        _ destination: WorkspaceDestination,
        marksCurrentCollectionContext: Bool = false
    ) -> Bool {
        guard !hasOtherCurrentDestination else { return false }
        switch destination {
        case let .collection(id):
            return model.selectedCollectionID == id
                || marksCurrentCollectionContext && currentCollectionID() == id
        case let .request(identity):
            return model.selectedCollectionID == nil && model.selectedSnapshotID == nil
                && model.selectedIdentity == identity
        case let .snapshot(id):
            return model.selectedSnapshotID == id
        }
    }

    private var hasOtherCurrentDestination: Bool {
        model.showsGlobalSettings || model.showsGlobalVariables || model.showsOngoingRequests
    }

    private func currentCollectionID() -> UUID? {
        guard !hasOtherCurrentDestination else { return nil }
        if let selectedCollectionID = model.selectedCollectionID { return selectedCollectionID }
        if let selectedSnapshotID = model.selectedSnapshotID,
            let snapshot = model.snapshots.first(where: { $0.id == selectedSnapshotID })
        {
            return model.snapshotGrouping(for: snapshot).identity.collectionID
        }
        return model.selectedIdentity?.collectionID
    }

    private func openDestination(_ destination: WorkspaceDestination) {
        switch destination {
        case let .collection(id):
            guard model.collections.contains(where: { $0.id == id }) else { return }
            opened()
            model.showCollection(id)
        case let .request(identity):
            guard model.request(for: identity) != nil else { return }
            opened()
            model.openRequest(identity)
        case let .snapshot(id):
            guard model.snapshots.contains(where: { $0.id == id }) else { return }
            opened()
            model.selectSnapshot(id)
        }
        model.showsRequestSearch = false
    }

    private func openCollectionSettings(_ id: UUID) {
        guard model.collections.contains(where: { $0.id == id }) else { return }
        opened()
        model.showCollection(id, section: .settings)
        model.showsRequestSearch = false
    }

    private func activate(_ command: WorkspacePaletteCommand) {
        guard let result = commandResults.first(where: { $0.command == command }), result.isEnabled else { return }

        switch command {
        case .settings:
            finishPaletteAction { model.showGlobalSettings() }
        case .requestHistory:
            finishPaletteAction { model.showOngoingRequests() }
        case .globalVariables:
            finishPaletteAction { model.showGlobalVariables() }
        case .createCollection:
            guard !model.workspaceIndexIsReadOnly else { return }
            finishPaletteAction(createCollection)
        case let .collectionSettings(id):
            guard model.collections.contains(where: { $0.id == id }) else { return }
            finishPaletteAction { model.showCollection(id, section: .settings) }
        case let .createRequest(id):
            guard !model.workspaceIndexIsReadOnly,
                !model.deletingCollections.contains(id),
                model.collections.contains(where: { $0.id == id && !$0.isReadOnly })
            else { return }
            finishPaletteAction { createRequest(id) }
        }
    }

    private func activate(_ identity: WorkspacePaletteVariableIdentity) {
        guard variableResults.contains(where: { $0.identity == identity }) else { return }
        finishPaletteAction {
            model.showWorkspaceVariable(owner: identity.owner, name: identity.name)
        }
    }

    private func finishPaletteAction(_ action: () -> Void) {
        opened()
        action()
        model.showsRequestSearch = false
    }

    private func activateSelection() {
        guard let selectedItem, selectableSelectionIDs.contains(selectedItem) else { return }
        switch selectedItem {
        case let .destination(destination):
            guard navigationResults.contains(where: { $0.destination == destination }) else { return }
            openDestination(destination)
        case let .command(command):
            activate(command)
        case let .variable(identity):
            activate(identity)
        }
    }

    private func moveSelection(by offset: Int) {
        let selections = selectableSelectionIDs
        guard !selections.isEmpty else { return }
        let currentIndex =
            selectedItem.flatMap { selected in
                selections.firstIndex(of: selected)
            } ?? 0
        selectedItem = selections[min(max(currentIndex + offset, 0), selections.count - 1)]
    }

    private func synchronizeSelection() {
        let selections = selectableSelectionIDs
        guard !selections.isEmpty else {
            selectedItem = nil
            return
        }
        if let selectedItem, selections.contains(selectedItem) { return }

        guard isNavigationInvocation else {
            selectedItem = selections.first
            return
        }

        let marksCurrentCollectionContext: Bool
        switch invocation {
        case .all, .collections:
            marksCurrentCollectionContext = !isSearching
        case .requests, .commands, .variables:
            marksCurrentCollectionContext = false
        }
        selectedItem =
            selections.first { selection in
                guard case let .destination(destination) = selection else { return false }
                return isCurrent(destination, marksCurrentCollectionContext: marksCurrentCollectionContext)
            } ?? selections.first
    }
}
