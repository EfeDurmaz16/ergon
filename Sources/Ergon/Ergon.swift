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

    private struct StagedEntry {
        let runGeneration: Int
        let action: StagedAction
    }

    @ObservationIgnored private var session: LanguageModelSession
    private let store: ReceiptStore
    @ObservationIgnored private var staged: [UUID: StagedEntry] = [:]
    @ObservationIgnored private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    @ObservationIgnored var currentIntent = ""
    @ObservationIgnored private var runGeneration = 0
    /// The wrapped tools actually handed to the model session. Internal so
    /// tests can drive a gate exactly the way the model would.
    @ObservationIgnored private(set) var gatedTools: [any FoundationModels.Tool] = []

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
    ///     Receipts store intents, arguments, and tool outputs in cleartext;
    ///     the file is created with until-first-unlock protection on iOS,
    ///     and rotation is the host's call via `quarantineReceipts(at:)`.
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
        self.gatedTools = gated
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
    /// `.executed` events reach the stream only while the run that staged
    /// the call is still streaming; for approvals decided later (the common
    /// case) take the receipt from `approve`'s return value or `receipts()`.
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
            runGeneration += 1
            let thisRun = runGeneration
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
                self.endRun(thisRun)
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                // A consumer that stops iterating early must not leave
                // isRunning latched while the generation winds down.
                Task { @MainActor [weak self] in self?.endRun(thisRun) }
            }
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
              let entry = staged[id] else {
            throw ErgonError.unknownApproval
        }
        let approval = pendingApprovals[index]
        // Consume the token synchronously, before any suspension point: a
        // second approve(id) racing this one must get unknownApproval, not a
        // second execution. This is MainActor state, so no interleave window.
        pendingApprovals.remove(at: index)
        staged[id] = nil

        // Atomic check-and-reserve inside the store actor. Two approvals
        // sharing one idempotency key (the model staged the same call twice)
        // cannot both pass this line: it writes the pending marker in the
        // same actor call, so the loser fails closed. The marker also means
        // dying mid-execution refuses re-execution on the next attempt.
        let reservation: ReceiptStore.Reservation
        do {
            reservation = try await store.reserve(intent: approval.intent,
                                                  toolName: approval.toolName,
                                                  argumentsJSON: approval.argumentsJSON,
                                                  idempotencyKey: approval.idempotencyKey)
        } catch let error as ErgonError {
            // The refusal itself is part of the audit trail.
            _ = try? await store.append(intent: approval.intent, toolName: approval.toolName,
                                    argumentsJSON: approval.argumentsJSON,
                                    idempotencyKey: nil, decision: .refused,
                                    outcome: .failure(error.errorDescription ?? "refused"),
                                    latencyMS: 0)
            throw error
        }
        if case .alreadySucceeded(let prior) = reservation {
            return prior
        }

        let start = ContinuousClock.now
        let outcome: Receipt.Outcome
        do {
            outcome = .success(try await entry.action.execute())
        } catch {
            outcome = .failure(String(describing: error))
        }
        let receipt = try await store.append(intent: approval.intent, toolName: approval.toolName,
                                             argumentsJSON: approval.argumentsJSON,
                                             idempotencyKey: approval.idempotencyKey,
                                             decision: .approved, outcome: outcome,
                                             latencyMS: latencyMS(since: start))
        yieldIntoOriginatingRun(entry.runGeneration, .executed(receipt))
        return receipt
    }

    /// Reject a staged call. Nothing executes; the denial itself is receipted.
    @discardableResult
    public func deny(_ id: UUID) async throws -> Receipt {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }),
              let entry = staged[id] else {
            throw ErgonError.unknownApproval
        }
        let approval = pendingApprovals[index]
        pendingApprovals.remove(at: index)
        staged[id] = nil
        let receipt = try await store.append(intent: approval.intent, toolName: approval.toolName,
                                             argumentsJSON: approval.argumentsJSON,
                                             idempotencyKey: approval.idempotencyKey,
                                             decision: .denied, outcome: .denied, latencyMS: 0)
        yieldIntoOriginatingRun(entry.runGeneration, .executed(receipt))
        return receipt
    }

    /// The full verified receipt trail, oldest first.
    public func receipts() async -> [Receipt] {
        await store.all()
    }

    /// Re-verifies a receipt log's hash chain from disk. Tamper evidence is
    /// only a claim if anyone can check it. A missing or empty log verifies
    /// as true: there is nothing to have tampered with. Detecting deletion
    /// of the whole log needs an anchor outside the file and is out of
    /// scope here.
    public nonisolated static func verifyReceipts(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return ReceiptStore.verifyChain(at: url)
    }

    /// Recovery for a log that fails verification: moves it aside to
    /// `<name>.corrupt-<timestamp>` so the evidence is preserved and a
    /// fresh chain can start, and returns the quarantine location.
    /// The next `Ergon.init` on the same URL will then succeed.
    public nonisolated static func quarantineReceipts(at url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + ".corrupt-" + stamp)
        try FileManager.default.moveItem(at: url, to: destination)
        let head = ReceiptStore.headURL(for: url)
        if FileManager.default.fileExists(atPath: head.path) {
            try? FileManager.default.moveItem(at: head, to: ReceiptStore.headURL(for: destination))
        }
        return destination
    }

    // MARK: - Internal

    func stage(_ action: StagedAction) -> UUID {
        let approval = Approval(
            id: UUID(),
            intent: currentIntent,
            toolName: action.toolName,
            preview: action.preview,
            isReversible: action.isReversible,
            argumentsJSON: action.argumentsJSON,
            idempotencyKey: Self.idempotencyKey(intent: currentIntent,
                                                toolName: action.toolName,
                                                argumentsJSON: action.argumentsJSON))
        staged[approval.id] = StagedEntry(runGeneration: runGeneration, action: action)
        pendingApprovals.append(approval)
        continuation?.yield(.needsApproval(approval))
        return approval.id
    }

    private func endRun(_ generation: Int) {
        guard generation == runGeneration else { return }
        isRunning = false
        continuation = nil
    }

    /// Receipts stream only into the run that staged the call. Approvals
    /// decided after their run finished (the common case) are delivered by
    /// approve's return value and `receipts()`, never into a later run's
    /// stream.
    private func yieldIntoOriginatingRun(_ generation: Int, _ event: Event) {
        guard generation == runGeneration else { return }
        continuation?.yield(event)
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

    /// Keys are exact, not semantic: same intent string, same tool, same
    /// canonical arguments. Arguments are re-serialized with sorted keys so
    /// a tool whose JSON key order varies between processes cannot dodge
    /// idempotency; fields are length-prefixed so no crafted delimiter can
    /// make two different calls collide.
    nonisolated static func idempotencyKey(intent: String, toolName: String, argumentsJSON: String) -> String {
        var material = Data()
        for field in [intent, toolName, canonicalJSON(argumentsJSON)] {
            let bytes = Data(field.utf8)
            material.append(Data("\(bytes.count):".utf8))
            material.append(bytes)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func canonicalJSON(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            return raw
        }
        return string
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
