import Foundation

private enum BodyPreviewError: LocalizedError {
    case invalidLimit
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "The preview size must be zero or greater."
        case .unreadableFile:
            return "The response body could not be read."
        }
    }
}

public enum ResponseBodyReader {
    public static func preview(at url: URL, maximumBytes: Int = 1_048_576) throws -> BodyPreview {
        guard maximumBytes >= 0 else {
            throw BodyPreviewError.invalidLimit
        }

        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1

        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }

            let sample = try file.read(upToCount: readLimit) ?? Data()
            let isTruncated = sample.count > maximumBytes
            let previewData = Data(sample.prefix(maximumBytes))

            guard let text = decodeText(previewData, isTruncated: isTruncated), isTextual(text) else {
                return BodyPreview(
                    text: "",
                    isTruncated: isTruncated,
                    isBinary: true
                )
            }

            return BodyPreview(text: text, isTruncated: isTruncated, isBinary: false)
        } catch {
            throw BodyPreviewError.unreadableFile
        }
    }

    private static func decodeText(_ data: Data, isTruncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        guard isTruncated else {
            return nil
        }

        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return ""
        }

        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80, continuationCount < 3 {
            continuationCount += 1
            if index == 0 {
                break
            }
            index -= 1
        }

        let leadIndex = index
        let lead = bytes[leadIndex]
        let expectedLength: Int
        switch lead {
        case 0xC2...0xDF:
            expectedLength = 2
        case 0xE0...0xEF:
            expectedLength = 3
        case 0xF0...0xF4:
            expectedLength = 4
        default:
            expectedLength = 1
        }

        let suffixLength = bytes.count - leadIndex
        guard expectedLength > suffixLength else {
            return nil
        }

        return String(data: Data(bytes.prefix(leadIndex)), encoding: .utf8)
    }

    private static func isTextual(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            if codePoint == 0x09 || codePoint == 0x0A || codePoint == 0x0C || codePoint == 0x0D {
                return true
            }

            return !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
