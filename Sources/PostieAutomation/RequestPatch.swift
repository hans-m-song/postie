import Foundation
import PostieCore

public enum RequestPatch {
    public static func apply(
        _ value: AutomationJSON,
        to original: HTTPRequestConfiguration,
        encrypt: @Sendable (String) async throws -> SecretEnvelope
    ) async throws -> HTTPRequestConfiguration {
        guard let fields = value.objectValue else { throw invalid() }
        let arguments = try AutomationArguments(
            fields,
            allowed: [
                "name", "method", "url", "pathParameters", "query", "headers", "body", "bodyEnabled",
                "bodySyntax", "optionOverrides", "authentication", "inheritsCollectionAuthentication",
                "bodyKind", "rawFile", "multipartParts",
            ])
        var request = original
        try UploadRequestPatch.apply(fields, to: &request)
        if let name = try arguments.string("name", required: false) {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }
            request.name = name
        }
        if let method = try arguments.string("method", required: false) {
            guard !method.isEmpty,
                method.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
            else { throw invalid() }
            request.method = method.uppercased()
        }
        if let url = try arguments.string("url", required: false) {
            let parsed = QueryParameters.parse(displayURL: url)
            request.url = parsed.baseURL
            request.query = parsed.fields
        }
        if let body = try arguments.string("body", required: false) { request.body = body }
        if let syntax = try arguments.string("bodySyntax", required: false) {
            guard let syntax = BodySyntax(rawValue: syntax) else { throw invalid() }
            request.bodySyntax = syntax
        }
        if let value = fields["bodyEnabled"] { request.bodyEnabled = try boolean(value) }
        if let value = fields["inheritsCollectionAuthentication"] {
            request.inheritsCollectionAuthentication = try boolean(value)
        }
        if let value = fields["pathParameters"] { request.pathParameters = try httpFields(value) }
        if let value = fields["query"] { request.query = try httpFields(value) }
        if let value = fields["headers"] { request.headers = try httpFields(value) }
        if let value = fields["optionOverrides"] {
            guard let object = value.objectValue else { throw invalid() }
            _ = try AutomationArguments(
                object,
                allowed: [
                    "followRedirects", "inactivityTimeout", "overallTimeout", "maximumResponseBytes",
                    "overallTimeoutIsUnlimited", "responseSizeIsUnlimited",
                ])
            var merged = try JSONDecoder().decode(
                [String: AutomationJSON].self,
                from: JSONEncoder().encode(request.optionOverrides ?? .explicit(request.options)))
            for (key, value) in object { merged[key] = value }
            let options = try JSONDecoder().decode(HTTPOptionsOverrides.self, from: JSONEncoder().encode(merged))
            guard options.inactivityTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
                options.overallTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
                options.maximumResponseBytes.map({ $0 > 0 }) ?? true
            else { throw invalid() }
            request.optionOverrides = options
        }
        if let value = fields["authentication"] {
            guard let fields = value.objectValue else { throw invalid() }
            let arguments = try AutomationArguments(
                fields, allowed: ["kind", "username", "password", "token", "apiKey", "apiKeyHeaderName"])
            var auth = request.authentication
            if let kind = try arguments.string("kind", required: false) {
                guard let kind = AuthenticationKind(rawValue: kind) else { throw invalid() }
                auth.kind = kind
            }
            if let username = try arguments.string("username", required: false) { auth.username = username }
            if let name = try arguments.string("apiKeyHeaderName", required: false) { auth.apiKeyHeaderName = name }
            if let secret = try arguments.string("password", required: false) {
                auth.password = try await encrypt(secret)
            }
            if let secret = try arguments.string("token", required: false) { auth.token = try await encrypt(secret) }
            if let secret = try arguments.string("apiKey", required: false) { auth.apiKey = try await encrypt(secret) }
            request.authentication = auth
        }
        return request
    }

    private static func httpFields(_ value: AutomationJSON) throws -> [HTTPField] {
        guard case .array(let rows) = value, rows.count <= 4096 else { throw invalid() }
        return try rows.map { row in
            guard let fields = row.objectValue else { throw invalid() }
            let arguments = try AutomationArguments(fields, allowed: ["name", "value", "isEnabled"])
            return HTTPField(
                name: try arguments.string("name") ?? "",
                value: try arguments.string("value") ?? "",
                isEnabled: try fields["isEnabled"].map(boolean) ?? true
            )
        }
    }

    private static func boolean(_ value: AutomationJSON) throws -> Bool {
        guard let value = value.boolValue else { throw invalid() }
        return value
    }

    private static func invalid() -> AutomationFailure {
        AutomationFailure(.invalidArguments, "Invalid request fields.")
    }
}
