import Foundation

public enum MCPResponseViewPolicy: String, Codable, CaseIterable, Sendable {
    case inherit
    case allow
    case block
    case unredacted

    public var displayName: String {
        switch self {
        case .block: "Block body; show safe metadata"
        case .allow: "Show body with secrets redacted"
        case .unredacted: "Show response unredacted"
        case .inherit: "Inherit"
        }
    }

    public static func resolveMode(
        global: Self = .block,
        collection: Self = .inherit,
        request: Self = .inherit
    ) -> Self {
        [request, collection, global].first { $0 != .inherit } ?? .block
    }

    public static func resolve(
        global: Self = .block,
        collection: Self = .inherit,
        request: Self = .inherit
    ) -> Bool {
        resolveMode(global: global, collection: collection, request: request) != .block
    }
}

public struct MCPResourcePolicy: Codable, Equatable, Sendable {
    public var excluded: Bool
    public var responseViewing: MCPResponseViewPolicy

    public init(excluded: Bool = false, responseViewing: MCPResponseViewPolicy = .inherit) {
        self.excluded = excluded
        self.responseViewing = responseViewing
    }

    private enum CodingKeys: String, CodingKey {
        case excluded
        case responseViewing
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        excluded = try values.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
        responseViewing = try values.decodeIfPresent(MCPResponseViewPolicy.self, forKey: .responseViewing) ?? .inherit
    }

    public static func isAccessible(collection: Self, request: Self = .init()) -> Bool {
        !collection.excluded && !request.excluded
    }
}
