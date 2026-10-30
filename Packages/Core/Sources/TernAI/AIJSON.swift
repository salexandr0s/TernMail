import Foundation

/// JSON retained across stateless model requests, including opaque reasoning items.
public indirect enum AIJSON: Codable, Equatable, Sendable {
    case object([String: AIJSON])
    case array([AIJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let array = try? value.decode([AIJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: AIJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> AIJSON? { objectValue?[key] }
    public var objectValue: [String: AIJSON]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [AIJSON]? { if case .array(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }

    public static func decode(_ data: Data) throws -> AIJSON { try JSONDecoder().decode(Self.self, from: data) }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public func jsonString() throws -> String { String(decoding: try encoded(), as: UTF8.self) }
}
