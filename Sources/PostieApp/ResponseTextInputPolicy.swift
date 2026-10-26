import Foundation

enum ResponseTextInputPolicy {
    static let maximumLogicalLineUTF16Length = 20_000

    enum PauseReason: Equatable, Sendable {
        case byteLimit
        case longLine

        var message: String {
            switch self {
            case .byteLimit:
                "Syntax highlighting paused because the text exceeds 1 MiB"
            case .longLine:
                "Syntax highlighting paused because a line exceeds 20,000 UTF-16 code units."
            }
        }
    }

    enum Inspection: Equatable, Sendable {
        case ready(textUTF16Length: Int)
        case paused(PauseReason)
        case cancelled
    }

    static func inspect(_ text: String) -> Inspection {
        guard !Task.isCancelled else {
            return .cancelled
        }

        var scannedScalarCount = 0
        var scannedByteCount = 0
        var currentLineUTF16Length = 0
        var textUTF16Length = 0

        for scalar in text.unicodeScalars {
            scannedScalarCount += 1
            if scannedScalarCount.isMultiple(of: 4_096), Task.isCancelled {
                return .cancelled
            }

            let value = scalar.value
            scannedByteCount += Self.utf8Length(of: value)
            guard scannedByteCount <= SyntaxHighlighting.maximumInputBytes else {
                return Task.isCancelled ? .cancelled : .paused(.byteLimit)
            }

            let scalarUTF16Length = value > 0xFFFF ? 2 : 1
            textUTF16Length += scalarUTF16Length
            if Self.isLineBreak(value) {
                currentLineUTF16Length = 0
                continue
            }

            currentLineUTF16Length += scalarUTF16Length
            if currentLineUTF16Length > maximumLogicalLineUTF16Length {
                return Task.isCancelled ? .cancelled : .paused(.longLine)
            }
        }

        guard !Task.isCancelled else {
            return .cancelled
        }

        return .ready(textUTF16Length: textUTF16Length)
    }

    private static func utf8Length(of scalar: UInt32) -> Int {
        switch scalar {
        case 0...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }

    private static func isLineBreak(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029: true
        default: false
        }
    }
}
