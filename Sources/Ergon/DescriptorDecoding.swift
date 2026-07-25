import Foundation

/// Why a descriptor could not be read, and where.
///
/// Descriptors are written by hand and, later, fetched from elsewhere, so the
/// failure a developer actually hits is a typo three levels down. The path is
/// carried through so the message names the field instead of the file.
public struct DescriptorError: Error, LocalizedError, Equatable {
    public let path: String
    public let reason: String

    public var errorDescription: String? {
        path.isEmpty ? reason : "\(path): \(reason)"
    }

    public init(_ path: String, _ reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// A cursor over decoded JSON that remembers where it is.
private struct Cursor {
    let value: JSONValue
    let path: String

    func child(_ key: String) -> Cursor {
        let next: JSONValue?
        if case .object(let fields) = value { next = fields[key] } else { next = nil }
        return Cursor(value: next ?? .null, path: path.isEmpty ? key : "\(path).\(key)")
    }

    func element(_ index: Int) -> Cursor {
        Cursor(value: value, path: "\(path)[\(index)]")
    }

    var isMissing: Bool { value == .null }

    func string() throws -> String {
        guard let text = value.stringValue else { throw DescriptorError(path, "expected a string") }
        return text
    }

    func string(default fallback: String) -> String {
        value.stringValue ?? fallback
    }

    func int(default fallback: Int) -> Int {
        value.intValue ?? fallback
    }

    func double() -> Double? { value.doubleValue }
    func bool(default fallback: Bool) -> Bool { value.boolValue ?? fallback }

    func array() throws -> [Cursor] {
        guard case .array(let elements) = value else { throw DescriptorError(path, "expected an array") }
        return elements.enumerated().map { Cursor(value: $1, path: "\(path)[\($0)]") }
    }

    func stringMap() throws -> [String: String] {
        guard !isMissing else { return [:] }
        guard case .object(let fields) = value else { throw DescriptorError(path, "expected an object") }
        return try fields.mapValues { entry in
            guard let text = entry.stringValue else { throw DescriptorError(path, "expected string values") }
            return text
        }
    }
}

extension ServiceDescriptor {
    /// Reads a descriptor from JSON. The shape mirrors the types: a service has
    /// a name, a base URL, an auth block, headers, and operations; an operation
    /// has parameters and a response projection.
    public init(json: String) throws {
        guard let value = JSONValue(jsonString: json) else {
            throw DescriptorError("", "not valid JSON")
        }
        try self.init(cursor: Cursor(value: value, path: ""))
    }

    public init(contentsOf url: URL) throws {
        try self.init(json: String(contentsOf: url, encoding: .utf8))
    }

    fileprivate init(cursor: Cursor) throws {
        let name = try cursor.child("name").string()
        let rawURL = try cursor.child("baseURL").string()
        guard let baseURL = URL(string: rawURL) else {
            throw DescriptorError("baseURL", "'\(rawURL)' is not a URL")
        }
        let operations = try cursor.child("operations").array().map(ServiceOperation.init(cursor:))
        guard !operations.isEmpty else {
            throw DescriptorError("operations", "a service with no operations is not a service")
        }
        self.init(name: name,
                  baseURL: baseURL,
                  authentication: try ServiceAuthentication(cursor: cursor.child("auth")),
                  headers: try cursor.child("headers").stringMap(),
                  operations: operations)
    }
}

extension ServiceAuthentication {
    fileprivate init(cursor: Cursor) throws {
        guard !cursor.isMissing else { self = .none; return }
        let type = try cursor.child("type").string()
        switch type {
        case "none":
            self = .none
        case "bearer":
            self = .bearer(credential: try cursor.child("credential").string())
        case "header":
            self = .header(name: try cursor.child("header").string(),
                           credential: try cursor.child("credential").string())
        default:
            // Deliberately not a query-parameter option: see ServiceAuthentication.
            throw DescriptorError(cursor.child("type").path,
                                  "'\(type)' is not one of none, bearer, header")
        }
    }
}

extension ServiceOperation {
    fileprivate init(cursor: Cursor) throws {
        let effectName = cursor.child("effect").string(default: "read")
        let effect: DynamicTool.Effect = switch effectName {
        case "read": .read
        case "irreversible": .irreversible
        case "reversible": .reversible
        default: throw DescriptorError(cursor.child("effect").path,
                                       "'\(effectName)' is not one of read, irreversible, reversible")
        }
        // A remote tool has no inverse to run, so declaring one reversible
        // would let it act unasked with an undo that cannot exist.
        guard effect != .reversible else {
            throw DescriptorError(cursor.child("effect").path,
                                  "remote operations cannot be reversible: no descriptor declares an inverse")
        }
        let parameters = cursor.child("parameters").isMissing
            ? []
            : try cursor.child("parameters").array().map(ServiceParameter.init(cursor:))
        self.init(name: try cursor.child("name").string(),
                  description: try cursor.child("description").string(),
                  method: cursor.child("method").string(default: "GET"),
                  path: try cursor.child("path").string(),
                  effect: effect,
                  parameters: parameters,
                  fixedQuery: try cursor.child("fixedQuery").stringMap(),
                  projection: try ResponseProjection(cursor: cursor.child("response")))
    }
}

extension ServiceParameter {
    fileprivate init(cursor: Cursor) throws {
        let name = try cursor.child("name").string()
        let locationName = cursor.child("in").string(default: "query")
        let location: ParameterLocation = switch locationName {
        case "path": .path
        case "query": .query
        case "body": .body
        case "header": .header
        default: throw DescriptorError(cursor.child("in").path,
                                       "'\(locationName)' is not one of path, query, body, header")
        }
        self.init(SchemaProperty(name: name,
                                 description: try cursor.child("description").string(),
                                 schema: try ErgonSchema(cursor: cursor, named: name),
                                 isOptional: cursor.child("optional").bool(default: false)),
                  in: location,
                  wireName: cursor.child("wireName").value.stringValue)
    }
}

extension ErgonSchema {
    /// Reads the type block of a parameter or a nested property.
    fileprivate init(cursor: Cursor, named name: String) throws {
        let type = cursor.child("type").string(default: "string")
        switch type {
        case "string":
            let choices = cursor.child("oneOf").isMissing
                ? []
                : try cursor.child("oneOf").array().map { try $0.string() }
            self = .string(oneOf: choices)
        case "number":
            self = .number(minimum: cursor.child("minimum").double(),
                           maximum: cursor.child("maximum").double())
        case "integer":
            self = .integer(minimum: cursor.child("minimum").value.intValue,
                            maximum: cursor.child("maximum").value.intValue)
        case "boolean":
            self = .boolean
        case "array":
            let items = cursor.child("items")
            guard !items.isMissing else { throw DescriptorError(items.path, "an array needs items") }
            self = .array(of: try ErgonSchema(cursor: items, named: name + "Item"))
        case "object":
            let properties = try cursor.child("properties").array().map { property in
                SchemaProperty(name: try property.child("name").string(),
                               description: try property.child("description").string(),
                               schema: try ErgonSchema(cursor: property,
                                                       named: try property.child("name").string()),
                               isOptional: property.child("optional").bool(default: false))
            }
            self = .object(name: cursor.child("name").string(default: name), properties: properties)
        default:
            throw DescriptorError(cursor.child("type").path,
                                  "'\(type)' is not one of string, number, integer, boolean, array, object")
        }
    }
}

extension ResponseProjection {
    fileprivate init(cursor: Cursor) throws {
        guard !cursor.isMissing else {
            throw DescriptorError(cursor.path, "an operation needs a response projection, or the model gets the raw body")
        }
        self.init(itemsPath: cursor.child("items").value.stringValue,
                  fields: try cursor.child("fields").array().map { field in
                      ProjectionField(label: try field.child("label").string(),
                                      path: try field.child("path").string(),
                                      maximumLength: field.child("maxLength").int(default: 160))
                  },
                  maximumItems: cursor.child("maxItems").int(default: 5),
                  maximumCharacters: cursor.child("maxCharacters").int(default: 2000))
    }
}
