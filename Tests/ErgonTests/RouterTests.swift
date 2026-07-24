import Foundation
import Testing
@testable import Ergon

@MainActor
@Suite struct RouterTests {
    private func makeRouter() throws -> (Router, SpyConsequentialTool, SpyReadTool) {
        let spy = SpyConsequentialTool()
        let read = SpyReadTool()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ergon-router-\(UUID().uuidString)")
        let router = try Router(toolsets: [
            Toolset(name: "acting", description: "does things", tools: [spy]),
            Toolset(name: "reading", description: "looks things up", tools: [read]),
        ], receiptsDirectory: directory)
        return (router, spy, read)
    }

    @Test func perDomainEnginesGetSeparateChainedLogs() throws {
        let (router, _, _) = try makeRouter()
        let acting = try #require(router.engine(for: "acting"))
        let reading = try #require(router.engine(for: "reading"))
        #expect(acting.receiptsURL != reading.receiptsURL)
        #expect(acting.receiptsURL.lastPathComponent == "receipts-acting.jsonl")
    }

    @Test func approvalForwardingFindsTheOwningEngine() async throws {
        let (router, spy, _) = try makeRouter()
        let acting = try #require(router.engine(for: "acting"))
        let gate = try #require(acting.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))

        let approval = try #require(router.pendingApprovals.first)
        let receipt = try await router.approve(approval.id)

        #expect(spy.executionCount == 1)
        #expect(receipt.decision == .approved)
        #expect(router.pendingApprovals.isEmpty)
    }

    @Test func denyForwardingAndUnknownIDs() async throws {
        let (router, spy, _) = try makeRouter()
        let acting = try #require(router.engine(for: "acting"))
        let gate = try #require(acting.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(router.pendingApprovals.first)

        let receipt = try await router.deny(approval.id)
        #expect(receipt.decision == .denied)
        #expect(spy.executionCount == 0)

        await #expect(throws: ErgonError.unknownApproval) {
            try await router.approve(approval.id)
        }
    }

    @Test func stagedApprovalIsVisibleThroughTheRouter() async throws {
        // The approval sheet reads router.pendingApprovals. If the engines
        // dictionary were observation-ignored, a staged call would be
        // invisible to the router and the sheet would never appear.
        let (router, spy, _) = try makeRouter()
        let acting = try #require(router.engine(for: "acting"))
        let gate = try #require(acting.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)

        #expect(router.pendingApprovals.isEmpty)
        _ = try await gate.call(arguments: .init(value: "x"))

        #expect(router.pendingApprovals.count == 1)
        #expect(spy.executionCount == 0)
    }

    @Test func mergedReceiptsSortByTimestamp() async throws {
        let (router, spy, _) = try makeRouter()
        let acting = try #require(router.engine(for: "acting"))
        let gate = try #require(acting.gatedTools.first as? ConsequentialGate<SpyConsequentialTool>)
        _ = try await gate.call(arguments: .init(value: "x"))
        let approval = try #require(router.pendingApprovals.first)
        _ = try await router.approve(approval.id)
        _ = spy

        let receipts = await router.receipts()
        #expect(receipts.count == 2)  // pending marker + success
        #expect(zip(receipts, receipts.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
    }
}
