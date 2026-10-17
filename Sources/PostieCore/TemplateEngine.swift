import Foundation

public struct TemplateReference: Equatable, Sendable {
    public let name: String
    public let range: NSRange

    public init(name: String, range: NSRange) {
        self.name = name
        self.range = range
    }
}

public struct TemplateScan: Equatable, Sendable {
    public let references: [TemplateReference]
    public let invalidRanges: [NSRange]

    public init(references: [TemplateReference], invalidRanges: [NSRange]) {
        self.references = references
        self.invalidRanges = invalidRanges
    }
}

private enum TemplateEngineFailure: Error {
    case malformedTemplate
    case missingValue(String)
}

public enum TemplateEngine {
    private static let openingBrace: unichar = 0x7B
    private static let closingBrace: unichar = 0x7D
    private static let backslash: unichar = 0x5C
    private static let slash: unichar = 0x2F

    public static func scan(_ source: String) -> TemplateScan {
        let text = source as NSString
        var references: [TemplateReference] = []
        var invalidRanges: [NSRange] = []
        var index = 0

        while index < text.length {
            if isEscapedOpener(in: text, at: index) {
                index += 3
                continue
            }

            guard isOpeningDelimiter(in: text, at: index) else {
                index += 1
                continue
            }

            var closingIndex = index + 2
            while closingIndex + 1 < text.length,
                  !isClosingDelimiter(in: text, at: closingIndex) {
                closingIndex += 1
            }

            guard closingIndex + 1 < text.length else {
                invalidRanges.append(NSRange(location: index, length: text.length - index))
                break
            }

            let nameRange = NSRange(location: index + 2, length: closingIndex - index - 2)
            let name = text.substring(with: nameRange)
            let tokenRange = NSRange(location: index, length: closingIndex + 2 - index)
            if isValidVariableName(name) {
                references.append(TemplateReference(name: name, range: tokenRange))
            } else {
                invalidRanges.append(tokenRange)
            }
            index = NSMaxRange(tokenRange)
        }

        return TemplateScan(references: references, invalidRanges: invalidRanges)
    }

    public static func substitute(_ source: String, values: [String: String]) throws -> String {
        let result = scan(source)
        guard result.invalidRanges.isEmpty else {
            throw TemplateEngineFailure.malformedTemplate
        }

        let text = source as NSString
        var output = ""
        var cursor = 0
        var literalStart = 0
        var referenceIndex = 0

        while cursor < text.length {
            if isEscapedOpener(in: text, at: cursor) {
                append(text, from: literalStart, to: cursor, into: &output)
                output.append("{{")
                cursor += 3
                literalStart = cursor
                continue
            }

            if referenceIndex < result.references.count,
               result.references[referenceIndex].range.location == cursor {
                let reference = result.references[referenceIndex]
                append(text, from: literalStart, to: cursor, into: &output)
                guard let value = values[reference.name] else {
                    throw TemplateEngineFailure.missingValue(reference.name)
                }
                output.append(value)
                cursor = NSMaxRange(reference.range)
                literalStart = cursor
                referenceIndex += 1
                continue
            }

            cursor += 1
        }

        append(text, from: literalStart, to: text.length, into: &output)
        return output
    }

    public static func isValidVariableName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard let first = bytes.first, isIdentifierStart(first) else {
            return false
        }

        return bytes.dropFirst().allSatisfy(isIdentifierContinuation)
    }

    public static func pathReferences(in source: String) -> [TemplateReference] {
        let text = source as NSString
        guard let pathRange = pathRange(in: text) else {
            return []
        }

        let scanResult = scan(source)
        let excludedRanges = scanResult.references.map(\.range) + scanResult.invalidRanges
        var references: [TemplateReference] = []
        var segmentStart = pathRange.lowerBound

        while segmentStart <= pathRange.upperBound {
            var segmentEnd = segmentStart
            while segmentEnd < pathRange.upperBound,
                  text.character(at: segmentEnd) != slash {
                segmentEnd += 1
            }

            if segmentEnd > segmentStart {
                let segmentRange = NSRange(location: segmentStart, length: segmentEnd - segmentStart)
                let overlapsTemplate = excludedRanges.contains {
                    NSIntersectionRange($0, segmentRange).length > 0
                }
                let segment = text.substring(with: segmentRange)
                if !overlapsTemplate,
                   segment.first == ":",
                   isValidVariableName(String(segment.dropFirst())) {
                    references.append(TemplateReference(name: String(segment.dropFirst()), range: segmentRange))
                }
            }

            guard segmentEnd < pathRange.upperBound else {
                break
            }
            segmentStart = segmentEnd + 1
        }

        return references
    }

    private static func pathRange(in text: NSString) -> Range<Int>? {
        let pathEnd = firstSuffixDelimiter(in: text)
        guard pathEnd > 0 else {
            return nil
        }

        let authorityDelimiter = rangeOfAuthorityDelimiter(in: text, before: pathEnd)
        let pathStart: Int
        if let authorityDelimiter {
            let authorityStart = authorityDelimiter + 3
            guard let slashIndex = firstSlash(in: text, from: authorityStart, before: pathEnd) else {
                return nil
            }
            pathStart = slashIndex
        } else if text.length >= 2,
                  pathEnd >= 2,
                  text.character(at: 0) == slash,
                  text.character(at: 1) == slash {
            guard let slashIndex = firstSlash(in: text, from: 2, before: pathEnd) else {
                return nil
            }
            pathStart = slashIndex
        } else if let colon = firstColon(in: text, before: pathEnd),
                  isScheme(String(text.substring(to: colon))) {
            pathStart = colon + 1
        } else {
            pathStart = 0
        }

        guard pathStart < pathEnd else {
            return nil
        }
        return pathStart..<pathEnd
    }

    private static func firstSuffixDelimiter(in text: NSString) -> Int {
        for index in 0..<text.length {
            let character = text.character(at: index)
            if character == 0x3F || character == 0x23 {
                return index
            }
        }
        return text.length
    }

    private static func rangeOfAuthorityDelimiter(in text: NSString, before end: Int) -> Int? {
        guard end >= 3 else {
            return nil
        }

        for index in 0...(end - 3) where text.character(at: index) == 0x3A {
            if text.character(at: index + 1) == slash,
               text.character(at: index + 2) == slash {
                return index
            }
        }
        return nil
    }

    private static func firstSlash(in text: NSString, from start: Int, before end: Int) -> Int? {
        guard start < end else {
            return nil
        }
        for index in start..<end where text.character(at: index) == slash {
            return index
        }
        return nil
    }

    private static func firstColon(in text: NSString, before end: Int) -> Int? {
        guard end > 0 else {
            return nil
        }
        for index in 0..<end where text.character(at: index) == 0x3A {
            return index
        }
        return nil
    }

    private static func isScheme(_ value: String) -> Bool {
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

    private static func isEscapedOpener(in text: NSString, at index: Int) -> Bool {
        index + 2 < text.length &&
            text.character(at: index) == backslash &&
            isOpeningDelimiter(in: text, at: index + 1)
    }

    private static func isOpeningDelimiter(in text: NSString, at index: Int) -> Bool {
        index + 1 < text.length &&
            text.character(at: index) == openingBrace &&
            text.character(at: index + 1) == openingBrace
    }

    private static func isClosingDelimiter(in text: NSString, at index: Int) -> Bool {
        index + 1 < text.length &&
            text.character(at: index) == closingBrace &&
            text.character(at: index + 1) == closingBrace
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x5F
    }

    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (0x30...0x39).contains(byte)
    }

    private static func append(_ text: NSString, from start: Int, to end: Int, into output: inout String) {
        guard end > start else {
            return
        }
        output.append(text.substring(with: NSRange(location: start, length: end - start)))
    }
}
