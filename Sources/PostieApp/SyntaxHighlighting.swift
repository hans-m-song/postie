import AppKit
import Foundation
import PostieCore

enum SyntaxHighlighting {
    static let maximumInputBytes = 1_048_576

    @MainActor
    static let templateColor = NSColor(name: "PostieTemplate") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 91 / 255, green: 159 / 255, blue: 239 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 36 / 255, green: 91 / 255, blue: 168 / 255, alpha: 1)
    }

    struct Request: Hashable, Sendable {
        let text: String
        let syntax: BodySyntax
        let availableVariables: Set<String>
        let validPathParameters: Set<String>
        let isURL: Bool
        var highlightsTemplates = true
    }

    enum Color: Equatable, Sendable {
        case variable
        case pathParameter
        case missing
        case invalid
        case jsonKey
        case jsonString
        case jsonNumber
        case jsonLiteral
        case markupTagName
        case markupTagDelimiter
        case markupAttributeName
        case markupString
        case markupComment
        case markupEntity
        case markupDeclaration
        case markupCDATA
        case markupKeyword
        case markupNumber
        case markupIdentifier
        case markupPunctuation
        case markupSelector
        case markupProperty

        @MainActor
        var appKitColor: NSColor {
            switch self {
            case .variable, .pathParameter: SyntaxHighlighting.templateColor
            case .missing, .invalid: .systemRed
            case .jsonKey: .systemBlue
            case .jsonString: .systemGreen
            case .jsonNumber: .systemOrange
            case .jsonLiteral: .systemIndigo
            case .markupTagName: .systemBlue
            case .markupTagDelimiter, .markupComment, .markupPunctuation: .secondaryLabelColor
            case .markupAttributeName, .markupProperty: .systemTeal
            case .markupString: .systemGreen
            case .markupEntity, .markupNumber: .systemOrange
            case .markupDeclaration, .markupCDATA, .markupKeyword, .markupSelector: .systemPurple
            case .markupIdentifier: .systemIndigo
            }
        }
    }

    struct Span: Equatable, Sendable {
        let location: Int
        let length: Int
        let color: Color

        var range: NSRange {
            NSRange(location: location, length: length)
        }
    }

    struct Result: Sendable {
        let spans: [Span]
        let isPaused: Bool
        let isCancelled: Bool

        static let paused = Result(spans: [], isPaused: true, isCancelled: false)
        static let cancelled = Result(spans: [], isPaused: false, isCancelled: true)
    }

    private static let cache = Cache()

    static func result(for request: Request) -> Result {
        guard let inputByteLength = boundedUTF8ByteLength(request.text) else {
            return .paused
        }
        guard !Task.isCancelled else {
            return .cancelled
        }
        if let cached = cache.result(for: request) {
            return cached
        }

        let source = request.text as NSString
        var spans: [Span] = []

        if request.syntax == .json,
            !appendJSONSpans(from: source, to: &spans)
        {
            return .cancelled
        }

        if request.syntax == .html || request.syntax == .xml {
            let markupResult = MarkupLexing.tokens(in: request.text, syntax: request.syntax)
            guard !markupResult.isCancelled else {
                return .cancelled
            }
            guard !markupResult.isPaused else {
                return .paused
            }
            for token in markupResult.tokens {
                spans.append(
                    Span(
                        location: token.location,
                        length: token.length,
                        color: color(for: token.kind)
                    ))
            }
        }

        if request.isURL {
            let pathReferences = TemplateEngine.pathReferences(in: request.text)
            guard !Task.isCancelled else {
                return .cancelled
            }
            for reference in pathReferences {
                spans.append(
                    Span(
                        location: reference.range.location,
                        length: reference.range.length,
                        color: .pathParameter
                    ))
                guard request.validPathParameters.contains(reference.name) else {
                    spans.append(
                        Span(
                            location: reference.range.location + 1,
                            length: reference.range.length - 1,
                            color: .missing
                        ))
                    continue
                }
            }
        }

        if request.highlightsTemplates {
            let templates = TemplateEngine.scan(request.text)
            guard !Task.isCancelled else {
                return .cancelled
            }
            for reference in templates.references {
                spans.append(
                    Span(
                        location: reference.range.location,
                        length: reference.range.length,
                        color: request.availableVariables.contains(reference.name) ? .variable : .missing
                    ))
            }
            for range in templates.invalidRanges {
                spans.append(Span(location: range.location, length: range.length, color: .invalid))
            }
        }
        guard !Task.isCancelled else {
            return .cancelled
        }

        let result = Result(spans: spans, isPaused: false, isCancelled: false)
        cache.insert(result, for: request, inputByteLength: inputByteLength)
        return result
    }

    @MainActor
    static func apply(_ result: Result, to textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            return
        }
        let length = (textView.string as NSString).length
        guard length > 0 else {
            return
        }

        let range = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        for span in result.spans where span.length > 0 && NSMaxRange(span.range) <= length {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: span.color.appKitColor,
                forCharacterRange: span.range
            )
        }
    }

    @MainActor
    static func clearTemporaryAttributes(from textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            return
        }
        let length = (textView.string as NSString).length
        guard length > 0 else {
            return
        }
        layoutManager.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: NSRange(location: 0, length: length)
        )
    }

    private static func boundedUTF8ByteLength(_ text: String) -> Int? {
        var iterator = text.utf8.makeIterator()
        var byteLength = 0
        while byteLength <= maximumInputBytes {
            guard iterator.next() != nil else {
                return byteLength
            }
            byteLength += 1
        }
        return nil
    }

    private static func appendJSONSpans(from text: NSString, to spans: inout [Span]) -> Bool {
        var index = 0
        while index < text.length {
            if index.isMultiple(of: 4_096), Task.isCancelled {
                return false
            }

            let character = text.character(at: index)
            if character == 0x22 {
                let start = index
                index += 1
                var isEscaped = false
                while index < text.length {
                    let current = text.character(at: index)
                    index += 1
                    if isEscaped {
                        isEscaped = false
                    } else if current == 0x5C {
                        isEscaped = true
                    } else if current == 0x22 {
                        break
                    }
                }

                var lookahead = index
                while lookahead < text.length, isWhitespace(text.character(at: lookahead)) {
                    lookahead += 1
                }
                let color: Color =
                    lookahead < text.length && text.character(at: lookahead) == 0x3A
                    ? .jsonKey
                    : .jsonString
                spans.append(Span(location: start, length: index - start, color: color))
                continue
            }

            if isNumberStart(character) {
                let start = index
                index += 1
                while index < text.length, !isJSONDelimiter(text.character(at: index)) {
                    index += 1
                }
                spans.append(Span(location: start, length: index - start, color: .jsonNumber))
                continue
            }

            if isASCIIWordStart(character) {
                let start = index
                index += 1
                while index < text.length, isASCIIWordContinuation(text.character(at: index)) {
                    index += 1
                }
                let word = text.substring(with: NSRange(location: start, length: index - start))
                if word == "true" || word == "false" || word == "null" {
                    spans.append(Span(location: start, length: index - start, color: .jsonLiteral))
                }
                continue
            }

            index += 1
        }
        return !Task.isCancelled
    }

    private static func isNumberStart(_ character: unichar) -> Bool {
        character == 0x2D || (0x30...0x39).contains(character)
    }

    private static func isASCIIWordStart(_ character: unichar) -> Bool {
        (0x41...0x5A).contains(character) || (0x61...0x7A).contains(character)
    }

    private static func isASCIIWordContinuation(_ character: unichar) -> Bool {
        isASCIIWordStart(character) || (0x30...0x39).contains(character)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    private static func isJSONDelimiter(_ character: unichar) -> Bool {
        isWhitespace(character) || character == 0x2C || character == 0x3A || character == 0x5D || character == 0x7D
            || character == 0x5B || character == 0x7B
    }

    private static func color(for kind: MarkupLexing.Kind) -> Color {
        switch kind {
        case .tagName: .markupTagName
        case .tagDelimiter: .markupTagDelimiter
        case .attributeName: .markupAttributeName
        case .string: .markupString
        case .comment: .markupComment
        case .entity: .markupEntity
        case .declaration: .markupDeclaration
        case .cdata: .markupCDATA
        case .keyword: .markupKeyword
        case .number: .markupNumber
        case .identifier: .markupIdentifier
        case .punctuation: .markupPunctuation
        case .selector: .markupSelector
        case .property: .markupProperty
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Request: Result] = [:]
        private var insertionOrder: [Request] = []
        private var cost = 0
        private let maximumEntries = 12
        private let maximumCost = 6 * 1_048_576

        func result(for request: Request) -> Result? {
            lock.lock()
            defer { lock.unlock() }
            return entries[request]
        }

        func insert(_ result: Result, for request: Request, inputByteLength: Int) {
            let entryCost = inputByteLength + result.spans.count * MemoryLayout<Span>.stride
            guard entryCost <= maximumCost else {
                return
            }

            lock.lock()
            defer { lock.unlock() }

            if let existing = entries.removeValue(forKey: request) {
                cost -= inputByteLength + existing.spans.count * MemoryLayout<Span>.stride
                insertionOrder.removeAll { $0 == request }
            }

            entries[request] = result
            insertionOrder.append(request)
            cost += entryCost

            while insertionOrder.count > maximumEntries || cost > maximumCost {
                let oldest = insertionOrder.removeFirst()
                guard let removed = entries.removeValue(forKey: oldest) else {
                    continue
                }
                let removedInputByteLength = oldest.text.utf8.count
                cost -= removedInputByteLength + removed.spans.count * MemoryLayout<Span>.stride
            }
        }
    }
}

@MainActor
final class NativeHighlightingHostView: NSView {
    let textView: NSTextView
    private let pausedLabel = NSTextField(labelWithString: "Highlighting paused over 1 MiB")

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)

        textView.autoresizingMask = [.width, .height]
        addSubview(textView)

        pausedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pausedLabel.textColor = .secondaryLabelColor
        pausedLabel.backgroundColor = .controlBackgroundColor
        pausedLabel.drawsBackground = true
        pausedLabel.isBordered = false
        pausedLabel.isHidden = true
        pausedLabel.setAccessibilityLabel("Syntax highlighting paused because the text exceeds 1 MiB")
        addSubview(pausedLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlightingPaused(_ isPaused: Bool) {
        pausedLabel.isHidden = !isPaused
        needsLayout = true
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        pausedLabel.sizeToFit()
        pausedLabel.setFrameOrigin(
            NSPoint(
                x: max(4, bounds.maxX - pausedLabel.frame.width - 8),
                y: max(4, bounds.maxY - pausedLabel.frame.height - 8)
            ))
    }
}
