import Foundation
import Testing
@testable import Ergon

/// The remote tool loop is protocol-shaped: a malformed transcript is rejected
/// by the API rather than misbehaving quietly, so these tests assert on the
/// exact bytes the loop sends rather than on a happy-path reply.
@Suite struct BackendTests {
    /// Records every request and replies from a script.
    private final class Recorder: @unchecked Sendable {
        /// Collects tool invocations from inside a @Sendable closure.
        final class Calls: @unchecked Sendable {
            private(set) var all: [String] = []
            func append(_ call: String) { all.append(call) }
        }

        var sent: [JSONValue] = []
        private var replies: [String]

        init(replies: [String]) {
            self.replies = replies
        }

        var transport: HTTPTransport {
            { [self] request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                sent.append(JSONValue(jsonString: body) ?? .null)
                let reply = replies.isEmpty ? #"{"stop_reason":"end_turn","content":[]}"# : replies.removeFirst()
                return (Data(reply.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private func backend(_ recorder: Recorder,
                         credentials: any CredentialStore = InMemoryCredentials(["anthropic-api-key": "sk-test"]),
                         maximumRounds: Int = 8) -> AnthropicBackend {
        AnthropicBackend(credentials: credentials, maximumRounds: maximumRounds,
                         transport: recorder.transport)
    }

    private let probe = BackendTool(
        name: "lookUp",
        description: "Look something up",
        jsonSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)

    private func field(_ path: String, of json: JSONValue) -> JSONValue? {
        value(at: path, in: json)
    }

    @Test func theRequestCarriesTheKeyAsAHeaderAndTheToolsAsSchemas() async throws {
        let recorder = Recorder(replies: [#"{"stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}"#])
        let reply = try await backend(recorder).respond(
            to: "hello", instructions: "be brief", tools: [probe], invoke: { _, _ in "" })

        #expect(reply == "hi")
        let body = try #require(recorder.sent.first)
        #expect(field("model", of: body)?.stringValue == "claude-opus-5")
        #expect(field("system", of: body)?.stringValue == "be brief")
        #expect(field("tools[0].name", of: body)?.stringValue == "lookUp")
        // The schema must arrive as an object, not as a string containing JSON.
        #expect(field("tools[0].input_schema.type", of: body)?.stringValue == "object")
        #expect(field("output_config.effort", of: body)?.stringValue == "medium")
    }

    /// Thinking must not be configured: turning it off is what makes the model
    /// write tool calls into its visible text, where they silently never run.
    @Test func theRequestDoesNotDisableThinking() async throws {
        let recorder = Recorder(replies: [#"{"stop_reason":"end_turn","content":[]}"#])
        _ = try await backend(recorder).respond(to: "hi", instructions: "", tools: [],
                                                invoke: { _, _ in "" })
        let body = try #require(recorder.sent.first)
        #expect(field("thinking", of: body) == nil)
    }

    /// The whole point of the loop. The assistant turn must be echoed back
    /// verbatim, and the tool answer must be a tool_result carrying the same id.
    @Test func aToolCallIsAnsweredInAFollowUpRequest() async throws {
        let recorder = Recorder(replies: [
            """
            {"stop_reason":"tool_use","content":[
              {"type":"text","text":"looking"},
              {"type":"tool_use","id":"toolu_1","name":"lookUp","input":{"query":"swift"}}]}
            """,
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"found it"}]}"#,
        ])

        let seen = Recorder.Calls()
        let reply = try await backend(recorder).respond(
            to: "look up swift", instructions: "", tools: [probe],
            invoke: { name, arguments in
                seen.append("\(name) \(arguments)")
                return "one result"
            })

        #expect(reply == "found it")
        #expect(seen.all == [#"lookUp {"query":"swift"}"#])
        #expect(recorder.sent.count == 2)

        let second = try #require(recorder.sent.last)
        #expect(field("messages[1].role", of: second)?.stringValue == "assistant")
        // Echoed verbatim: a dropped tool_use leaves the tool_result orphaned
        // and the API rejects the request.
        #expect(field("messages[1].content[1].type", of: second)?.stringValue == "tool_use")
        #expect(field("messages[2].role", of: second)?.stringValue == "user")
        #expect(field("messages[2].content[0].type", of: second)?.stringValue == "tool_result")
        #expect(field("messages[2].content[0].tool_use_id", of: second)?.stringValue == "toolu_1")
        #expect(field("messages[2].content[0].content", of: second)?.stringValue == "one result")
    }

    /// Parallel calls must come back in one user message: splitting them trains
    /// the model to stop asking for parallel calls at all.
    @Test func everyToolCallIsAnsweredInASingleUserMessage() async throws {
        let recorder = Recorder(replies: [
            """
            {"stop_reason":"tool_use","content":[
              {"type":"tool_use","id":"toolu_1","name":"lookUp","input":{"query":"a"}},
              {"type":"tool_use","id":"toolu_2","name":"lookUp","input":{"query":"b"}}]}
            """,
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}"#,
        ])

        _ = try await backend(recorder).respond(to: "two things", instructions: "", tools: [probe],
                                                invoke: { _, _ in "ok" })

        let second = try #require(recorder.sent.last)
        #expect(recorder.sent.count == 2, "one follow-up request, not two")
        #expect(field("messages[2].content[0].tool_use_id", of: second)?.stringValue == "toolu_1")
        #expect(field("messages[2].content[1].tool_use_id", of: second)?.stringValue == "toolu_2")
        #expect(field("messages[3]", of: second) == nil, "results must not be split across messages")
    }

    /// A failing tool is reported as a failed tool. Dropping it would leave a
    /// tool_use unanswered, which invalidates the next request outright.
    @Test func aFailingToolIsReportedRatherThanDropped() async throws {
        let recorder = Recorder(replies: [
            #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"lookUp","input":{}}]}"#,
            #"{"stop_reason":"end_turn","content":[{"type":"text","text":"understood"}]}"#,
        ])

        _ = try await backend(recorder).respond(to: "go", instructions: "", tools: [probe],
                                                invoke: { _, _ in throw TestError.boom })

        let second = try #require(recorder.sent.last)
        #expect(field("messages[2].content[0].is_error", of: second)?.boolValue == true)
        #expect(field("messages[2].content[0].tool_use_id", of: second)?.stringValue == "toolu_1")
    }

    /// A tool that keeps returning work must not bill the user indefinitely.
    @Test func theLoopIsBounded() async throws {
        let looping = #"{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"lookUp","input":{}}]}"#
        let recorder = Recorder(replies: Array(repeating: looping, count: 20))

        let reply = try await backend(recorder, maximumRounds: 3).respond(
            to: "loop", instructions: "", tools: [probe], invoke: { _, _ in "again" })

        #expect(recorder.sent.count == 3)
        #expect(reply.contains("too many steps"))
    }

    /// Safety classifiers decline with a successful HTTP 200 and empty content.
    /// Reading the first content block here is the documented way to crash.
    @Test func aRefusalIsHandledRatherThanCrashing() async throws {
        let recorder = Recorder(replies: [#"{"stop_reason":"refusal","content":[]}"#])
        let reply = try await backend(recorder).respond(to: "no", instructions: "", tools: [],
                                                        invoke: { _, _ in "" })
        #expect(reply == "That request was declined.")
    }

    @Test func anUnconnectedAccountFailsBeforeSendingAnything() async {
        let recorder = Recorder(replies: [])
        await #expect(throws: ErgonError.self) {
            try await backend(recorder, credentials: InMemoryCredentials([:]))
                .respond(to: "hi", instructions: "", tools: [], invoke: { _, _ in "" })
        }
        #expect(recorder.sent.isEmpty)
    }

    @Test func anApiErrorSurfacesTheReasonNotJustTheStatus() async {
        let failing: HTTPTransport = { request in
            (Data(#"{"error":{"message":"credit balance is too low"}}"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 400,
                             httpVersion: nil, headerFields: nil)!)
        }
        let backend = AnthropicBackend(
            credentials: InMemoryCredentials(["anthropic-api-key": "sk-test"]),
            transport: failing)

        await #expect(throws: ErgonError.generation("Model request failed (400): credit balance is too low")) {
            try await backend.respond(to: "hi", instructions: "", tools: [], invoke: { _, _ in "" })
        }
    }

    /// The key is a header, never a query item: a URL is logged by every proxy
    /// between here and the API.
    @Test func theKeyNeverReachesTheURL() async throws {
        let backend = AnthropicBackend(
            credentials: InMemoryCredentials(["anthropic-api-key": "sk-secret"]),
            transport: URLSessionTransport)
        let request = try backend.buildRequest(messages: [], instructions: "", tools: [], key: "sk-secret")

        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }
}
