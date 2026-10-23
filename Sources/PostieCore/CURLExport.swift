import Foundation

private enum CURLExportError: LocalizedError {
    case invalidRequest
    case invalidTimeout
    case invalidTextBody
    case missingUploadBody
    case unsupportedMultipartBody
    case unsupportedMultipartName
    case unsupportedMultipartFile
    case unsupportedMultipartMetadata
    case unsupportedMultipartContentType
    case unsupportedMultipartTransportHeader
    case unsupportedHeadBody
    case nulCharacter
    case invalidHeader

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The prepared request cannot be represented as an HTTP cURL command."
        case .invalidTimeout:
            return "The prepared request has an invalid timeout."
        case .invalidTextBody:
            return "The prepared text body is not valid UTF-8."
        case .missingUploadBody:
            return "The prepared upload body is unavailable. Prepare the request again before exporting it."
        case .unsupportedMultipartBody:
            return "An empty multipart body cannot be represented by cURL form options."
        case .unsupportedMultipartName:
            return "A multipart field name contains syntax that cURL cannot represent safely."
        case .unsupportedMultipartFile:
            return "A multipart file path contains characters that cURL cannot represent safely."
        case .unsupportedMultipartMetadata:
            return "The prepared multipart metadata no longer matches the request configuration."
        case .unsupportedMultipartContentType:
            return "A multipart file Content-Type cannot be represented safely in cURL form syntax."
        case .unsupportedMultipartTransportHeader:
            return "Explicit multipart Content-Type or Content-Length cannot be preserved with cURL's generated body."
        case .unsupportedHeadBody:
            return "A cURL HEAD request cannot preserve an enabled request body."
        case .nulCharacter:
            return "A cURL command cannot contain a NUL character."
        case .invalidHeader:
            return "A prepared HTTP header cannot be represented safely in a cURL command."
        }
    }
}

private enum CURLArgument {
    case flag(String)
    case option(String, String)
}

public enum CURLExport {
    /// Builds a shell-quoted command from the prepared request and effective request configuration.
    /// cURL's `--location` keeps the custom method for redirects and forwards custom headers to redirected hosts,
    /// except for its built-in cross-origin handling of Authorization and Cookie. This does not reproduce Postie's
    /// redirect method, body, or sensitive-header policy. The inactivity timeout is approximated by a connection
    /// timeout and a whole-second low-speed timeout. `maximumResponseBytes` is not exported.
    public static func command(
        for prepared: PreparedHTTPRequest,
        configuration: HTTPRequestConfiguration
    ) throws -> String {
        guard let url = prepared.request.url,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let method = prepared.request.httpMethod, !method.isEmpty
        else {
            throw CURLExportError.invalidRequest
        }

        try validateOptions(configuration.options)

        var arguments: [CURLArgument] = [
            .flag("--disable"),
            .flag("--globoff"),
            .option("--proto", "=http,https"),
            .option("--proto-redir", "=http,https"),
            .option("--request", method),
        ]

        if method == "HEAD" {
            guard !configuration.bodyEnabled else { throw CURLExportError.unsupportedHeadBody }
            arguments.append(.flag("--head"))
        }

        if configuration.options.followRedirects {
            arguments.append(contentsOf: [.flag("--location"), .option("--max-redirs", "10")])
        }

        if let overallTimeout = configuration.options.overallTimeout {
            arguments.append(.option("--max-time", String(overallTimeout)))
        }
        let inactivitySpeedTimeout = try speedTimeoutSeconds(configuration.options.inactivityTimeout)
        arguments.append(contentsOf: [
            .option("--connect-timeout", String(configuration.options.inactivityTimeout)),
            .option("--speed-limit", "1"),
            .option("--speed-time", inactivitySpeedTimeout),
        ])

        let bodyKind = configuration.bodyKind
        let bodyEnabled = configuration.bodyEnabled
        if bodyEnabled, bodyKind == .multipart {
            let explicitTransportHeader = ["content-type", "content-length"].contains { name in
                prepared.requestHeaderSources[name].map { $0 != .automatic } ?? false
            }
            if explicitTransportHeader {
                throw CURLExportError.unsupportedMultipartTransportHeader
            }
            let multipartArguments = try multipartArguments(for: prepared, configuration: configuration)
            arguments.append(contentsOf: multipartArguments)
        } else if bodyEnabled, bodyKind == .rawFile {
            guard let file = configuration.rawFile,
                prepared.uploadBody?.kind == .rawFile,
                (file.path as NSString).isAbsolutePath
            else {
                throw CURLExportError.missingUploadBody
            }
            arguments.append(.option("--data-binary", "@" + file.path))
        } else if bodyEnabled, bodyKind == .text {
            guard let data = prepared.request.httpBody,
                let body = String(data: data, encoding: .utf8)
            else {
                throw CURLExportError.invalidTextBody
            }
            arguments.append(.option("--data-raw", body))
        }

        let requestHeaders = prepared.request.allHTTPHeaderFields ?? [:]
        let contentTypeIsPresent = requestHeaders.keys.contains {
            $0.caseInsensitiveCompare("Content-Type") == .orderedSame
        }
        for (name, value) in requestHeaders.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            let normalizedName = name.lowercased()
            if bodyEnabled, bodyKind == .multipart, ["content-type", "content-length"].contains(normalizedName) {
                continue
            }
            guard isHTTPToken(name), !containsLineBreak(name), !containsLineBreak(value) else {
                throw CURLExportError.invalidHeader
            }
            let header = value.isEmpty ? "\(name);" : "\(name): \(value)"
            arguments.append(.option("--header", header))
        }

        if bodyEnabled, bodyKind != .multipart, !contentTypeIsPresent {
            arguments.append(.option("--header", "Content-Type:"))
        }

        arguments.append(.option("--url", url.absoluteString))
        let lines = try arguments.map { argument -> String in
            switch argument {
            case let .flag(name):
                return name
            case let .option(name, value):
                return "\(name) \(try shellQuote(value))"
            }
        }
        var commandLines = ["curl \\"]
        for (index, line) in lines.enumerated() {
            let continuation = index < lines.count - 1 ? " \\" : ""
            commandLines.append("  \(line)\(continuation)")
        }
        return commandLines.joined(separator: "\n")
    }

    private static func multipartArguments(
        for prepared: PreparedHTTPRequest,
        configuration: HTTPRequestConfiguration
    ) throws -> [CURLArgument] {
        guard let uploadBody = prepared.uploadBody, uploadBody.kind == .multipart else {
            throw CURLExportError.missingUploadBody
        }
        let metadata = uploadBody.snapshotMetadata
        guard let parts = metadata.parts, !parts.isEmpty else {
            throw CURLExportError.unsupportedMultipartBody
        }

        var configurationParts: [UUID: HTTPMultipartPart] = [:]
        for part in configuration.multipartParts where part.isEnabled {
            guard configurationParts.updateValue(part, forKey: part.id) == nil else {
                throw CURLExportError.unsupportedMultipartMetadata
            }
        }
        guard configurationParts.count == parts.count else {
            throw CURLExportError.unsupportedMultipartMetadata
        }

        var arguments: [CURLArgument] = []
        for preparedPart in parts {
            guard let configuredPart = configurationParts[preparedPart.id],
                configuredPart.kind == preparedPart.kind,
                isSafeFormName(preparedPart.name)
            else {
                throw CURLExportError.unsupportedMultipartName
            }

            if preparedPart.kind == .text {
                guard let text = preparedPart.text else {
                    throw CURLExportError.unsupportedMultipartMetadata
                }
                arguments.append(.option("--form-string", "\(preparedPart.name)=\(text)"))
                continue
            }

            guard let fileIndex = preparedPart.fileIndex, metadata.files.indices.contains(fileIndex),
                let file = configuredPart.file,
                (file.path as NSString).isAbsolutePath,
                !containsControlCharacter(file.path)
            else {
                throw CURLExportError.unsupportedMultipartFile
            }
            let fileMetadata = metadata.files[fileIndex]
            guard fileMetadata.partName == preparedPart.name,
                !containsControlCharacter(fileMetadata.filename),
                !containsControlCharacter(fileMetadata.contentType)
            else {
                throw CURLExportError.unsupportedMultipartMetadata
            }
            let contentType = try curlFormContentType(fileMetadata.contentType)
            let value =
                "\(preparedPart.name)=@\(formQuoted(file.path));filename=\(formQuoted(fileMetadata.filename));"
                + "type=\(contentType)"
            arguments.append(.option("--form", value))
        }

        return arguments
    }

    private static func validateOptions(_ options: HTTPOptions) throws {
        guard options.inactivityTimeout.isFinite, options.inactivityTimeout > 0,
            options.inactivityTimeout.rounded(.up) < Double(Int.max),
            options.overallTimeout.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw CURLExportError.invalidTimeout
        }
    }

    private static func speedTimeoutSeconds(_ timeout: TimeInterval) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout.rounded(.up) < Double(Int.max) else {
            throw CURLExportError.invalidTimeout
        }
        return String(Int(timeout.rounded(.up)))
    }

    private static func shellQuote(_ value: String) throws -> String {
        guard !value.utf8.contains(0) else { throw CURLExportError.nulCharacter }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func formQuoted(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func curlFormContentType(_ value: String) throws -> String {
        let components = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let mediaType = components.first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
            let separator = mediaType.firstIndex(of: "/"),
            isCurlFormToken(String(mediaType[..<separator])),
            isCurlFormToken(String(mediaType[mediaType.index(after: separator)...]))
        else {
            throw CURLExportError.unsupportedMultipartContentType
        }

        let reservedFormAttributes: Set<String> = ["type", "filename", "headers", "encoder"]
        var result = mediaType
        for component in components.dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw CURLExportError.unsupportedMultipartContentType }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            let parameterValue = String(pair[1]).trimmingCharacters(in: .whitespaces)
            guard isCurlFormToken(name), isCurlFormToken(parameterValue),
                !reservedFormAttributes.contains(name.lowercased())
            else {
                throw CURLExportError.unsupportedMultipartContentType
            }
            result += "; \(name)=\(parameterValue)"
        }
        return result
    }

    private static func isCurlFormToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let punctuation = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && ((scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || punctuation.contains(scalar))
        }
    }

    private static func isSafeFormName(_ value: String) -> Bool {
        !value.isEmpty && !containsControlCharacter(value)
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "=;,\\\"")) == nil
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let separators = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t")
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 32 && scalar.value < 127 && !separators.contains(scalar)
        }
    }
}
