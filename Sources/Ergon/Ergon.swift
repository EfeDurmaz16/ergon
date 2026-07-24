import Foundation
import CryptoKit
import FoundationModels
import Observation

/// The runtime. Owns one model session, the approval gates around your tools,
/// and the receipt log. Natural language goes in through `run(_:)`; nothing
/// consequential comes out the other side without an approval.
@MainActor
@Observable
public final class Ergon {
    /// Emitted by `run(_:)`. `partial` carries the cumulative response text
    /// (FoundationModels streams snapshots, not deltas).
    public enum Event: Sendable {
        case partial(String)
        case needsApproval(Approval)
        case executed(Receipt)
        case reply(String)
    }

    public enum Availability: Sendable, Equatable {
        case ready
        case unavailable(UnavailableReason)
    }

    public enum UnavailableReason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    /// Staged calls waiting for a decision. Observable: drive your own UI
    /// from this, or attach the built-in sheet with `.approvalSheet(_:)`.
    public private(set) var pendingApprovals: [Approval] = []
    public private(set) var isRunning = false

    /// Where the JSONL receipt log lives.
    public let receiptsURL: URL

    private var session: LanguageModelSession
    private let store: ReceiptStore
    private var staged: [UUID: StagedAction] = [:]
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var currentIntent = ""

    /// Whether the on-device model can run here at all.
    public nonisolated static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.deviceNotEligible): .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady): .unavailable(.modelNotReady)
        case .unavailable: .unavailable(.unknown)
        }
    }

    /// Whether the model supports a locale. Turkish needs iOS 26.1 or later,
    /// so check this before promising a Turkish experience.
    public nonisolated static func supports(_ locale: Locale = .current) -> Bool {
        SystemLanguageModel.default.supportsLocale(locale)
    }

    /// - Parameters:
    ///   - tools: your tools. `ReadTool`s run freely; everything else is
    ///     approval-gated. An unclassified `Tool` is gated too (deny by default).
    ///   - instructions: system guidance for the model. Ergon appends the
    ///     current date, time, and time zone so relative dates resolve.
    ///   - receiptsURL: override the receipt log location (tests, demos).
    public init(tools: [any Tool], instructions: String? = nil, receiptsURL: URL? = nil) throws {
        let url = receiptsURL ?? URL.applicationSupportDirectory
            .appending(path: "Ergon/receipts.jsonl")
        self.receiptsURL = url
        self.store = try ReceiptStore(url: url)
        // Placeholder so self is fully initialized before the gate callbacks
        // capture it; replaced with the real tool-carrying session below.
        self.session = LanguageModelSession()

        var gated: [any FoundationModels.Tool] = []
        let stage: StageCallback = { [weak self] action in
            await self?.stage(action) ?? UUID()
        }
        let record: ReadRecordCallback = { [weak self] toolName, argsJSON, outcome, ms in
            await self?.recordRead(toolName: toolName, argumentsJSON: argsJSON, outcome: outcome, latencyMS: ms)
        }
        for tool in tools {
            if let consequential = tool as? any ConsequentialTool {
                gated.append(consequential.gate(stage: stage))
            } else if let read = tool as? any ReadTool {
                gated.append(read.gate(record: record))
            } else {
                gated.append(tool.fallbackGate(stage: stage))
            }
        }
        // ponytail: instructions capture the date at init; a session that
        // straddles midnight resolves "tomorrow" against the old day. Create
        // a new Ergon per conversation if that matters.
        self.session = LanguageModelSession(tools: gated, instructions: Self.composed(instructions))
    }

    /// Loads the model into memory ahead of the first intent to cut
    /// first-token latency. Call it when your input UI appears.
    public func prewarm() {
        session.prewarm()
    }

    /// Resolve one natural-language intent. Read tools may execute during the
    /// stream; consequential calls surface as `.needsApproval` and execute
    /// only via `approve(_:)`, which you can call during or after the stream.
    public func run(_ intent: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            if case .unavailable(let reason) = Self.availability {
                continuation.finish(throwing: ErgonError.modelUnavailable(reason))
                return
            }
            guard !isRunning else {
                continuation.finish(throwing: ErgonError.generation("a run is already in progress"))
                return
            }
            isRunning = true
            currentIntent = intent
            self.continuation = continuation
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    var finalText = ""
                    for try await snapshot in self.session.streamResponse(to: intent) {
                        finalText = snapshot.content
                        continuation.yield(.partial(snapshot.content))
                    }
                    continuation.yield(.reply(finalText))
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    continuation.finish(throwing: ErgonError(error))
                } catch let error as ErgonError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ErgonError.generation(String(describing: error)))
                }
                self.isRunning = false
                self.continuation = nil
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Execute a staged call. Exactly-once: a key that already succeeded
    /// returns the original receipt without executing; a key whose previous
    /// execution was interrupted throws instead of re-executing (fail closed).
    /// Tool failures do not throw; they return a receipt with a `failure`
    /// outcome so the denial/failure trail is never lost.
    @discardableResult
    public func approve(_ id: UUID) async throws -> Receipt {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }),
              let action = staged[id] else {
            throw ErgonError.unknownApproval
        }
        let approval = pendingApprovals[index]

        if let prior = await store.successReceipt(for: approval.idempotencyKey) {
            pendingApprovals.remove(at: index)
            staged[id] = nil
            return prior
        }
        if await store.hasUnresolvedPending(for: approval.idempotencyKey) {
            throw ErgonError.unresolvedExecution(idempotencyKey: approval.idempotencyKey)
        }

        // Marker first: if we die mid-execution, the next attempt fails
        // closed instead of double-executing.
        try await store.append(intent: currentIntent, toolName: approval.toolName,
                               argumentsJSON: approval.argumentsJSON,
                               idempotencyKey: approval.idempotencyKey,
                               decision: .approved, outcome: .pending, latencyMS: 0)
        pendingApprovals.remove(at: index)
        staged[id] = nil

        let start = ContinuousClock.now
        let outcome: Receipt.Outcome
        do {
            outcome = .success(try await action.execute())
        } catch {
            outcome = .failure(String(describing: error))
        }
        let receipt = try await store.append(intent: currentIntent, toolName: approval.toolName,
                                             argumentsJSON: approval.argumentsJSON,
                                             idempotencyKey: approval.idempotencyKey,
                                             decision: .approved, outcome: outcome,
                                             latencyMS: latencyMS(since: start))
        continuation?.yield(.executed(receipt))
        return receipt
    }

    /// Reject a staged call. Nothing executes; the denial itself is receipted.
    @discardableResult
    public func deny(_ id: UUID) async throws -> Receipt {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else {
            throw ErgonError.unknownApproval
        }
        let approval = pendingApprovals[index]
        pendingApprovals.remove(at: index)
        staged[id] = nil
        let receipt = try await store.append(intent: currentIntent, toolName: approval.toolName,
                                             argumentsJSON: approval.argumentsJSON,
                                             idempotencyKey: approval.idempotencyKey,
                                             decision: .denied, outcome: .denied, latencyMS: 0)
        continuation?.yield(.executed(receipt))
        return receipt
    }

    /// The full verified receipt trail, oldest first.
    public func receipts() async -> [Receipt] {
        await store.all()
    }

    // MARK: - Internal

    func stage(_ action: StagedAction) -> UUID {
        let approval = Approval(
            id: UUID(),
            toolName: action.toolName,
            preview: action.preview,
            isReversible: action.isReversible,
            argumentsJSON: action.argumentsJSON,
            idempotencyKey: Self.idempotencyKey(intent: currentIntent,
                                                toolName: action.toolName,
                                                argumentsJSON: action.argumentsJSON))
        staged[approval.id] = action
        pendingApprovals.append(approval)
        continuation?.yield(.needsApproval(approval))
        return approval.id
    }

    private func recordRead(toolName: String, argumentsJSON: String,
                            outcome: Receipt.Outcome, latencyMS: Int) async {
        // Read receipts are observability, not a money path: losing one to a
        // full disk should not break the tool call itself.
        let receipt = try? await store.append(intent: currentIntent, toolName: toolName,
                                              argumentsJSON: argumentsJSON, idempotencyKey: nil,
                                              decision: .autoRead, outcome: outcome,
                                              latencyMS: latencyMS)
        if let receipt {
            continuation?.yield(.executed(receipt))
        }
    }

    nonisolated static func idempotencyKey(intent: String, toolName: String, argumentsJSON: String) -> String {
        let material = [intent, toolName, argumentsJSON].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func composed(_ instructions: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: Date())
        let base = instructions ?? "Help the user by using the available tools."
        return base + "\nCurrent date and time: \(now) (time zone \(TimeZone.current.identifier)). Resolve relative dates like 'tomorrow' against this."
    }
}

extension ErgonError {
    init(_ error: LanguageModelSession.GenerationError) {
        self = switch error {
        case .guardrailViolation: .guardrailRefusal
        case .refusal: .guardrailRefusal
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        case .exceededContextWindowSize: .contextOverflow
        default: .generation(String(describing: error))
        }
    }
}
