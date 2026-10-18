import Foundation

public struct QueryParameterEncoding: Codable, Equatable, Sendable {
    public var encodedName: String
    public var encodedValue: String?
    public var originalName: String
    public var originalValue: String

    public var hasEquals: Bool { encodedValue != nil }

    public init(encodedName: String, encodedValue: String?, originalName: String, originalValue: String) {
        self.encodedName = encodedName
        self.encodedValue = encodedValue
        self.originalName = originalName
        self.originalValue = originalValue
    }

    private enum CodingKeys: String, CodingKey {
        case encodedName, encodedValue, originalName, originalValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(encodedName, forKey: .encodedName)
        if let encodedValue {
            try container.encode(encodedValue, forKey: .encodedValue)
        } else {
            try container.encodeNil(forKey: .encodedValue)
        }
        try container.encode(originalName, forKey: .originalName)
        try container.encode(originalValue, forKey: .originalValue)
    }
}

public struct QueryParameterState: Equatable, Sendable {
    public var baseURL: String
    public var fields: [HTTPField]

    public init(baseURL: String, fields: [HTTPField]) {
        self.baseURL = baseURL
        self.fields = fields
    }
}

public enum QueryParameters {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func isActive(_ field: HTTPField) -> Bool {
        guard field.isEnabled else { return false }
        if !field.name.isEmpty || !field.value.isEmpty { return true }
        return field.queryEncoding.map { $0.originalName.isEmpty && $0.originalValue.isEmpty } ?? false
    }

    public static func render(baseURL: String, fields: [HTTPField]) -> String {
        guard let query = encodedQuery(fields: fields) else { return baseURL }

        let fragmentIndex = firstDelimiter(in: baseURL, matching: ["#"]) ?? baseURL.endIndex
        return String(baseURL[..<fragmentIndex]) + "?" + query + baseURL[fragmentIndex...]
    }

    public static func encodedQuery(fields: [HTTPField], preserveTemplates: Bool = true) -> String? {
        let active = fields.filter(isActive)
        guard !active.isEmpty else { return nil }
        return active.map { renderField($0, preserveTemplates: preserveTemplates) }.joined(separator: "&")
    }

    public static func templateSources(for field: HTTPField) -> [String] {
        let raw = rawComponents(for: field)
        return [raw.name ?? field.name, raw.value ?? field.value]
    }

    public static func encodedQuery(fields: [HTTPField], values: [String: String]) throws -> String? {
        let active = fields.filter(isActive)
        guard !active.isEmpty else { return nil }
        let encodedValues = values.mapValues { encode($0, preserveTemplates: false) }

        return try active.map { field in
            let raw = rawComponents(for: field)
            let name = try resolveComponent(field.name, raw: raw.name, values: values, encodedValues: encodedValues)
            let value = try resolveComponent(field.value, raw: raw.value, values: values, encodedValues: encodedValues)
            let hasEquals = field.queryEncoding?.hasEquals ?? true
            return name + (hasEquals || !value.isEmpty ? "=" + value : "")
        }.joined(separator: "&")
    }

    public static func parse(
        displayURL: String,
        previousFields: [HTTPField] = [],
        previousBase: String? = nil
    ) -> QueryParameterState {
        if let previousBase, render(baseURL: previousBase, fields: previousFields) == displayURL {
            return QueryParameterState(baseURL: previousBase, fields: previousFields)
        }

        let parsed = splitURL(displayURL)
        var fields = parsed.fields
        let enabled = previousFields.filter(\.isEnabled)
        var available = Set(enabled.indices)
        var matched: [Int: Int] = [:]

        for index in fields.indices {
            if let previousIndex = enabled.indices.first(where: {
                available.contains($0) && fields[index].name == enabled[$0].name && fields[index].value == enabled[$0].value
            }) {
                matched[index] = previousIndex
                available.remove(previousIndex)
            }
        }

        for index in fields.indices where matched[index] == nil {
            if let previousIndex = enabled.indices.first(where: {
                available.contains($0) && fields[index].name == enabled[$0].name
            }) {
                matched[index] = previousIndex
                available.remove(previousIndex)
            }
        }

        for index in fields.indices where matched[index] == nil {
            guard available.contains(index) else { continue }
            matched[index] = index
            available.remove(index)
        }

        for (index, previousIndex) in matched {
            fields[index].id = enabled[previousIndex].id
        }

        for (index, field) in previousFields.enumerated() where !field.isEnabled {
            fields.insert(field, at: min(index, fields.count))
        }

        return QueryParameterState(baseURL: parsed.baseURL, fields: fields)
    }

    public static func normalize(url: String, fields: [HTTPField]) -> QueryParameterState {
        let parsed = splitURL(url)
        return QueryParameterState(baseURL: parsed.baseURL, fields: parsed.fields + fields)
    }

    private static func splitURL(_ source: String) -> QueryParameterState {
        let fragmentIndex = firstDelimiter(in: source, matching: ["#"]) ?? source.endIndex
        let prefix = String(source[..<fragmentIndex])
        guard let queryIndex = firstDelimiter(in: prefix, matching: ["?"]) else {
            return QueryParameterState(baseURL: source, fields: [])
        }

        let queryStart = prefix.index(after: queryIndex)
        let query = String(prefix[queryStart...])
        let baseURL = String(prefix[..<queryIndex]) + source[fragmentIndex...]
        let fields = split(query, separator: "&").map { component in
            let equalsIndex = firstDelimiter(in: component, matching: ["="])
            let encodedName = equalsIndex.map { String(component[..<$0]) } ?? component
            let encodedValue = equalsIndex.map { String(component[component.index(after: $0)...]) }
            let name = encodedName.removingPercentEncoding ?? encodedName
            let value = encodedValue.map { $0.removingPercentEncoding ?? $0 } ?? ""
            return HTTPField(
                name: name,
                value: value,
                queryEncoding: QueryParameterEncoding(
                    encodedName: encodedName,
                    encodedValue: encodedValue,
                    originalName: name,
                    originalValue: value
                )
            )
        }

        return QueryParameterState(baseURL: baseURL, fields: fields)
    }

    private static func renderField(_ field: HTTPField, preserveTemplates: Bool) -> String {
        let metadata = field.queryEncoding
        let raw = rawComponents(for: field)
        let name = reusable(raw.name, preserveTemplates: preserveTemplates) ?? encode(field.name, preserveTemplates: preserveTemplates)
        let value = reusable(raw.value, preserveTemplates: preserveTemplates) ?? encode(field.value, preserveTemplates: preserveTemplates)
        let hasEquals = metadata?.hasEquals ?? true
        return name + (hasEquals || !field.value.isEmpty ? "=" + value : "")
    }

    private static func rawComponents(for field: HTTPField) -> (name: String?, value: String?) {
        let metadata = field.queryEncoding
        return (
            metadata.flatMap { field.name == $0.originalName ? $0.encodedName : nil },
            metadata.flatMap { field.value == $0.originalValue ? $0.encodedValue : nil }
        )
    }

    private static func resolveComponent(
        _ source: String,
        raw: String?,
        values: [String: String],
        encodedValues: [String: String]
    ) throws -> String {
        guard let raw else {
            return encode(try TemplateEngine.substitute(source, values: values), preserveTemplates: false)
        }
        return sanitizeRaw(try TemplateEngine.substitute(raw, values: encodedValues))
    }

    private static func sanitizeRaw(_ source: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&#%"))
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let scalars = Array(source.unicodeScalars)
        var output = ""
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%", index + 2 < scalars.count,
               hex.contains(scalars[index + 1]), hex.contains(scalars[index + 2]) {
                output += String(String.UnicodeScalarView(scalars[index...index + 2]))
                index += 3
                continue
            }

            let text = String(scalar)
            output += scalar.isASCII && allowed.contains(scalar)
                ? text
                : encode(text, preserveTemplates: false)
            index += 1
        }

        return output
    }

    private static func reusable(_ raw: String?, preserveTemplates: Bool) -> String? {
        guard let raw else { return nil }
        return preserveTemplates ? raw : sanitizeRaw(raw)
    }

    private static func encode(_ source: String, preserveTemplates: Bool) -> String {
        var output = ""
        var cursor = source.startIndex

        while cursor < source.endIndex {
            if preserveTemplates && source[cursor...].hasPrefix("\\{{") {
                let opening = source.index(after: cursor)
                let end = templateEnd(in: source, from: opening)
                output += source[cursor..<end]
                cursor = end
                continue
            }
            if preserveTemplates && source[cursor...].hasPrefix("{{") {
                let end = templateEnd(in: source, from: cursor)
                output += source[cursor..<end]
                cursor = end
                continue
            }

            let next = source.index(after: cursor)
            output += String(source[cursor..<next]).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String(source[cursor..<next])
            cursor = next
        }

        return output
    }

    private static func split(_ source: String, separator: Character) -> [String] {
        var parts: [String] = []
        var remainder = source[...]

        while let index = firstDelimiter(in: remainder, matching: [separator]) {
            parts.append(String(remainder[..<index]))
            remainder = remainder[remainder.index(after: index)...]
        }

        parts.append(String(remainder))
        return parts
    }

    private static func firstDelimiter<S: StringProtocol>(in source: S, matching delimiters: Set<Character>) -> S.Index? {
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor...].hasPrefix("{{") {
                cursor = templateEnd(in: source, from: cursor)
                continue
            }
            if delimiters.contains(source[cursor]) { return cursor }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func templateEnd<S: StringProtocol>(in source: S, from start: S.Index) -> S.Index {
        var cursor = source.index(start, offsetBy: 2)
        while cursor < source.endIndex {
            if source[cursor...].hasPrefix("}}") {
                return source.index(cursor, offsetBy: 2)
            }
            cursor = source.index(after: cursor)
        }
        return source.endIndex
    }
}
