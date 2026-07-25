import Foundation
import FoundationModels
import Observation

/// Two-stage resolution for large tool catalogs: a tiny classifier call
/// picks a ``Toolset``, then that domain's engine (carrying only its few
/// tools) resolves the intent. Approval, receipts, and idempotency are the
/// engines' unchanged machinery; the router only routes.
///
/// The domain split exists for exactly one reason: the on-device model shares
/// a 4096-token window with its output and picks the wrong tool as the catalog
/// grows. A capable model has neither problem, so when one is connected the
/// router also decides which model runs the intent, and hands the capable one
/// the whole catalog rather than a slice of it.
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
    /// Carries every tool; only the capable tier drives it.
    private var orchestration: Ergon
    @ObservationIgnored private let backend: (any ModelBackend)?

    /// Classification is stateless, so it gets a fresh session per call. A
    /// single long-lived classifier session appends every request and reply to
    /// its transcript and crosses the 4096-token window after a dozen or so
    /// intents, after which every route fails with a context overflow and the
    /// whole assistant appears dead.
    @ObservationIgnored private static let classifierInstructions = """
    You route user requests to exactly one toolset. Reply with only the toolset name.
    Choose by what the user wants done, not by nouns they happen to mention. A request to be reminded to call someone is a reminder, not a contact lookup.
    """

    /// Asked only when a capable model is connected, and asked on its own.
    ///
    /// Measured on the real classifier over the same intents: asked as a yes/no
    /// judgement it is right 5 times in 9, and asked as a second field beside
    /// the domain it leaves the list empty and nothing ever escalates, because
    /// a small model spends its effort on whichever field is primary. Asked for
    /// a bare list of toolsets it names the topic rather than counting the work
    /// ("find the swift repo and write a note about it" is one name, github).
    /// Making it write down each action first is what makes it count them:
    /// that scores 13 of 14, and its one miss escalates a single Turkish
    /// request it split in two, which costs money rather than correctness.
    /// Classification is a decision, not prose. Left to sample, the same
    /// request routes two ways on two runs: the whole suite caught a
    /// single-step intent escalating that had stayed on device moments before.
    @ObservationIgnored private static let classifierOptions =
        GenerationOptions(sampling: .greedy)

    @ObservationIgnored private static let scopeInstructions = """
    You list the separate actions a request asks for, in order, and name the toolset each action uses.
    An action is something the assistant has to do. "check the weather and tell me" is one action; "check the weather and write it down" is two.
    Most requests are a single action.
    """

    /// Guidance for the capable tier. It carries every tool, so the one thing
    /// it must be told is that a tool changing something may not have run yet.
    @ObservationIgnored public static let orchestrationInstructions = """
    You carry out multi-step requests using the tools available. Reply in the language of the request.
    Some tools finish immediately and some only ask the user for permission first. Do not guess which: read what the tool returned and say exactly that. Never announce a result the tool did not report.
    Work through the steps yourself rather than asking the user what to do next, and stop to ask only when a choice genuinely changes the outcome.
    Pass times as ISO 8601 with offset like 2026-07-25T09:00:00+03:00.
    """

    /// Which model resolves an intent.
    public enum Tier: Sendable, Equatable {
        /// The on-device model, carrying one domain's few tools. Private, free,
        /// offline, and enough for a single action.
        case onDevice(domain: String)
        /// A capable model carrying the whole catalog. For requests that span
        /// domains or whose steps depend on each other, which no calling
        /// convention lets a 3B model with a 4096-token window carry.
        case capable
    }

    public struct Routing: Sendable, Equatable {
        public let domain: String
        public let needsMoreThanOneDomain: Bool
    }

    /// Merged pending approvals across all domains, oldest first.
    public var pendingApprovals: [Approval] {
        engines.values.flatMap(\.pendingApprovals) + orchestration.pendingApprovals
    }

    /// Reversible actions that already ran, across every domain.
    public var undoable: [Ergon.UndoableAction] {
        engines.values.flatMap(\.undoable) + orchestration.undoable
    }

    public var isRunning: Bool {
        engines.values.contains(where: \.isRunning) || general.isRunning || orchestration.isRunning
    }

    /// - Parameter receiptsDirectory: each domain appends to its own
    ///   hash-chained log in this directory (`receipts-<name>.jsonl`), plus
    ///   `receipts-general.jsonl` for unrouted small talk.
    /// - Parameter backend: a capable model, when the user has connected one.
    ///   Without it every intent stays on device: an assistant that silently
    ///   stops working when a key is missing is worse than one that never had
    ///   the tier.
    public init(toolsets: [Toolset], receiptsDirectory: URL? = nil,
                backend: (any ModelBackend)? = nil) throws {
        precondition(!toolsets.isEmpty, "Router needs at least one toolset")
        let directory = receiptsDirectory ?? URL.applicationSupportDirectory.appending(path: "Ergon")
        // Build locals first: every @Observable stored property must be
        // assigned before any is mutated in place.
        var builtEngines: [String: Ergon] = [:]
        for toolset in toolsets {
            builtEngines[toolset.name] = try Ergon(
                tools: toolset.tools,
                dynamicTools: toolset.dynamicTools,
                instructions: toolset.instructions,
                receiptsURL: directory.appending(path: "receipts-\(toolset.name).jsonl"))
        }
        let builtGeneral = try Ergon(
            tools: [],
            instructions: "Answer briefly in the language of the user's request.",
            receiptsURL: directory.appending(path: "receipts-general.jsonl"))
        // One engine carrying every tool, used only by the capable tier. Its
        // catalog is deliberately the union: the reason for splitting does not
        // apply to a model with a million-token window, and an intent that
        // spans domains cannot be served by a slice.
        let builtOrchestration = try Ergon(
            tools: toolsets.flatMap(\.tools),
            dynamicTools: toolsets.flatMap(\.dynamicTools),
            instructions: Self.orchestrationInstructions,
            receiptsURL: directory.appending(path: "receipts-orchestration.jsonl"))
        self.toolsets = toolsets
        self.engines = builtEngines
        self.general = builtGeneral
        self.orchestration = builtOrchestration
        self.backend = backend
    }

    /// Classify, then forward the chosen engine's stream. Emits `.routed`
    /// first so hosts can show where the intent went.
    public func run(_ intent: String) -> AsyncThrowingStream<Ergon.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let tier = try await self.tier(for: intent)
                    switch tier {
                    case .onDevice(let domain):
                        continuation.yield(.routed(domain))
                        let engine = self.engines[domain] ?? self.general
                        for try await event in engine.run(intent) {
                            continuation.yield(event)
                        }
                    case .capable:
                        guard let backend = self.backend else {
                            continuation.finish(throwing: ErgonError.generation("No capable model connected."))
                            return
                        }
                        continuation.yield(.routed("orchestration"))
                        for try await event in self.orchestration.run(intent, on: backend) {
                            continuation.yield(event)
                        }
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
        guard let engine = allEngines.first(where: { $0.pendingApprovals.contains { $0.id == id } }) else {
            throw ErgonError.unknownApproval
        }
        return try await engine.approve(id)
    }

    @discardableResult
    public func undo(_ id: UUID) async throws -> Receipt {
        guard let engine = allEngines.first(where: { $0.undoable.contains { $0.id == id } }) else {
            throw ErgonError.unknownApproval
        }
        return try await engine.undo(id)
    }

    @discardableResult
    public func deny(_ id: UUID) async throws -> Receipt {
        guard let engine = allEngines.first(where: { $0.pendingApprovals.contains { $0.id == id } }) else {
            throw ErgonError.unknownApproval
        }
        return try await engine.deny(id)
    }

    /// All domains' receipts merged, oldest first. Each domain's own log
    /// stays independently hash-chain verifiable.
    public func receipts() async -> [Receipt] {
        var all: [Receipt] = []
        for engine in allEngines {
            all.append(contentsOf: await engine.receipts())
        }
        all.append(contentsOf: await general.receipts())
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    /// Prewarming loads the model itself, which every session shares, so
    /// warming the general engine is enough for the classifier too.
    public func prewarm() {
        general.prewarm()
    }

    /// The domain this intent would route to, without running it. Useful for
    /// previews, tests, and showing the user where a request will go.
    public func route(_ intent: String) async throws -> String {
        try await classify(intent).domain
    }

    // MARK: - Internal

    /// The domain question, unchanged: it measures 15 out of 15 on the routing
    /// suite and replacing it with the scope question cost that accuracy.
    func classify(_ intent: String) async throws -> Routing {
        // Without a connected model there is nothing to escalate to, so the
        // second question is not worth asking or paying for.
        guard backend != nil else {
            return Routing(domain: try await domain(for: intent), needsMoreThanOneDomain: false)
        }
        async let domain = domain(for: intent)
        async let spans = spansDomains(intent)
        return Routing(domain: try await domain, needsMoreThanOneDomain: await spans)
    }

    private func domain(for intent: String) async throws -> String {
        let names = toolsets.map(\.name) + ["general"]
        let schema = GenerationSchema(type: String.self,
                                      description: "The single best toolset name for the request.",
                                      anyOf: names)
        let classifier = LanguageModelSession(instructions: Self.classifierInstructions)
        let response = try await classifier.respond(to: menuPrompt(intent), schema: schema,
                                                    options: Self.classifierOptions)
        let choice = (try? response.content.value(String.self)) ?? "general"
        return names.contains(choice) ? choice : "general"
    }

    /// Never throws: a failed scope call means the intent stays on device,
    /// which is the safe direction. Escalating on a guess would spend the
    /// user's money on a request the phone could answer.
    private func spansDomains(_ intent: String) async -> Bool {
        let names = toolsets.map(\.name) + ["general"]
        guard let schema = try? generationSchema(for: .object(name: "scope", properties: [
            SchemaProperty(name: "steps", description: "The actions the request asks for, in order.",
                           schema: .array(of: .object(name: "step", properties: [
                               SchemaProperty(name: "action", description: "What to do, in a few words.",
                                              schema: .string(oneOf: [])),
                               SchemaProperty(name: "toolset", description: "The toolset that action uses.",
                                              schema: .string(oneOf: names)),
                           ]))),
        ])) else { return false }
        let classifier = LanguageModelSession(instructions: Self.scopeInstructions)
        guard let response = try? await classifier.respond(to: menuPrompt(intent), schema: schema,
                                                           options: Self.classifierOptions),
              let steps = try? response.content.value([GeneratedContent].self, forProperty: "steps") else {
            return false
        }
        // A step in "general" is the model answering or narrating rather than
        // reaching for tools, and counting it escalates plain questions.
        let used = steps.compactMap { try? $0.value(String.self, forProperty: "toolset") }
            .filter { names.contains($0) && $0 != "general" }
        return Set(used).count > 1
    }

    private func menuPrompt(_ intent: String) -> String {
        let menu = toolsets.map { "\($0.name): \($0.description)" }
            .joined(separator: "\n") + "\ngeneral: anything else, questions, small talk"
        return "Toolsets:\n\(menu)\n\nRequest: \(intent)\n\nRouting:"
    }

    /// Which tier an intent lands on, without running it.
    public func tier(for intent: String) async throws -> Tier {
        let routing = try await classify(intent)
        // No connected model means no tier to escalate to. Saying so is the
        // job of whatever tries to run it, not of the router.
        guard backend != nil, routing.needsMoreThanOneDomain else {
            return .onDevice(domain: routing.domain)
        }
        return .capable
    }

    /// Every engine that can hold an approval or an undo.
    private var allEngines: [Ergon] {
        Array(engines.values) + [orchestration]
    }

    /// Engine lookup for tests and advanced hosts.
    func engine(for name: String) -> Ergon? {
        engines[name]
    }
}
