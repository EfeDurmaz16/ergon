import Foundation
import FoundationModels
import Observation

/// Two-stage resolution for large tool catalogs: a tiny classifier call
/// picks a ``Toolset``, then that domain's engine (carrying only its few
/// tools) resolves the intent. Approval, receipts, and idempotency are the
/// engines' unchanged machinery; the router only routes.
@MainActor
@Observable
public final class Router {
    public private(set) var toolsets: [Toolset]
    // NOT @ObservationIgnored: the UI reads pendingApprovals/isRunning through
    // these, and each Ergon is itself @Observable, so observation must reach
    // through the dictionary to the engines' own published state. Ignoring it
    // would leave the approval sheet blind to a staged call.
    private var engines: [String: Ergon] = [:]
    private var general: Ergon
    @ObservationIgnored private let classifier: LanguageModelSession

    /// Merged pending approvals across all domains, oldest first.
    public var pendingApprovals: [Approval] {
        engines.values.flatMap(\.pendingApprovals)
    }

    public var isRunning: Bool {
        engines.values.contains(where: \.isRunning) || general.isRunning
    }

    /// - Parameter receiptsDirectory: each domain appends to its own
    ///   hash-chained log in this directory (`receipts-<name>.jsonl`), plus
    ///   `receipts-general.jsonl` for unrouted small talk.
    public init(toolsets: [Toolset], receiptsDirectory: URL? = nil) throws {
        precondition(!toolsets.isEmpty, "Router needs at least one toolset")
        let directory = receiptsDirectory ?? URL.applicationSupportDirectory.appending(path: "Ergon")
        // Build locals first: every @Observable stored property must be
        // assigned before any is mutated in place.
        var builtEngines: [String: Ergon] = [:]
        for toolset in toolsets {
            builtEngines[toolset.name] = try Ergon(
                tools: toolset.tools,
                instructions: toolset.instructions,
                receiptsURL: directory.appending(path: "receipts-\(toolset.name).jsonl"))
        }
        let builtGeneral = try Ergon(
            tools: [],
            instructions: "Answer briefly in the language of the user's request.",
            receiptsURL: directory.appending(path: "receipts-general.jsonl"))
        self.toolsets = toolsets
        self.engines = builtEngines
        self.general = builtGeneral
        self.classifier = LanguageModelSession(
            instructions: "You route user requests to exactly one toolset. Reply with only the toolset name.")
    }

    /// Classify, then forward the chosen engine's stream. Emits `.routed`
    /// first so hosts can show where the intent went.
    public func run(_ intent: String) -> AsyncThrowingStream<Ergon.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let domain = try await self.classify(intent)
                    continuation.yield(.routed(domain))
                    let engine = self.engines[domain] ?? self.general
                    for try await event in engine.run(intent) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: ErgonError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func approve(_ id: UUID) async throws -> Receipt {
        guard let engine = engines.values.first(where: { $0.pendingApprovals.contains { $0.id == id } }) else {
            throw ErgonError.unknownApproval
        }
        return try await engine.approve(id)
    }

    @discardableResult
    public func deny(_ id: UUID) async throws -> Receipt {
        guard let engine = engines.values.first(where: { $0.pendingApprovals.contains { $0.id == id } }) else {
            throw ErgonError.unknownApproval
        }
        return try await engine.deny(id)
    }

    /// All domains' receipts merged, oldest first. Each domain's own log
    /// stays independently hash-chain verifiable.
    public func receipts() async -> [Receipt] {
        var all: [Receipt] = []
        for engine in engines.values {
            all.append(contentsOf: await engine.receipts())
        }
        all.append(contentsOf: await general.receipts())
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    public func prewarm() {
        classifier.prewarm()
    }

    /// The domain this intent would route to, without running it. Useful for
    /// previews, tests, and showing the user where a request will go.
    public func route(_ intent: String) async throws -> String {
        try await classify(intent)
    }

    // MARK: - Internal

    func classify(_ intent: String) async throws -> String {
        let names = toolsets.map(\.name) + ["general"]
        let menu = toolsets.map { "\($0.name): \($0.description)" }
            .joined(separator: "\n") + "\ngeneral: anything else, questions, small talk"
        let schema = GenerationSchema(type: String.self,
                                      description: "The single best toolset name for the request.",
                                      anyOf: names)
        let prompt = "Toolsets:\n\(menu)\n\nRequest: \(intent)\n\nBest toolset:"
        let response = try await classifier.respond(to: prompt, schema: schema,
                                                    options: GenerationOptions())
        let choice = (try? response.content.value(String.self)) ?? "general"
        return names.contains(choice) ? choice : "general"
    }

    /// Engine lookup for tests and advanced hosts.
    func engine(for name: String) -> Ergon? {
        engines[name]
    }
}
