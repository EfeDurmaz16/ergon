import Foundation

/// The capable tier, running on the user's own Anthropic account.
///
/// Plain HTTP against the Messages API rather than an SDK: there is no official
/// Anthropic SDK for Swift, the request is three JSON fields, and a dependency
/// that has to compile on iOS, Android, and Windows earns its weight only if it
/// does more than `URLSession` already does.
///
/// The key is read from the credential store at request time and set as a
/// header. It is never placed in the URL, never handed to a tool, and never
/// written to a receipt.
public struct AnthropicBackend: ModelBackend {
    /// How hard the model works. The API's own default is `high`; `medium` is
    /// the better default for an assistant a user is waiting on, and the dial
    /// is exposed because the right answer is per-product.
    public enum Effort: String, Sendable {
        case low, medium, high, xhigh, max
    }

    public let model: String
    public let effort: Effort
    public let maximumTokens: Int
    /// Name of the credential holding the user's API key.
    public let credentialName: String

    let credentials: any CredentialStore
    let transport: HTTPTransport
    /// Bound so a tool that keeps returning work cannot bill the user forever.
    let maximumRounds: Int

    public init(credentials: any CredentialStore,
                credentialName: String = "anthropic-api-key",
                model: String = "claude-opus-5",
                effort: Effort = .medium,
                maximumTokens: Int = 4096,
                maximumRounds: Int = 8,
                transport: @escaping HTTPTransport = URLSessionTransport) {
        self.credentials = credentials
        self.credentialName = credentialName
        self.model = model
        self.effort = effort
        self.maximumTokens = maximumTokens
        self.maximumRounds = maximumRounds
        self.transport = transport
    }

    public func respond(to intent: String,
                        instructions: String,
                        tools: [BackendTool],
                        invoke: @escaping ToolInvocation) async throws -> String {
        guard let key = await credentials.credential(named: credentialName) else {
            throw ErgonError.generation("No API key connected yet.")
        }

        // The transcript the API sees. Assistant turns are echoed back
        // verbatim: dropping a tool_use block from the history leaves a
        // tool_result with nothing to attach to, and the request is rejected.
        var messages: [JSONValue] = [
            .object(["role": .string("user"), "content": .string(intent)]),
        ]

        for _ in 0..<maximumRounds {
            let reply = try await send(messages: messages, instructions: instructions,
                                       tools: tools, key: key)
            guard case .object(let fields) = reply else {
                throw ErgonError.generation("The model returned something that is not a message.")
            }
            guard case .array(let content)? = fields["content"] else {
                throw ErgonError.generation("The model returned a message with no content.")
            }

            let stopReason = fields["stop_reason"]?.stringValue
            // Safety classifiers can decline a request: HTTP 200, empty or
            // partial content, and a reason. Reading content[0] blindly here
            // is the documented way to crash on a refusal.
            if stopReason == "refusal" {
                return "That request was declined."
            }
            guard stopReason == "tool_use" else {
                return text(in: content)
            }

            messages.append(.object(["role": .string("assistant"), "content": .array(content)]))

            // Every tool_use block must be answered, and all the answers must
            // travel in one user message: splitting them teaches the model to
            // stop asking for parallel calls.
            var results: [JSONValue] = []
            for block in content {
                guard case .object(let fields) = block,
                      fields["type"]?.stringValue == "tool_use",
                      let id = fields["id"]?.stringValue,
                      let name = fields["name"]?.stringValue else { continue }
                let arguments = (fields["input"] ?? .object([:])).jsonString
                var result = JSONValue.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(id),
                ])
                do {
                    result = result.merging(["content": .string(try await invoke(name, arguments))])
                } catch {
                    // A failed tool is reported as a failed tool, not dropped:
                    // an unanswered tool_use invalidates the next request.
                    result = result.merging([
                        "content": .string(String(describing: error)),
                        "is_error": .bool(true),
                    ])
                }
                results.append(result)
            }
            guard !results.isEmpty else { return text(in: content) }
            messages.append(.object(["role": .string("user"), "content": .array(results)]))
        }
        return "That took too many steps to finish."
    }

    private func text(in content: [JSONValue]) -> String {
        content.compactMap { block -> String? in
            guard case .object(let fields) = block,
                  fields["type"]?.stringValue == "text" else { return nil }
            return fields["text"]?.stringValue
        }.joined(separator: "\n")
    }

    func buildRequest(messages: [JSONValue], instructions: String,
                      tools: [BackendTool], key: String) throws -> URLRequest {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maximumTokens)),
            "system": .string(instructions),
            "messages": .array(messages),
            "output_config": .object(["effort": .string(effort.rawValue)]),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": JSONValue(jsonString: tool.jsonSchema) ?? .object([:]),
                ])
            })
        }
        // Thinking is deliberately not configured. It is on by default on this
        // model, and turning it off is what makes it write tool calls into its
        // visible text instead of emitting them: the call silently never runs.
        // Effort is the cost dial; thinking is not.

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ErgonError.generation("bad API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(JSONValue.object(body).jsonString.utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        return request
    }

    private func send(messages: [JSONValue], instructions: String,
                      tools: [BackendTool], key: String) async throws -> JSONValue {
        let request = try buildRequest(messages: messages, instructions: instructions,
                                       tools: tools, key: key)
        let (data, response) = try await transport(request)
        let text = String(data: data, encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The body carries the reason; the status alone rarely explains it.
            let reason = JSONValue(jsonString: text).flatMap { value -> String? in
                guard case .object(let fields) = value,
                      case .object(let error)? = fields["error"] else { return nil }
                return error["message"]?.stringValue
            }
            throw ErgonError.generation("Model request failed (\(http.statusCode)): \(reason ?? text)")
        }
        guard let value = JSONValue(jsonString: text) else {
            throw ErgonError.generation("The model returned a response that is not JSON.")
        }
        return value
    }
}

extension JSONValue {
    /// Returns this object with extra fields added. Non-objects are returned
    /// unchanged rather than silently becoming one.
    func merging(_ fields: [String: JSONValue]) -> JSONValue {
        guard case .object(let existing) = self else { return self }
        return .object(existing.merging(fields) { _, new in new })
    }
}
