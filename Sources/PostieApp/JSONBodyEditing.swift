import Foundation

struct JSONBodyStringStateCache {
    struct State {
        fileprivate(set) var isInsideString = false
        fileprivate(set) var isEscaped = false
    }

    private struct Checkpoint {
        let location: Int
        let state: State
    }

    private let checkpointInterval = 2_048
    private var checkpoints = [Checkpoint(location: 0, state: State())]

    mutating func invalidate(from location: Int) {
        let unchangedPrefixEnd = max(0, location)
        checkpoints.removeAll { $0.location > unchangedPrefixEnd }
    }

    mutating func state(in source: NSString, before location: Int) -> State? {
        guard location >= 0, location <= source.length,
              let checkpoint = checkpoints.last(where: { $0.location <= location }) else {
            return nil
        }

        var state = checkpoint.state
        var cursor = checkpoint.location
        while cursor < location {
            consume(source.character(at: cursor), into: &state)
            cursor += 1
            guard cursor.isMultiple(of: checkpointInterval),
                  checkpoints.last?.location != cursor else {
                continue
            }
            checkpoints.append(Checkpoint(location: cursor, state: state))
        }
        return state
    }

    private func consume(_ character: unichar, into state: inout State) {
        if state.isInsideString {
            if state.isEscaped {
                state.isEscaped = false
            } else if character == 0x5C {
                state.isEscaped = true
            } else if character == 0x22 {
                state.isInsideString = false
            }
            return
        }

        if character == 0x22 {
            state.isInsideString = true
            state.isEscaped = false
        }
    }
}

enum JSONBodyEditing {
    enum InputKind: Equatable {
        case typing
        case backspace
        case other
    }

    enum Edit: Equatable {
        case replace(range: NSRange, with: String, selection: NSRange)
        case moveCaret(to: Int)
    }

    static func edit(
        in value: String,
        range: NSRange,
        replacement: String,
        inputKind: InputKind,
        stringStateCache: inout JSONBodyStringStateCache
    ) -> Edit? {
        let source = value as NSString
        guard range.location >= 0,
              range.location <= source.length,
              range.length >= 0,
              range.length <= source.length - range.location else {
            return nil
        }

        stringStateCache.invalidate(from: range.location)
        guard let state = stringStateCache.state(in: source, before: range.location) else {
            return nil
        }

        if inputKind == .backspace,
           replacement.isEmpty,
           range.length == 1,
           range.location + 1 < source.length,
           isOpeningDelimiter(source.character(at: range.location)),
           isMatchingClosingDelimiter(
               source.character(at: range.location),
               source.character(at: range.location + 1)
           ),
           canManagePairs(state: state) {
            return .replace(
                range: NSRange(location: range.location, length: 2),
                with: "",
                selection: NSRange(location: range.location, length: 0)
            )
        }

        guard inputKind == .typing,
              range.length == 0,
              replacement.utf16.count == 1,
              let character = replacement.utf16.first else {
            return nil
        }

        if isClosingDelimiter(character),
           range.location < source.length,
           source.character(at: range.location) == character,
           shouldSkip(character, state: state) {
            return .moveCaret(to: range.location + 1)
        }

        guard shouldPair(character, state: state),
              let closing = closingDelimiter(for: character) else {
            return nil
        }

        return .replace(
            range: range,
            with: "\(replacement)\(closing)",
            selection: NSRange(location: range.location + 1, length: 0)
        )
    }

    private static func shouldPair(_ character: unichar, state: JSONBodyStringStateCache.State) -> Bool {
        guard !state.isInsideString, !state.isEscaped else {
            return false
        }
        return character == 0x7B || character == 0x5B || character == 0x22
    }

    private static func shouldSkip(_ character: unichar, state: JSONBodyStringStateCache.State) -> Bool {
        switch character {
        case 0x7D, 0x5D:
            return !state.isInsideString
        case 0x22:
            return state.isInsideString && !state.isEscaped
        default:
            return false
        }
    }

    private static func canManagePairs(state: JSONBodyStringStateCache.State) -> Bool {
        !state.isInsideString && !state.isEscaped
    }

    private static func isOpeningDelimiter(_ character: unichar) -> Bool {
        character == 0x7B || character == 0x5B || character == 0x22
    }

    private static func isClosingDelimiter(_ character: unichar) -> Bool {
        character == 0x7D || character == 0x5D || character == 0x22
    }

    private static func isMatchingClosingDelimiter(_ opening: unichar, _ closing: unichar) -> Bool {
        (opening == 0x7B && closing == 0x7D) ||
            (opening == 0x5B && closing == 0x5D) ||
            (opening == 0x22 && closing == 0x22)
    }

    private static func closingDelimiter(for opening: unichar) -> Character? {
        switch opening {
        case 0x7B: "}"
        case 0x5B: "]"
        case 0x22: "\""
        default: nil
        }
    }
}
