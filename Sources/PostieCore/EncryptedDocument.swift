import CoreFoundation
import Foundation

public enum EncryptedDocumentError: LocalizedError, Equatable, Sendable {
    case invalidJSON
    case malformedDocument
    case unsupportedDocumentVersion(Int)
    case malformedEnvelope
    case unsupportedEnvelopeVersion(Int)
    case replacementCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "The encrypted document is not valid JSON."
        case .malformedDocument:
            "The encrypted document has an invalid shape."
        case .unsupportedDocumentVersion(let version):
            "The encrypted document format version \(version) is not supported."
        case .malformedEnvelope:
            "The encrypted document contains a malformed secret envelope."
        case .unsupportedEnvelopeVersion(let version):
            "The secret envelope version \(version) is not supported."
        case .replacementCountMismatch(let expected, let actual):
            "Expected \(expected) secret envelope replacements but received \(actual)."
        }
    }
}

public enum EncryptedDocument {
    public enum Kind: Sendable {
        case globals
        case collection
        case request
        case snapshot
        case automation
    }

    private struct EnvelopeSlot {
        let path: [String]
        let envelope: SecretEnvelope
    }

    private struct ParsedDocument {
        let object: [String: Any]
        let slots: [EnvelopeSlot]
    }

    public static func envelopes(in data: Data, kind: Kind) throws -> [SecretEnvelope] {
        try parse(data, kind: kind).slots.map(\.envelope)
    }

    public static func replacingEnvelopes(
        in data: Data,
        kind: Kind,
        with replacements: [SecretEnvelope]
    ) throws -> Data {
        let parsed = try parse(data, kind: kind)
        guard parsed.slots.count == replacements.count else {
            throw EncryptedDocumentError.replacementCountMismatch(
                expected: parsed.slots.count,
                actual: replacements.count
            )
        }

        var object = parsed.object
        for (slot, replacement) in zip(parsed.slots, replacements) {
            try validate(replacement)
            object = try replacing(slot.path[...], in: object, with: replacement)
        }

        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw EncryptedDocumentError.malformedDocument
        }
    }

    private static func parse(_ data: Data, kind: Kind) throws -> ParsedDocument {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw EncryptedDocumentError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw EncryptedDocumentError.malformedDocument
        }

        var slots: [EnvelopeSlot] = []
        switch kind {
        case .globals:
            _ = try validateDocumentVersion(in: object, key: "formatVersion", supported: [1])
            try collectVariables(in: object, required: true, slots: &slots)
        case .collection:
            _ = try validateDocumentVersion(in: object, key: "formatVersion", supported: [1])
            try collectVariables(in: object, required: false, slots: &slots)
            try collectAuthentication(in: object, slots: &slots)
        case .request:
            _ = try validateDocumentVersion(in: object, key: "formatVersion", supported: [1, 2])
            try collectVariables(in: object, required: false, nullIsMissing: true, slots: &slots)
            try collectAuthentication(in: object, nullIsMissing: true, slots: &slots)
        case .snapshot:
            let version = try validateDocumentVersion(in: object, key: "version", supported: [1, 2])
            guard let preparationVersion = integerValue(object["preparationVersion"]) else {
                throw EncryptedDocumentError.malformedDocument
            }
            guard preparationVersion == 1 || preparationVersion == 2 else {
                throw EncryptedDocumentError.unsupportedDocumentVersion(preparationVersion)
            }
            guard preparationVersion == version else {
                throw EncryptedDocumentError.malformedDocument
            }
            guard let rawEnvelope = object["encryptedContext"] else {
                throw EncryptedDocumentError.malformedDocument
            }
            slots.append(EnvelopeSlot(path: ["encryptedContext"], envelope: try envelope(from: rawEnvelope)))
        case .automation:
            _ = try validateDocumentVersion(in: object, key: "formatVersion", supported: [1])
            guard let rawEnvelope = object["token"] else {
                throw EncryptedDocumentError.malformedDocument
            }
            slots.append(EnvelopeSlot(path: ["token"], envelope: try envelope(from: rawEnvelope)))
        }

        return ParsedDocument(object: object, slots: slots)
    }

    private static func validateDocumentVersion(
        in object: [String: Any],
        key: String,
        supported: [Int]
    ) throws -> Int {
        guard let version = integerValue(object[key]) else {
            throw EncryptedDocumentError.malformedDocument
        }
        guard supported.contains(version) else {
            throw EncryptedDocumentError.unsupportedDocumentVersion(version)
        }
        return version
    }

    private static func collectVariables(
        in object: [String: Any],
        required: Bool,
        nullIsMissing: Bool = false,
        slots: inout [EnvelopeSlot]
    ) throws {
        guard let rawVariables = object["variables"] else {
            if required { throw EncryptedDocumentError.malformedDocument }
            return
        }
        if nullIsMissing, rawVariables is NSNull { return }
        guard let variables = rawVariables as? [String: Any] else {
            throw EncryptedDocumentError.malformedDocument
        }

        for name in variables.keys.sorted() {
            guard let value = variables[name] else { throw EncryptedDocumentError.malformedDocument }
            if value is String { continue }
            slots.append(EnvelopeSlot(path: ["variables", name], envelope: try envelope(from: value)))
        }
    }

    private static func collectAuthentication(
        in object: [String: Any],
        nullIsMissing: Bool = false,
        slots: inout [EnvelopeSlot]
    ) throws {
        guard let rawAuthentication = object["authentication"] else { return }
        if nullIsMissing, rawAuthentication is NSNull { return }
        guard let authentication = rawAuthentication as? [String: Any] else {
            throw EncryptedDocumentError.malformedDocument
        }

        for field in ["password", "token", "apiKey"] {
            guard let value = authentication[field], !(value is NSNull) else { continue }
            slots.append(
                EnvelopeSlot(
                    path: ["authentication", field],
                    envelope: try envelope(from: value)
                ))
        }
    }

    private static func envelope(from value: Any) throws -> SecretEnvelope {
        guard let object = value as? [String: Any],
            let version = integerValue(object["version"])
        else {
            throw EncryptedDocumentError.malformedEnvelope
        }

        guard version == 1 || version == 2 else {
            throw EncryptedDocumentError.unsupportedEnvelopeVersion(version)
        }
        guard let combined = object["combined"] as? String else {
            throw EncryptedDocumentError.malformedEnvelope
        }

        let keyID: UUID?
        if version == 1 {
            guard object["keyID"] == nil else { throw EncryptedDocumentError.malformedEnvelope }
            keyID = nil
        } else {
            guard let rawKeyID = object["keyID"] as? String,
                let id = UUID(uuidString: rawKeyID),
                rawKeyID == id.uuidString
            else {
                throw EncryptedDocumentError.malformedEnvelope
            }
            keyID = id
        }

        guard validCombined(combined) else {
            throw EncryptedDocumentError.malformedEnvelope
        }

        return SecretEnvelope(version: version, combined: combined, keyID: keyID)
    }

    private static func validate(_ envelope: SecretEnvelope) throws {
        guard envelope.version == 1 || envelope.version == 2 else {
            throw EncryptedDocumentError.unsupportedEnvelopeVersion(envelope.version)
        }
        switch envelope.version {
        case 1:
            guard envelope.keyID == nil else { throw EncryptedDocumentError.malformedEnvelope }
        case 2:
            guard envelope.keyID != nil else { throw EncryptedDocumentError.malformedEnvelope }
        default:
            throw EncryptedDocumentError.malformedEnvelope
        }
        guard validCombined(envelope.combined) else {
            throw EncryptedDocumentError.malformedEnvelope
        }
    }

    private static func validCombined(_ combined: String) -> Bool {
        guard let data = Data(base64Encoded: combined) else { return false }
        return data.base64EncodedString() == combined && data.count >= 28
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        return Int(exactly: double)
    }

    private static func replacing(
        _ path: ArraySlice<String>,
        in object: [String: Any],
        with envelope: SecretEnvelope
    ) throws -> [String: Any] {
        guard let key = path.first, let value = object[key] else {
            throw EncryptedDocumentError.malformedDocument
        }

        var updated = object
        if path.count == 1 {
            guard var envelopeObject = value as? [String: Any] else {
                throw EncryptedDocumentError.malformedEnvelope
            }
            envelopeObject["version"] = envelope.version
            envelopeObject["combined"] = envelope.combined
            if let keyID = envelope.keyID {
                envelopeObject["keyID"] = keyID.uuidString
            } else {
                envelopeObject.removeValue(forKey: "keyID")
            }
            updated[key] = envelopeObject
            return updated
        }

        guard let nested = value as? [String: Any] else {
            throw EncryptedDocumentError.malformedDocument
        }
        updated[key] = try replacing(path.dropFirst(), in: nested, with: envelope)
        return updated
    }
}
