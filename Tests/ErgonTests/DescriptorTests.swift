import Foundation
import Testing
@testable import Ergon
@testable import ErgonTools

/// A descriptor is written by hand and will one day arrive over the network,
/// so the decoder has to be strict about what it accepts and clear about what
/// it rejects. Silently dropping a malformed field would produce a tool that
/// exists but sends the wrong request.
@Suite struct DescriptorTests {
    @Test func theBundledGitHubDescriptorLoadsAndProducesTools() throws {
        let descriptor = try bundledService(named: "github")

        #expect(descriptor.name == "GitHub")
        #expect(descriptor.authentication == .none)
        #expect(descriptor.headers["X-GitHub-Api-Version"] == "2022-11-28")
        #expect(descriptor.operations.map(\.name) == ["searchRepositories", "listIssues"])

        let tools = descriptor.tools()
        #expect(tools.count == 2)
        #expect(tools.allSatisfy { $0.effect == .read })
    }

    /// The wire name differs from the name the model reasons about, and the
    /// path parameters have to survive decoding as path parameters.
    @Test func parametersKeepTheirWireNamesAndLocations() throws {
        let descriptor = try bundledService(named: "github")
        let search = try #require(descriptor.operations.first { $0.name == "searchRepositories" })
        #expect(search.parameters[0].property.name == "query")
        #expect(search.parameters[0].wireName == "q")
        #expect(search.parameters[0].location == .query)

        let issues = try #require(descriptor.operations.first { $0.name == "listIssues" })
        #expect(issues.parameters.map(\.location) == [.path, .path])
    }

    /// A descriptor from JSON must build the same request as one written in
    /// Swift, or the format is decorative.
    @Test func aDecodedDescriptorBuildsTheRequestItDescribes() async throws {
        let descriptor = try bundledService(named: "github")
        let issues = try #require(descriptor.operations.first { $0.name == "listIssues" })
        let executor = HTTPExecutor(service: descriptor, operation: issues,
                                    credentials: InMemoryCredentials([:]),
                                    transport: URLSessionTransport)

        let request = try await executor.buildRequest(
            ToolArguments(jsonString: #"{"owner": "apple", "repo": "swift"}"#))

        #expect(request.url?.absoluteString ==
                "https://api.github.com/repos/apple/swift/issues?per_page=5&state=open")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func aMalformedDescriptorNamesTheFieldThatIsWrong() {
        let missingURL = #"{"name": "X", "operations": []}"#
        #expect(throws: DescriptorError("baseURL", "expected a string")) {
            try ServiceDescriptor(json: missingURL)
        }

        let badAuth = """
            {"name": "X", "baseURL": "https://x.test", "auth": {"type": "query", "credential": "k"},
             "operations": [{"name": "op", "description": "d", "path": "/op",
                             "response": {"fields": [{"label": "A", "path": "a"}]}}]}
            """
        #expect(throws: DescriptorError("auth.type", "'query' is not one of none, bearer, header")) {
            try ServiceDescriptor(json: badAuth)
        }

        #expect(throws: DescriptorError("", "not valid JSON")) {
            try ServiceDescriptor(json: "{not json")
        }
    }

    /// A remote tool has no inverse to run, so a descriptor claiming
    /// reversibility would let it act unasked with an undo that cannot exist.
    @Test func aDescriptorCannotDeclareARemoteOperationReversible() {
        let json = """
            {"name": "X", "baseURL": "https://x.test", "operations": [
              {"name": "wipe", "description": "d", "path": "/wipe", "effect": "reversible",
               "response": {"fields": []}}]}
            """
        #expect(throws: DescriptorError.self) { try ServiceDescriptor(json: json) }
    }

    /// Without a projection the raw body reaches the model, which is how a
    /// single response eats the whole context window.
    @Test func anOperationWithoutAProjectionIsRejected() {
        let json = """
            {"name": "X", "baseURL": "https://x.test", "operations": [
              {"name": "list", "description": "d", "path": "/list"}]}
            """
        #expect(throws: DescriptorError.self) { try ServiceDescriptor(json: json) }
    }

    @Test func schemaTypesDecodeIncludingBoundsAndClosedSets() throws {
        let json = """
            {"name": "X", "baseURL": "https://x.test", "operations": [
              {"name": "op", "description": "d", "path": "/op",
               "parameters": [
                 {"name": "mode", "description": "m", "type": "string", "oneOf": ["fast", "slow"]},
                 {"name": "count", "description": "c", "type": "integer", "minimum": 1, "maximum": 9,
                  "optional": true},
                 {"name": "lat", "description": "l", "type": "number", "minimum": -90, "maximum": 90},
                 {"name": "tags", "description": "t", "type": "array", "items": {"type": "string"}}
               ],
               "response": {"fields": [{"label": "A", "path": "a"}]}}]}
            """
        let operation = try ServiceDescriptor(json: json).operations[0]
        #expect(operation.parameters[0].property.schema == .string(oneOf: ["fast", "slow"]))
        #expect(operation.parameters[1].property.schema == .integer(minimum: 1, maximum: 9))
        #expect(operation.parameters[1].property.isOptional)
        #expect(operation.parameters[2].property.schema == .number(minimum: -90, maximum: 90))
        #expect(operation.parameters[3].property.schema == .array(of: .string(oneOf: [])))

        // And the decoded shape still renders for the model, which is the only
        // thing that makes it a tool rather than a document.
        _ = try generationSchema(for: .object(name: "op",
                                              properties: operation.parameters.map(\.property)))
    }
}
