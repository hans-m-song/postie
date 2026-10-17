import SwiftUI
import PostieCore

struct OngoingRequestsView: View {
    @EnvironmentObject private var model: AppModel

    private var identities: [RequestIdentity] {
        model.activeRuns.keys.sorted {
            let left = model.activeRuns[$0]?.request.name ?? ""
            let right = model.activeRuns[$1]?.request.name ?? ""
            let order = left.localizedCaseInsensitiveCompare(right)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.collectionID != $1.collectionID { return $0.collectionID.uuidString < $1.collectionID.uuidString }
            return $0.requestID.uuidString < $1.requestID.uuidString
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ongoing Requests")
                        .font(.title2.weight(.semibold))
                    Text("\(model.activeRunCount) active")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            if identities.isEmpty {
                ContentUnavailableView(
                    "No requests are running",
                    systemImage: "clock",
                    description: Text("Requests will remain visible here while you navigate through the workspace.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(identities, id: \.self) { identity in
                    if let active = model.activeRuns[identity] {
                        OngoingRequestRow(identity: identity, active: active)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct OngoingRequestRow: View {
    @EnvironmentObject private var model: AppModel
    let identity: RequestIdentity
    let active: AppModel.ActiveRun

    private var collectionName: String {
        model.collection(for: identity)?.name ?? "Unavailable collection"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 3)
                    .accessibilityLabel(active.phase == .cancelling ? "Cancelling" : "Request in progress")

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(active.request.name)
                            .font(.headline)
                        Text(collectionName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(active.request.method.uppercased())  \(active.request.url)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 10)

                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f s", model.elapsed(for: identity) ?? 0))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 60, alignment: .trailing)

                Button("Open Request") {
                    model.openRequest(identity)
                }
                .buttonStyle(.bordered)

                Button("Cancel", systemImage: "stop.fill") {
                    model.cancelRequest(identity)
                }
                .buttonStyle(.bordered)
                .disabled(active.phase == .cancelling)
            }

            if let progress = active.progress {
                HStack(spacing: 10) {
                    if let expected = progress.expectedBytes, expected > 0 {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(expected))
                    }
                    Text("\(progress.receivedBytes.formatted(.byteCount(style: .file))) received")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private var status: String {
        switch active.phase {
        case .preparing: "Preparing"
        case .running: active.runID == nil ? "Starting" : "Running"
        case .cancelling: "Cancelling"
        }
    }
}
