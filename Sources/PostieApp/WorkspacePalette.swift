import Foundation
import PostieCore

enum WorkspacePaletteInvocation: Equatable {
    case all(query: String)
    case requests(query: String)
    case collections(query: String)
    case commands(query: String)
    case variables(query: String)

    var query: String {
        switch self {
        case let .all(query), let .requests(query), let .collections(query), let .commands(query),
            let .variables(query):
            query
        }
    }
}

enum WorkspacePaletteResult: Identifiable, Equatable {
    enum ID: Hashable {
        case destination(WorkspaceDestination)
        case command(WorkspacePaletteCommand)
        case variable(WorkspacePaletteVariableIdentity)
    }

    case navigation(WorkspaceSearchResult)
    case command(WorkspacePaletteCommandResult)
    case variable(WorkspacePaletteVariableResult)

    var id: ID {
        switch self {
        case let .navigation(result): .destination(result.destination)
        case let .command(result): .command(result.id)
        case let .variable(result): .variable(result.id)
        }
    }

    var isEnabled: Bool {
        guard case let .command(result) = self else { return true }
        return result.isEnabled
    }
}

enum WorkspacePaletteCommand: Hashable, Identifiable {
    case settings
    case requestHistory
    case globalVariables
    case createCollection
    case toggleRequestResponseLayout
    case toggleSidebar
    case setTheme(AppTheme)
    case collectionSettings(UUID)
    case createRequest(UUID)

    var id: Self { self }
}

struct WorkspacePaletteCommandResult: Equatable, Identifiable {
    let command: WorkspacePaletteCommand
    let title: String
    let detail: String?
    let isEnabled: Bool

    var id: WorkspacePaletteCommand { command }
}

struct WorkspacePaletteVariableIdentity: Equatable, Hashable, Identifiable {
    let owner: VariableOwner
    let name: String

    var id: Self { self }
}

struct WorkspacePaletteVariableResult: Equatable, Identifiable {
    let identity: WorkspacePaletteVariableIdentity
    let scope: String
    let isSecret: Bool
    let preview: String?

    var id: WorkspacePaletteVariableIdentity { identity }
    var name: String { identity.name }
    var owner: VariableOwner { identity.owner }
}

enum WorkspacePalette {
    private static let maximumPreviewLength = 120

    static func invocation(for query: String) -> WorkspacePaletteInvocation {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = trimmed.first else { return .all(query: query) }
        let remainder = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)

        return switch prefix {
        case "@": .requests(query: remainder)
        case "#": .collections(query: remainder)
        case ">": .commands(query: remainder)
        case "$": .variables(query: remainder)
        default: .all(query: query)
        }
    }

    static func results(
        for invocation: WorkspacePaletteInvocation,
        navigation: [WorkspaceSearchResult],
        commands: [WorkspacePaletteCommandResult],
        variables: [WorkspacePaletteVariableResult]
    ) -> [WorkspacePaletteResult] {
        switch invocation {
        case .all:
            navigation.map(WorkspacePaletteResult.navigation)
                + commands.map(WorkspacePaletteResult.command)
                + variables.map(WorkspacePaletteResult.variable)
        case .requests:
            navigation.compactMap { result in
                guard case .request(_) = result.destination else { return nil }
                return .navigation(result)
            }
        case .collections:
            navigation.compactMap { result in
                guard case .collection(_) = result.destination else { return nil }
                return .navigation(result)
            }
        case .commands:
            commands.map(WorkspacePaletteResult.command)
        case .variables:
            variables.map(WorkspacePaletteResult.variable)
        }
    }

    static func commands(
        matching query: String,
        collections: [RequestCollection],
        workspaceIndexIsReadOnly: Bool = false,
        deletingCollections: Set<UUID> = []
    ) -> [WorkspacePaletteCommandResult] {
        var results = [
            WorkspacePaletteCommandResult(
                command: .settings,
                title: "Settings",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .requestHistory,
                title: "Request History",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .globalVariables,
                title: "Global Variables",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .createCollection,
                title: "Create Collection…",
                detail: nil,
                isEnabled: !workspaceIndexIsReadOnly
            ),
            WorkspacePaletteCommandResult(
                command: .toggleRequestResponseLayout,
                title: "Toggle Request / Response Layout",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .setTheme(.system),
                title: "Use System Theme",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .setTheme(.light),
                title: "Use Light Theme",
                detail: nil,
                isEnabled: true
            ),
            WorkspacePaletteCommandResult(
                command: .setTheme(.dark),
                title: "Use Dark Theme",
                detail: nil,
                isEnabled: true
            ),
        ]

        results.append(
            WorkspacePaletteCommandResult(
                command: .toggleSidebar,
                title: "Toggle Sidebar",
                detail: "⌘B",
                isEnabled: true
            )
        )

        for collection in collections {
            let collectionLabel = collectionLabel(collection, among: collections)
            results.append(
                WorkspacePaletteCommandResult(
                    command: .collectionSettings(collection.id),
                    title: "Collection Settings",
                    detail: collectionLabel,
                    isEnabled: true
                ))
            results.append(
                WorkspacePaletteCommandResult(
                    command: .createRequest(collection.id),
                    title: "Create Request…",
                    detail: collectionLabel,
                    isEnabled: !workspaceIndexIsReadOnly && !collection.isReadOnly
                        && !deletingCollections.contains(collection.id)
                ))
        }

        let queryTerms = query.split(whereSeparator: \.isWhitespace)
        guard !queryTerms.isEmpty else { return results }
        return results.filter { result in
            let searchableText = [result.title, result.detail].compactMap { $0 }.joined(separator: " ")
            return queryTerms.allSatisfy {
                searchableText.range(of: String($0), options: .caseInsensitive) != nil
            }
        }
    }

    static func variables(
        matching query: String,
        globalVariables: VariableValues,
        collections: [RequestCollection],
        drafts: [RequestIdentity: HTTPRequestConfiguration]
    ) -> [WorkspacePaletteVariableResult] {
        var results: [WorkspacePaletteVariableResult] = []
        appendVariables(
            globalVariables,
            owner: .global,
            scope: "Global",
            matching: query,
            to: &results
        )

        for collection in collections {
            let collectionLabel = collectionLabel(collection, among: collections)
            appendVariables(
                collection.variables,
                owner: .collection(collection.id),
                scope: "Collection · \(collectionLabel)",
                matching: query,
                to: &results
            )

            let requests = collection.requests.map {
                savedRequest -> (identity: RequestIdentity, configuration: HTTPRequestConfiguration) in
                let identity = RequestIdentity(collectionID: collection.id, requestID: savedRequest.id)
                return (identity, drafts[identity] ?? savedRequest)
            }
            for request in requests {
                appendVariables(
                    request.configuration.variables,
                    owner: .request(request.identity),
                    scope:
                        "Request · \(requestLabel(request.configuration, among: requests.map(\.configuration))) · \(collectionLabel)",
                    matching: query,
                    to: &results
                )
            }
        }

        return results
    }

    private static func appendVariables(
        _ variables: VariableValues,
        owner: VariableOwner,
        scope: String,
        matching query: String,
        to results: inout [WorkspacePaletteVariableResult]
    ) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in variables.keys.sorted(by: variableNameOrder) {
            guard query.isEmpty || name.range(of: query, options: .caseInsensitive) != nil,
                let value = variables[name]
            else { continue }

            switch value {
            case .plain(let value):
                results.append(
                    WorkspacePaletteVariableResult(
                        identity: WorkspacePaletteVariableIdentity(owner: owner, name: name),
                        scope: scope,
                        isSecret: false,
                        preview: singleLinePreview(value)
                    ))
            case .encrypted:
                results.append(
                    WorkspacePaletteVariableResult(
                        identity: WorkspacePaletteVariableIdentity(owner: owner, name: name),
                        scope: scope,
                        isSecret: true,
                        preview: nil
                    ))
            }
        }
    }

    private static func variableNameOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.localizedCaseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    private static func singleLinePreview(_ value: String) -> String {
        let boundedSource = String(value.prefix(maximumPreviewLength + 1))
        let isTruncated = boundedSource.count > maximumPreviewLength
        let characterLimit = isTruncated ? maximumPreviewLength - 1 : maximumPreviewLength
        let singleLine = boundedSource.prefix(characterLimit)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return isTruncated ? singleLine + "…" : singleLine
    }

    private static func collectionLabel(_ collection: RequestCollection, among collections: [RequestCollection])
        -> String
    {
        let duplicates = collections.filter {
            $0.name.compare(collection.name, options: .caseInsensitive) == .orderedSame
        }
        guard duplicates.count > 1 else { return collection.name }

        for length in stride(from: 8, through: 32, by: 4) {
            let identifiers = duplicates.map { identifierPrefix($0.id, length: length) }
            if Set(identifiers).count == identifiers.count {
                return "\(collection.name) · ID \(identifierPrefix(collection.id, length: length))"
            }
        }
        return "\(collection.name) · ID \(collection.id.uuidString)"
    }

    private static func requestLabel(_ request: HTTPRequestConfiguration, among requests: [HTTPRequestConfiguration])
        -> String
    {
        let duplicates = requests.filter {
            $0.name.compare(request.name, options: .caseInsensitive) == .orderedSame
        }
        guard duplicates.count > 1 else { return request.name }

        for length in stride(from: 8, through: 32, by: 4) {
            let identifiers = duplicates.map { identifierPrefix($0.id, length: length) }
            if Set(identifiers).count == identifiers.count {
                return "\(request.name) · ID \(identifierPrefix(request.id, length: length))"
            }
        }
        return "\(request.name) · ID \(request.id.uuidString)"
    }

    private static func identifierPrefix(_ id: UUID, length: Int) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(length))
    }
}
