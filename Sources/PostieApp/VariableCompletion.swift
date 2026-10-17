import Foundation
import PostieCore

struct VariableCompletion: Equatable, Hashable, Sendable {
    let name: String
    let scope: VariableScope
    let isSecret: Bool

    init(name: String, scope: VariableScope, isSecret: Bool) {
        self.name = name
        self.scope = scope
        self.isSecret = isSecret
    }
}

struct VariableCompletionContext: Equatable, Sendable {
    let prefix: String
    let replacementRange: NSRange
}

enum VariableCompletionMatcher {
    static let maximumSuggestionCount = 20
    static let maximumInputLength = 16_384
    static let maximumCandidatesInspected = 4_096

    static func context(in value: String, selection: NSRange) -> VariableCompletionContext? {
        guard value.utf16.prefix(maximumInputLength + 1).count <= maximumInputLength else {
            return nil
        }

        let source = value as NSString
        guard isInsertionPoint(selection, in: source) else {
            return nil
        }

        return context(
            in: source,
            selection: selection,
            scanStart: 0,
            scanEnd: source.length
        )
    }

    static func bodyContext(in value: String, selection: NSRange) -> VariableCompletionContext? {
        let source = value as NSString
        guard isInsertionPoint(selection, in: source) else {
            return nil
        }

        let scanStart = max(0, selection.location - maximumInputLength - 3)
        let scanEnd = min(source.length, selection.location + maximumInputLength)
        return context(
            in: source,
            selection: selection,
            scanStart: scanStart,
            scanEnd: scanEnd
        )
    }

    private static func context(
        in source: NSString,
        selection: NSRange,
        scanStart: Int,
        scanEnd: Int
    ) -> VariableCompletionContext? {
        var cursor = scanStart
        while cursor + 1 < selection.location {
            if isEscapedOpeningDelimiter(in: source, at: cursor) {
                cursor += 3
                continue
            }

            guard isOpeningDelimiter(in: source, at: cursor) else {
                cursor += 1
                continue
            }

            let identifierStart = cursor + 2
            var identifierEnd = identifierStart
            while identifierEnd < scanEnd,
                  isIdentifierContinuation(source.character(at: identifierEnd)) {
                identifierEnd += 1
            }

            if identifierEnd == scanEnd,
               scanEnd < source.length,
               isIdentifierContinuation(source.character(at: scanEnd)) {
                return nil
            }

            if selection.location <= identifierEnd {
                let prefixRange = NSRange(location: identifierStart, length: selection.location - identifierStart)
                let prefix = source.substring(with: prefixRange)
                guard prefix.isEmpty || TemplateEngine.isValidVariableName(prefix) else {
                    return nil
                }

                let endIndex = adjacentClosingDelimiterEnd(in: source, after: identifierEnd)
                return VariableCompletionContext(
                    prefix: prefix,
                    replacementRange: NSRange(location: cursor, length: endIndex - cursor)
                )
            }

            cursor = identifierEnd
            if cursor < source.length, source.character(at: cursor) == 0x7D {
                cursor += 1
                if cursor < source.length, source.character(at: cursor) == 0x7D {
                    cursor += 1
                }
            }
        }

        return nil
    }

    private static func isInsertionPoint(_ selection: NSRange, in source: NSString) -> Bool {
        selection.length == 0 &&
            selection.location >= 0 &&
            selection.location <= source.length
    }

    static func suggestions(
        for context: VariableCompletionContext,
        from variables: [VariableCompletion]
    ) -> [VariableCompletion] {
        var seenNames = Set<String>()
        var matches: [VariableCompletion] = []
        for variable in variables.prefix(maximumCandidatesInspected) {
            guard TemplateEngine.isValidVariableName(variable.name),
                  variable.name.hasPrefix(context.prefix),
                  seenNames.insert(variable.name).inserted else {
                continue
            }

            matches.append(variable)
            if matches.count == maximumSuggestionCount {
                break
            }
        }
        return matches.sorted { $0.name < $1.name }
    }

    static func replacement(for variable: VariableCompletion) -> String {
        "{{\(variable.name)}}"
    }

    private static func adjacentClosingDelimiterEnd(in source: NSString, after start: Int) -> Int {
        guard start < source.length, source.character(at: start) == 0x7D else {
            return start
        }

        if start + 1 < source.length, source.character(at: start + 1) == 0x7D {
            return start + 2
        }
        return start + 1
    }

    private static func isEscapedOpeningDelimiter(in source: NSString, at index: Int) -> Bool {
        index + 2 < source.length &&
            source.character(at: index) == 0x5C &&
            isOpeningDelimiter(in: source, at: index + 1)
    }

    private static func isOpeningDelimiter(in source: NSString, at index: Int) -> Bool {
        index + 1 < source.length &&
            source.character(at: index) == 0x7B &&
            source.character(at: index + 1) == 0x7B
    }

    private static func isIdentifierContinuation(_ character: unichar) -> Bool {
        (0x41...0x5A).contains(character) ||
            (0x61...0x7A).contains(character) ||
            (0x30...0x39).contains(character) ||
            character == 0x5F
    }
}
