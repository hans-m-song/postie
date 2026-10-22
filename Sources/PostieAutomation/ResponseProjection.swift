import Foundation
import PostieCore

public enum ResponseProjection {
    public static let maximumBodyPreviewBytes = 1_048_576

    private static let maximumHeaderNameBytes = 1_024
    private static let maximumHeaderValueBytes = 16_384
    private static let maximumErrorBytes = 4_096

    public static func mcpBlocked(response: HTTPResponseRecord) -> AutomationJSON {
        mcpBlocked(response: response, context: response.snapshotCapture)
    }

    public static func mcpBlocked(
        response: HTTPResponseRecord,
        context: SnapshotPreparationCapture?
    ) -> AutomationJSON {
        let sanitizer = SecretRetemplating(capture: context)
        let headers = metadataHeaders(response.responseHeaders, sanitizer: sanitizer)
        let redirects = response.redirects.enumerated().map { index, redirect in
            redirectProjection(index: index, redirect: redirect, headers: .metadata(sanitizer), sanitizer: sanitizer)
        }
        return responseObject(
            response: response,
            headers: headers,
            redirects: redirects,
            body: .null,
            bodyWithheld: true
        )
    }

    public static func mcpAllowed(response: HTTPResponseRecord, bodyURL: URL?) -> AutomationJSON {
        mcpAllowed(response: response, bodyURL: bodyURL, context: response.snapshotCapture)
    }

    public static func mcpAllowed(
        response: HTTPResponseRecord,
        bodyURL: URL?,
        context: SnapshotPreparationCapture?
    ) -> AutomationJSON {
        let sanitizer = SecretRetemplating(capture: context)
        let canSanitize = sanitizer.hasFrozenContext && sanitizer.isComplete
        let headers = canSanitize ? allMCPHeaders(response.responseHeaders, sanitizer: sanitizer) : []
        let headerMode: RedirectHeaderMode = canSanitize ? .all(sanitizer) : .none
        let redirects = response.redirects.enumerated().map { index, redirect in
            redirectProjection(index: index, redirect: redirect, headers: headerMode, sanitizer: sanitizer)
        }

        guard canSanitize,
            let bodyURL,
            let sample = readBody(at: bodyURL, expectedByteCount: response.bodyByteCount)
        else {
            return responseObject(
                response: response,
                headers: headers,
                redirects: redirects,
                body: .null,
                bodyWithheld: true
            )
        }

        let truncated = response.bodyByteCount > Int64(sample.count)
        guard let text = decodedText(sample, isTruncated: truncated),
            isTextual(text)
        else {
            return responseObject(
                response: response,
                headers: headers,
                redirects: redirects,
                body: .null,
                bodyWithheld: true
            )
        }

        guard
            let content = sanitizer.sanitizePreview(
                text,
                maximumUTF8Bytes: maximumBodyPreviewBytes,
                isTruncated: truncated
            )
        else {
            return responseObject(
                response: response,
                headers: headers,
                redirects: redirects,
                body: .null,
                bodyWithheld: true
            )
        }
        return responseObject(
            response: response,
            headers: headers,
            redirects: redirects,
            body: bodyObject(
                content: content, encoding: "utf-8", byteCount: response.bodyByteCount, truncated: truncated),
            bodyWithheld: false
        )
    }

    public static func mcpUnredacted(response: HTTPResponseRecord, bodyURL: URL?) -> AutomationJSON {
        rawResponseProjection(response: response, bodyURL: bodyURL, includeURLs: true)
    }

    public static func mcpRedirects(
        _ redirects: [HTTPRedirect],
        context: SnapshotPreparationCapture?,
        allowed: Bool = false
    ) -> AutomationJSON {
        mcpRedirects(redirects, context: context, mode: allowed ? .allow : .block)
    }

    public static func mcpRedirects(
        _ redirects: [HTTPRedirect],
        context: SnapshotPreparationCapture?,
        mode: MCPResponseViewPolicy
    ) -> AutomationJSON {
        let sanitizer = SecretRetemplating(capture: context)
        let headerMode: RedirectHeaderMode
        switch mode {
        case .unredacted:
            headerMode = .unredacted
        case .allow where sanitizer.hasFrozenContext && sanitizer.isComplete:
            headerMode = .all(sanitizer)
        case .block, .allow, .inherit:
            headerMode = .metadata(sanitizer)
        }
        return .array(
            redirects.enumerated().map { index, redirect in
                redirectProjection(index: index, redirect: redirect, headers: headerMode, sanitizer: sanitizer)
            })
    }

    public static func cliRedirects(_ redirects: [HTTPRedirect]) -> AutomationJSON {
        .array(
            redirects.enumerated().map { index, redirect in
                redirectProjection(index: index, redirect: redirect, headers: .raw, sanitizer: nil)
            })
    }

    public static func cliRaw(response: HTTPResponseRecord, bodyURL: URL?) -> AutomationJSON {
        rawResponseProjection(response: response, bodyURL: bodyURL, includeURLs: false)
    }

    private static func rawResponseProjection(
        response: HTTPResponseRecord,
        bodyURL: URL?,
        includeURLs: Bool
    ) -> AutomationJSON {
        let headers = rawHeaders(response.responseHeaders)
        let redirects = response.redirects.enumerated().map { index, redirect in
            redirectProjection(
                index: index,
                redirect: redirect,
                headers: includeURLs ? .unredacted : .raw,
                sanitizer: nil
            )
        }
        let finalURL = includeURLs ? response.finalURL.absoluteString : nil

        guard let bodyURL,
            let sample = readBody(at: bodyURL, expectedByteCount: response.bodyByteCount)
        else {
            return responseObject(
                response: response,
                headers: headers,
                redirects: redirects,
                body: .null,
                bodyWithheld: true,
                finalURL: finalURL
            )
        }

        let truncated = response.bodyByteCount > Int64(sample.count)
        if let text = decodedText(sample, isTruncated: truncated), isTextual(text) {
            return responseObject(
                response: response,
                headers: headers,
                redirects: redirects,
                body: bodyObject(
                    content: text, encoding: "utf-8", byteCount: response.bodyByteCount, truncated: truncated),
                bodyWithheld: false,
                finalURL: finalURL
            )
        }

        return responseObject(
            response: response,
            headers: headers,
            redirects: redirects,
            body: bodyObject(
                content: sample.base64EncodedString(),
                encoding: "base64",
                byteCount: response.bodyByteCount,
                truncated: truncated
            ),
            bodyWithheld: false,
            finalURL: finalURL
        )
    }

    public static func mcpFailure(_ error: String, context: SnapshotPreparationCapture?) -> AutomationJSON {
        let sanitizer = SecretRetemplating(capture: context)
        let safeError = sanitizer.sanitizeBounded(error, maximumUTF8Bytes: maximumErrorBytes)
        return .object([
            "state": .string("failed"),
            "error": .string(safeError),
        ])
    }

    public static func mcpCancelled() -> AutomationJSON {
        .object(["state": .string("cancelled")])
    }

    private static func responseObject(
        response: HTTPResponseRecord,
        headers: [AutomationJSON],
        redirects: [AutomationJSON],
        body: AutomationJSON,
        bodyWithheld: Bool,
        finalURL: String? = nil
    ) -> AutomationJSON {
        var result: [String: AutomationJSON] = [
            "state": .string("completed"),
            "statusCode": number(Int64(response.statusCode)),
            "reason": .string(reasonPhrase(response.statusCode)),
            "durationSeconds": number(max(0, response.duration.isFinite ? response.duration : 0)),
            "bodyByteCount": number(max(0, response.bodyByteCount)),
            "bodyWithheld": .bool(bodyWithheld),
            "redirectCount": number(Int64(response.redirects.count)),
            "redirectLimitReached": .bool(response.redirectLimitReached),
            "headers": .array(headers),
            "redirects": .array(redirects),
            "body": body,
        ]
        if let finalURL {
            result["finalURL"] = .string(finalURL)
        }
        return .object(result)
    }

    private static func bodyObject(content: String, encoding: String, byteCount: Int64, truncated: Bool)
        -> AutomationJSON
    {
        .object([
            "encoding": .string(encoding),
            "content": .string(content),
            "byteCount": number(max(0, byteCount)),
            "previewByteCount": number(Int64(content.utf8.count)),
            "truncated": .bool(truncated),
        ])
    }

    private static func number(_ value: Int64) -> AutomationJSON {
        .number(Decimal(string: String(value)) ?? .zero)
    }

    private static func number(_ value: Double) -> AutomationJSON {
        .number(Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) ?? .zero)
    }

    private static func rawHeaders(_ fields: [HTTPField]) -> [AutomationJSON] {
        fields.map { headerObject(name: $0.name, value: $0.value) }
    }

    private static func allMCPHeaders(_ fields: [HTTPField], sanitizer: SecretRetemplating) -> [AutomationJSON] {
        guard sanitizer.hasFrozenContext, sanitizer.isComplete else { return [] }
        return fields.compactMap { field in
            guard field.name.utf8.count <= maximumHeaderNameBytes,
                field.value.utf8.count <= maximumHeaderValueBytes,
                isHTTPToken(field.name), !containsForbiddenControl(field.value)
            else { return nil }

            let name: String
            if field.name.caseInsensitiveCompare("Location") == .orderedSame {
                guard let location = sanitizedLocation(field.value, sanitizer: sanitizer) else { return nil }
                name = "Location"
                return headerObject(name: name, value: location)
            }

            let sanitizedName = sanitizer.sanitizeBounded(field.name, maximumUTF8Bytes: maximumHeaderNameBytes)
            let safeName = sanitizedName == field.name ? field.name.lowercased() : sanitizedName
            let value = sanitizer.sanitizeBounded(field.value, maximumUTF8Bytes: maximumHeaderValueBytes)
            guard !containsForbiddenControl(value) else { return nil }
            return headerObject(name: safeName, value: value)
        }
    }

    private static func metadataHeaders(_ fields: [HTTPField], sanitizer: SecretRetemplating) -> [AutomationJSON] {
        if sanitizer.hasFrozenContext && !sanitizer.isComplete { return [] }
        let acceptedNames = Set(metadataHeaderNames.keys).union(["location"])
        let selected = fields.filter { acceptedNames.contains($0.name.lowercased()) }
        let counts = Dictionary(grouping: selected, by: { $0.name.lowercased() }).mapValues { $0.count }

        return selected.compactMap { field in
            let key = field.name.lowercased()
            guard counts[key] == 1,
                field.name.utf8.count <= maximumHeaderNameBytes,
                field.value.utf8.count <= maximumHeaderValueBytes,
                !containsForbiddenControl(field.value)
            else { return nil }

            if key == "location" {
                guard let location = sanitizedLocation(field.value, sanitizer: sanitizer) else { return nil }
                return headerObject(name: "Location", value: location)
            }

            guard let canonicalName = metadataHeaderNames[key],
                let normalized = normalizedMetadataValue(name: key, value: field.value),
                !sanitizer.containsKnownSecret(normalized)
            else {
                return nil
            }
            return headerObject(name: canonicalName, value: normalized)
        }
    }

    private static func sanitizedLocation(_ rawValue: String, sanitizer: SecretRetemplating) -> String? {
        guard sanitizer.hasFrozenContext, sanitizer.isComplete,
            rawValue.utf8.count <= maximumHeaderValueBytes,
            !containsForbiddenControl(rawValue)
        else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !trimmed.isEmpty, hasValidPercentEscapes(trimmed),
            !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
            var components = URLComponents(string: trimmed)
        else {
            return nil
        }

        if components.user != nil || components.password != nil {
            guard let host = components.host, !host.isEmpty else { return nil }
        }
        components.user = nil
        components.password = nil
        guard let normalized = components.string,
            !normalized.isEmpty,
            !containsForbiddenControl(normalized)
        else {
            return nil
        }

        let sanitized = sanitizer.sanitizeBounded(normalized, maximumUTF8Bytes: maximumHeaderValueBytes)
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func normalizedMetadataValue(name: String, value: String) -> String? {
        switch name {
        case "content-type": return normalizedContentType(value)
        case "content-length", "age": return nonnegativeInteger(value)
        case "content-encoding": return recognizedCodings(value, allowed: contentCodings)
        case "transfer-encoding": return recognizedCodings(value, allowed: transferCodings)
        case "date", "expires", "last-modified": return normalizedHTTPDate(value)
        case "retry-after": return normalizedRetryAfter(value)
        case "allow": return normalizedMethods(value)
        case "accept-ranges": return normalizedAcceptRanges(value)
        case "content-range": return normalizedContentRange(value)
        case "cache-control": return normalizedCacheControl(value)
        default: return nil
        }
    }

    private static func normalizedContentType(_ value: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let mediaType = parts.first,
            mediaType.split(separator: "/", omittingEmptySubsequences: false).count == 2,
            mediaType.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ isHTTPToken(String($0)) })
        else {
            return nil
        }

        var charset: String?
        var sawCharset = false
        for parameter in parts.dropFirst() {
            let pieces = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawParameterValue = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isHTTPToken(key), validParameterValue(rawParameterValue) else { return nil }
            guard key == "charset" else { continue }
            guard !sawCharset else { return nil }
            sawCharset = true
            let unquoted = unquoted(rawParameterValue).lowercased()
            guard let recognized = recognizedCharsets[unquoted] else { continue }
            charset = recognized
        }

        let normalizedMediaType = mediaType.lowercased()
        if let charset {
            return "\(normalizedMediaType); charset=\(charset)"
        }
        return normalizedMediaType
    }

    private static func validParameterValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if isHTTPToken(value) { return true }
        guard value.first == "\"", value.last == "\"" else { return false }

        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\""
                || character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            {
                return false
            }
        }
        return !escaped
    }

    private static func unquoted(_ value: String) -> String {
        guard value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func nonnegativeInteger(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let number = Int64(trimmed), number >= 0
        else {
            return nil
        }
        return String(number)
    }

    private static func recognizedCodings(_ value: String, allowed: Set<String>) -> String? {
        let codings = value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !codings.isEmpty,
            codings.allSatisfy({ allowed.contains($0) })
        else {
            return nil
        }
        return codings.joined(separator: ", ")
    }

    private static func normalizedHTTPDate(_ value: String) -> String? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return ISO8601DateFormatter().string(from: date)
            }
        }
        return nil
    }

    private static func normalizedRetryAfter(_ value: String) -> String? {
        nonnegativeInteger(value) ?? normalizedHTTPDate(value)
    }

    private static func normalizedMethods(_ value: String) -> String? {
        let methods = value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        guard !methods.isEmpty, methods.allSatisfy({ recognizedMethods.contains($0) }) else { return nil }
        var seen: Set<String> = []
        return methods.filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private static func normalizedAcceptRanges(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bytes": return "bytes"
        case "none": return "none"
        default: return nil
        }
    }

    private static func normalizedContentRange(_ value: String) -> String? {
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2, let total = nonnegativeInteger(String(rangeAndTotal[1])) else { return nil }

        if rangeAndTotal[0] == "*" {
            return "bytes */\(total)"
        }
        let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
            let start = nonnegativeInteger(String(bounds[0])),
            let end = nonnegativeInteger(String(bounds[1])),
            let startValue = Int64(start), let endValue = Int64(end), let totalValue = Int64(total),
            startValue <= endValue, endValue < totalValue
        else {
            return nil
        }
        return "bytes \(start)-\(end)/\(total)"
    }

    private static func normalizedCacheControl(_ value: String) -> String? {
        guard let parts = splitCacheDirectives(value), !parts.isEmpty else { return nil }
        var directives: [String: String] = [:]
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isHTTPToken(name) else { continue }
            let rawValue = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            guard let normalized = normalizedCacheDirective(name: name, value: rawValue) else { continue }
            if let existing = directives[name], existing != normalized { return nil }
            directives[name] = normalized
        }

        guard !directives.isEmpty else { return nil }
        return directives.keys.sorted().compactMap { directives[$0] }.joined(separator: ", ")
    }

    private static func normalizedCacheDirective(name: String, value: String?) -> String? {
        let deltaDirectives: Set<String> = [
            "max-age", "s-maxage", "min-fresh", "stale-while-revalidate", "stale-if-error",
        ]
        if deltaDirectives.contains(name) {
            guard let value, let number = nonnegativeInteger(value) else { return nil }
            return "\(name)=\(number)"
        }
        if name == "max-stale" {
            guard let value else { return name }
            guard let number = nonnegativeInteger(value) else { return nil }
            return "\(name)=\(number)"
        }
        guard value == nil,
            [
                "public", "private", "no-cache", "no-store", "no-transform", "must-revalidate",
                "proxy-revalidate", "immutable", "only-if-cached", "must-understand",
            ].contains(name)
        else {
            return nil
        }
        return name
    }

    private static func splitCacheDirectives(_ value: String) -> [String]? {
        var result: [String] = []
        var part = ""
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped {
                part.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                part.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                part.append(character)
                continue
            }
            if character == ",", !inQuotes {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                result.append(trimmed)
                part = ""
                continue
            }
            part.append(character)
        }
        guard !inQuotes, !escaped else { return nil }
        let final = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return nil }
        result.append(final)
        return result
    }

    private static func redirectProjection(
        index: Int,
        redirect: HTTPRedirect,
        headers mode: RedirectHeaderMode,
        sanitizer: SecretRetemplating?
    ) -> AutomationJSON {
        let methods = (
            projectedMethod(redirect.method, sanitizer: sanitizer, isRaw: mode.isRaw),
            projectedMethod(redirect.nextMethod, sanitizer: sanitizer, isRaw: mode.isRaw)
        )

        let projectedHeaders: [AutomationJSON]
        switch mode {
        case .metadata(let value): projectedHeaders = metadataHeaders(redirect.responseHeaders, sanitizer: value)
        case .all(let value): projectedHeaders = allMCPHeaders(redirect.responseHeaders, sanitizer: value)
        case .none: projectedHeaders = []
        case .raw, .unredacted: projectedHeaders = rawHeaders(redirect.responseHeaders)
        }

        var result: [String: AutomationJSON] = [
            "index": number(Int64(index)),
            "statusCode": number(Int64(redirect.statusCode)),
            "reason": .string(reasonPhrase(redirect.statusCode)),
            "method": .string(methods.0),
            "nextMethod": .string(methods.1),
            "originChanged": .bool(!sameOrigin(redirect.url, redirect.nextURL)),
            "headers": .array(projectedHeaders),
        ]
        if case .unredacted = mode {
            result["url"] = .string(redirect.url.absoluteString)
            result["nextURL"] = .string(redirect.nextURL.absoluteString)
        }
        return .object(result)
    }

    private enum RedirectHeaderMode {
        case metadata(SecretRetemplating)
        case all(SecretRetemplating)
        case none
        case raw
        case unredacted

        var isRaw: Bool {
            switch self {
            case .raw, .unredacted: true
            case .metadata, .all, .none: false
            }
        }
    }

    private static func projectedMethod(_ value: String, sanitizer: SecretRetemplating?, isRaw: Bool) -> String {
        if isRaw { return value }
        if let sanitizer, sanitizer.hasFrozenContext, sanitizer.isComplete {
            return sanitizer.sanitizeBounded(value, maximumUTF8Bytes: maximumHeaderNameBytes)
        }

        let method = value.uppercased()
        return method.utf8.count <= maximumHeaderNameBytes && recognizedMethods.contains(method)
            ? method
            : SecretRetemplating.redaction
    }

    private static func headerObject(name: String, value: String) -> AutomationJSON {
        .object(["name": .string(name), "value": .string(value)])
    }

    private static func readBody(at url: URL, expectedByteCount: Int64) -> Data? {
        guard expectedByteCount >= 0 else { return nil }
        let expectedReadCount = min(expectedByteCount, Int64(maximumBodyPreviewBytes))
        guard let readCount = Int(exactly: expectedReadCount) else { return nil }

        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: readCount) ?? Data()
            guard data.count == readCount else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func decodedText(_ data: Data, isTruncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        guard isTruncated else { return nil }

        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }
        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuationCount < 3 {
            continuationCount += 1
            if index == 0 { break }
            index -= 1
        }

        let leadIndex = index
        let expectedLength: Int
        switch bytes[leadIndex] {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: expectedLength = 1
        }
        guard expectedLength > bytes.count - leadIndex else { return nil }
        return String(data: Data(bytes.prefix(leadIndex)), encoding: .utf8)
    }

    private static func isTextual(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func containsForbiddenControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value != 0x09 && CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                isHex(bytes[index + 1]), isHex(bytes[index + 2])
            else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { byte in
                (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                    || [0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E]
                        .contains(byte)
            }
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        guard let leftScheme = left.scheme?.lowercased(),
            let rightScheme = right.scheme?.lowercased(),
            let leftHost = left.host?.lowercased(),
            let rightHost = right.host?.lowercased()
        else {
            return false
        }
        return leftScheme == rightScheme
            && leftHost == rightHost
            && effectivePort(left) == effectivePort(right)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func reasonPhrase(_ status: Int) -> String {
        statusReasons[status] ?? "Unknown"
    }

    private static let metadataHeaderNames: [String: String] = [
        "content-type": "Content-Type",
        "content-length": "Content-Length",
        "content-encoding": "Content-Encoding",
        "transfer-encoding": "Transfer-Encoding",
        "date": "Date",
        "expires": "Expires",
        "last-modified": "Last-Modified",
        "age": "Age",
        "retry-after": "Retry-After",
        "allow": "Allow",
        "accept-ranges": "Accept-Ranges",
        "content-range": "Content-Range",
        "cache-control": "Cache-Control",
    ]

    private static let recognizedCharsets: [String: String] = [
        "utf-8": "utf-8",
        "utf8": "utf-8",
        "us-ascii": "us-ascii",
        "ascii": "us-ascii",
        "iso-8859-1": "iso-8859-1",
        "latin1": "iso-8859-1",
        "windows-1252": "windows-1252",
    ]

    private static let contentCodings: Set<String> = ["identity", "gzip", "deflate", "br", "compress"]
    private static let transferCodings: Set<String> = ["chunked", "gzip", "deflate", "compress"]
    private static let recognizedMethods: Set<String> = [
        "GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH",
        "ACL", "BASELINE-CONTROL", "BIND", "CHECKIN", "CHECKOUT", "COPY", "LABEL", "LINK",
        "LOCK", "MERGE", "MKACTIVITY", "MKCALENDAR", "MKCOL", "MKREDIRECTREF", "MKWORKSPACE",
        "MOVE", "ORDERPATCH", "PRI", "REBIND", "REPORT", "SEARCH", "UNBIND", "UNCHECKOUT",
        "UNLINK", "UNLOCK", "UPDATE", "UPDATEREDIRECTREF", "VERSION-CONTROL",
    ]

    private static let statusReasons: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 102: "Processing", 103: "Early Hints",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
        208: "Already Reported", 226: "IM Used",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
        304: "Not Modified", 305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required",
        408: "Request Timeout", 409: "Conflict", 410: "Gone", 411: "Length Required",
        412: "Precondition Failed", 413: "Content Too Large", 414: "URI Too Long",
        415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
        421: "Misdirected Request", 422: "Unprocessable Content", 423: "Locked", 424: "Failed Dependency",
        425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported", 506: "Variant Also Negotiates",
        507: "Insufficient Storage", 508: "Loop Detected", 510: "Not Extended",
        511: "Network Authentication Required",
    ]
}
