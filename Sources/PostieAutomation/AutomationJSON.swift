import Foundation

public enum AutomationJSON: Codable, Equatable, Sendable {
    case object([String: AutomationJSON])
    case array([AutomationJSON])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: AutomationJSON] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(AutomationJSON.self, forKey: key)
            }
            self = .object(values)
            return
        }

        if var array = try? decoder.unkeyedContainer() {
            var values: [AutomationJSON] = []
            while !array.isAtEnd {
                values.append(try array.decode(AutomationJSON.self))
            }
            self = .array(values)
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let boolean = try? value.decode(Bool.self) {
            self = .bool(boolean)
        } else if let number = try? value.decode(Decimal.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                AutomationJSON.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a JSON value.")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
