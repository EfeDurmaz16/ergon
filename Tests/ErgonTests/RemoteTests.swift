import Foundation
import Testing
@testable import Ergon

/// The descriptor path is where a remote service stops being code, so these
/// tests pin the two things that go silently wrong: a request built with the
/// wrong values, and a response big enough to eat the whole context window.
@Suite struct RemoteTests {
    private func service(auth: ServiceAuthentication = .none) -> ServiceDescriptor {
        ServiceDescriptor(
            name: "probe",
            baseURL: URL(string: "https://api.example.com")!,
            authentication: auth,
            headers: ["Accept": "application/json"],
            operations: [
                ServiceOperation(
                    name: "findThings",
                    description: "Find things",
                    path: "/repos/{owner}/things",
                    parameters: [
                        ServiceParameter(SchemaProperty(name: "owner", description: "who",
                                                        schema: .string(oneOf: [])), in: .path),
                        ServiceParameter(SchemaProperty(name: "query", description: "what",
                                                        schema: .string(oneOf: [])), in: .query, wireName: "q"),
                        ServiceParameter(SchemaProperty(name: "limit", description: "how many",
                                                        schema: .integer(minimum: 1, maximum: 50),
                                                        isOptional: true), in: .query),
                    ],
                    fixedQuery: ["sort": "updated"],
                    projection: ResponseProjection(
                        itemsPath: "items",
                        fields: [ProjectionField(label: "Title", path: "title"),
                                 ProjectionField(label: "By", path: "user.login")],
                        maximumItems: 2)),
            ])
    }

    private func executor(_ descriptor: ServiceDescriptor,
                          credentials: any CredentialStore = InMemoryCredentials([:])) -> HTTPExecutor {
        HTTPExecutor(service: descriptor, operation: descriptor.operations[0],
                     credentials: credentials, transport: URLSessionTransport)
    }

    @Test func argumentsLandInTheRightPartOfTheRequest() async throws {
        let request = try await executor(service()).buildRequest(ToolArguments(jsonString: #"""
            {"owner": "efe", "query": "engine", "limit": 3}
            """#))

        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://api.example.com/repos/efe/things?limit=3&q=engine&sort=updated")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// An integer argument is a JSON number, and half of the APIs in the world
    /// reject "3.0" where they accept "3".
    @Test func integersGoOnTheWireWithoutADecimalPoint() async throws {
        let request = try await executor(service()).buildRequest(
            ToolArguments(jsonString: #"{"owner": "efe", "query": "x", "limit": 10}"#))
        #expect(request.url?.absoluteString.contains("limit=10") == true)
    }

    /// A path parameter carrying a slash would address a different endpoint.
    @Test func aPathArgumentCannotEscapeItsSegment() async throws {
        let request = try await executor(service()).buildRequest(
            ToolArguments(jsonString: #"{"owner": "efe/../admin", "query": "x"}"#))
        let url = try #require(request.url?.absoluteString)
        #expect(!url.contains("/admin/"))
        #expect(url.contains("efe%2F..%2Fadmin"))
    }

    /// Omitted optional arguments must vanish, not appear as empty or null.
    @Test func omittedOptionalsDoNotReachTheWire() async throws {
        let request = try await executor(service()).buildRequest(
            ToolArguments(jsonString: #"{"owner": "efe", "query": "x"}"#))
        #expect(request.url?.absoluteString.contains("limit") == false)
    }

    @Test func credentialsBecomeAHeaderAndNothingElse() async throws {
        let descriptor = service(auth: .bearer(credential: "probe-token"))
        let request = try await executor(descriptor,
                                         credentials: InMemoryCredentials(["probe-token": "s3cret"]))
            .buildRequest(ToolArguments(jsonString: #"{"owner": "efe", "query": "x"}"#))

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        // The secret must not have leaked into the URL, where it would end up
        // in every proxy and access log between here and the service.
        #expect(request.url?.absoluteString.contains("s3cret") == false)
    }

    @Test func anUnconnectedServiceFailsBeforeSendingAnything() async {
        let descriptor = service(auth: .bearer(credential: "probe-token"))
        await #expect(throws: ErgonError.self) {
            try await executor(descriptor).buildRequest(
                ToolArguments(jsonString: #"{"owner": "efe", "query": "x"}"#))
        }
    }

    @Test func theResponseIsProjectedDownToWhatWasAskedFor() {
        let json = try! #require(JSONValue(jsonString: #"""
            {"items": [
                {"title": "First", "user": {"login": "efe"}, "body": "a very long body"},
                {"title": "Second", "user": {"login": "ada"}, "body": "another long body"},
                {"title": "Third", "user": {"login": "raf"}}
            ]}
            """#))

        let summary = executor(service()).project(json)

        #expect(summary == """
            1. Title: First, By: efe
            2. Title: Second, By: ada
            Showing 2 of 3.
            """)
        #expect(!summary.contains("long body"), "unasked-for fields must not reach the model")
    }

    @Test func aMissingPathYieldsNothingRatherThanCrashing() {
        let run = executor(service())
        let json = try! #require(JSONValue(jsonString: #"{"items": [{"title": "Only"}]}"#))
        #expect(value(at: "items[0].user.login", in: json) == nil)
        #expect(value(at: "items[7].title", in: json) == nil)
        #expect(run.project(json) == "1. Title: Only")
    }

    /// Naming the fields bounds the shape of a response but not its size. A
    /// real GitHub search returns a repository whose description alone is
    /// 190,000 characters, twelve times the context window, and the generation
    /// dies before it can answer.
    @Test func oneEnormousFieldCannotEatTheContextWindow() {
        let huge = String(repeating: "x", count: 200_000)
        let json = try! #require(JSONValue(jsonString: JSONValue.object([
            "items": .array([.object(["title": .string(huge),
                                      "user": .object(["login": .string("efe")])])]),
        ]).jsonString))

        let summary = executor(service()).project(json)

        #expect(summary.count < 2_100, "projected \(summary.count) characters")
        #expect(summary.contains("…"), "a trimmed value must say so")
        #expect(summary.contains("By: efe"), "later fields must survive the trim")
    }

    /// Most list endpoints answer with a bare array. Without a way to say so,
    /// a descriptor has to address items by index and can only ever describe
    /// the first one, which reads to the user as "there is only one".
    @Test func aRootLevelArrayCanBeProjectedAsTheItemList() {
        let descriptor = ServiceDescriptor(
            name: "probe",
            baseURL: URL(string: "https://api.example.com")!,
            operations: [ServiceOperation(
                name: "list", description: "d", path: "/list",
                projection: ResponseProjection(
                    itemsPath: ".",
                    fields: [ProjectionField(label: "Title", path: "title")]))])
        let run = HTTPExecutor(service: descriptor, operation: descriptor.operations[0],
                               credentials: InMemoryCredentials([:]), transport: URLSessionTransport)
        let json = try! #require(JSONValue(jsonString: #"[{"title": "One"}, {"title": "Two"}]"#))

        #expect(run.project(json) == "1. Title: One\n2. Title: Two")
    }

    @Test func anEmptyResultReadsAsEmptyRatherThanAsAnError() {
        let json = try! #require(JSONValue(jsonString: #"{"items": []}"#))
        #expect(executor(service()).project(json) == "No results.")
    }

    /// A descriptor produces tools the engine gates like any other, and a
    /// remote tool is never reversible because no descriptor declares an
    /// inverse operation.
    @Test func aDescriptorProducesGatedTools() {
        let tools = service().tools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "findThings")
        #expect(tools[0].effect == .read)
        #expect(tools[0].arguments.count == 3)
    }
}
