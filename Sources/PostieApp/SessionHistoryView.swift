import SwiftUI
import PostieCore

struct SessionHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var history: SessionExecutionStore
    @State private var selectedToken: UUID?

    init(history: SessionExecutionStore) {
        _history = ObservedObject(wrappedValue: history)
    }

    var body: some View {
        HSplitView {
            historyList
                .frame(minWidth: 235, idealWidth: 300, maxWidth: 360)
            selectedDetail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Request History")
                        .font(.title2.weight(.semibold))
                    Text(historySummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)

            Divider()

            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No requests in this session",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Requests will appear here as they run.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedToken) {
                    ForEach(history.entries) { entry in
                        SessionHistoryRow(entry: entry)
                            .tag(entry.token)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let selectedToken, let entry = history.entry(for: selectedToken) {
            SessionHistoryDetailView(entry: entry)
                .id(entry.token)
        } else if selectedToken != nil {
            ContentUnavailableView(
                "Request history entry unavailable",
                systemImage: "clock.badge.questionmark",
                description: Text("This entry is no longer retained in the current session.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Select a request",
                systemImage: "arrow.up.right.square",
                description: Text("Choose a request to inspect its captured details.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var historySummary: String {
        let activeCount = history.entries.filter { $0.phase.isActive }.count
        let activeLabel = activeCount == 1 ? "1 active" : "\(activeCount) active"
        let entryLabel = history.entries.count == 1 ? "1 run" : "\(history.entries.count) runs"
        return "\(entryLabel) · \(activeLabel)"
    }
}

private struct SessionHistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: SessionExecutionStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.requestName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(entry.startedAt.formatted(.dateTime.year().month(.twoDigits).day().hour().minute().second()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("\(entry.method.uppercased())  \(entry.url)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack(spacing: 7) {
                Circle()
                    .fill(entry.phase.historyColor)
                    .frame(width: 7, height: 7)
                HStack(spacing: 7) {
                    Text(entry.phase.historyLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.phase.historyColor)
                    if let statusCode = entry.statusCode {
                        Text("· \(statusCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let bodyByteCount = entry.bodyByteCount {
                    Text(bodyByteCount.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if entry.phase.isActive {
                    Button {
                        model.cancelHistoryRun(token: entry.token)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel request")
                    .accessibilityLabel("Cancel \(entry.requestName)")
                    .disabled(entry.phase == .cancelling || model.isTerminating)
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private extension SessionExecutionStore.Phase {
    var historyLabel: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var historyColor: Color {
        switch self {
        case .preparing, .running, .cancelling: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
