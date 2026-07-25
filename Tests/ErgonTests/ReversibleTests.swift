import Foundation
import Testing
@testable import Ergon

/// A reversible tool trades the approval sheet for an undo. That trade is only
/// honest if the undo actually runs, only once, and leaves a trail. These
/// tests drive the gate exactly the way the model would.
@MainActor
@Suite struct ReversibleTests {
    private func makeEngine() throws -> (Ergon, SpyReversibleTool) {
        let tool = SpyReversibleTool()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ergon-reversible-\(UUID().uuidString).jsonl")
        return (try Ergon(tools: [tool], receiptsURL: url), tool)
    }

    private func gate(_ engine: Ergon) throws -> ReversibleGate<SpyReversibleTool> {
        try #require(engine.gatedTools.first as? ReversibleGate<SpyReversibleTool>)
    }

    @Test func reversibleToolRunsWithoutAskingAndOffersAnUndo() async throws {
        let (engine, tool) = try makeEngine()
        engine.currentIntent = "do the thing"

        let output = try await gate(engine).call(arguments: SpyArguments(value: "one"))

        #expect(output == "did one")
        #expect(tool.executionCount == 1)
        #expect(engine.pendingApprovals.isEmpty, "a reversible tool must not interrupt")
        #expect(engine.undoable.count == 1)
    }

    @Test func undoRunsTheInverseAndClearsTheOffer() async throws {
        let (engine, tool) = try makeEngine()
        engine.currentIntent = "do the thing"
        _ = try await gate(engine).call(arguments: SpyArguments(value: "one"))
        let action = try #require(engine.undoable.first)

        let receipt = try await engine.undo(action.id)

        #expect(tool.undoCount == 1)
        #expect(engine.undoable.isEmpty)
        #expect(receipt.decision == .undone)
        #expect(receipt.outcome == .success("undid one"))
    }

    /// Two taps on the undo button, or a tap racing a retry, must not run the
    /// inverse twice: undoing a deletion twice would delete a second thing.
    @Test func undoingTwiceIsRefused() async throws {
        let (engine, tool) = try makeEngine()
        engine.currentIntent = "do the thing"
        _ = try await gate(engine).call(arguments: SpyArguments(value: "one"))
        let action = try #require(engine.undoable.first)

        _ = try await engine.undo(action.id)
        await #expect(throws: ErgonError.self) { try await engine.undo(action.id) }
        #expect(tool.undoCount == 1)
    }

    /// Skipping the approval sheet must not skip the idempotency interlock.
    @Test func repeatingTheSameCallInOneIntentExecutesOnce() async throws {
        let (engine, tool) = try makeEngine()
        engine.currentIntent = "do the thing"
        let gate = try gate(engine)

        _ = try await gate.call(arguments: SpyArguments(value: "one"))
        _ = try await gate.call(arguments: SpyArguments(value: "one"))

        #expect(tool.executionCount == 1, "same intent, same tool, same arguments")
    }

    @Test func theRunIsReceiptedAsAutoRun() async throws {
        let (engine, _) = try makeEngine()
        engine.currentIntent = "do the thing"
        _ = try await gate(engine).call(arguments: SpyArguments(value: "one"))

        // Two lines: the reservation marker, then the terminal receipt. Both
        // say autoRun, because nobody approved anything.
        let receipts = await engine.receipts()
        #expect(receipts.count == 2)
        #expect(receipts.allSatisfy { $0.decision == .autoRun })
        #expect(receipts.last?.outcome == .success("did one"))
        #expect(Ergon.verifyReceipts(at: engine.receiptsURL))
    }
}
