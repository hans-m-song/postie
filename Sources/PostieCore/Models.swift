import Foundation

public struct HTTPField: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String = "", value: String = "", isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

public enum BodySyntax: String, Codable, CaseIterable, Sendable {
    case none
    case json
}

public struct HTTPOptions: Codable, Equatable, Sendable {
    public var followRedirects: Bool
    public var inactivityTimeout: TimeInterval
    public var overallTimeout: TimeInterval?
    public var maximumResponseBytes: Int64?

    public init(
        followRedirects: Bool = false,
        inactivityTimeout: TimeInterval = 300,
        overallTimeout: TimeInterval? = 1800,
        maximumResponseBytes: Int64? = 1_073_741_824
    ) {
        self.followRedirects = followRedirects
        self.inactivityTimeout = inactivityTimeout
        self.overallTimeout = overallTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public struct HTTPRequestConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var method: String
    public var url: String
    public var pathParameters: [HTTPField]
    public var query: [HTTPField]
    public var headers: [HTTPField]
    public var body: String
    public var bodyEnabled: Bool
    public var bodySyntax: BodySyntax
    public var options: HTTPOptions
    public var variables: VariableValues
    public var authentication: RequestAuthentication

    public init(
        id: UUID = UUID(),
        name: String = "New request",
        method: String = "GET",
        url: String = "",
        pathParameters: [HTTPField] = [],
        query: [HTTPField] = [],
        headers: [HTTPField] = [],
        body: String = "",
        bodyEnabled: Bool = false,
        bodySyntax: BodySyntax = .none,
        options: HTTPOptions = HTTPOptions(),
        variables: VariableValues = [:],
        authentication: RequestAuthentication = RequestAuthentication()
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.pathParameters = pathParameters
        self.query = query
        self.headers = headers
        self.body = body
        self.bodyEnabled = bodyEnabled
        self.bodySyntax = bodySyntax
        self.options = options
        self.variables = variables
        self.authentication = authentication
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case method
        case url
        case pathParameters
        case query
        case headers
        case body
        case bodyEnabled
        case bodySyntax
        case options
        case variables
        case authentication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        pathParameters = try container.decodeIfPresent([HTTPField].self, forKey: .pathParameters) ?? []
        query = try container.decode([HTTPField].self, forKey: .query)
        headers = try container.decode([HTTPField].self, forKey: .headers)
        body = try container.decode(String.self, forKey: .body)
        bodyEnabled = try container.decode(Bool.self, forKey: .bodyEnabled)
        bodySyntax = try container.decode(BodySyntax.self, forKey: .bodySyntax)
        options = try container.decode(HTTPOptions.self, forKey: .options)
        variables = try container.decodeIfPresent(VariableValues.self, forKey: .variables) ?? [:]
        authentication = try container.decodeIfPresent(RequestAuthentication.self, forKey: .authentication) ?? RequestAuthentication()
    }
}

public struct RequestIdentity: Hashable, Codable, Sendable {
    public let collectionID: UUID
    public let requestID: UUID

    public init(collectionID: UUID, requestID: UUID) {
        self.collectionID = collectionID
        self.requestID = requestID
    }
}

public struct RequestCollection: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var requests: [HTTPRequestConfiguration]
    public var isReadOnly: Bool
    public var variables: VariableValues

    public init(id: UUID = UUID(), name: String, requests: [HTTPRequestConfiguration] = [], isReadOnly: Bool = false, variables: VariableValues = [:]) {
        self.id = id
        self.name = name
        self.requests = requests
        self.isReadOnly = isReadOnly
        self.variables = variables
    }
}

public struct StorageIssue: Identifiable, Equatable, Sendable {
    public var id: String
    public var message: String
    public var collectionID: UUID?
    public var requestID: UUID?
    public var canRecover: Bool

    public init(id: String, message: String, collectionID: UUID? = nil, requestID: UUID? = nil, canRecover: Bool = false) {
        self.id = id
        self.message = message
        self.collectionID = collectionID
        self.requestID = requestID
        self.canRecover = canRecover
    }
}

public struct WorkspaceLoad: Sendable {
    public var collections: [RequestCollection]
    public var issues: [StorageIssue]
    public var globalVariables: VariableValues
    public var globalVariablesAreReadOnly: Bool

    public init(collections: [RequestCollection], issues: [StorageIssue] = [], globalVariables: VariableValues = [:], globalVariablesAreReadOnly: Bool = false) {
        self.collections = collections
        self.issues = issues
        self.globalVariables = globalVariables
        self.globalVariablesAreReadOnly = globalVariablesAreReadOnly
    }
}

public struct HTTPRedirect: Identifiable, Sendable {
    public let id: UUID
    public let statusCode: Int
    public let url: URL
    public let nextURL: URL
    public let method: String
    public let nextMethod: String
    public let requestHeaders: [HTTPField]
    public let responseHeaders: [HTTPField]

    public init(id: UUID = UUID(), statusCode: Int, url: URL, nextURL: URL, method: String, nextMethod: String, requestHeaders: [HTTPField], responseHeaders: [HTTPField]) {
        self.id = id
        self.statusCode = statusCode
        self.url = url
        self.nextURL = nextURL
        self.method = method
        self.nextMethod = nextMethod
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
    }
}

public struct HTTPProgress: Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64? = nil) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

public struct HTTPResponseRecord: Sendable {
    public let runID: UUID
    public let request: HTTPRequestConfiguration
    public let finalURL: URL
    public let statusCode: Int
    public let requestHeaders: [HTTPField]
    public let responseHeaders: [HTTPField]
    public let redirects: [HTTPRedirect]
    public let bodyFileURL: URL
    public let bodyByteCount: Int64
    public let duration: TimeInterval
    public let redirectLimitReached: Bool
    public let effectiveMethod: String
    public let redirectRequest: URLRequest?
    public let pendingRedirect: HTTPRedirect?

    public init(runID: UUID, request: HTTPRequestConfiguration, finalURL: URL, statusCode: Int, requestHeaders: [HTTPField], responseHeaders: [HTTPField], redirects: [HTTPRedirect], bodyFileURL: URL, bodyByteCount: Int64, duration: TimeInterval, redirectLimitReached: Bool = false, effectiveMethod: String? = nil, redirectRequest: URLRequest? = nil, pendingRedirect: HTTPRedirect? = nil) {
        self.runID = runID
        self.request = request
        self.finalURL = finalURL
        self.statusCode = statusCode
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.redirects = redirects
        self.bodyFileURL = bodyFileURL
        self.bodyByteCount = bodyByteCount
        self.duration = duration
        self.redirectLimitReached = redirectLimitReached
        self.effectiveMethod = effectiveMethod ?? request.method
        self.redirectRequest = redirectRequest
        self.pendingRedirect = pendingRedirect
    }
}

public enum HTTPExecutionEvent: Sendable {
    case progress(HTTPProgress)
    case redirect(HTTPRedirect)
    case completed(HTTPResponseRecord)
    case failed(String)
    case cancelled
}

public struct HTTPRun: Sendable {
    public let id: UUID
    public let events: AsyncStream<HTTPExecutionEvent>

    public init(id: UUID, events: AsyncStream<HTTPExecutionEvent>) {
        self.id = id
        self.events = events
    }
}

public struct BodyPreview: Sendable {
    public let text: String
    public let isTruncated: Bool
    public let isBinary: Bool

    public init(text: String, isTruncated: Bool, isBinary: Bool) {
        self.text = text
        self.isTruncated = isTruncated
        self.isBinary = isBinary
    }
}
