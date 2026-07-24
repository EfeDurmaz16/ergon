import Foundation
import Testing
import FoundationModels
@testable import Ergon
@testable import ErgonTools

/// Regression tests from the adversarial review: same-key races, intent
/// attribution, torn logs, double-open, both-conformance gating, and the
/// hand-conformed ErgonTools argument schemas.
@MainActor
@Suite struct HardeningTests {
    private func makeEngine(tools: [any ErgonTool],
                            url: URL = temporaryLogURL()) throws -> Ergon {
        try Ergon(tools: tools, receiptsURL: url)
    }

    @Test func concurrentDistinctApprovalsSharingKeyExecuteOnce() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        // The model stages the same call twice in one generation: two
        // approvals, distinct ids, one idempotency key.
        _ = try await gate.call(arguments: .init(value: "x"))
        _ = try await gate.call(arguments: .init(value: "x"))
        #expect(engine.pendingApprovals.count == 2)
        let ids = engine.pendingApprovals.map(\.id)
        let keys = Set(engine.pendingApprovals.map(\.idempotencyKey))
        #expect(keys.count == 1)

        // A concurrent-approval host approves both at once. Exactly one
        // execution; the loser either fails closed or returns the winner's
        // receipt, never a second execution.
        let first = Task { @MainActor in try await engine.approve(ids[0]) }
        let second = Task { @MainActor in try await engine.approve(ids[1]) }
        let outcomes = [await first.result, await second.result]

        #expect(spy.executionCount == 1)
        let receipts = outcomes.compactMap { try? $0.get() }
        let successes = receipts.filter {
            if case .success = $0.outcome { return true } else { return false }
        }
        #expect(Set(successes.map(\.id)).count <= 1)
    }

    @Test func receiptsCarryTheStagingIntentNotTheCurrentOne() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        engine.currentIntent = "book the dentist"
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)
        #expect(approval.intent == "book the dentist")

        // A second run starts before the user decides.
        engine.currentIntent = "what is on friday"
        let receipt = try await engine.approve(approval.id)

        #expect(receipt.intent == "book the dentist")
    }

    @Test func refusalIsReceipted() async throws {
        let url = temporaryLogURL()
        let argumentsJSON = SpyArguments(value: "x").generatedContent.jsonString
        let key = Ergon.idempotencyKey(intent: "", toolName: "spy", argumentsJSON: argumentsJSON)
        do {
            let store = try ReceiptStore(url: url)
            try await store.append(intent: "", toolName: "spy", argumentsJSON: argumentsJSON,
                                   idempotencyKey: key, decision: .approved,
                                   outcome: .pending, latencyMS: 0)
        }

        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy], url: url)
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)

        await #expect(throws: ErgonError.unresolvedExecution(idempotencyKey: key)) {
            try await engine.approve(approval.id)
        }
        let receipts = await engine.receipts()
        #expect(receipts.last?.decision == .refused)
        #expect(spy.executionCount == 0)
    }

    @Test func bothConformancesAreGatedConsequentially() async throws {
        let tool = SpyBothTool()
        let engine = try makeEngine(tools: [tool])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyBothTool>)

        _ = try await gate.call(arguments: .init(value: "x"))

        #expect(tool.executions.withLock { $0 } == 0)
        #expect(engine.pendingApprovals.count == 1)
    }

    @Test func tornTailIsTruncatedAndStoreRecovers() async throws {
        let url = temporaryLogURL()
        do {
            let store = try ReceiptStore(url: url)
            try await store.append(intent: "first", toolName: "t", argumentsJSON: "{}",
                                   idempotencyKey: nil, decision: .autoRead,
                                   outcome: .success("ok"), latencyMS: 1)
            try await store.append(intent: "second", toolName: "t", argumentsJSON: "{}",
                                   idempotencyKey: nil, decision: .autoRead,
                                   outcome: .success("ok"), latencyMS: 1)
        }
        // Crash mid-append: a partial line with no terminating newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"torn"#.utf8))
        try handle.close()

        let reopened = try ReceiptStore(url: url)
        #expect(await reopened.all().count == 2)
        try await reopened.append(intent: "third", toolName: "t", argumentsJSON: "{}",
                                  idempotencyKey: nil, decision: .autoRead,
                                  outcome: .success("ok"), latencyMS: 1)
        #expect(ReceiptStore.verifyChain(at: url))
        #expect(await reopened.all().count == 3)
    }

    @Test func secondStoreOnSamePathFailsClosed() async throws {
        let url = temporaryLogURL()
        let store = try ReceiptStore(url: url)
        #expect(throws: ErgonError.self) {
            _ = try ReceiptStore(url: url)
        }
        withExtendedLifetime(store) {}
    }

    @Test func verifyReceiptsOnEmptyAndMissingLogs() throws {
        let missing = temporaryLogURL()
        #expect(Ergon.verifyReceipts(at: missing))

        let empty = temporaryLogURL()
        try FileManager.default.createDirectory(at: empty.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: empty)
        #expect(Ergon.verifyReceipts(at: empty))
    }

    @Test func quarantineMovesCorruptLogAside() async throws {
        let url = temporaryLogURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "garbage line\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ErgonError.self) { _ = try ReceiptStore(url: url) }

        let moved = try Ergon.quarantineReceipts(at: url)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try ReceiptStore(url: url)
    }

    @Test func denyingARestagedActionKeepsTheCrashInterlock() async throws {
        let url = temporaryLogURL()
        let argumentsJSON = SpyArguments(value: "x").generatedContent.jsonString
        let key = Ergon.idempotencyKey(intent: "", toolName: "spy", argumentsJSON: argumentsJSON)
        // Crash-orphaned pending marker: the action may already have fired.
        do {
            let store = try ReceiptStore(url: url)
            try await store.append(intent: "", toolName: "spy", argumentsJSON: argumentsJSON,
                                   idempotencyKey: key, decision: .approved,
                                   outcome: .pending, latencyMS: 0)
        }

        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy], url: url)
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        // Re-proposal is DENIED (or the sheet is swiped away). A denial must
        // not disarm the interlock for a pending it never created.
        _ = try await gate.call(arguments: .init(value: "x"))
        let denied = try #require(engine.pendingApprovals.first)
        _ = try await engine.deny(denied.id)

        // Re-proposed once more and approved: still refused, still zero runs.
        _ = try await gate.call(arguments: .init(value: "x"))
        let approved = try #require(engine.pendingApprovals.first)
        await #expect(throws: ErgonError.unresolvedExecution(idempotencyKey: key)) {
            try await engine.approve(approved.id)
        }
        #expect(spy.executionCount == 0)
    }

    @Test func trailingTruncationIsDetectedByTheHeadAnchor() async throws {
        let url = temporaryLogURL()
        do {
            let store = try ReceiptStore(url: url)
            for intent in ["first", "second", "third"] {
                try await store.append(intent: intent, toolName: "t", argumentsJSON: "{}",
                                       idempotencyKey: nil, decision: .autoRead,
                                       outcome: .success("ok"), latencyMS: 1)
            }
        }
        // Delete the trailing COMPLETE line: the remaining prefix is still a
        // self-consistent chain, only the anchor can expose it.
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        lines.removeLast()
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(!ReceiptStore.verifyChain(at: url))
        #expect(throws: ErgonError.self) { _ = try ReceiptStore(url: url) }
    }

    @Test func idempotencyKeyIsStableAcrossJSONKeyOrder() {
        let a = Ergon.idempotencyKey(intent: "i", toolName: "t",
                                     argumentsJSON: #"{"a":1,"b":"x"}"#)
        let b = Ergon.idempotencyKey(intent: "i", toolName: "t",
                                     argumentsJSON: #"{"b":"x","a":1}"#)
        #expect(a == b)
    }

    @Test func idempotencyKeyFieldsCannotCollideAcrossBoundaries() {
        // Under a naive delimiter scheme these two would concatenate to the
        // same material; length prefixes must keep them distinct.
        let a = Ergon.idempotencyKey(intent: "ab", toolName: "c", argumentsJSON: "x")
        let b = Ergon.idempotencyKey(intent: "a", toolName: "bc", argumentsJSON: "x")
        #expect(a != b)
    }

    @Test func calendarArgumentsRoundTripWithAndWithoutNotes() throws {
        let full = try CalendarCreateTool.Arguments(GeneratedContent(json: #"""
            {"title": "Dis randevusu", "startISO8601": "2026-07-25T09:00:00+03:00",
             "durationMinutes": 60, "notes": "bring insurance card"}
            """#))
        #expect(full.title == "Dis randevusu")
        #expect(full.durationMinutes == 60)
        #expect(full.notes == "bring insurance card")

        let roundTripped = try CalendarCreateTool.Arguments(full.generatedContent)
        #expect(roundTripped.title == full.title)
        #expect(roundTripped.notes == full.notes)

        // The model omitted the optional key entirely: must be nil, not a throw.
        let sparse = try CalendarCreateTool.Arguments(GeneratedContent(json: #"""
            {"title": "Kontrol", "startISO8601": "2026-07-26T10:00:00+03:00",
             "durationMinutes": 30}
            """#))
        #expect(sparse.notes == nil)

        let reminderSparse = try ReminderCreateTool.Arguments(GeneratedContent(json: #"""
            {"title": "Su al"}
            """#))
        #expect(reminderSparse.dueISO8601 == nil)
        #expect(reminderSparse.notes == nil)

        // "Weather here": the model omits both coordinates and the tool falls
        // back to the device location, so this must decode rather than throw.
        let here = try WeatherTool.Arguments(GeneratedContent(json: "{}"))
        #expect(here.latitude == nil)
        #expect(here.longitude == nil)
    }

    /// The location fallback races the fix against a deadline, because an
    /// unanswered permission prompt keeps the update stream alive without ever
    /// yielding a location. If that race regresses this test hangs, which is
    /// the same signal a user would get.
    @Test func locationFixHonorsItsDeadline() async {
        let start = ContinuousClock.now
        _ = await CurrentLocation.fix(timeout: .milliseconds(200))
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
