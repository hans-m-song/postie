import Foundation

public struct SnapshotInput: Codable, Equatable, Sendable {
    public let value: String
    public let scope: VariableScope
    public let isSecret: Bool

    public init(value: String, scope: VariableScope, isSecret: Bool) {
        self.value = value
        self.scope = scope
        self.isSecret = isSecret
    }
}

public struct SnapshotRequestTemplate: Codable, Equatable, Sendable {
    public let method: String
    public let url: String
    public let pathParameters: [HTTPField]
    public let query: [HTTPField]
    public let headers: [HTTPField]
    public let body: String
    public let bodyEnabled: Bool
    public let bodySyntax: BodySyntax
    public let options: HTTPOptions

    public init(configuration: HTTPRequestConfiguration, headers: [HTTPField]? = nil) {
        method = configuration.method
        url = configuration.url
        pathParameters = configuration.pathParameters
        query = configuration.query
        self.headers = headers ?? configuration.headers
        body = configuration.body
        bodyEnabled = configuration.bodyEnabled
        bodySyntax = configuration.bodySyntax
        options = configuration.options
    }

    public var configuration: HTTPRequestConfiguration {
        HTTPRequestConfiguration(
            method: method, url: url, pathParameters: pathParameters, query: query,
            headers: headers, body: body, bodyEnabled: bodyEnabled, bodySyntax: bodySyntax, options: options
        )
    }
}

public struct SnapshotAuthenticationInput: Codable, Equatable, Sendable {
    public let kind: AuthenticationKind
    public let username: String
    public let secretTemplate: String?
    public let resolvedSecret: String?
    public let apiKeyHeaderName: String?

    public init(
        kind: AuthenticationKind, username: String = "", secretTemplate: String? = nil,
        resolvedSecret: String? = nil, apiKeyHeaderName: String? = nil
    ) {
        self.kind = kind
        self.username = username
        self.secretTemplate = secretTemplate
        self.resolvedSecret = resolvedSecret
        self.apiKeyHeaderName = apiKeyHeaderName
    }
}

public struct SnapshotTransportRequest: Codable, Equatable, Sendable {
    public let method: String
    public let url: URL
    public let headers: [HTTPField]
    public let body: String?
    public let headerSources: [String: HTTPHeaderSource]
    public let sensitiveNames: Set<String>
    public let secretNames: Set<String>

    public init(
        method: String, url: URL, headers: [HTTPField], body: String? = nil,
        headerSources: [String: HTTPHeaderSource] = [:], sensitiveNames: Set<String> = [],
        secretNames: Set<String> = []
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.headerSources = headerSources
        self.sensitiveNames = sensitiveNames
        self.secretNames = secretNames
    }
}

public struct SnapshotRedactionCapture: Codable, Equatable, Sendable {
    public let inputs: [String: SnapshotInput]
    public let isComplete: Bool

    public init(inputs: [String: SnapshotInput], isComplete: Bool) {
        self.inputs = inputs
        self.isComplete = isComplete
    }
}

public struct SnapshotPreparationCapture: Codable, Equatable, Sendable {
    public let preparationVersion: Int
    public let template: SnapshotRequestTemplate
    public let referencedInputs: [String: SnapshotInput]
    public let authentication: SnapshotAuthenticationInput
    public let submitted: SnapshotTransportRequest
    public let redactionInputs: SnapshotRedactionCapture?

    public init(
        preparationVersion: Int = 1, template: SnapshotRequestTemplate,
        referencedInputs: [String: SnapshotInput], authentication: SnapshotAuthenticationInput,
        submitted: SnapshotTransportRequest, redactionInputs: SnapshotRedactionCapture? = nil
    ) {
        self.preparationVersion = preparationVersion
        self.template = template
        self.referencedInputs = referencedInputs
        self.authentication = authentication
        self.submitted = submitted
        self.redactionInputs = redactionInputs
    }
}

public struct SnapshotSource: Codable, Equatable, Sendable {
    public let identity: RequestIdentity
    public let collectionName: String
    public let requestName: String

    public init(identity: RequestIdentity, collectionName: String, requestName: String) {
        self.identity = identity
        self.collectionName = collectionName
        self.requestName = requestName
    }
}

public struct SavedSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let capturedAt: Date
    public let source: SnapshotSource
    public let statusCode: Int
    public let bodyByteCount: Int64

    public init(
        id: UUID, name: String, capturedAt: Date, source: SnapshotSource,
        statusCode: Int, bodyByteCount: Int64
    ) {
        self.id = id
        self.name = name
        self.capturedAt = capturedAt
        self.source = source
        self.statusCode = statusCode
        self.bodyByteCount = bodyByteCount
    }
}

public struct SnapshotLoad: Sendable {
    public let snapshots: [SavedSnapshot]
    public let issues: [StorageIssue]
    public let containsEncryptedData: Bool

    public init(snapshots: [SavedSnapshot], issues: [StorageIssue] = [], containsEncryptedData: Bool) {
        self.snapshots = snapshots
        self.issues = issues
        self.containsEncryptedData = containsEncryptedData
    }
}

public struct FrozenSnapshotContext: Codable, Sendable {
    public let preparation: SnapshotPreparationCapture
    public let observedTransport: SnapshotTransportRequest
    public let redirects: [HTTPRedirect]

    public init(
        preparation: SnapshotPreparationCapture, observedTransport: SnapshotTransportRequest,
        redirects: [HTTPRedirect]
    ) {
        self.preparation = preparation
        self.observedTransport = observedTransport
        self.redirects = redirects
    }
}

public struct OpenedSnapshot: Sendable {
    public let summary: SavedSnapshot
    public let template: SnapshotRequestTemplate
    public let context: FrozenSnapshotContext?
    public let contextError: String?
    public let response: HTTPResponseRecord

    public init(
        summary: SavedSnapshot, template: SnapshotRequestTemplate, context: FrozenSnapshotContext?,
        contextError: String?, response: HTTPResponseRecord
    ) {
        self.summary = summary
        self.template = template
        self.context = context
        self.contextError = contextError
        self.response = response
    }
}

public struct HTTPBodyLease: Sendable {
    public let token: UUID
    public let runID: UUID
    public let bodyURL: URL

    init(token: UUID, runID: UUID, bodyURL: URL) {
        self.token = token
        self.runID = runID
        self.bodyURL = bodyURL
    }
}
