import Foundation

/// A JSON value. Tool arguments arrive as one, HTTP bodies are built from one,
/// and descriptors are parsed into one, so it is the single shape data takes
/// as it crosses the boundary between the model, the catalog, and the network.
///
/// One numeric case, not two: JSON has one number type, and carrying the
/// integer/float distinction here only creates two ways to be wrong about the
/// same value.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        doubleValue.map(Int.init)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Decodes JSON text. Returns nil rather than throwing: every caller here
    /// is handling untrusted model output and has a sensible fallback.
    public init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        self = JSONValue(any)
    }

    init(_ any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool where type(of: any) == type(of: true): self = .bool(value)
        case let value as NSNumber:
            // NSNumber erases Bool into a number, so the boolean check has to
            // happen through the type encoding before the numeric one.
            self = String(cString: value.objCType) == "c" ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .array(let values): values.map(\.foundationValue)
        case .object(let fields): fields.mapValues(\.foundationValue)
        case .null: NSNull()
        }
    }

    public var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue,
                                                     options: [.sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}

/// The arguments a tool was called with, already decoded. Accessors return
/// optionals because the values came from a model: a missing or mistyped
/// field is an ordinary Tuesday, not an exceptional condition.
public struct ToolArguments: Sendable, Equatable {
    public let fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(jsonString: String) {
        if case .object(let fields)? = JSONValue(jsonString: jsonString) {
            self.fields = fields
        } else {
            self.fields = [:]
        }
    }

    public subscript(key: String) -> JSONValue? { fields[key] }
    public func string(_ key: String) -> String? { fields[key]?.stringValue }
    public func number(_ key: String) -> Double? { fields[key]?.doubleValue }
    public func integer(_ key: String) -> Int? { fields[key]?.intValue }
    public func bool(_ key: String) -> Bool? { fields[key]?.boolValue }

    public var jsonString: String { JSONValue.object(fields).jsonString }
}

/// A tool's argument shape, as data rather than as a Swift type.
///
/// This is the seam the whole catalog turns on. While a tool's arguments are
/// expressed as a Swift generic, a tool can only be added by shipping an app
/// build, and only on a platform that has Swift macros. Expressed as a value,
/// the same tool can arrive from a descriptor at runtime and be rendered for
/// whatever the model backend happens to be.
public indirect enum ErgonSchema: Sendable, Equatable {
    /// Free text, or a closed set of allowed strings when `oneOf` is non-empty.
    case string(oneOf: [String])
    case number(minimum: Double?, maximum: Double?)
    case integer(minimum: Int?, maximum: Int?)
    case boolean
    case array(of: ErgonSchema)
    case object(name: String, properties: [SchemaProperty])
}

public struct SchemaProperty: Sendable, Equatable {
    public let name: String
    /// Written for the model, not for a developer: this is the only place the
    /// model learns what to put in the field.
    public let description: String
    public let schema: ErgonSchema
    public let isOptional: Bool

    public init(name: String, description: String, schema: ErgonSchema, isOptional: Bool = false) {
        self.name = name
        self.description = description
        self.schema = schema
        self.isOptional = isOptional
    }
}
