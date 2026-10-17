import Foundation

public struct SecretEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var combined: String

    public init(version: Int = 1, combined: String) {
        self.version = version
        self.combined = combined
    }
}

public enum VariableValue: Codable, Equatable, Sendable {
    case plain(String)
    case encrypted(SecretEnvelope)

    public var isEncrypted: Bool {
        if case .encrypted = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .plain(value)
        } else {
            self = .encrypted(try container.decode(SecretEnvelope.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let value): try container.encode(value)
        case .encrypted(let envelope): try container.encode(envelope)
        }
    }
}

public typealias VariableValues = [String: VariableValue]

public enum AuthenticationKind: String, Codable, CaseIterable, Sendable {
    case none
    case basic
    case bearer
}

public struct RequestAuthentication: Codable, Equatable, Sendable {
    public var kind: AuthenticationKind
    public var username: String
    public var password: SecretEnvelope?
    public var token: SecretEnvelope?

    public init(kind: AuthenticationKind = .none, username: String = "", password: SecretEnvelope? = nil, token: SecretEnvelope? = nil) {
        self.kind = kind
        self.username = username
        self.password = password
        self.token = token
    }
}

public struct CollectionRequestDefaults: Codable, Equatable, Sendable {
    public var headers: [HTTPField]
    public var authentication: RequestAuthentication

    public init(headers: [HTTPField] = [], authentication: RequestAuthentication = .init()) {
        self.headers = headers
        self.authentication = authentication
    }
}

public enum VariableScope: String, CaseIterable, Sendable {
    case global
    case collection
    case request
}

public struct VariableContext: Equatable, Sendable {
    public var global: VariableValues
    public var collection: VariableValues
    public var request: VariableValues

    public init(global: VariableValues = [:], collection: VariableValues = [:], request: VariableValues = [:]) {
        self.global = global
        self.collection = collection
        self.request = request
    }
}

public struct ResolvedVariable: Equatable, Sendable {
    public let value: String
    public let scope: VariableScope
    public let isSecret: Bool

    public init(value: String, scope: VariableScope, isSecret: Bool) {
        self.value = value
        self.scope = scope
        self.isSecret = isSecret
    }
}

public struct PreparedHTTPRequest: Sendable {
    public let configuration: HTTPRequestConfiguration
    public let request: URLRequest
    public let referencedInputs: [String: ResolvedVariable]

    init(configuration: HTTPRequestConfiguration, request: URLRequest, referencedInputs: [String: ResolvedVariable]) {
        self.configuration = configuration
        self.request = request
        self.referencedInputs = referencedInputs
    }
}

public protocol SecretValueDecrypting: Sendable {
    func decrypt(_ envelope: SecretEnvelope) async throws -> String
}

public protocol ApplicationKeyStore: Sendable {
    func loadKey() throws -> Data?
    func createKey(_ proposedKey: Data) throws -> Data
}
