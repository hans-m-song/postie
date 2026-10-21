import Foundation

private enum RequestPreparationError: LocalizedError {
    case invalidURL
    case invalidMethod
    case invalidHeaderName
    case invalidHeaderValue
    case invalidPathParameter(String)
    case unresolvedTemplate
    case missingVariable(String)
    case secretUnavailable
    case invalidAuthentication
    case collectionDefaultsUnavailable
    case invalidBasicCredentials
    case invalidBearerCredential
    case invalidAPIKeyCredential
    case invalidTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid HTTP or HTTPS URL."
        case .invalidMethod:
            return "Enter a valid HTTP method."
        case .invalidHeaderName:
            return "A header name is invalid."
        case .invalidHeaderValue:
            return "A header value contains invalid characters."
        case .invalidPathParameter(let name):
            return "Path parameter '\(name)' needs exactly one enabled, non-empty value."
        case .unresolvedTemplate:
            return "Resolve all valid {{...}} template values before sending."
        case .missingVariable(let name):
            return "Variable '\(name)' is missing."
        case .secretUnavailable:
            return "A required secret value could not be unlocked."
        case .invalidAuthentication:
            return "The selected authentication method is missing its secret value."
        case .collectionDefaultsUnavailable:
            return "Collection authentication requires collection defaults during request preparation."
        case .invalidBasicCredentials:
            return "Basic credentials contain invalid characters."
        case .invalidBearerCredential:
            return "The Bearer token must be non-empty and contain no whitespace or control characters."
        case .invalidAPIKeyCredential:
            return "The API key must be non-empty and contain no control characters."
        case .invalidTimeout:
            return "Timeouts and response limits must be valid positive values."
        }
    }
}

public enum RequestPreparer {
    static let standardSensitiveRequestHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie"
    ]

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private struct PathParameterValue {
        let name: String
        let value: String
    }

    public static func pathParameterNames(in url: String) -> [String] {
        var seen = Set<String>()
        return TemplateEngine.pathReferences(in: url).compactMap { reference in
            guard seen.insert(reference.name).inserted else {
                return nil
            }
            return reference.name
        }
    }

    public static func prepare(_ configuration: HTTPRequestConfiguration) throws -> URLRequest {
        guard !configuration.inheritsCollectionAuthentication else {
            throw RequestPreparationError.collectionDefaultsUnavailable
        }
        guard configuration.authentication.kind == .none else {
            throw RequestPreparationError.secretUnavailable
        }

        try validateOptions(configuration.options)
        let pathParameters = try pathParameterValues(in: configuration)
        let names = try referencedNames(in: templateSources(configuration, pathParameters: pathParameters))
        let context = VariableContext(request: configuration.variables)
        let resolvedVariables = try resolvePlainVariables(names, in: context)
        return try makeRequest(
            configuration,
            pathParameters: pathParameters,
            variableValues: resolvedVariables.mapValues(\.value),
            structuredHeader: nil
        )
    }

    public static func prepare(
        _ configuration: HTTPRequestConfiguration,
        context: VariableContext,
        decryptor: (any SecretValueDecrypting)?,
        collection: CollectionRequestDefaults = .init(),
        captureRedactionInputs: Bool = false
    ) async throws -> PreparedHTTPRequest {
        try validateOptions(configuration.options)

        let pathParameters = try pathParameterValues(in: configuration)
        let effectiveContext = contextByAddingConfigurationRequestValues(configuration, to: context)
        let selectedAuthentication = configuration.inheritsCollectionAuthentication
            ? collection.authentication
            : configuration.authentication
        let selectedAuthenticationHeaderName = try authenticationHeaderName(for: selectedAuthentication)
        let requestHeaders = configuration.headers.filter(hasNonblankName)
        let collectionHeaderNames = collection.headers.filter { $0.isEnabled && hasNonblankName($0) }
        let headerNameSources = collectionHeaderNames.map(\.name) + requestHeaders.map(\.name)
        let headerNameVariables = try referencedNames(in: headerNameSources)
        var resolvedVariables = try await resolveVariables(headerNameVariables, in: effectiveContext, decryptor: decryptor)
        let resolvedNameValues = resolvedVariables.mapValues(\.value)
        let resolvedRequestHeaderNames = try requestHeaders.map {
            try substitute($0.name, values: resolvedNameValues).lowercased()
        }
        let suppressedHeaderNames = Set(resolvedRequestHeaderNames)
        let manualAuthenticationHeaderOverride = selectedAuthenticationHeaderName.map { authenticationHeaderName in
            zip(requestHeaders, resolvedRequestHeaderNames).contains { pair in
                pair.0.isEnabled && isActive(pair.0) && pair.1 == authenticationHeaderName.lowercased()
            }
        } ?? false
        let authenticationToPrepare = manualAuthenticationHeaderOverride ? RequestAuthentication() : selectedAuthentication
        var inheritedHeaders: [HTTPField] = []
        for field in collection.headers where isActive(field) {
            let name = try substitute(field.name, values: resolvedNameValues)
            let normalizedName = name.lowercased()
            let matchesStructuredAuthenticationHeader = selectedAuthenticationHeaderName.map {
                $0.caseInsensitiveCompare(name) == .orderedSame
            } ?? false
            guard !suppressedHeaderNames.contains(normalizedName), !matchesStructuredAuthenticationHeader else {
                continue
            }
            inheritedHeaders.append(field)
        }

        let headers = inheritedHeaders + configuration.headers
        let sources = templateSources(
            configuration,
            pathParameters: pathParameters,
            headers: headers,
            authentication: authenticationToPrepare
        )
        let names = try referencedNames(in: sources).filter { resolvedVariables[$0] == nil }
        let remainingVariables = try await resolveVariables(names, in: effectiveContext, decryptor: decryptor)
        resolvedVariables.merge(remainingVariables) { current, _ in current }

        let secretTemplate: String?
        switch authenticationToPrepare.kind {
        case .none:
            secretTemplate = nil
        case .basic:
            guard let envelope = authenticationToPrepare.password else {
                throw RequestPreparationError.invalidAuthentication
            }
            secretTemplate = try await decrypt(envelope, using: decryptor)
        case .bearer:
            guard let envelope = authenticationToPrepare.token else {
                throw RequestPreparationError.invalidAuthentication
            }
            secretTemplate = try await decrypt(envelope, using: decryptor)
        case .apiKey:
            guard let envelope = authenticationToPrepare.apiKey else {
                throw RequestPreparationError.invalidAuthentication
            }
            secretTemplate = try await decrypt(envelope, using: decryptor)
        }

        if let secretTemplate {
            let additionalNames = try referencedNames(in: [secretTemplate]).filter { resolvedVariables[$0] == nil }
            let additionalVariables = try await resolveVariables(additionalNames, in: effectiveContext, decryptor: decryptor)
            resolvedVariables.merge(additionalVariables) { current, _ in current }
        }

        let variableValues = resolvedVariables.mapValues(\.value)
        let headerSensitivity = try requestHeaderSensitivity(
            in: headers,
            resolvedVariables: resolvedVariables,
            variableValues: variableValues
        )
        let structuredHeader = try structuredAuthenticationHeader(
            authenticationToPrepare,
            headerName: selectedAuthenticationHeaderName,
            secretTemplate: secretTemplate,
            variableValues: variableValues
        )
        var sensitiveRequestHeaderNames = headerSensitivity.sensitiveRequestHeaderNames
        let secretRequestHeaderNames = headerSensitivity.secretRequestHeaderNames
        if selectedAuthentication.kind == .apiKey, let selectedAuthenticationHeaderName {
            sensitiveRequestHeaderNames.insert(selectedAuthenticationHeaderName.lowercased())
        }
        let request = try makeRequest(
            configuration,
            pathParameters: pathParameters,
            variableValues: variableValues,
            structuredHeader: structuredHeader,
            headers: headers
        )
        var requestHeaderSources: [String: HTTPHeaderSource] = [:]
        for field in inheritedHeaders where isActive(field) {
            let name = try substitute(field.name, values: variableValues).lowercased()
            requestHeaderSources[name] = .collection
        }
        for field in configuration.headers where isActive(field) {
            let name = try substitute(field.name, values: variableValues).lowercased()
            requestHeaderSources[name] = .request
        }
        if let structuredHeader {
            let source: HTTPHeaderSource = configuration.inheritsCollectionAuthentication ? .collectionAuth : .requestAuth
            requestHeaderSources[structuredHeader.name.lowercased()] = source
        }
        let presentHeaderNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        requestHeaderSources = requestHeaderSources.reduce(into: [:]) { result, entry in
            if presentHeaderNames.contains(entry.key) {
                result[entry.key] = entry.value
            }
        }

        let capturedNames = Set(try referencedNames(in: sources + (secretTemplate.map { [$0] } ?? [])))
        let redactionInputs = captureRedactionInputs
            ? try await captureSecretInputs(in: effectiveContext, resolved: resolvedVariables, decryptor: decryptor)
            : nil
        let capture = SnapshotPreparationCapture(
            template: SnapshotRequestTemplate(configuration: configuration, headers: headers),
            referencedInputs: resolvedVariables.filter { capturedNames.contains($0.key) }.mapValues {
                SnapshotInput(value: $0.value, scope: $0.scope, isSecret: $0.isSecret)
            },
            authentication: SnapshotAuthenticationInput(
                kind: authenticationToPrepare.kind,
                username: authenticationToPrepare.kind == .basic ? authenticationToPrepare.username : "",
                secretTemplate: secretTemplate,
                resolvedSecret: try secretTemplate.map { try substitute($0, values: variableValues) },
                apiKeyHeaderName: authenticationToPrepare.kind == .apiKey ? selectedAuthenticationHeaderName : nil
            ),
            submitted: SnapshotTransportRequest(
                method: request.httpMethod ?? configuration.method,
                url: request.url!,
                headers: (request.allHTTPHeaderFields ?? [:]).map { HTTPField(name: $0.key, value: $0.value) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                body: request.httpBody.map { String(decoding: $0, as: UTF8.self) },
                headerSources: requestHeaderSources,
                sensitiveNames: sensitiveRequestHeaderNames,
                secretNames: secretRequestHeaderNames
            ),
            redactionInputs: redactionInputs
        )

        return PreparedHTTPRequest(
            configuration: configuration,
            request: request,
            referencedInputs: resolvedVariables,
            sensitiveRequestHeaderNames: sensitiveRequestHeaderNames,
            secretRequestHeaderNames: secretRequestHeaderNames,
            requestHeaderSources: requestHeaderSources,
            snapshotCapture: capture
        )
    }

    private static func contextByAddingConfigurationRequestValues(
        _ configuration: HTTPRequestConfiguration,
        to context: VariableContext
    ) -> VariableContext {
        var result = context
        for (name, value) in configuration.variables where result.request[name] == nil {
            result.request[name] = value
        }
        return result
    }

    private static func captureSecretInputs(
        in context: VariableContext,
        resolved: [String: ResolvedVariable],
        decryptor: (any SecretValueDecrypting)?
    ) async throws -> SnapshotRedactionCapture {
        let maximumSecretCount = 128
        let maximumByteCount = 1_048_576
        let names = Set(context.request.keys).union(context.collection.keys).union(context.global.keys).sorted()
        var inputs: [String: SnapshotInput] = [:]
        var attemptedCount = 0
        var byteCount = 0
        var isComplete = true

        try Task.checkCancellation()
        for name in names {
            guard let (value, scope) = effectiveValue(named: name, in: context),
                  case .encrypted(let envelope) = value else {
                continue
            }
            try Task.checkCancellation()
            let nameByteCount = name.utf8.count
            guard attemptedCount < maximumSecretCount, byteCount < maximumByteCount,
                  nameByteCount <= maximumByteCount - byteCount else {
                isComplete = false
                break
            }
            attemptedCount += 1
            let plaintext: String
            do {
                if let existing = resolved[name] {
                    plaintext = existing.value
                } else {
                    plaintext = try await decrypt(envelope, using: decryptor)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                isComplete = false
                continue
            }
            let valueByteCount = plaintext.utf8.count
            guard valueByteCount <= maximumByteCount - byteCount - nameByteCount else {
                isComplete = false
                break
            }
            byteCount += nameByteCount + valueByteCount
            inputs[name] = SnapshotInput(value: plaintext, scope: scope, isSecret: true)
        }
        return SnapshotRedactionCapture(inputs: inputs, isComplete: isComplete)
    }

    private static func templateSources(
        _ configuration: HTTPRequestConfiguration,
        pathParameters: [PathParameterValue],
        headers: [HTTPField]? = nil,
        authentication: RequestAuthentication? = nil
    ) -> [String] {
        let query = QueryParameters.normalize(url: configuration.url, fields: configuration.query)
        var sources = [query.baseURL]
        sources.append(contentsOf: pathParameters.map(\.value))
        sources.append(contentsOf: query.fields.filter(QueryParameters.isActive).flatMap(QueryParameters.templateSources))
        sources.append(contentsOf: (headers ?? configuration.headers).filter(isActive).flatMap { [$0.name, $0.value] })

        if configuration.bodyEnabled {
            sources.append(configuration.body)
        }

        let selectedAuthentication = authentication ?? configuration.authentication
        if selectedAuthentication.kind == .basic {
            sources.append(selectedAuthentication.username)
        }

        return sources
    }

    private static func isActive(_ field: HTTPField) -> Bool {
        field.isEnabled && !(field.name.isEmpty && field.value.isEmpty)
    }

    private static func requestHeaderSensitivity(
        in headers: [HTTPField],
        resolvedVariables: [String: ResolvedVariable],
        variableValues: [String: String]
    ) throws -> (sensitiveRequestHeaderNames: Set<String>, secretRequestHeaderNames: Set<String>) {
        var sensitiveNames = standardSensitiveRequestHeaderNames
        var secretNames = Set<String>()

        for field in headers where isActive(field) {
            let nameReferences = try referencedNames(in: [field.name])
            let valueReferences = try referencedNames(in: [field.value])
            let hasSecretName = nameReferences.contains { resolvedVariables[$0]?.isSecret == true }
            let hasSecretValue = valueReferences.contains { resolvedVariables[$0]?.isSecret == true }
            guard hasSecretName || hasSecretValue else {
                continue
            }

            let resolvedName = try substitute(field.name, values: variableValues).lowercased()
            sensitiveNames.insert(resolvedName)
            if hasSecretName {
                secretNames.insert(resolvedName)
            }
        }

        return (sensitiveNames, secretNames)
    }

    private static func hasNonblankName(_ field: HTTPField) -> Bool {
        !field.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func referencedNames(in sources: [String]) throws -> [String] {
        var seen = Set<String>()
        var names: [String] = []

        for source in sources {
            let result = TemplateEngine.scan(source)
            guard result.invalidRanges.isEmpty else {
                throw RequestPreparationError.unresolvedTemplate
            }

            for reference in result.references where seen.insert(reference.name).inserted {
                names.append(reference.name)
            }
        }

        return names
    }

    private static func resolvePlainVariables(
        _ names: [String],
        in context: VariableContext
    ) throws -> [String: ResolvedVariable] {
        var resolved: [String: ResolvedVariable] = [:]
        for name in names {
            guard let (value, scope) = effectiveValue(named: name, in: context) else {
                throw RequestPreparationError.missingVariable(name)
            }
            guard case .plain(let plainValue) = value else {
                throw RequestPreparationError.secretUnavailable
            }
            resolved[name] = ResolvedVariable(value: plainValue, scope: scope, isSecret: false)
        }
        return resolved
    }

    private static func resolveVariables(
        _ names: [String],
        in context: VariableContext,
        decryptor: (any SecretValueDecrypting)?
    ) async throws -> [String: ResolvedVariable] {
        var resolved: [String: ResolvedVariable] = [:]
        for name in names {
            guard let (value, scope) = effectiveValue(named: name, in: context) else {
                throw RequestPreparationError.missingVariable(name)
            }

            switch value {
            case .plain(let plainValue):
                resolved[name] = ResolvedVariable(value: plainValue, scope: scope, isSecret: false)
            case .encrypted(let envelope):
                let plainValue = try await decrypt(envelope, using: decryptor)
                resolved[name] = ResolvedVariable(value: plainValue, scope: scope, isSecret: true)
            }
        }
        return resolved
    }

    private static func effectiveValue(
        named name: String,
        in context: VariableContext
    ) -> (VariableValue, VariableScope)? {
        if let value = context.request[name] {
            return (value, .request)
        }
        if let value = context.collection[name] {
            return (value, .collection)
        }
        if let value = context.global[name] {
            return (value, .global)
        }
        return nil
    }

    private static func decrypt(
        _ envelope: SecretEnvelope,
        using decryptor: (any SecretValueDecrypting)?
    ) async throws -> String {
        guard let decryptor else {
            throw RequestPreparationError.secretUnavailable
        }

        do {
            return try await decryptor.decrypt(envelope)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RequestPreparationError.secretUnavailable
        }
    }

    private static func authenticationHeaderName(for authentication: RequestAuthentication) throws -> String? {
        switch authentication.kind {
        case .none:
            return nil
        case .basic, .bearer:
            return "Authorization"
        case .apiKey:
            guard let name = authentication.apiKeyHeaderName, isHTTPToken(name) else {
                throw RequestPreparationError.invalidHeaderName
            }
            return name
        }
    }

    private static func structuredAuthenticationHeader(
        _ authentication: RequestAuthentication,
        headerName: String?,
        secretTemplate: String?,
        variableValues: [String: String]
    ) throws -> (name: String, value: String)? {
        switch authentication.kind {
        case .none:
            return nil
        case .basic:
            guard let secretTemplate else {
                throw RequestPreparationError.invalidAuthentication
            }
            let username = try substitute(authentication.username, values: variableValues)
            let password = try substitute(secretTemplate, values: variableValues)
            guard !username.contains(":"), !containsControlCharacters(username), !containsControlCharacters(password) else {
                throw RequestPreparationError.invalidBasicCredentials
            }
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            return (headerName ?? "Authorization", "Basic \(credentials)")
        case .bearer:
            guard let secretTemplate else {
                throw RequestPreparationError.invalidAuthentication
            }
            let token = try substitute(secretTemplate, values: variableValues)
            guard !token.isEmpty,
                  token.unicodeScalars.allSatisfy({
                      !CharacterSet.whitespacesAndNewlines.contains($0) &&
                          !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw RequestPreparationError.invalidBearerCredential
            }
            return (headerName ?? "Authorization", "Bearer \(token)")
        case .apiKey:
            guard let secretTemplate else {
                throw RequestPreparationError.invalidAuthentication
            }
            let key = try substitute(secretTemplate, values: variableValues)
            guard !key.isEmpty, !containsControlCharacters(key) else {
                throw RequestPreparationError.invalidAPIKeyCredential
            }
            guard let headerName else {
                throw RequestPreparationError.invalidHeaderName
            }
            return (headerName, key)
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func pathParameterValues(in configuration: HTTPRequestConfiguration) throws -> [PathParameterValue] {
        var seen = Set<String>()
        var values: [PathParameterValue] = []

        for reference in TemplateEngine.pathReferences(in: configuration.url) where seen.insert(reference.name).inserted {
            let candidates = configuration.pathParameters.filter { $0.name == reference.name && $0.isEnabled }
            guard candidates.count == 1,
                  let candidate = candidates.first,
                  !candidate.value.isEmpty else {
                throw RequestPreparationError.invalidPathParameter(reference.name)
            }
            values.append(PathParameterValue(name: reference.name, value: candidate.value))
        }

        return values
    }

    private static func makeRequest(
        _ configuration: HTTPRequestConfiguration,
        pathParameters: [PathParameterValue],
        variableValues: [String: String],
        structuredHeader: (name: String, value: String)?,
        headers: [HTTPField]? = nil
    ) throws -> URLRequest {
        var encodedPathValues: [String: String] = [:]
        for pathParameter in pathParameters {
            let resolvedValue = try substitute(pathParameter.value, values: variableValues)
            guard let encodedValue = encodePathSegment(resolvedValue) else {
                throw RequestPreparationError.invalidURL
            }
            encodedPathValues[pathParameter.name] = encodedValue
        }

        let query = QueryParameters.normalize(url: configuration.url, fields: configuration.query)
        let originalPathReferences = TemplateEngine.pathReferences(in: query.baseURL)
        let urlWithPathValues = replacingPathParameters(
            in: query.baseURL,
            references: originalPathReferences,
            values: encodedPathValues
        )
        let resolvedURL = try substitute(urlWithPathValues, values: variableValues)
        guard !resolvedURL.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }),
              var components = URLComponents(string: resolvedURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw RequestPreparationError.invalidURL
        }

        guard isHTTPToken(configuration.method) else {
            throw RequestPreparationError.invalidMethod
        }

        if let encodedQuery = try QueryParameters.encodedQuery(fields: query.fields, values: variableValues) {
            components.percentEncodedQuery = components.percentEncodedQuery.map { $0 + "&" + encodedQuery } ?? encodedQuery
        }

        guard let url = components.url else {
            throw RequestPreparationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = configuration.method
        request.timeoutInterval = configuration.options.inactivityTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        var resolvedHeaders: [HTTPField] = []
        for field in (headers ?? configuration.headers) where isActive(field) {
            resolvedHeaders.append(HTTPField(
                id: field.id,
                name: try substitute(field.name, values: variableValues),
                value: try substitute(field.value, values: variableValues),
                isEnabled: true
            ))
        }

        for field in resolvedHeaders {
            guard isHTTPToken(field.name) else {
                throw RequestPreparationError.invalidHeaderName
            }
            guard isValidHeaderValue(field.value) else {
                throw RequestPreparationError.invalidHeaderValue
            }

            if field.name.caseInsensitiveCompare("Cookie") == .orderedSame {
                let existingValue = request.value(forHTTPHeaderField: field.name)
                let combinedValue = existingValue.map { "\($0); \(field.value)" } ?? field.value
                request.setValue(combinedValue, forHTTPHeaderField: field.name)
            } else {
                request.addValue(field.value, forHTTPHeaderField: field.name)
            }
        }

        if let structuredHeader {
            guard isHTTPToken(structuredHeader.name) else {
                throw RequestPreparationError.invalidHeaderName
            }
            guard isValidHeaderValue(structuredHeader.value) else {
                throw RequestPreparationError.invalidHeaderValue
            }
            request.setValue(structuredHeader.value, forHTTPHeaderField: structuredHeader.name)
        }

        if configuration.bodyEnabled {
            let body = try substitute(configuration.body, values: variableValues)
            request.httpBody = Data(body.utf8)
        }

        return request
    }

    private static func substitute(_ source: String, values: [String: String]) throws -> String {
        do {
            return try TemplateEngine.substitute(source, values: values)
        } catch {
            throw RequestPreparationError.unresolvedTemplate
        }
    }

    private static func replacingPathParameters(
        in source: String,
        references: [TemplateReference],
        values: [String: String]
    ) -> String {
        let result = NSMutableString(string: source)
        for reference in references.reversed() {
            guard let value = values[reference.name] else {
                continue
            }
            result.replaceCharacters(in: reference.range, with: value)
        }
        return result as String
    }

    private static func encodePathSegment(_ value: String) -> String? {
        if value == "." {
            return "%2E"
        }
        if value == ".." {
            return "%2E%2E"
        }
        return value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    private static func validateOptions(_ options: HTTPOptions) throws {
        guard options.inactivityTimeout.isFinite,
              options.inactivityTimeout > 0,
              options.overallTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              options.maximumResponseBytes.map({ $0 >= 0 }) ?? true else {
            throw RequestPreparationError.invalidTimeout
        }
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        return value.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D...0x2E, 0x5E...0x60, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            if codePoint == 0x09 {
                return true
            }

            guard codePoint >= 0x20, codePoint != 0x7F else {
                return false
            }

            return !CharacterSet.newlines.contains(scalar)
        }
    }
}
