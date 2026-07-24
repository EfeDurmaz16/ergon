import Foundation
import Testing
import FoundationModels
@testable import Ergon

/// The trust claims. A consequential tool must never execute without an
/// approval, must execute exactly once per approval, and a confirmed intent
/// must never double-execute.
@MainActor
@Suite struct ApprovalGateTests {
    private func makeEngine(tools: [any ErgonTool],
                            url: URL = temporaryLogURL()) throws -> Ergon {
        try Ergon(tools: tools, receiptsURL: url)
    }

    @Test func consequentialCallStagesInsteadOfExecuting() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        let reply = try await gate.call(arguments: .init(value: "x"))

        #expect(spy.executionCount == 0)
        #expect(engine.pendingApprovals.count == 1)
        #expect(reply.localizedCaseInsensitiveContains("approval"))
        let approval = try #require(engine.pendingApprovals.first)
        #expect(approval.toolName == "spy")
        #expect(approval.preview == ActionPreview(title: "Spy action", detail: "x"))
        #expect(!approval.isReversible)
    }

    @Test func approveExecutesExactlyOnce() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)

        let receipt = try await engine.approve(approval.id)

        #expect(spy.executionCount == 1)
        #expect(receipt.decision == .approved)
        #expect(receipt.outcome == .success("ran with x"))
        #expect(engine.pendingApprovals.isEmpty)

        // The token is spent: a second approve of the same id must fail
        // and must not execute anything.
        await #expect(throws: ErgonError.unknownApproval) {
            try await engine.approve(approval.id)
        }
        #expect(spy.executionCount == 1)
    }

    @Test func denyNeverExecutesAndIsReceipted() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)

        let receipt = try await engine.deny(approval.id)

        #expect(spy.executionCount == 0)
        #expect(receipt.decision == .denied)
        #expect(receipt.outcome == .denied)
        #expect(engine.pendingApprovals.isEmpty)
        let all = await engine.receipts()
        #expect(all.count == 1)
    }

    @Test func confirmedIntentNeverDoubleExecutes() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        _ = try await gate.call(arguments: .init(value: "x"))
        let first = try #require(engine.pendingApprovals.first)
        let firstReceipt = try await engine.approve(first.id)
        #expect(spy.executionCount == 1)

        // The model resolves the same intent again (retry, regenerate,
        // re-run): same tool, same arguments, so the same idempotency key.
        _ = try await gate.call(arguments: .init(value: "x"))
        let second = try #require(engine.pendingApprovals.first)
        #expect(second.idempotencyKey == first.idempotencyKey)

        let secondReceipt = try await engine.approve(second.id)

        #expect(spy.executionCount == 1)
        #expect(secondReceipt.id == firstReceipt.id)
    }

    @Test func differentArgumentsGetDifferentKeys() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        _ = try await gate.call(arguments: .init(value: "x"))
        _ = try await gate.call(arguments: .init(value: "y"))

        #expect(engine.pendingApprovals.count == 2)
        let keys = Set(engine.pendingApprovals.map(\.idempotencyKey))
        #expect(keys.count == 2)
    }

    @Test func interruptedExecutionFailsClosed() async throws {
        let url = temporaryLogURL()
        let argumentsJSON = SpyArguments(value: "x").generatedContent.jsonString
        let key = Ergon.idempotencyKey(intent: "", toolName: "spy", argumentsJSON: argumentsJSON)

        // Simulate a crash: an approved pending marker exists on disk with
        // no terminal receipt after it.
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
        #expect(approval.idempotencyKey == key)

        await #expect(throws: ErgonError.unresolvedExecution(idempotencyKey: key)) {
            try await engine.approve(approval.id)
        }
        #expect(spy.executionCount == 0)
    }

    @Test func toolFailureIsReceiptedNotThrown() async throws {
        let spy = SpyConsequentialTool(shouldThrow: true)
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)

        let receipt = try await engine.approve(approval.id)

        #expect(spy.attempts.withLock { $0 } == 1)
        #expect(spy.executionCount == 0)
        #expect(receipt.decision == .approved)
        if case .failure = receipt.outcome {} else {
            Issue.record("expected failure outcome, got \(receipt.outcome)")
        }
    }

    @Test func unclassifiedToolIsGatedByDefault() async throws {
        let tool = UnclassifiedTool()
        let engine = try makeEngine(tools: [tool])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<UnclassifiedTool>)

        _ = try await gate.call(arguments: .init(value: "x"))

        #expect(tool.executions.withLock { $0 } == 0)
        #expect(engine.pendingApprovals.count == 1)
        let approval = try #require(engine.pendingApprovals.first)
        #expect(!approval.isReversible)
    }

    @Test func readToolExecutesImmediatelyAndLeavesReceipt() async throws {
        let read = SpyReadTool()
        let engine = try makeEngine(tools: [read])
        let gate = try #require(engine.gatedTools.first as? ReadGate<SpyReadTool>)

        let output = try await gate.call(arguments: .init(value: "q"))

        #expect(output == "read result")
        #expect(read.executions.withLock { $0 } == 1)
        #expect(engine.pendingApprovals.isEmpty)
        let all = await engine.receipts()
        #expect(all.count == 1)
        #expect(all[0].decision == .autoRead)
        #expect(all[0].idempotencyKey == nil)
    }

    @Test func concurrentApprovesOfSameTokenExecuteOnce() async throws {
        let spy = SpyConsequentialTool()
        let engine = try makeEngine(tools: [spy])
        let gate = try #require(engine.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(engine.pendingApprovals.first)

        // Two racing approvals: the token is consumed synchronously, so
        // exactly one may execute, the other must see unknownApproval.
        let first = Task { @MainActor in try await engine.approve(approval.id) }
        let second = Task { @MainActor in try await engine.approve(approval.id) }
        let outcomes = [await first.result, await second.result]

        let successes = outcomes.filter { (try? $0.get()) != nil }
        #expect(successes.count == 1)
        #expect(spy.executionCount == 1)
    }

    @Test func idempotencyKeyIsDeterministic() {
        let a = Ergon.idempotencyKey(intent: "i", toolName: "t", argumentsJSON: "{}")
        let b = Ergon.idempotencyKey(intent: "i", toolName: "t", argumentsJSON: "{}")
        let c = Ergon.idempotencyKey(intent: "i2", toolName: "t", argumentsJSON: "{}")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64)
    }
}
