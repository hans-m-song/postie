import Foundation
import PostieCore

public struct SecretRetemplating: Sendable {
    public static let redaction = "[redacted]"
    private static let maximumSanitizedOutputBytes = 1_048_576
    private static let maximumSanitizedMatchCount = 65_536

    fileprivate struct Pattern: Sendable {
        let value: String
        let replacement: String
    }

    private let patterns: [Pattern]
    private let replacementsByValue: [String: String]
    private let expression: RegularExpressionBox
    public let hasFrozenContext: Bool
    public let isComplete: Bool
    public let maximumPatternByteCount: Int

    public init(capture: SnapshotPreparationCapture?) {
        guard let capture else {
            patterns = []
            replacementsByValue = [:]
            expression = RegularExpressionBox(patterns: [])
            hasFrozenContext = false
            isComplete = false
            maximumPatternByteCount = 0
            return
        }

        var builder = PatternBuilder()
        if capture.redactionInputs?.isComplete == false {
            builder.markIncomplete()
        }
        let variableValues = capture.referencedInputs.mapValues { $0.value }
        let referencedSecrets = capture.referencedInputs
            .filter { $0.value.isSecret && !$0.value.value.isEmpty }
            .sorted { $0.key < $1.key }
        let unusedSecrets = (capture.redactionInputs?.inputs ?? [:])
            .filter { capture.referencedInputs[$0.key] == nil && $0.value.isSecret && !$0.value.value.isEmpty }
            .sorted { $0.key < $1.key }

        for (name, input) in referencedSecrets + unusedSecrets {
            builder.add(input.value, replacement: Self.reference(name))
        }

        let authentication = capture.authentication
        let authenticationSecret = authentication.resolvedSecret
        let authenticationReference = Self.authenticationReference(in: authentication, capture: capture)
        let authenticationReplacement = authenticationReference.map(Self.reference) ?? Self.redaction

        if let authenticationSecret, !authenticationSecret.isEmpty {
            builder.add(authenticationSecret, replacement: authenticationReplacement)
            builder.addBase64(of: authenticationSecret, replacement: authenticationReplacement)
        }

        if authentication.kind == .basic,
            let authenticationSecret,
            let username = try? TemplateEngine.substitute(authentication.username, values: variableValues),
            !username.isEmpty
        {
            builder.add(username, replacement: Self.redaction)
            let encoded = Data("\(username):\(authenticationSecret)".utf8).base64EncodedString()
            for scheme in ["Basic", "basic", "BASIC"] {
                builder.add("\(scheme) \(encoded)", replacement: "\(scheme) \(authenticationReplacement)")
            }
            builder.add(encoded, replacement: authenticationReplacement)
        }

        if authentication.kind == .bearer, let authenticationSecret {
            for scheme in ["Bearer", "bearer", "BEARER"] {
                builder.add("\(scheme) \(authenticationSecret)", replacement: "\(scheme) \(authenticationReplacement)")
            }
        }

        let credentialHeaderNames = Set(
            ["authorization", "proxy-authorization", "cookie", "cookie2"]
                + capture.submitted.sensitiveNames.map { $0.lowercased() }
                + capture.submitted.secretNames.map { $0.lowercased() }
                + (authentication.apiKeyHeaderName.map { [$0.lowercased()] } ?? [])
        )
        for header in capture.submitted.headers where credentialHeaderNames.contains(header.name.lowercased()) {
            let name = header.name.lowercased()
            let replacement = Self.authorizationReplacement(
                for: header.value,
                authentication: authentication,
                defaultReplacement: Self.redaction
            )
            builder.add(header.value, replacement: replacement)

            switch name {
            case "authorization", "proxy-authorization":
                switch Self.authorizationPayload(in: header.value) {
                case .some(.bearer(let token)):
                    let tokenReplacement =
                        authentication.kind == .bearer && authentication.resolvedSecret == token
                        ? authenticationReplacement
                        : Self.redaction
                    builder.add(token, replacement: tokenReplacement)
                case .some(.basic(let encoded, let credentials, let password)):
                    builder.add(encoded, replacement: Self.redaction)
                    builder.add(credentials, replacement: Self.redaction)
                    let passwordReplacement =
                        authentication.kind == .basic && authentication.resolvedSecret == password
                        ? authenticationReplacement
                        : Self.redaction
                    builder.add(password, replacement: passwordReplacement)
                case .none:
                    let configuredAPIKeyIsKnown =
                        authentication.kind == .apiKey
                        && authentication.resolvedSecret.map { !$0.isEmpty && header.value.contains($0) } == true
                    if !configuredAPIKeyIsKnown { builder.markIncomplete() }
                }
            case "cookie", "cookie2":
                guard let values = Self.cookieValues(in: header.value) else {
                    builder.markIncomplete()
                    continue
                }
                for value in values { builder.add(value, replacement: Self.redaction) }
            default:
                break
            }
        }

        let builtPatterns = builder.isComplete ? builder.patterns : []
        let compiledExpression = RegularExpressionBox(patterns: builtPatterns)
        patterns = builtPatterns
        replacementsByValue = Dictionary(uniqueKeysWithValues: builtPatterns.map { ($0.value, $0.replacement) })
        expression = compiledExpression
        hasFrozenContext = true
        isComplete = builder.isComplete && (builtPatterns.isEmpty || compiledExpression.value != nil)
        maximumPatternByteCount = builder.maximumPatternByteCount
    }

    public func sanitize(_ value: String) -> String {
        guard hasFrozenContext else { return Self.redaction }
        guard isComplete else { return Self.redaction }
        guard value.utf8.count <= Self.maximumSanitizedOutputBytes else { return Self.redaction }
        guard !patterns.isEmpty else { return value }
        guard let expression = expression.value else { return Self.redaction }

        let source = value as NSString
        var result = ""
        var resultByteCount = 0
        var pendingRange: SanitizedRange?
        var cursor = 0
        var matchCount = 0
        var matchLimitExceeded = false
        var outputLimitExceeded = false

        func append(_ piece: String) {
            guard !outputLimitExceeded else { return }
            let byteCount = piece.utf8.count
            guard byteCount <= Self.maximumSanitizedOutputBytes - resultByteCount else {
                outputLimitExceeded = true
                return
            }
            result.append(contentsOf: piece)
            resultByteCount += byteCount
        }

        func appendSource(from start: Int, to end: Int) {
            guard end > start else { return }
            append(source.substring(with: NSRange(location: start, length: end - start)))
        }

        func flush(_ range: SanitizedRange) {
            appendSource(from: cursor, to: range.range.location)
            append(range.replacement)
            cursor = NSMaxRange(range.range)
        }

        expression.enumerateMatches(
            in: value,
            options: [],
            range: NSRange(location: 0, length: source.length)
        ) { match, _, stop in
            guard !outputLimitExceeded else {
                stop.pointee = true
                return
            }
            guard let match else { return }
            matchCount += 1
            guard matchCount <= Self.maximumSanitizedMatchCount else {
                matchLimitExceeded = true
                stop.pointee = true
                return
            }

            let range = match.range(at: 1)
            guard range.location != NSNotFound else { return }
            let matchedValue = source.substring(with: range)
            let candidate = SanitizedRange(
                range: range,
                replacement: replacement(for: matchedValue),
                preferredLength: range.length
            )
            if var previous = pendingRange, range.location < NSMaxRange(previous.range) {
                let end = max(NSMaxRange(previous.range), NSMaxRange(range))
                previous.range.length = end - previous.range.location
                if candidate.preferredLength > previous.preferredLength {
                    previous.replacement = candidate.replacement
                    previous.preferredLength = candidate.preferredLength
                } else if candidate.preferredLength == previous.preferredLength,
                    candidate.replacement != previous.replacement
                {
                    previous.replacement = Self.redaction
                }
                pendingRange = previous
                return
            }
            if let previous = pendingRange {
                flush(previous)
                guard !outputLimitExceeded else {
                    stop.pointee = true
                    return
                }
            }
            pendingRange = candidate
        }

        guard !matchLimitExceeded, !outputLimitExceeded else { return Self.redaction }
        if let pendingRange {
            flush(pendingRange)
        }
        appendSource(from: cursor, to: source.length)
        guard !outputLimitExceeded else { return Self.redaction }
        return result
    }

    public func sanitizeBounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes >= 0 else { return Self.redaction }
        return sanitizePreview(value, maximumUTF8Bytes: maximumUTF8Bytes) ?? Self.redaction
    }

    public func sanitizePreview(
        _ value: String,
        maximumUTF8Bytes: Int,
        isTruncated: Bool = false
    ) -> String? {
        guard hasFrozenContext, isComplete, maximumUTF8Bytes >= 0 else { return nil }
        let inputIsTruncated = isTruncated || value.utf8.count > maximumUTF8Bytes
        var source = Self.validUTF8Prefix(value, maximumBytes: maximumUTF8Bytes)
        if inputIsTruncated {
            let partialSecretLength = partialSecretSuffixLength(source)
            if partialSecretLength > 0 {
                source = Self.validUTF8Prefix(source, maximumBytes: max(0, source.utf8.count - partialSecretLength))
                guard partialSecretSuffixLength(source) == 0 else { return nil }
            }
        }
        return Self.validUTF8Prefix(sanitize(source), maximumBytes: maximumUTF8Bytes)
    }

    public func containsKnownSecret(_ value: String) -> Bool {
        guard hasFrozenContext, isComplete, !patterns.isEmpty,
            let expression = expression.value
        else { return false }
        return expression.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private func replacement(for value: String) -> String {
        replacementsByValue[value] ?? Self.redaction
    }

    private func partialSecretSuffixLength(_ value: String) -> Int {
        let valueBytes = Array(value.utf8)
        guard !valueBytes.isEmpty else { return 0 }
        var longestMatch = 0

        for pattern in patterns {
            let patternBytes = Array(pattern.value.utf8)
            guard patternBytes.count > 1 else { continue }

            if patternBytes.count <= valueBytes.count,
                valueBytes.suffix(patternBytes.count).elementsEqual(patternBytes)
            {
                continue
            }

            let comparisonLength = min(patternBytes.count, valueBytes.count)
            let prefix = Array(patternBytes.prefix(comparisonLength))
            let suffix = Array(valueBytes.suffix(comparisonLength))
            let matchLength = Self.longestPrefixSuffixMatch(prefix, suffix)
            if matchLength < patternBytes.count {
                longestMatch = max(longestMatch, matchLength)
            }
        }
        return longestMatch
    }

    private static func longestPrefixSuffixMatch(_ pattern: [UInt8], _ value: [UInt8]) -> Int {
        guard !pattern.isEmpty, !value.isEmpty else { return 0 }
        var prefixTable = [Int](repeating: 0, count: pattern.count)
        var prefixLength = 0
        if pattern.count > 1 {
            for index in 1..<pattern.count {
                while prefixLength > 0, pattern[index] != pattern[prefixLength] {
                    prefixLength = prefixTable[prefixLength - 1]
                }
                if pattern[index] == pattern[prefixLength] {
                    prefixLength += 1
                    prefixTable[index] = prefixLength
                }
            }
        }

        var matched = 0
        for byte in value {
            while matched > 0, (matched == pattern.count || pattern[matched] != byte) {
                matched = prefixTable[matched - 1]
            }
            if matched < pattern.count, pattern[matched] == byte {
                matched += 1
            }
        }
        return matched
    }

    private static func reference(_ name: String) -> String {
        TemplateEngine.isValidVariableName(name) ? "{{\(name)}}" : redaction
    }

    private static func authenticationReference(
        in authentication: SnapshotAuthenticationInput,
        capture: SnapshotPreparationCapture
    ) -> String? {
        guard let name = authenticationReferenceName(authentication),
            let resolvedSecret = authentication.resolvedSecret,
            capture.referencedInputs[name]?.value == resolvedSecret
        else {
            return nil
        }
        return name
    }

    private static func authorizationReplacement(
        for value: String,
        authentication: SnapshotAuthenticationInput,
        defaultReplacement: String
    ) -> String {
        let scheme: String
        switch authentication.kind {
        case .basic: scheme = "Basic"
        case .bearer: scheme = "Bearer"
        case .apiKey:
            guard let secret = authentication.resolvedSecret,
                !secret.isEmpty,
                value.contains(secret)
            else {
                return defaultReplacement
            }
            let placeholder = authenticationReferenceName(authentication).map(reference) ?? defaultReplacement
            return value.replacingOccurrences(of: secret, with: placeholder)
        case .none: return defaultReplacement
        }

        guard value.lowercased().hasPrefix(scheme.lowercased() + " ") else {
            return defaultReplacement
        }
        let placeholder = authenticationReferenceName(authentication).map(reference) ?? defaultReplacement
        return "\(scheme) \(placeholder)"
    }

    private static func authenticationReferenceName(_ authentication: SnapshotAuthenticationInput) -> String? {
        guard let template = authentication.secretTemplate,
            template.count > 4,
            template.hasPrefix("{{"),
            template.hasSuffix("}}")
        else {
            return nil
        }
        let name = String(template.dropFirst(2).dropLast(2))
        return TemplateEngine.isValidVariableName(name) ? name : nil
    }

    private enum AuthorizationPayload {
        case bearer(String)
        case basic(encoded: String, credentials: String, password: String)
    }

    private static func authorizationPayload(in value: String) -> AuthorizationPayload? {
        guard value.utf8.count <= PatternBuilder.maximumSourceBytes else {
            return nil
        }
        let components = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard components.count == 2 else { return nil }

        let scheme = components[0].lowercased()
        let payload = components[1]
        switch scheme {
        case "bearer":
            guard isBearerToken(payload) else { return nil }
            return .bearer(String(payload))
        case "basic":
            let encoded = String(payload)
            guard let data = Data(base64Encoded: encoded),
                let credentials = String(data: data, encoding: .utf8),
                let colon = credentials.firstIndex(of: ":")
            else {
                return nil
            }
            return .basic(
                encoded: encoded,
                credentials: credentials,
                password: String(credentials[credentials.index(after: colon)...])
            )
        default:
            return nil
        }
    }

    private static func isBearerToken(_ value: Substring) -> Bool {
        let token = value.prefix { $0 != "=" }
        let padding = value.dropFirst(token.count)
        guard !token.isEmpty,
            token.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || [45, 46, 47, 95, 126, 43].contains(byte)
            })
        else {
            return false
        }
        return padding.allSatisfy { $0 == "=" }
    }

    private static func cookieValues(in value: String) -> [String]? {
        guard value.utf8.count <= PatternBuilder.maximumSourceBytes else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !trimmed.isEmpty else { return [] }

        let pairs = trimmed.split(separator: ";", omittingEmptySubsequences: false)
        guard pairs.count <= PatternBuilder.maximumPatternCount else { return nil }
        var values: [String] = []
        values.reserveCapacity(pairs.count)

        for rawPair in pairs {
            let pair = String(rawPair).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = pair[..<separator]
            let cookieValue = pair[pair.index(after: separator)...]
            guard !name.isEmpty,
                name.utf8.allSatisfy(isHTTPTokenByte),
                cookieValue.utf8.allSatisfy(isCookieOctet)
            else {
                return nil
            }
            values.append(String(cookieValue))
        }
        return values
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }

    private static func isCookieOctet(_ byte: UInt8) -> Bool {
        byte == 33 || (35...43).contains(byte) || (45...58).contains(byte)
            || (60...91).contains(byte) || (93...126).contains(byte)
    }

    private static func validUTF8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var end = value.startIndex
        var byteCount = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextByteCount = value[end..<next].utf8.count
            guard byteCount + nextByteCount <= maximumBytes else { break }
            byteCount += nextByteCount
            end = next
        }
        return String(value[..<end])
    }
}

// Compiled expressions are immutable and safe to share across concurrent matches.
private final class RegularExpressionBox: @unchecked Sendable {
    let value: NSRegularExpression?

    init(patterns: [SecretRetemplating.Pattern]) {
        let alternatives =
            patterns
            .sorted { $0.value.utf8.count > $1.value.utf8.count }
            .map { NSRegularExpression.escapedPattern(for: $0.value) }
        if alternatives.isEmpty {
            value = nil
        } else {
            value = try? NSRegularExpression(pattern: "(?=(" + alternatives.joined(separator: "|") + "))")
        }
    }
}

private struct SanitizedRange {
    var range: NSRange
    var replacement: String
    var preferredLength: Int
}

private struct PatternBuilder {
    private static let maximumPatternBytes = 1_048_576
    fileprivate static let maximumPatternCount = 4_096
    fileprivate static let maximumSourceBytes = maximumPatternBytes / 8

    private var replacements: [String: String] = [:]
    private var totalPatternBytes = 0
    private(set) var isComplete = true
    private(set) var maximumPatternByteCount = 0

    mutating func markIncomplete() {
        isComplete = false
    }

    var patterns: [SecretRetemplating.Pattern] {
        replacements.map { SecretRetemplating.Pattern(value: $0.key, replacement: $0.value) }
    }

    mutating func addBase64(of value: String, replacement: String) {
        guard isComplete else { return }
        guard value.utf8.count <= Self.maximumSourceBytes else {
            isComplete = false
            return
        }
        let encoded = Data(value.utf8).base64EncodedString()
        add(encoded, replacement: replacement)
        add(
            encoded.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""), replacement: replacement)
    }

    mutating func add(_ value: String, replacement: String) {
        guard isComplete, !value.isEmpty else { return }
        guard value.utf8.count <= Self.maximumSourceBytes else {
            isComplete = false
            return
        }
        let variants = Self.variants(for: value)
        for variant in variants where !variant.isEmpty {
            if let existing = replacements[variant] {
                if existing == SecretRetemplating.redaction,
                    replacement != SecretRetemplating.redaction
                {
                    replacements[variant] = replacement
                }
                continue
            }

            let byteCount = variant.utf8.count
            guard replacements.count < Self.maximumPatternCount,
                totalPatternBytes + byteCount <= Self.maximumPatternBytes
            else {
                isComplete = false
                return
            }
            replacements[variant] = replacement
            totalPatternBytes += byteCount
            maximumPatternByteCount = max(maximumPatternByteCount, byteCount)
        }
    }

    private static func variants(for value: String) -> Set<String> {
        var variants: Set<String> = [value]
        if let encoded = try? JSONEncoder().encode(value), encoded.count >= 2 {
            let jsonValue = String(decoding: encoded.dropFirst().dropLast(), as: UTF8.self)
            variants.insert(jsonValue)
            variants.insert(jsonValue.replacingOccurrences(of: "/", with: "\\/"))
        }

        for allowedCharacters in [CharacterSet.urlQueryAllowed, .urlPathAllowed, .alphanumerics] {
            guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else { continue }
            variants.insert(escaped)
            variants.insert(escaped.lowercasedPercentEscapes)
        }

        if let formEncoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            let formValue = formEncoded.replacingOccurrences(of: "%20", with: "+")
            variants.insert(formValue)
            variants.insert(formValue.lowercasedPercentEscapes)
        }
        return variants
    }
}

private extension String {
    var lowercasedPercentEscapes: String {
        var result = ""
        var iterator = makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                result.append(character)
                continue
            }
            result.append(character)
            if let high = iterator.next() {
                result.append(String(high).lowercased())
            }
            if let low = iterator.next() {
                result.append(String(low).lowercased())
            }
        }
        return result
    }
}
