import Foundation

/// A JSON value, kept as the Claude API sent it so that content Uriel does not model is never lost.
///
/// shortcut: numbers are `Double`, so integers beyond 2^53 lose precision; no field Uriel sends back
/// carries one. Add a lossless number case if one ever does.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// Decodes JSON text.
  public init(json data: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Encodes to JSON text with sorted keys, so the same value always gives the same bytes.
  public func jsonData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// The member named `key`, when this is an object.
  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  /// The members, when this is an object.
  public var objectValue: [String: JSONValue]? {
    if case .object(let object) = self { object } else { nil }
  }

  /// The string, when this is a string.
  public var stringValue: String? {
    if case .string(let string) = self { string } else { nil }
  }

  /// The number, when this is a whole number that fits in an `Int`.
  public var intValue: Int? {
    if case .number(let number) = self { Int(exactly: number) } else { nil }
  }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let bool): try container.encode(bool)
    case .number(let number): try container.encode(number)
    case .string(let string): try container.encode(string)
    case .array(let array): try container.encode(array)
    case .object(let object): try container.encode(object)
    }
  }
}
