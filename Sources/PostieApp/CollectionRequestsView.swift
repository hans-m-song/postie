import SwiftUI
import PostieCore

struct CollectionRequestsView: View {
    @EnvironmentObject private var model: AppModel
    let collectionID: UUID

    var body: some View {
        if let collection = model.collection(id: collectionID) {
            if collection.requests.isEmpty {
                ContentUnavailableView(
                    "No requests",
                    systemImage: "arrow.up.right.square",
                    description: Text("This collection has no saved requests.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(collection.requests) { request in
                        requestRow(request)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Collection unavailable", systemImage: "folder.badge.questionmark")
        }
    }

    private func requestRow(_ savedRequest: HTTPRequestConfiguration) -> some View {
        let identity = RequestIdentity(collectionID: collectionID, requestID: savedRequest.id)
        let request = model.request(for: identity) ?? savedRequest
        let url = QueryParameters.render(baseURL: request.url, fields: request.query)
        let canOpen = model.request(for: identity) != nil && !model.reconcilingRequests.contains(identity)

        return Button {
            model.openRequest(identity)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(request.method.uppercased())
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 58, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(url.isEmpty ? "No URL" : url)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel("\(request.method.uppercased()) \(request.name), \(url.isEmpty ? "No URL" : url)")
        .accessibilityHint("Opens the request editor without sending it")
    }
}
