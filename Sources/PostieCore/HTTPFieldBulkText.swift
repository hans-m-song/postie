import Foundation

public enum HTTPFieldBulkTextError: Error, Equatable, LocalizedError, Sendable {
    case missingDelimiter(line: Int)
    case invalidEscape(line: Int)

    public var errorDescription: String? {
        switch self {
        case .missingDelimiter(let line):
            return "Line \(line): expected a colon between the field name and value."
        case .invalidEscape(let line):
            return "Line \(line): contains an invalid escape sequence."
        }
    }
}

public enum HTTPFieldBulkText {
    public static func encode(_ fields: [HTTPField]) -> String {
        fields.map { field in
            let disabledPrefix = field.isEnabled ? "" : "# "
            return disabledPrefix + escape(field.name, isName: true) + ": " + escape(field.value, isName: false)
        }
        .joined(separator: "\n")
    }

    public static func decode(_ text: String) throws -> [HTTPField] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [HTTPField] = []

        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineIndex, substring) in lines.enumerated() {
            let line = String(substring)
            guard !line.isEmpty, !line.allSatisfy({ $0.isWhitespace }) else { continue }

            let isEnabled = !line.hasPrefix("# ")
            let content = isEnabled ? line : String(line.dropFirst(2))
            let delimiter = try delimiterIndex(in: content, lineNumber: lineIndex + 1)
            let encodedName = String(content[..<delimiter])
            var encodedValue = String(content[content.index(after: delimiter)...])

            if encodedValue.first == " " {
                encodedValue.removeFirst()
            }

            fields.append(
                HTTPField(
                    name: try unescape(encodedName, lineNumber: lineIndex + 1),
                    value: try unescape(encodedValue, lineNumber: lineIndex + 1),
                    isEnabled: isEnabled
                ))
        }

        return fields
    }

    public static func reconcile(
        _ decodedFields: [HTTPField],
        against originalFields: [HTTPField]
    ) -> [HTTPField] {
        var unmatchedOriginalIndices = Set(originalFields.indices)
        var originalIndexByDecodedIndex: [Int: Int] = [:]

        for decodedIndex in decodedFields.indices {
            guard
                let originalIndex = originalFields.indices.first(where: { originalIndex in
                    unmatchedOriginalIndices.contains(originalIndex)
                        && sameVisibleFields(decodedFields[decodedIndex], originalFields[originalIndex])
                })
            else { continue }
            originalIndexByDecodedIndex[decodedIndex] = originalIndex
            unmatchedOriginalIndices.remove(originalIndex)
        }

        for decodedIndex in decodedFields.indices where originalIndexByDecodedIndex[decodedIndex] == nil {
            guard
                let originalIndex = originalFields.indices.first(where: { originalIndex in
                    unmatchedOriginalIndices.contains(originalIndex)
                        && decodedFields[decodedIndex].name == originalFields[originalIndex].name
                })
            else { continue }
            originalIndexByDecodedIndex[decodedIndex] = originalIndex
            unmatchedOriginalIndices.remove(originalIndex)
        }

        if decodedFields.count == originalFields.count {
            for decodedIndex in decodedFields.indices where originalIndexByDecodedIndex[decodedIndex] == nil {
                guard unmatchedOriginalIndices.contains(decodedIndex) else { continue }
                originalIndexByDecodedIndex[decodedIndex] = decodedIndex
                unmatchedOriginalIndices.remove(decodedIndex)
            }
        }

        return decodedFields.enumerated().map { decodedIndex, decodedField in
            guard let originalIndex = originalIndexByDecodedIndex[decodedIndex] else { return decodedField }
            var field = decodedField
            field.id = originalFields[originalIndex].id
            field.queryEncoding = originalFields[originalIndex].queryEncoding
            return field
        }
    }

    private static func sameVisibleFields(_ lhs: HTTPField, _ rhs: HTTPField) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value && lhs.isEnabled == rhs.isEnabled
    }

    private static func delimiterIndex(in line: String, lineNumber: Int) throws -> String.Index {
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]

            if character == "\\" {
                let escapeIndex = line.index(after: index)
                guard escapeIndex < line.endIndex, isValidEscape(line[escapeIndex]) else {
                    throw HTTPFieldBulkTextError.invalidEscape(line: lineNumber)
                }
                index = line.index(after: escapeIndex)
                continue
            }

            if character == ":" {
                return index
            }

            index = line.index(after: index)
        }

        throw HTTPFieldBulkTextError.missingDelimiter(line: lineNumber)
    }

    private static func isValidEscape(_ character: Character) -> Bool {
        character == "\\" || character == ":" || character == "n" || character == "r" || character == "t"
            || character == "#" || character.isWhitespace
    }

    private static func unescape(_ value: String, lineNumber: Int) throws -> String {
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]

            guard character == "\\" else {
                result.append(character)
                index = value.index(after: index)
                continue
            }

            let escapeIndex = value.index(after: index)
            guard escapeIndex < value.endIndex else {
                throw HTTPFieldBulkTextError.invalidEscape(line: lineNumber)
            }

            let escaped = value[escapeIndex]
            switch escaped {
            case "\\": result.append("\\")
            case ":": result.append(":")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "#": result.append("#")
            case let whitespace where whitespace.isWhitespace: result.append(whitespace)
            default: throw HTTPFieldBulkTextError.invalidEscape(line: lineNumber)
            }

            index = value.index(after: escapeIndex)
        }

        return result
    }

    private static func escape(_ value: String, isName: Bool) -> String {
        let scalars = Array(value.unicodeScalars)
        let leadingWhitespaceEnd = scalars.prefix(while: { Character(String($0)).isWhitespace }).count
        let trailingWhitespaceStart =
            scalars.lastIndex(where: { !Character(String($0)).isWhitespace })
            .map { $0 + 1 } ?? 0
        let hasAmbiguousDisabledPrefix = isName && value.hasPrefix("# ")

        return scalars.enumerated().map { index, scalar in
            switch scalar.value {
            case 0x5C: return "\\\\"
            case 0x3A where isName: return "\\:"
            case 0x0A: return "\\n"
            case 0x0D: return "\\r"
            case 0x09: return "\\t"
            case 0x23 where hasAmbiguousDisabledPrefix && index == 0: return "\\#"
            default:
                if Character(String(scalar)).isWhitespace
                    && (index < leadingWhitespaceEnd || index >= trailingWhitespaceStart)
                {
                    return "\\" + String(scalar)
                }
                return String(scalar)
            }
        }
        .joined()
    }
}
