import SwiftUI
import PostieCore

struct RequestSearchResult: Identifiable, Equatable {
    let id: RequestIdentity
    let name: String
    let collectionName: String
    let method: String
    let url: String

    static func matching(
        _ query: String, collections: [RequestCollection], drafts: [RequestIdentity: HTTPRequestConfiguration]
    ) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return collections.flatMap { collection in
            collection.requests.compactMap { saved in
                let identity = RequestIdentity(collectionID: collection.id, requestID: saved.id)
                let request = drafts[identity] ?? saved
                let displayURL = QueryParameters.render(baseURL: request.url, fields: request.query)
                guard
                    query.isEmpty || request.name.localizedCaseInsensitiveContains(query)
                        || displayURL.localizedCaseInsensitiveContains(query)
                else { return nil }
                return Self(
                    id: identity, name: request.name, collectionName: collection.name,
                    method: request.method, url: displayURL)
            }
        }
    }
}

struct RequestSearchPalette: View {
    @EnvironmentObject private var model: AppModel
    let opened: () -> Void
    @State private var query = ""
    @State private var selected: RequestIdentity?
    @FocusState private var isSearchFocused: Bool

    private var results: [RequestSearchResult] {
        RequestSearchResult.matching(query, collections: model.collections, drafts: model.drafts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search requests by name or URL/path", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(openSelection)
                Button("Cancel") { model.showsRequestSearch = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No saved requests" : "No matching requests",
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(results) { result in
                                Button {
                                    open(result.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(result.method.uppercased())
                                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                                .foregroundStyle(.tint)
                                            Text(result.name).fontWeight(.medium)
                                            Spacer()
                                            Text(result.collectionName).foregroundStyle(.secondary)
                                        }
                                        Text(result.url)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(disambiguator(for: result.id))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selected == result.id ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected == result.id ? .isSelected : [])
                            }
                        }
                    }
                    .onChange(of: selected) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                }
            }
            HStack {
                Text("↑ ↓ to choose · Return to open · Esc to close")
                Spacer()
                Text("\(results.count) requests")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 620, height: 420)
        .onAppear {
            selected = results.first?.id; isSearchFocused = true
        }
        .onChange(of: results.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selected }) { selected = ids.first }
        }
        .onKeyPress(.downArrow) {
            move(1); return .handled
        }
        .onKeyPress(.upArrow) {
            move(-1); return .handled
        }
    }

    private func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        let index = selected.flatMap { selection in results.firstIndex { $0.id == selection } } ?? 0
        selected = results[min(max(0, index + offset), results.count - 1)].id
    }

    private func disambiguator(for identity: RequestIdentity) -> String {
        let prefix = String(identity.requestID.uuidString.prefix(8))
        guard
            results.contains(where: {
                $0.id != identity && $0.id.requestID.uuidString.hasPrefix(prefix)
            })
        else { return prefix }
        return "\(identity.collectionID.uuidString) / \(identity.requestID.uuidString)"
    }

    private func openSelection() {
        if let selected, results.contains(where: { $0.id == selected }) { open(selected) }
    }

    private func open(_ identity: RequestIdentity) {
        guard model.request(for: identity) != nil else { return }
        opened()
        model.openRequest(identity)
        model.showsRequestSearch = false
    }
}
