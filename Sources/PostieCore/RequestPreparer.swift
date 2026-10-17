import Foundation

private enum RequestPreparationError: LocalizedError {
    case invalidURL
    case invalidMethod
    case invalidHeaderName
    case invalidHeaderValue
    case invalidPathParameter(String)
    case unresolvedTemplate
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
            return "Resolve all {{...}} template values before sending."
        case .invalidTimeout:
            return "Timeouts and response limits must be valid positive values."
        }
    }
}

public enum RequestPreparer {
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func pathParameterNames(in url: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []

        for segment in rawPath(in: url).split(separator: "/", omittingEmptySubsequences: false) {
            guard let name = pathParameterName(in: segment), seen.insert(name).inserted else {
                continue
            }
            names.append(name)
        }

        return names
    }

    public static func prepare(_ configuration: HTTPRequestConfiguration) throws -> URLRequest {
        try validateOptions(configuration.options)
        try rejectTemplates(in: configuration.url)

        guard !configuration.url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var components = URLComponents(string: configuration.url),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw RequestPreparationError.invalidURL
        }

        let pathValues = try pathParameterValues(in: configuration)
        components.percentEncodedPath = replacingPathParameters(in: components.percentEncodedPath, with: pathValues)

        guard isHTTPToken(configuration.method) else {
            throw RequestPreparationError.invalidMethod
        }

        var queryItems: [HTTPField] = []
        for field in configuration.query where field.isEnabled {
            if field.name.isEmpty && field.value.isEmpty {
                continue
            }

            try rejectTemplates(in: field.name)
            try rejectTemplates(in: field.value)
            queryItems.append(field)
        }

        if !queryItems.isEmpty {
            let encodedItems = try queryItems.map { field -> String in
                guard let name = field.name.addingPercentEncoding(withAllowedCharacters: unreservedCharacters),
                      let value = field.value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) else {
                    throw RequestPreparationError.invalidURL
                }
                return "\(name)=\(value)"
            }
            let encodedAdditions = encodedItems.joined(separator: "&")
            let existingQuery = components.percentEncodedQuery ?? ""
            let separator = existingQuery.isEmpty || existingQuery.hasSuffix("&") ? "" : "&"
            components.percentEncodedQuery = existingQuery + separator + encodedAdditions
        }

        guard let url = components.url else {
            throw RequestPreparationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = configuration.method
        request.timeoutInterval = configuration.options.inactivityTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        for field in configuration.headers where field.isEnabled {
            if field.name.isEmpty && field.value.isEmpty {
                continue
            }

            try rejectTemplates(in: field.name)
            try rejectTemplates(in: field.value)

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

        if configuration.bodyEnabled {
            try rejectTemplates(in: configuration.body)
            request.httpBody = Data(configuration.body.utf8)
        }

        return request
    }

    private static func validateOptions(_ options: HTTPOptions) throws {
        guard options.inactivityTimeout.isFinite,
              options.inactivityTimeout > 0,
              options.overallTimeout.map({ $0.isFinite && $0 > 0 }) ?? true,
              options.maximumResponseBytes.map({ $0 >= 0 }) ?? true else {
            throw RequestPreparationError.invalidTimeout
        }
    }

    private static func pathParameterValues(in configuration: HTTPRequestConfiguration) throws -> [String: String] {
        var values: [String: String] = [:]

        for name in pathParameterNames(in: configuration.url) {
            let candidates = configuration.pathParameters.filter { $0.name == name && $0.isEnabled }
            guard candidates.count == 1,
                  let candidate = candidates.first,
                  !candidate.value.isEmpty else {
                throw RequestPreparationError.invalidPathParameter(name)
            }

            try rejectTemplates(in: candidate.value)
            guard let encodedValue = encodePathSegment(candidate.value) else {
                throw RequestPreparationError.invalidURL
            }
            values[name] = encodedValue
        }

        return values
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

    private static func replacingPathParameters(in path: String, with values: [String: String]) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                guard let name = pathParameterName(in: segment), let value = values[name] else {
                    return String(segment)
                }
                return value
            }
            .joined(separator: "/")
    }

    private static func pathParameterName(in segment: Substring) -> String? {
        guard segment.first == ":" else {
            return nil
        }

        let name = segment.dropFirst()
        let bytes = name.utf8
        guard let first = bytes.first,
              isASCIIIdentifierStart(first),
              bytes.dropFirst().allSatisfy(isASCIIIdentifierContinuation) else {
            return nil
        }
        return String(name)
    }

    private static func isASCIIIdentifierStart(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }

    private static func isASCIIIdentifierContinuation(_ byte: UInt8) -> Bool {
        isASCIIIdentifierStart(byte) || (0x30...0x39).contains(byte)
    }

    private static func rawPath(in url: String) -> String {
        let boundary = url.firstIndex { $0 == "?" || $0 == "#" } ?? url.endIndex
        let urlWithoutSuffix = url[..<boundary]

        if let delimiter = urlWithoutSuffix.range(of: "://"),
           isScheme(urlWithoutSuffix[..<delimiter.lowerBound]) {
            let authority = urlWithoutSuffix[delimiter.upperBound...]
            guard let pathStart = authority.firstIndex(of: "/") else {
                return ""
            }
            return String(urlWithoutSuffix[pathStart...])
        }

        if urlWithoutSuffix.hasPrefix("//") {
            let authorityStart = urlWithoutSuffix.index(urlWithoutSuffix.startIndex, offsetBy: 2)
            guard let pathStart = urlWithoutSuffix[authorityStart...].firstIndex(of: "/") else {
                return ""
            }
            return String(urlWithoutSuffix[pathStart...])
        }

        if let schemeEnd = urlWithoutSuffix.firstIndex(of: ":"),
           isScheme(urlWithoutSuffix[..<schemeEnd]) {
            return String(urlWithoutSuffix[urlWithoutSuffix.index(after: schemeEnd)...])
        }

        return String(urlWithoutSuffix)
    }

    private static func isScheme(_ value: Substring) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first,
              (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ||
                (0x30...0x39).contains(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E
        }
    }

    private static func rejectTemplates(in value: String) throws {
        guard !value.contains("{{"), !value.contains("}}") else {
            throw RequestPreparationError.unresolvedTemplate
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
