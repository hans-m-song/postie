import Foundation

public enum AutomationOperation: String, Codable, CaseIterable, Sendable {
    case collectionsList = "collections.list"
    case requestsList = "requests.list"
    case requestsGet = "requests.get"
    case requestsCreate = "requests.create"
    case requestsUpdate = "requests.update"
    case requestsStart = "requests.start"
    case runsList = "runs.list"
    case runsGet = "runs.get"
    case runsCancel = "runs.cancel"
    case variablesList = "variables.list"
    case variablesGet = "variables.get"
    case snapshotsList = "snapshots.list"
    case snapshotsGet = "snapshots.get"
    case snapshotsCreate = "snapshots.create"
    case snapshotsRename = "snapshots.rename"
    case snapshotsDelete = "snapshots.delete"

    public var toolName: String { rawValue.replacingOccurrences(of: ".", with: "_") }

    public init?(toolName: String) {
        guard let operation = Self.allCases.first(where: { $0.toolName == toolName }) else { return nil }
        self = operation
    }
}

public enum AutomationChannel: Sendable {
    case mcp
    case cli
}

public struct AutomationCommand: Codable, Equatable, Sendable {
    public let id: UUID
    public let operation: AutomationOperation
    public let arguments: [String: AutomationJSON]

    public init(id: UUID = UUID(), operation: AutomationOperation, arguments: [String: AutomationJSON] = [:]) {
        self.id = id
        self.operation = operation
        self.arguments = arguments
    }
}

public struct AutomationFailure: Error, Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case invalidArguments, unavailable, notFound, forbidden, conflict, storageFailure
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct AutomationReply: Codable, Equatable, Sendable {
    public let id: UUID
    public let result: AutomationJSON?
    public let error: AutomationFailure?

    public init(id: UUID, result: AutomationJSON) {
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: UUID, error: AutomationFailure) {
        self.id = id
        result = nil
        self.error = error
    }
}

public typealias AutomationDispatcher = @Sendable (AutomationCommand, AutomationChannel) async -> AutomationReply

extension AutomationJSON {
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: Self]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [Self]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

public struct AutomationArguments: Sendable {
    private let values: [String: AutomationJSON]

    public init(_ values: [String: AutomationJSON], allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else {
            throw AutomationFailure(.invalidArguments, "Unknown argument.")
        }
        self.values = values
    }

    public func string(_ name: String, required: Bool = true) throws -> String? {
        guard let value = values[name] else {
            if required { throw AutomationFailure(.invalidArguments, "Missing \(name).") }
            return nil
        }
        guard let string = value.stringValue else {
            throw AutomationFailure(.invalidArguments, "Invalid \(name).")
        }
        return string
    }

    public func uuid(_ name: String, required: Bool = true) throws -> UUID? {
        guard let value = try string(name, required: required) else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw AutomationFailure(.invalidArguments, "Invalid \(name).")
        }
        return id
    }

    public func value(_ name: String) -> AutomationJSON? { values[name] }
}
