import Foundation

struct MarkupScanner {
    enum Form { case text, start, end, standalone }

    struct Piece {
        let range: Range<Int>
        let form: Form
        var name = ""
        var protected = false
        var whitespace = false
    }

    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let rawTags: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext",
    ]

    let units: [UInt16]
    let syntax: BodySyntax
    let collectTokens: Bool
    var tokens: [MarkupLexing.Token] = []
    var pieces: [Piece] = []
    var valid = true
    var cancelled = false
    private var position = 0

    init(_ text: String, syntax: BodySyntax, collectTokens: Bool = true) {
        units = Array(text.utf16)
        self.syntax = syntax
        self.collectTokens = collectTokens
    }

    mutating func scan() {
        while position < units.count {
            if checkCancellation() { return }
            let start = position
            if units[position] != 60 {
                while position < units.count && units[position] != 60 {
                    if checkCancellation() { return }
                    if units[position] == 38 { entity() } else { position += 1 }
                }
                pieces.append(
                    Piece(
                        range: start..<position, form: .text,
                        whitespace: units[start..<position].allSatisfy(Self.space)))
                continue
            }
            if matches("<!--", at: position) {
                delimited("-->", prefix: 4, kind: .comment)
            } else if matches("<![CDATA[", at: position) {
                delimited("]]>", prefix: 9, kind: .cdata, protected: true)
            } else if matches("<?", at: position) {
                delimited("?>", prefix: 2, kind: .declaration)
            } else if matches("<!", at: position) {
                declaration()
            } else {
                tag()
            }
            if start == position { valid = false; position += 1 }
        }
        if Task.isCancelled { cancelled = true }
    }

    private mutating func checkCancellation() -> Bool {
        if position & 1023 == 0 && Task.isCancelled { cancelled = true }
        return cancelled
    }

    private func matches(_ value: String, at offset: Int, folded: Bool = false) -> Bool {
        let expected = value.utf16
        guard offset <= units.count - expected.count else { return false }
        for (index, expectedUnit) in expected.enumerated() {
            let unit = units[offset + index]
            if (folded ? Self.lower(unit) : unit) != expectedUnit { return false }
        }
        return true
    }

    private mutating func emit(_ start: Int, _ end: Int, _ kind: MarkupLexing.Kind) {
        guard collectTokens && end > start else { return }
        tokens.append(.init(location: start, length: end - start, kind: kind))
    }

    private mutating func delimited(
        _ suffix: String, prefix: Int, kind: MarkupLexing.Kind, protected: Bool = false
    ) {
        let start = position
        position += prefix
        while position < units.count && !matches(suffix, at: position) {
            if checkCancellation() { return }
            position += 1
        }
        if position == units.count { valid = false } else { position += suffix.utf16.count }
        emit(start, position, kind)
        pieces.append(Piece(range: start..<position, form: .standalone, protected: protected))
    }

    private mutating func declaration() {
        let start = position
        position += 2
        var quote: UInt16?
        var brackets = 0
        var complete = false
        while position < units.count {
            if checkCancellation() { return }
            let unit = units[position]
            position += 1
            if let current = quote {
                if unit == current { quote = nil }
                continue
            }
            if unit == 34 || unit == 39 { quote = unit }
            if unit == 91 { brackets += 1 }
            if unit == 93 { brackets = max(0, brackets - 1) }
            if unit == 62 && brackets == 0 { complete = true; break }
        }
        if !complete { valid = false }
        emit(start, position, .declaration)
        pieces.append(Piece(range: start..<position, form: .standalone))
    }

    private mutating func entity() {
        let start = position
        position += 1
        while position < units.count && Self.entityUnit(units[position]) {
            if checkCancellation() { return }
            position += 1
        }
        if position < units.count && units[position] == 59 && position > start + 1 {
            position += 1
            if validEntity((start + 1)..<(position - 1)) {
                emit(start, position, .entity)
            } else if syntax == .xml {
                valid = false
            }
        } else if syntax == .xml {
            valid = false
        }
    }

    private mutating func tag() {
        let start = position
        position += 1
        let closing = position < units.count && units[position] == 47
        if closing { position += 1 }
        emit(start, position, .tagDelimiter)
        let nameStart = position
        guard position < units.count && Self.nameStart(units[position]) else { valid = false; return }
        while position < units.count && Self.nameUnit(units[position]) {
            if checkCancellation() { return }
            position += 1
        }
        let name = string(nameStart..<position, folded: syntax == .html)
        emit(nameStart, position, .tagName)
        var attributes: [String: String] = [:]
        var selfClosing = false
        var complete = false
        while position < units.count {
            if checkCancellation() { return }
            let beforeSpace = position
            skipSpace()
            guard position < units.count else { break }
            if matches("/>", at: position) || units[position] == 62 {
                let delimiter = position
                selfClosing = units[position] == 47
                position += selfClosing ? 2 : 1
                emit(delimiter, position, .tagDelimiter)
                complete = true
                break
            }
            let attributeStart = position
            if beforeSpace == position { valid = false }
            guard !closing && Self.nameStart(units[position]) else { valid = false; position += 1; continue }
            while position < units.count && Self.nameUnit(units[position]) {
                if checkCancellation() { return }
                position += 1
            }
            let attribute = string(attributeStart..<position, folded: syntax == .html)
            if syntax == .xml && attributes[attribute] != nil { valid = false }
            emit(attributeStart, position, .attributeName)
            let attributeEnd = position
            skipSpace()
            guard position < units.count && units[position] == 61 else {
                if syntax == .xml { valid = false }
                attributes[attribute] = ""
                position = attributeEnd
                continue
            }
            emit(position, position + 1, .punctuation)
            position += 1
            skipSpace()
            guard position < units.count else { valid = false; break }
            let valueStart = position
            let quote = units[position]
            if quote == 34 || quote == 39 {
                position += 1
                let contentStart = position
                while position < units.count && units[position] != quote {
                    if checkCancellation() { return }
                    if syntax == .xml && units[position] == 60 { valid = false }
                    position += 1
                }
                attributes[attribute] = string(contentStart..<position)
                if position == units.count { valid = false } else { position += 1 }
            } else {
                if syntax == .xml { valid = false }
                while position < units.count && !Self.space(units[position]) && units[position] != 62 {
                    if checkCancellation() { return }
                    position += 1
                }
                attributes[attribute] = string(valueStart..<position)
            }
            attributeValueTokens(valueStart..<position)
        }
        if !complete { valid = false }
        if closing && selfClosing { valid = false }
        let isVoid = syntax == .html && Self.voidTags.contains(name)
        if syntax == .html && selfClosing && !isVoid { valid = false }
        let protected =
            [
                "pre", "listing", "noscript", "plaintext", "textarea", "script", "style", "title", "xmp", "iframe",
                "noembed", "noframes",
            ]
            .contains(name) || attributes["xml:space"].map { $0 != "default" } == true
        pieces.append(
            Piece(
                range: start..<position, form: closing ? .end : (selfClosing || isVoid ? .standalone : .start),
                name: name, protected: protected))
        guard complete && !closing && !selfClosing && syntax == .html && Self.rawTags.contains(name) else { return }
        rawText(name: name, attributes: attributes)
    }

    private mutating func rawText(name: String, attributes: [String: String]) {
        let start = position
        let closingTag = "</" + name
        while position < units.count {
            if checkCancellation() { return }
            if name != "plaintext" && units[position] == 60 && matches(closingTag, at: position, folded: true) {
                let next = position + name.utf16.count + 2
                if next == units.count || Self.space(units[next]) || units[next] == 62 || units[next] == 47 { break }
            }
            position += 1
        }
        let end = position
        pieces.append(Piece(range: start..<end, form: .text, protected: true))
        if collectTokens {
            let type =
                attributes["type", default: ""].split(separator: ";", maxSplits: 1)
                .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
            if name == "style" && (type.isEmpty || type == "text/css") {
                embedded(start..<end, language: .css)
            } else if name == "script" {
                if type.isEmpty || type == "module" || Self.javaScriptTypes.contains(type) {
                    embedded(start..<end, language: .javaScript)
                } else if type == "importmap" || type == "speculationrules" || type == "application/json"
                    || type == "text/json" || type.hasSuffix("+json")
                {
                    embedded(start..<end, language: .json)
                }
            } else if name == "textarea" || name == "title" {
                position = start
                while position < end {
                    if checkCancellation() { return }
                    if units[position] == 38 { entity() } else { position += 1 }
                }
            }
        }
        position = end
    }

    private static let javaScriptTypes: Set<String> = [
        "application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
        "text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
        "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript",
        "text/x-ecmascript", "text/x-javascript",
    ]

    private mutating func skipSpace() {
        while position < units.count && Self.space(units[position]) {
            if checkCancellation() { return }
            position += 1
        }
    }

    private func string(_ range: Range<Int>, folded: Bool = false) -> String {
        let value = String(decoding: units[range], as: UTF16.self)
        return folded ? value.lowercased() : value
    }

    static func space(_ unit: UInt16) -> Bool { unit == 9 || unit == 10 || unit == 13 || unit == 32 }
    private static func lower(_ unit: UInt16) -> UInt16 { (65...90).contains(unit) ? unit + 32 : unit }
    private static func nameStart(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 58 || unit >= 128
    }
    private static func nameUnit(_ unit: UInt16) -> Bool {
        nameStart(unit) || (48...57).contains(unit) || unit == 45 || unit == 46
    }
    private static func entityUnit(_ unit: UInt16) -> Bool { nameUnit(unit) || unit == 35 }

    private static func embeddedNameStart(_ unit: UInt16) -> Bool {
        (nameStart(unit) && unit != 58) || unit == 36
    }

    private static func embeddedNameUnit(_ unit: UInt16, css: Bool) -> Bool {
        embeddedNameStart(unit) || (48...57).contains(unit) || (css && unit == 45)
    }

    private func validEntity(_ range: Range<Int>) -> Bool {
        guard let first = units[range].first else { return false }
        if first != 35 { return Self.nameStart(first) && units[range].allSatisfy(Self.nameUnit) }
        let start = range.lowerBound + 1
        guard start < range.upperBound else { return false }
        if units[start] == 120 {
            return start + 1 < range.upperBound
                && units[(start + 1)..<range.upperBound].allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
        }
        return units[start..<range.upperBound].allSatisfy { (48...57).contains($0) }
    }

    private mutating func attributeValueTokens(_ range: Range<Int>) {
        var cursor = range.lowerBound
        var segment = cursor
        while cursor < range.upperBound {
            if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
            guard units[cursor] == 38 else { cursor += 1; continue }
            let start = cursor
            cursor += 1
            while cursor < range.upperBound && Self.entityUnit(units[cursor]) {
                if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
                cursor += 1
            }
            guard cursor < range.upperBound && units[cursor] == 59 && validEntity((start + 1)..<cursor) else {
                if syntax == .xml { valid = false }
                continue
            }
            emit(segment, start, .string)
            cursor += 1
            emit(start, cursor, .entity)
            segment = cursor
        }
        emit(segment, range.upperBound, .string)
    }

    private enum EmbeddedLanguage { case css, javaScript, json }

    private mutating func embedded(_ range: Range<Int>, language: EmbeddedLanguage) {
        var cursor = range.lowerBound
        var braces = 0
        var value = false
        let keywords: Set<String> = [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
            "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if",
            "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch",
            "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
        ]
        while cursor < range.upperBound {
            if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
            let start = cursor
            let unit = units[cursor]
            if Self.space(unit) { cursor += 1; continue }
            if unit == 34 || unit == 39 || (unit == 96 && language == .javaScript) {
                cursor += 1
                while cursor < range.upperBound {
                    let current = units[cursor]
                    cursor += 1
                    if Task.isCancelled { cancelled = true; return }
                    if current == 92 && cursor < range.upperBound { cursor += 1; continue }
                    if current == unit { break }
                }
                emit(start, cursor, .string)
                continue
            }
            if unit == 47 && cursor + 1 < range.upperBound && language != .json
                && (units[cursor + 1] == 42 || (units[cursor + 1] == 47 && language == .javaScript))
            {
                let block = units[cursor + 1] == 42
                cursor += 2
                while cursor < range.upperBound {
                    if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
                    if !block && (units[cursor] == 10 || units[cursor] == 13) { break }
                    if block && cursor + 1 < range.upperBound && units[cursor] == 42 && units[cursor + 1] == 47 {
                        cursor += 2; break
                    }
                    cursor += 1
                }
                emit(start, cursor, .comment)
                continue
            }
            if (48...57).contains(unit)
                || (unit == 45 && cursor + 1 < range.upperBound && (48...57).contains(units[cursor + 1]))
            {
                cursor += 1
                while cursor < range.upperBound
                    && ((48...57).contains(units[cursor])
                        || [UInt16(46), 101, 69, 43, 45].contains(units[cursor]))
                {
                    if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
                    cursor += 1
                }
                emit(start, cursor, .number)
                continue
            }
            if Self.embeddedNameStart(unit) || (language == .css && [UInt16(46), 35, 64, 45].contains(unit)) {
                cursor += 1
                while cursor < range.upperBound && Self.embeddedNameUnit(units[cursor], css: language == .css) {
                    if cursor & 1023 == 0 && Task.isCancelled { cancelled = true; return }
                    cursor += 1
                }
                let word = string(start..<cursor)
                let kind: MarkupLexing.Kind
                if language == .css {
                    kind = braces == 0 ? .selector : (value ? .identifier : .property)
                } else {
                    kind = keywords.contains(word) ? .keyword : .identifier
                }
                emit(start, cursor, kind)
                continue
            }
            if unit == 123 { braces += 1; value = false }
            if unit == 125 { braces = max(0, braces - 1); value = false }
            if unit == 58 { value = true }
            if unit == 59 { value = false }
            cursor += 1
            emit(start, cursor, .punctuation)
        }
    }
}
