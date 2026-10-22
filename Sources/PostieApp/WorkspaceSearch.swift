import Foundation
import PostieCore

enum WorkspaceDestination: Hashable, Identifiable {
    case collection(UUID)
    case request(RequestIdentity)
    case snapshot(UUID)

    var id: Self { self }
}

struct WorkspaceSearchResult: Identifiable, Equatable {
    let destination: WorkspaceDestination
    let collectionID: UUID
    let name: String
    let collectionName: String
    let requestName: String?
    let method: String?
    let url: String?
    let requestCount: Int?
    let capturedAt: Date?
    let statusCode: Int?

    var id: WorkspaceDestination { destination }

    static func disambiguator(for result: Self, among visibleResults: [Self]) -> String? {
        let collisions = visibleResults.filter { $0.visibleContext == result.visibleContext }
        guard collisions.count > 1 else { return nil }

        for prefixLength in stride(from: 8, through: 36, by: 4) {
            let identifiers = collisions.map { $0.identityPrefix(length: prefixLength) }
            if Set(identifiers).count == collisions.count {
                return result.identityPrefix(length: prefixLength)
            }
        }
        return result.fullIdentity
    }

    static func matching(
        _ query: String,
        collections: [RequestCollection],
        drafts: [RequestIdentity: HTTPRequestConfiguration],
        snapshots: [SavedSnapshot],
        groupingForSnapshot: (SavedSnapshot) -> SnapshotGrouping
    ) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let collectionAndRequestResults = collections.flatMap { collection -> [Self] in
            let collectionResult = Self(
                destination: .collection(collection.id),
                collectionID: collection.id,
                name: collection.name,
                collectionName: collection.name,
                requestName: nil,
                method: nil,
                url: nil,
                requestCount: collection.requests.count,
                capturedAt: nil,
                statusCode: nil
            )
            let requestResults = collection.requests.map { saved in
                let identity = RequestIdentity(collectionID: collection.id, requestID: saved.id)
                let request = drafts[identity] ?? saved
                return Self(
                    destination: .request(identity),
                    collectionID: identity.collectionID,
                    name: request.name,
                    collectionName: collection.name,
                    requestName: request.name,
                    method: request.method,
                    url: QueryParameters.render(baseURL: request.url, fields: request.query),
                    requestCount: nil,
                    capturedAt: nil,
                    statusCode: nil
                )
            }
            return [collectionResult] + requestResults
        }
        let snapshotResults =
            snapshots
            .sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { snapshot in
                let grouping = groupingForSnapshot(snapshot)
                return Self(
                    destination: .snapshot(snapshot.id),
                    collectionID: grouping.identity.collectionID,
                    name: snapshot.name,
                    collectionName: grouping.collectionName,
                    requestName: grouping.requestName,
                    method: nil,
                    url: nil,
                    requestCount: nil,
                    capturedAt: snapshot.capturedAt,
                    statusCode: snapshot.statusCode
                )
            }
        let results = collectionAndRequestResults + snapshotResults

        guard !query.isEmpty else { return results }
        return results.filter { result in
            let searchableValues: [String]
            switch result.destination {
            case .collection(_):
                searchableValues = [result.name]
            case .request(_):
                searchableValues = [result.name, result.url ?? ""]
            case .snapshot(_):
                searchableValues = [result.name]
            }
            return searchableValues.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var visibleContext: [String] {
        switch destination {
        case .collection(_):
            ["collection", name, "\(requestCount ?? 0) requests"]
        case .request(_):
            ["request", method?.uppercased() ?? "", name, collectionName, url ?? ""]
        case .snapshot(_):
            [
                "snapshot", name, requestName ?? "", collectionName,
                capturedAt?.formatted(date: .numeric, time: .shortened) ?? "",
                statusCode.map(String.init) ?? "",
            ]
        }
    }

    private func identityPrefix(length: Int) -> String {
        switch destination {
        case let .collection(id), let .snapshot(id):
            String(id.uuidString.prefix(length))
        case let .request(identity):
            String(identity.requestID.uuidString.prefix(length))
        }
    }

    private var fullIdentity: String {
        switch destination {
        case let .collection(id):
            "collection/\(id.uuidString)"
        case let .request(identity):
            "request/\(identity.collectionID.uuidString)/\(identity.requestID.uuidString)"
        case let .snapshot(id):
            "snapshot/\(id.uuidString)"
        }
    }
}
