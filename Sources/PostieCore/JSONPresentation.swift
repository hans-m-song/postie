import Foundation

public enum JSONPresentation {
    public static let maximumBytes = 5 * 1_048_576

    public static func pretty(at url: URL, maximumBytes: Int = maximumBytes) throws -> String {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw PresentationError.tooLarge }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) }
        catch { throw PresentationError.unreadable }
        defer { try? file.close() }
        let data: Data
        do { data = try file.read(upToCount: maximumBytes + 1) ?? Data() }
        catch { throw PresentationError.unreadable }
        guard data.count <= maximumBytes else { throw PresentationError.tooLarge }
        return try pretty(data, maximumBytes: maximumBytes)
    }

    public static func pretty(_ data: Data, maximumBytes: Int = maximumBytes) throws -> String {
        guard maximumBytes > 0, data.count <= maximumBytes else { throw PresentationError.tooLarge }
        guard String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw PresentationError.invalidJSON
        }
        let source = Array(data)
        var output = Data()
        var depth = 0
        var quoted = false
        var escaped = false
        var previous: UInt8?

        func append(_ bytes: [UInt8]) throws {
            guard output.count <= maximumBytes - bytes.count else { throw PresentationError.tooLarge }
            output.append(contentsOf: bytes)
        }
        func line() throws {
            guard depth <= maximumBytes / 2 else { throw PresentationError.tooLarge }
            try append([10])
            guard output.count <= maximumBytes - depth * 2 else { throw PresentationError.tooLarge }
            output.append(contentsOf: repeatElement(UInt8(32), count: depth * 2))
        }
        for (index, byte) in source.enumerated() {
            if quoted {
                try append([byte])
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if [9, 10, 13, 32].contains(byte) { continue }
            switch byte {
            case 34:
                quoted = true
                try append([byte])
            case 123, 91:
                try append([byte])
                depth += 1
                let next = source[(index + 1)...].first { ![9, 10, 13, 32].contains($0) }
                if next != (byte == 123 ? 125 : 93) { try line() }
            case 125, 93:
                depth = max(0, depth - 1)
                if previous != (byte == 125 ? 123 : 91) { try line() }
                try append([byte])
            case 44:
                try append([byte])
                try line()
            case 58:
                try append([58, 32])
            default:
                try append([byte])
            }
            previous = byte
        }
        return String(decoding: output, as: UTF8.self)
    }

    public enum PresentationError: LocalizedError {
        case unreadable, invalidJSON, tooLarge

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The response body could not be read."
            case .invalidJSON: "Pretty view requires a complete, valid UTF-8 JSON body. Raw remains available."
            case .tooLarge: "Pretty view is limited to 5 MiB of input and formatted output. Raw remains available."
            }
        }
    }
}
