import Foundation

public enum MarkupLexing {
    public static let maximumInputBytes = 1_048_576

    public enum Kind: Sendable, Equatable {
        case tagName, tagDelimiter, attributeName, string, comment, entity, declaration, cdata
        case keyword, number, identifier, punctuation, selector, property
    }

    public struct Token: Sendable, Equatable {
        public let location: Int
        public let length: Int
        public let kind: Kind

        public init(location: Int, length: Int, kind: Kind) {
            self.location = location
            self.length = length
            self.kind = kind
        }
    }

    public struct Result: Sendable, Equatable {
        public let tokens: [Token]
        public let isPaused: Bool
        public let isCancelled: Bool
    }

    public static func tokens(in text: String, syntax: BodySyntax) -> Result {
        guard !Task.isCancelled else { return Result(tokens: [], isPaused: false, isCancelled: true) }
        guard text.utf8.count <= maximumInputBytes else {
            return Result(tokens: [], isPaused: true, isCancelled: false)
        }
        guard syntax == .html || syntax == .xml else {
            return Result(tokens: [], isPaused: false, isCancelled: false)
        }
        var scanner = MarkupScanner(text, syntax: syntax)
        scanner.scan()
        return Result(
            tokens: scanner.cancelled ? [] : scanner.tokens, isPaused: false, isCancelled: scanner.cancelled)
    }
}
