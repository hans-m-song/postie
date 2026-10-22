import Foundation

public enum MarkupPresentation {
    public static let maximumBytes = 5 * 1_048_576

    public static func pretty(
        at url: URL, syntax: BodySyntax, maximumBytes: Int = maximumBytes
    ) throws -> String {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw PresentationError.tooLarge }
        let limit = min(maximumBytes, Self.maximumBytes)
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) } catch { throw PresentationError.unreadable }
        defer { try? file.close() }
        let data: Data
        do { data = try file.read(upToCount: limit + 1) ?? Data() } catch { throw PresentationError.unreadable }
        try Task.checkCancellation()
        guard data.count <= limit else { throw PresentationError.tooLarge }
        return try pretty(data, syntax: syntax, maximumBytes: limit)
    }

    public static func pretty(
        _ data: Data, syntax: BodySyntax, maximumBytes: Int = maximumBytes
    ) throws -> String {
        try Task.checkCancellation()
        guard maximumBytes > 0, data.count <= min(maximumBytes, Self.maximumBytes) else {
            throw PresentationError.tooLarge
        }
        guard syntax == .html || syntax == .xml, let text = String(data: data, encoding: .utf8) else {
            throw PresentationError.invalidMarkup
        }
        var scanner = MarkupScanner(text, syntax: syntax, collectTokens: false)
        scanner.scan()
        if scanner.cancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard scanner.valid else { throw PresentationError.invalidMarkup }
        return try project(scanner, text: text, maximumBytes: min(maximumBytes, Self.maximumBytes))
    }

    private struct Frame {
        let index: Int
        let name: String
        var preserve: Bool
        var hasStructure = false
    }

    private static func project(_ scanner: MarkupScanner, text: String, maximumBytes: Int) throws -> String {
        let pieces = scanner.pieces
        var stack: [Frame] = []
        var ends: [Int: Int] = [:]
        var preserved: Set<Int> = []
        var roots = 0
        var preserveDocument = false
        for (index, piece) in pieces.enumerated() {
            if index & 255 == 0 { try Task.checkCancellation() }
            switch piece.form {
            case .start:
                if stack.isEmpty { roots += 1 } else { stack[stack.count - 1].hasStructure = true }
                guard stack.count < 256 else { throw PresentationError.tooLarge }
                stack.append(Frame(index: index, name: piece.name, preserve: piece.protected))
            case .end:
                guard let frame = stack.popLast(), frame.name == piece.name else {
                    throw PresentationError.invalidMarkup
                }
                ends[frame.index] = index
                if frame.preserve || !frame.hasStructure { preserved.insert(frame.index) }
            case .text:
                if !piece.whitespace {
                    if stack.isEmpty {
                        if scanner.syntax == .xml {
                            let prefix = String(decoding: scanner.units[piece.range], as: UTF16.self)
                            guard piece.range.lowerBound == 0,
                                prefix.trimmingCharacters(in: .whitespacesAndNewlines) == "\u{FEFF}"
                            else { throw PresentationError.invalidMarkup }
                        }
                        preserveDocument = true
                    } else {
                        stack[stack.count - 1].preserve = true
                    }
                }
            case .standalone:
                if stack.isEmpty {
                    if !piece.name.isEmpty { roots += 1 }
                    if piece.protected && scanner.syntax == .xml { throw PresentationError.invalidMarkup }
                } else {
                    stack[stack.count - 1].hasStructure = true
                    if piece.protected { stack[stack.count - 1].preserve = true }
                }
            }
        }
        guard stack.isEmpty, roots > 0, scanner.syntax != .xml || roots == 1 else {
            throw PresentationError.invalidMarkup
        }
        if preserveDocument { return text }
        var output = Data()
        var depth = 0
        var index = 0
        func append(_ range: Range<Int>, depth: Int) throws {
            try Task.checkCancellation()
            let chunk = Data(String(decoding: scanner.units[range], as: UTF16.self).utf8)
            let padding = output.isEmpty ? 0 : 1 + depth * 2
            guard chunk.count <= maximumBytes - output.count,
                padding <= maximumBytes - output.count - chunk.count
            else { throw PresentationError.tooLarge }
            if !output.isEmpty {
                output.append(10)
                output.append(contentsOf: repeatElement(UInt8(32), count: depth * 2))
            }
            output.append(chunk)
        }
        while index < pieces.count {
            let piece = pieces[index]
            if piece.form == .text { index += 1; continue }
            if piece.form == .end { depth -= 1 }
            if piece.form == .start, preserved.contains(index), let end = ends[index] {
                try append(piece.range.lowerBound..<pieces[end].range.upperBound, depth: depth)
                index = end + 1
                continue
            }
            try append(piece.range, depth: depth)
            if piece.form == .start { depth += 1 }
            index += 1
        }
        try Task.checkCancellation()
        return String(decoding: output, as: UTF8.self)
    }

    public enum PresentationError: LocalizedError, Equatable {
        case unreadable, invalidMarkup, tooLarge

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The response body could not be read."
            case .invalidMarkup:
                "Pretty view requires complete UTF-8 markup supported by the conservative formatter. Raw remains available."
            case .tooLarge:
                "Markup Pretty view is limited to 5 MiB of input and output and 256 nested elements. Raw remains available."
            }
        }
    }
}
