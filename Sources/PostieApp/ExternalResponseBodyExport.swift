import AppKit
import Foundation

enum ExternalResponseBodyExport {
    enum Kind: Hashable, Sendable {
        case pdf
        case html

        var fileName: String {
            switch self {
            case .pdf: "response.pdf"
            case .html: "response.html"
            }
        }
    }

    static func pdf(from sourceURL: URL, rootURL: URL = exportRootURL) async throws -> URL {
        try await export(from: sourceURL, kind: .pdf, baseURL: nil, rootURL: rootURL)
    }

    static func html(from sourceURL: URL, baseURL: URL?, rootURL: URL = exportRootURL) async throws -> URL {
        try await export(from: sourceURL, kind: .html, baseURL: baseURL, rootURL: rootURL)
    }

    private static var exportRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PostieExternalResponses", isDirectory: true)
    }

    private static func export(from sourceURL: URL, kind: Kind, baseURL: URL?, rootURL: URL) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try writeExport(from: sourceURL, kind: kind, baseURL: baseURL, rootURL: rootURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func writeExport(from sourceURL: URL, kind: Kind, baseURL: URL?, rootURL: URL) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let directoryURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let partialURL = directoryURL.appendingPathComponent(".response-\(UUID().uuidString).partial")
        let finalURL = directoryURL.appendingPathComponent(kind.fileName)
        do {
            switch kind {
            case .pdf:
                try streamCopy(from: sourceURL, to: partialURL)
            case .html:
                let html = try CompleteHTMLSource.read(at: sourceURL)
                let standaloneHTML = try StandaloneHTMLSource.make(html, baseURL: baseURL)
                try write(standaloneHTML, to: partialURL)
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: partialURL, to: finalURL)
            return finalURL
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private static func streamCopy(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard
            fileManager.createFile(
                atPath: destinationURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else { throw ExportError.unwritable }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw ExportError.unreadable
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destinationURL)
        } catch {
            try? input.close()
            try? fileManager.removeItem(at: destinationURL)
            throw ExportError.unwritable
        }
        defer {
            try? input.close()
            try? output.close()
        }

        do {
            while true {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: 64 * 1_024) ?? Data()
                guard !bytes.isEmpty else { break }
                try output.write(contentsOf: bytes)
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func write(_ text: String, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard
            fileManager.createFile(
                atPath: destinationURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else { throw ExportError.unwritable }

        do {
            let file = try FileHandle(forWritingTo: destinationURL)
            defer { try? file.close() }
            try file.write(contentsOf: Data(text.utf8))
            try file.synchronize()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw ExportError.unwritable
        }
    }

    enum ExportError: LocalizedError {
        case unreadable
        case unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable: "The captured response body could not be read for export."
            case .unwritable: "The external response copy could not be written."
            }
        }
    }
}

@MainActor
struct ExternalResponseBodyOpeners {
    typealias OpenAction = @MainActor (URL) async throws -> Void

    let preview: OpenAction
    let browser: OpenAction

    static let system = ExternalResponseBodyOpeners(
        preview: { url in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
            else { throw OpenError.previewUnavailable }
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        },
        browser: { url in
            guard let httpsURL = URL(string: "https://example.invalid/"),
                let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL)
            else { throw OpenError.browserUnavailable }
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        }
    )

    enum OpenError: LocalizedError {
        case previewUnavailable
        case browserUnavailable

        var errorDescription: String? {
            switch self {
            case .previewUnavailable: "Preview is not available on this Mac."
            case .browserUnavailable: "No default browser is available for HTTP and HTTPS links."
            }
        }
    }
}

private enum StandaloneHTMLSource {
    private struct Attribute {
        let name: String
        let nameRange: Range<Int>
        let valueRange: Range<Int>?
    }

    private struct Tag {
        let name: String
        let range: Range<Int>
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: [Attribute]
    }

    static func make(_ html: String, baseURL: URL?) throws -> String {
        guard let capturedBaseURL = baseURL,
            let baseURL = ResponseBodyPresentationPolicy.htmlBaseURL(for: capturedBaseURL)
        else { return html }
        var source = Array(html.utf8)
        let tags = effectiveTags(in: source)
        try Task.checkCancellation()
        if let base = tags.first(where: {
            $0.name == "base" && !$0.isClosing && $0.attributes.contains(where: { $0.name == "href" })
        }) {
            let href = base.attributes.first(where: { $0.name == "href" })
            if let href, let range = href.valueRange {
                let rawValue = String(decoding: source[range], as: UTF8.self)
                let decodedValue = try decodeEntities(rawValue)
                try Task.checkCancellation()
                guard let resolvedURL = URL(string: decodedValue, relativeTo: baseURL)?.absoluteURL else {
                    throw SourceError.unresolvableBase
                }
                if resolvedURL.scheme != nil {
                    let sourceValue = String(decoding: source[range], as: UTF8.self)
                    if URL(string: sourceValue)?.scheme != nil { return html }
                }
                let value = attributeValue(resolvedURL.absoluteString)
                source.replaceSubrange(range, with: value.utf8)
                return String(decoding: source, as: UTF8.self)
            }
            if let href {
                let value = "=\"\(attributeValue(baseURL.absoluteString))\""
                source.insert(contentsOf: value.utf8, at: href.nameRange.upperBound)
                return String(decoding: source, as: UTF8.self)
            }
        }

        let baseTag = "<base href=\"\(attributeValue(baseURL.absoluteString))\">"
        if let head = tags.first(where: { $0.name == "head" && !$0.isClosing }) {
            source.insert(contentsOf: baseTag.utf8, at: head.range.upperBound)
        } else if let htmlTag = tags.first(where: { $0.name == "html" && !$0.isClosing }) {
            source.insert(contentsOf: "<head>\(baseTag)</head>".utf8, at: htmlTag.range.upperBound)
        } else if let bodyTag = tags.first(where: { $0.name == "body" && !$0.isClosing }) {
            source.insert(contentsOf: "<head>\(baseTag)</head>".utf8, at: bodyTag.range.lowerBound)
        } else {
            let insertionPoint = leadingDeclarationEnd(in: source)
            try Task.checkCancellation()
            source.insert(contentsOf: "<head>\(baseTag)</head>".utf8, at: insertionPoint)
        }
        return String(decoding: source, as: UTF8.self)
    }

    private static func effectiveTags(in source: [UInt8]) -> [Tag] {
        var result: [Tag] = []
        var templateDepth = 0
        for tag in tags(in: source) {
            if tag.name == "template" {
                if tag.isClosing { templateDepth = max(0, templateDepth - 1) } else { templateDepth += 1 }
                continue
            }
            if templateDepth == 0 { result.append(tag) }
        }
        return result
    }

    private static func tags(in source: [UInt8]) -> [Tag] {
        var result: [Tag] = []
        var position = 0
        var rawTextTag: String?
        while position < source.count {
            if position & 1_023 == 0, Task.isCancelled { return result }
            if let activeRawTextTag = rawTextTag {
                guard activeRawTextTag != "plaintext",
                    let close = rawTextEnd(in: source, from: position, name: activeRawTextTag)
                else { break }
                position = close
                rawTextTag = nil
            }
            guard source[position] == 60 else { position += 1; continue }
            if matches(source, at: position, "<!--") {
                position = after(source, from: position + 4, marker: "-->") ?? source.count
                continue
            }
            if matches(source, at: position, "<![CDATA[") {
                position = after(source, from: position + 9, marker: "]]>") ?? source.count
                continue
            }
            if matches(source, at: position, "<!") || matches(source, at: position, "<?") {
                position = declarationEnd(in: source, from: position) ?? source.count
                continue
            }
            guard let tag = tag(in: source, from: position) else { position += 1; continue }
            result.append(tag)
            position = tag.range.upperBound
            if !tag.isClosing, !tag.isSelfClosing, isRawText(tag.name) { rawTextTag = tag.name }
        }
        return result
    }

    private static func rawTextEnd(in source: [UInt8], from position: Int, name: String) -> Int? {
        var cursor = position
        while cursor < source.count {
            if cursor & 1_023 == 0, Task.isCancelled { return nil }
            guard source[cursor] == 60, cursor + 2 < source.count,
                source[cursor + 1] == 47,
                matches(source, at: cursor + 2, name)
            else { cursor += 1; continue }
            let end = cursor + 2 + name.utf8.count
            guard end == source.count || isSpace(source[end]) || source[end] == 62 || source[end] == 47 else {
                cursor += 1
                continue
            }
            return cursor
        }
        return nil
    }

    private static func tag(in source: [UInt8], from start: Int) -> Tag? {
        var cursor = start + 1
        var isClosing = false
        if cursor < source.count, source[cursor] == 47 { isClosing = true; cursor += 1 }
        guard cursor < source.count, isNameByte(source[cursor]) else { return nil }
        let nameStart = cursor
        while cursor < source.count, isNameByte(source[cursor]) { cursor += 1 }
        let name = String(decoding: source[nameStart..<cursor], as: UTF8.self).lowercased()
        var attributes: [Attribute] = []
        var isSelfClosing = false
        while cursor < source.count {
            if cursor & 1_023 == 0, Task.isCancelled { return nil }
            while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
            guard cursor < source.count else { return nil }
            if source[cursor] == 62 {
                return Tag(
                    name: name, range: start..<(cursor + 1), isClosing: isClosing,
                    isSelfClosing: isSelfClosing, attributes: attributes)
            }
            if source[cursor] == 47, cursor + 1 < source.count, source[cursor + 1] == 62 {
                isSelfClosing = true
                return Tag(
                    name: name, range: start..<(cursor + 2), isClosing: isClosing,
                    isSelfClosing: isSelfClosing, attributes: attributes)
            }
            let attributeStart = cursor
            while cursor < source.count, !isSpace(source[cursor]), source[cursor] != 61,
                source[cursor] != 62, source[cursor] != 47
            { cursor += 1 }
            guard cursor > attributeStart else { cursor += 1; continue }
            let attributeNameEnd = cursor
            let attributeName = String(decoding: source[attributeStart..<cursor], as: UTF8.self).lowercased()
            while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
            guard cursor < source.count, source[cursor] == 61 else {
                attributes.append(
                    Attribute(name: attributeName, nameRange: attributeStart..<attributeNameEnd, valueRange: nil))
                continue
            }
            cursor += 1
            while cursor < source.count, isSpace(source[cursor]) { cursor += 1 }
            guard cursor < source.count else { return nil }
            let quote = source[cursor] == 34 || source[cursor] == 39 ? source[cursor] : nil
            if let quote {
                cursor += 1
                let valueStart = cursor
                while cursor < source.count, source[cursor] != quote { cursor += 1 }
                guard cursor < source.count else { return nil }
                attributes.append(
                    Attribute(
                        name: attributeName, nameRange: attributeStart..<attributeNameEnd,
                        valueRange: valueStart..<cursor))
                cursor += 1
            } else {
                let valueStart = cursor
                while cursor < source.count, !isSpace(source[cursor]), source[cursor] != 62 { cursor += 1 }
                attributes.append(
                    Attribute(
                        name: attributeName, nameRange: attributeStart..<attributeNameEnd,
                        valueRange: valueStart..<cursor))
            }
        }
        return nil
    }

    private static func decodeEntities(_ source: String) throws -> String {
        let named: [String: String] = [
            "amp": "&", "AMP": "&", "apos": "'", "colon": ":", "commat": "@", "dollar": "$",
            "equals": "=", "excl": "!", "gt": ">", "GT": ">", "lpar": "(", "lt": "<", "LT": "<",
            "num": "#", "percnt": "%", "period": ".", "plus": "+", "quest": "?", "quot": "\"", "QUOT": "\"",
            "semi": ";", "sol": "/", "bsol": "\\", "lowbar": "_", "hyphen": "-", "ast": "*", "comma": ",",
            "lbrack": "[", "rbrack": "]", "lcub": "{", "rcub": "}", "Hat": "^", "grave": "`", "verbar": "|",
        ]
        let bytes = Array(source.utf8)
        var result = [UInt8]()
        var position = 0
        while position < bytes.count {
            if position & 1_023 == 0 { try Task.checkCancellation() }
            guard bytes[position] == 38 else { result.append(bytes[position]); position += 1; continue }
            var semicolon = position + 1
            let entityStart = semicolon
            while semicolon < bytes.count, semicolon - entityStart < 64,
                bytes[semicolon] != 59, bytes[semicolon] != 38
            { semicolon += 1 }
            guard semicolon < bytes.count, bytes[semicolon] == 59 else {
                result.append(38)
                position += 1
                continue
            }
            let entity = String(decoding: bytes[(position + 1)..<semicolon], as: UTF8.self)
            if entity.first == "#" {
                let numberText = entity.dropFirst()
                let radix = numberText.first == "x" || numberText.first == "X" ? 16 : 10
                let digits = radix == 16 ? numberText.dropFirst() : numberText[...]
                guard let scalarValue = UInt32(digits, radix: radix),
                    let scalar = Unicode.Scalar(scalarValue)
                else { throw SourceError.unresolvableBase }
                result.append(contentsOf: String(scalar).utf8)
            } else if let value = named[entity] {
                result.append(contentsOf: value.utf8)
            } else if entity.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            }) {
                throw SourceError.unsupportedBaseEntity
            } else {
                result.append(contentsOf: bytes[position...semicolon])
            }
            position = semicolon + 1
        }
        guard let decoded = String(bytes: result, encoding: .utf8) else { throw SourceError.unresolvableBase }
        return decoded
    }

    private static func attributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func matches(_ source: [UInt8], at position: Int, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard position <= source.count - bytes.count else { return false }
        return bytes.enumerated().allSatisfy { offset, byte in
            lower(source[position + offset]) == lower(byte)
        }
    }

    private static func after(_ source: [UInt8], from position: Int, marker: String) -> Int? {
        var cursor = position
        while cursor < source.count {
            if cursor & 1_023 == 0, Task.isCancelled { return nil }
            if matches(source, at: cursor, marker) { return cursor + marker.utf8.count }
            cursor += 1
        }
        return nil
    }

    private static func declarationEnd(in source: [UInt8], from position: Int) -> Int? {
        var cursor = position + 2
        var quote: UInt8?
        while cursor < source.count {
            if cursor & 1_023 == 0, Task.isCancelled { return nil }
            let byte = source[cursor]
            if let currentQuote = quote {
                if byte == currentQuote { quote = nil }
            } else if byte == 34 || byte == 39 {
                quote = byte
            } else if byte == 62 {
                return cursor + 1
            }
            cursor += 1
        }
        return nil
    }

    private static func leadingDeclarationEnd(in source: [UInt8]) -> Int {
        var cursor = 0
        while cursor < source.count {
            if cursor & 1_023 == 0, Task.isCancelled { return cursor }
            if isSpace(source[cursor]) { cursor += 1; continue }
            if matches(source, at: cursor, "<!--") {
                guard let end = after(source, from: cursor + 4, marker: "-->") else { return source.count }
                cursor = end
                continue
            }
            if matches(source, at: cursor, "<!doctype") || matches(source, at: cursor, "<?") {
                guard let end = declarationEnd(in: source, from: cursor) else { return source.count }
                cursor = end
                continue
            }
            return cursor
        }
        return cursor
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 58
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    private static func isRawText(_ name: String) -> Bool {
        ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"].contains(name)
    }

    enum SourceError: LocalizedError {
        case unresolvableBase
        case unsupportedBaseEntity

        var errorDescription: String? {
            switch self {
            case .unresolvableBase:
                "The captured HTML has a relative base URL that cannot be resolved safely for export."
            case .unsupportedBaseEntity:
                "The captured HTML uses a character reference in a relative base URL that cannot be resolved safely for export."
            }
        }
    }
}
