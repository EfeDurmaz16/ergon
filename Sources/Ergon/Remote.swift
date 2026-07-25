import Foundation

/// Where a credential lives while a remote tool runs.
///
/// The executor asks the store for a token at the moment it builds the
/// request. Nothing else ever holds one: not the descriptor, not the tool
/// closure, not the arguments the model produced, and not the receipt. This
/// is the whole point of routing remote calls through one executor instead of
/// letting each tool make its own request.
public protocol CredentialStore: Sendable {
    /// Returns the secret for a named credential, or nil if the user has not
    /// connected that service yet.
    func credential(named name: String) async -> String?
}

/// A credential store backed by memory. Useful for tests and for a first run;
/// a real host puts these in the keychain.
public struct InMemoryCredentials: CredentialStore {
    private let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public func credential(named name: String) async -> String? {
        values[name]
    }
}

/// How a service authenticates.
///
/// There is deliberately no query-parameter option. Secrets in a URL end up in
/// proxy logs, server access logs, and referrer headers, and a descriptor
/// format that offers the choice will eventually be used to make it.
public enum ServiceAuthentication: Sendable, Equatable {
    case none
    /// `Authorization: Bearer <credential>`
    case bearer(credential: String)
    /// An arbitrary header, for services that predate bearer tokens.
    case header(name: String, credential: String)
}

/// Where an argument goes on the wire.
public enum ParameterLocation: Sendable, Equatable {
    case path
    case query
    case body
    case header
}

public struct ServiceParameter: Sendable {
    public let property: SchemaProperty
    public let location: ParameterLocation
    /// The name the API expects, when it differs from the name the model sees.
    /// Models do better with `query` than with `q`, and APIs rarely agree.
    public let wireName: String

    public init(_ property: SchemaProperty, in location: ParameterLocation, wireName: String? = nil) {
        self.property = property
        self.location = location
        self.wireName = wireName ?? property.name
    }
}

/// How to turn a JSON response into something a small model can read.
///
/// Handing back the raw body is not an option: a single API response routinely
/// exceeds the whole context window, and the model then has no room left to
/// answer. The descriptor says which fields matter, and everything else is
/// dropped before the model ever sees it.
public struct ResponseProjection: Sendable {
    /// Dotted path to an array to summarise one line at a time. Nil projects
    /// the root object instead.
    public let itemsPath: String?
    public let fields: [ProjectionField]
    public let maximumItems: Int
    /// Hard ceiling on the whole summary. Bounding the number of items and the
    /// length of each field still leaves the product of the two unbounded, and
    /// the context window is a fixed budget: this is the last line of defence.
    public let maximumCharacters: Int

    public init(itemsPath: String? = nil, fields: [ProjectionField],
                maximumItems: Int = 5, maximumCharacters: Int = 2000) {
        self.itemsPath = itemsPath
        self.fields = fields
        self.maximumItems = maximumItems
        self.maximumCharacters = maximumCharacters
    }
}

public struct ProjectionField: Sendable {
    public let label: String
    /// Dotted path, with `[n]` for array indices: `current.temperature`,
    /// `items[0].name`. Relative to the item when the projection has one.
    public let path: String
    /// How much of the value the model is allowed to see.
    ///
    /// Naming the fields bounds the shape of a response but not its size: a
    /// single field can hold anything. A live GitHub search for "swift http
    /// client" returns a repository whose description alone is 190,000
    /// characters, roughly twelve times the entire context window, and the
    /// generation dies before it can answer.
    public let maximumLength: Int

    public init(label: String, path: String, maximumLength: Int = 160) {
        self.label = label
        self.path = path
        self.maximumLength = maximumLength
    }
}

/// Cuts to a character budget on a character boundary, marking the cut so the
/// model can tell the difference between a short value and a trimmed one.
func clamped(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(max(0, limit - 1))) + "…"
}

public struct ServiceOperation: Sendable {
    public let name: String
    public let description: String
    public let method: String
    /// May contain `{name}` placeholders filled from `.path` parameters.
    public let path: String
    public let effect: DynamicTool.Effect
    public let parameters: [ServiceParameter]
    /// Query items the caller does not choose. Keeping these out of the
    /// schema stops the model inventing values for knobs it has no opinion on.
    public let fixedQuery: [String: String]
    public let projection: ResponseProjection

    public init(name: String, description: String, method: String = "GET", path: String,
                effect: DynamicTool.Effect = .read, parameters: [ServiceParameter] = [],
                fixedQuery: [String: String] = [:], projection: ResponseProjection) {
        self.name = name
        self.description = description
        self.method = method
        self.path = path
        self.effect = effect
        self.parameters = parameters
        self.fixedQuery = fixedQuery
        self.projection = projection
    }
}

/// One remote service, as data. Everything a tool needs to exist is here, so
/// a service can arrive at runtime rather than in a build, and the same
/// descriptor works on every platform because HTTP is the same everywhere.
public struct ServiceDescriptor: Sendable {
    public let name: String
    public let baseURL: URL
    public let authentication: ServiceAuthentication
    public let operations: [ServiceOperation]
    /// Headers every request carries, such as an API version or a user agent.
    public let headers: [String: String]

    public init(name: String, baseURL: URL, authentication: ServiceAuthentication = .none,
                headers: [String: String] = [:], operations: [ServiceOperation]) {
        self.name = name
        self.baseURL = baseURL
        self.authentication = authentication
        self.headers = headers
        self.operations = operations
    }

    /// Turns the descriptor into tools the engine can gate and receipt exactly
    /// like a hand-written one.
    public func tools(credentials: any CredentialStore = InMemoryCredentials([:]),
                      transport: @escaping HTTPTransport = URLSessionTransport) -> [DynamicTool] {
        operations.map { operation in
            let executor = HTTPExecutor(service: self, operation: operation,
                                        credentials: credentials, transport: transport)
            return DynamicTool(
                name: operation.name,
                description: operation.description,
                arguments: operation.parameters.map(\.property),
                effect: operation.effect,
                preview: { arguments in
                    ActionPreview(title: operation.name, detail: arguments.jsonString)
                },
                run: { try await executor.run($0) },
                // Undo over HTTP needs an inverse operation, which no
                // descriptor declares yet, so a remote tool is never
                // reversible: it either reads or it asks.
                undo: nil)
        }
    }
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public let URLSessionTransport: HTTPTransport = { request in
    try await URLSession.shared.data(for: request)
}

/// Builds and sends one operation's request, then projects the response.
struct HTTPExecutor: Sendable {
    /// Everything a path segment may contain literally. Notably not "/".
    static let pathSegmentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/"))

    let service: ServiceDescriptor
    let operation: ServiceOperation
    let credentials: any CredentialStore
    let transport: HTTPTransport

    /// Returns a described failure rather than throwing for read operations:
    /// a thrown read-tool error aborts the whole generation, and a network
    /// blip should not cost the user their turn.
    func run(_ arguments: ToolArguments) async throws -> String {
        let request: URLRequest
        do {
            request = try await buildRequest(arguments)
        } catch {
            return "Could not build the request for \(operation.name): \(error.localizedDescription)"
        }
        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return "\(service.name) returned HTTP \(http.statusCode)."
            }
            guard let text = String(data: data, encoding: .utf8),
                  let json = JSONValue(jsonString: text) else {
                return "\(service.name) returned a response that is not JSON."
            }
            return project(json)
        } catch {
            return "Could not reach \(service.name): \(error.localizedDescription)"
        }
    }

    func buildRequest(_ arguments: ToolArguments) async throws -> URLRequest {
        var path = operation.path
        var queryItems: [URLQueryItem] = []
        var body: [String: JSONValue] = [:]
        var headers = service.headers

        for parameter in operation.parameters {
            guard let value = arguments[parameter.property.name], value != .null else { continue }
            let text = wireText(value)
            switch parameter.location {
            case .path:
                // Encoded against a set that excludes "/", not .urlPathAllowed,
                // which permits it. A value of "efe/../admin" substituted raw
                // addresses a different endpoint entirely, and the value comes
                // from a model reading untrusted text.
                let encoded = text.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? text
                path = path.replacingOccurrences(of: "{\(parameter.wireName)}", with: encoded)
            case .query:
                queryItems.append(URLQueryItem(name: parameter.wireName, value: text))
            case .body:
                body[parameter.wireName] = value
            case .header:
                headers[parameter.wireName] = text
            }
        }
        for (name, value) in operation.fixedQuery {
            queryItems.append(URLQueryItem(name: name, value: value))
        }

        // The path is already percent-encoded, so it is assigned as encoded
        // rather than appended: appending would encode it a second time and
        // the service would receive a literal "%2F" instead of the character
        // the user meant.
        guard var components = URLComponents(url: service.baseURL, resolvingAgainstBaseURL: false) else {
            throw ErgonError.generation("bad URL for \(operation.name)")
        }
        let base = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = base + (path.hasPrefix("/") ? path : "/" + path)
        if !queryItems.isEmpty {
            components.queryItems = queryItems.sorted { $0.name < $1.name }
        }
        guard let url = components.url else {
            throw ErgonError.generation("bad URL for \(operation.name)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        if !body.isEmpty {
            request.httpBody = Data(JSONValue.object(body).jsonString.utf8)
            headers["Content-Type"] = "application/json"
        }
        // Credentials are read here and nowhere else, and they are only ever
        // set as headers.
        switch service.authentication {
        case .none:
            break
        case .bearer(let name):
            guard let secret = await credentials.credential(named: name) else {
                throw ErgonError.generation("\(service.name) is not connected yet")
            }
            headers["Authorization"] = "Bearer \(secret)"
        case .header(let headerName, let name):
            guard let secret = await credentials.credential(named: name) else {
                throw ErgonError.generation("\(service.name) is not connected yet")
            }
            headers[headerName] = secret
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func wireText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number):
            // Integers on the wire, not "3.0": half the APIs reject the float.
            number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): flag ? "true" : "false"
        default: value.jsonString
        }
    }

    func project(_ json: JSONValue) -> String {
        let projection = operation.projection
        guard let itemsPath = projection.itemsPath else {
            let line = summarize(json, fields: projection.fields)
            return line.isEmpty ? "No details returned." : clamped(line, to: projection.maximumCharacters)
        }
        guard case .array(let items)? = value(at: itemsPath, in: json) else {
            return "No results."
        }
        guard !items.isEmpty else { return "No results." }
        let lines = items.prefix(projection.maximumItems).enumerated().map { index, item in
            "\(index + 1). " + summarize(item, fields: projection.fields)
        }
        let more = items.count > projection.maximumItems
            ? "\nShowing \(projection.maximumItems) of \(items.count)."
            : ""
        return clamped(lines.joined(separator: "\n"), to: projection.maximumCharacters) + more
    }

    private func summarize(_ json: JSONValue, fields: [ProjectionField]) -> String {
        fields.compactMap { field -> String? in
            guard let found = value(at: field.path, in: json), found != .null else { return nil }
            let text = switch found {
            case .string(let value): value
            default: wireText(found)
            }
            return "\(field.label): \(clamped(text, to: field.maximumLength))"
        }.joined(separator: ", ")
    }

    /// Resolves `a.b[2].c` against a JSON value. Returns nil for anything the
    /// path does not reach, which is the common case with real APIs.
    func value(at path: String, in json: JSONValue) -> JSONValue? {
        var current: JSONValue? = json
        for rawComponent in path.split(separator: ".") {
            var component = Substring(rawComponent)
            var indices: [Int] = []
            while let open = component.lastIndex(of: "["), component.hasSuffix("]") {
                let inside = component[component.index(after: open)..<component.index(before: component.endIndex)]
                guard let index = Int(inside) else { return nil }
                indices.insert(index, at: 0)
                component = component[component.startIndex..<open]
            }
            if !component.isEmpty {
                guard case .object(let fields)? = current else { return nil }
                current = fields[String(component)]
            }
            for index in indices {
                guard case .array(let elements)? = current, elements.indices.contains(index) else { return nil }
                current = elements[index]
            }
        }
        return current
    }
}
