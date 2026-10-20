import SwiftUI
import PostieCore

@MainActor
final class SnapshotSidebarExpansion: ObservableObject {
    @Published private(set) var expandedRequests: Set<RequestIdentity> = []

    func isExpanded(identity: RequestIdentity) -> Bool {
        expandedRequests.contains(identity)
    }

    func toggle(identity: RequestIdentity) {
        var expanded = expandedRequests
        if !expanded.insert(identity).inserted {
            expanded.remove(identity)
        }
        expandedRequests = expanded
    }
}

struct SnapshotSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: SavedSnapshot
    var isHistorical = false

    @State private var isRenameSheetPresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Button {
            model.selectSnapshot(snapshot.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(snapshot.capturedAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text("\(snapshot.statusCode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(statusColor)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(model.selectedSnapshotID == snapshot.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(isHistorical ? 0.68 : 1)
        }
        .buttonStyle(.plain)
        .padding(.leading, 25)
        .help("\(snapshot.name) · \(snapshot.capturedAt.formatted(date: .numeric, time: .shortened)) · HTTP \(snapshot.statusCode)")
        .contextMenu {
            Button("Rename Snapshot…") { isRenameSheetPresented = true }
            Divider()
            Button("Delete Snapshot", role: .destructive) { isDeleteConfirmationPresented = true }
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            SnapshotNameSheet(title: "Rename Snapshot", initialValue: snapshot.name) { name in
                Task { await model.renameSnapshot(id: snapshot.id, name: name) }
            }
        }
        .confirmationDialog(
            "Delete this snapshot?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Snapshot", role: .destructive) {
                Task { await model.deleteSnapshot(id: snapshot.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved request and response snapshot.")
        }
        .accessibilityAddTraits(model.selectedSnapshotID == snapshot.id ? .isSelected : [])
    }

    private var statusColor: Color {
        switch snapshot.statusCode {
        case 200..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }
}

struct HistoricalSnapshotCollectionsSidebar: View {
    let snapshots: [SavedSnapshot]
    let liveCollectionIDs: Set<UUID>

    private var historicalGroups: [HistoricalCollectionGroup] {
        Dictionary(grouping: snapshots.filter { !liveCollectionIDs.contains($0.source.identity.collectionID) }) {
            $0.source.identity.collectionID
        }
        .map { HistoricalCollectionGroup(id: $0.key, snapshots: $0.value) }
        .sorted {
            let left = $0.latestSnapshot.source.collectionName.localizedCaseInsensitiveCompare($1.latestSnapshot.source.collectionName)
            return left == .orderedSame ? $0.id.uuidString < $1.id.uuidString : left == .orderedAscending
        }
    }

    var body: some View {
        ForEach(historicalGroups) { group in
            HistoricalSnapshotCollectionSection(group: group)
        }
    }
}

private struct HistoricalCollectionGroup: Identifiable {
    let id: UUID
    let snapshots: [SavedSnapshot]

    var latestSnapshot: SavedSnapshot {
        snapshots.max { $0.capturedAt < $1.capturedAt } ?? snapshots[0]
    }
}

private struct HistoricalSnapshotCollectionSection: View {
    let group: HistoricalCollectionGroup
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14)
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.latestSnapshot.source.collectionName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Deleted collection")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .opacity(0.58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Historical collection \(group.latestSnapshot.source.collectionName)")

            if isExpanded {
                DeletedRequestSnapshotGroups(snapshots: group.snapshots)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DeletedRequestSnapshotGroups: View {
    @EnvironmentObject private var snapshotSidebarExpansion: SnapshotSidebarExpansion
    let snapshots: [SavedSnapshot]

    private var requestGroups: [HistoricalRequestGroup] {
        Dictionary(grouping: snapshots) { $0.source.identity }
            .map { HistoricalRequestGroup(identity: $0.key, snapshots: $0.value) }
            .sorted {
                let left = $0.latestSnapshot.source.requestName.localizedCaseInsensitiveCompare($1.latestSnapshot.source.requestName)
                return left == .orderedSame ? $0.identity.requestID.uuidString < $1.identity.requestID.uuidString : left == .orderedAscending
            }
    }

    var body: some View {
        ForEach(requestGroups) { group in
            let snapshots = group.snapshots.sorted { $0.capturedAt > $1.capturedAt }
            let isExpanded = snapshotSidebarExpansion.isExpanded(identity: group.identity)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(group.latestSnapshot.source.requestName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("Deleted request")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        snapshotSidebarExpansion.toggle(identity: group.identity)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(snapshots.count)")
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
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(isExpanded ? "Hide" : "Show") \(snapshots.count) snapshots")
                    .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(snapshots.count) snapshots for deleted request \(group.latestSnapshot.source.requestName)")
                    .accessibilityHint("Expands or collapses saved snapshots for this deleted request.")
                }
                .padding(.leading, 18)
                .padding(.vertical, 3)
                .opacity(0.58)

                if isExpanded {
                    ForEach(snapshots) { snapshot in
                        SnapshotSidebarRow(snapshot: snapshot, isHistorical: true)
                    }
                }
            }
        }
    }
}

private struct HistoricalRequestGroup: Identifiable {
    let identity: RequestIdentity
    let snapshots: [SavedSnapshot]
    var id: RequestIdentity { identity }

    var latestSnapshot: SavedSnapshot {
        snapshots.max { $0.capturedAt < $1.capturedAt } ?? snapshots[0]
    }
}

struct SnapshotStorageIssuesSection: View {
    let loadError: String?
    let issues: [StorageIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SNAPSHOT RECOVERY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let loadError {
                issueRow(loadError)
            }
            ForEach(issues) { issue in
                issueRow(issue.message)
            }
        }
        .padding(.horizontal, 8)
    }

    private func issueRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SnapshotNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialValue: String
    let submit: (String) -> Void

    @State private var value: String

    init(title: String, initialValue: String, submit: @escaping (String) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.submit = submit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            TextField("Snapshot name", text: $value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        submit(normalized)
        dismiss()
    }
}
