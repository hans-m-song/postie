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
    case apiKey
}

public struct RequestAuthentication: Codable, Equatable, Sendable {
    public var kind: AuthenticationKind
    public var username: String
    public var password: SecretEnvelope?
    public var token: SecretEnvelope?
    public var apiKeyHeaderName: String?
    public var apiKey: SecretEnvelope?

    public init(
        kind: AuthenticationKind = .none,
        username: String = "",
        password: SecretEnvelope? = nil,
        token: SecretEnvelope? = nil,
        apiKeyHeaderName: String? = nil,
        apiKey: SecretEnvelope? = nil
    ) {
        self.kind = kind
        self.username = username
        self.password = password
        self.token = token
        self.apiKeyHeaderName = apiKeyHeaderName
        self.apiKey = apiKey
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

public enum VariableScope: String, Codable, CaseIterable, Sendable {
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

public enum HTTPHeaderSource: String, Codable, Equatable, Sendable {
    case request
    case collection
    case requestAuth
    case collectionAuth
    case automatic
}

public struct PreparedHTTPRequest: Sendable {
    public let configuration: HTTPRequestConfiguration
    public let request: URLRequest
    public let uploadBody: PreparedUploadBody?
    public let referencedInputs: [String: ResolvedVariable]
    public let snapshotCapture: SnapshotPreparationCapture?
    public let sensitiveRequestHeaderNames: Set<String>
    public let secretRequestHeaderNames: Set<String>
    public let requestHeaderSources: [String: HTTPHeaderSource]

    public init(
        configuration: HTTPRequestConfiguration,
        request: URLRequest,
        referencedInputs: [String: ResolvedVariable],
        sensitiveRequestHeaderNames: Set<String> = [],
        secretRequestHeaderNames: Set<String> = [],
        requestHeaderSources: [String: HTTPHeaderSource] = [:],
        snapshotCapture: SnapshotPreparationCapture? = nil,
        uploadBody: PreparedUploadBody? = nil
    ) {
        self.snapshotCapture = snapshotCapture
        self.uploadBody = uploadBody
        self.configuration = configuration
        self.request = request
        self.referencedInputs = referencedInputs
        self.sensitiveRequestHeaderNames = Set(sensitiveRequestHeaderNames.map { $0.lowercased() })
        self.secretRequestHeaderNames = Set(secretRequestHeaderNames.map { $0.lowercased() })
        self.requestHeaderSources = requestHeaderSources.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
    }
}

public protocol SecretValueDecrypting: Sendable {
    func decrypt(_ envelope: SecretEnvelope) async throws -> String
}

public protocol ApplicationKeyStore: Sendable {
    func loadKey() throws -> Data?
    func createKey(_ proposedKey: Data) throws -> Data
}
