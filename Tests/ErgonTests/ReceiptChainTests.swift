import Foundation
import Testing
@testable import Ergon

@Suite struct ReceiptChainTests {
    private func append(_ store: ReceiptStore, intent: String,
                        outcome: Receipt.Outcome = .success("ok"),
                        key: String? = nil) async throws -> Receipt {
        try await store.append(intent: intent, toolName: "t", argumentsJSON: "{}",
                               idempotencyKey: key, decision: .approved,
                               outcome: outcome, latencyMS: 5)
    }

    @Test func chainLinksAndVerifies() async throws {
        let url = temporaryLogURL()
        let store = try ReceiptStore(url: url)
        let r1 = try await append(store, intent: "first")
        let r2 = try await append(store, intent: "second")
        let r3 = try await append(store, intent: "third")

        #expect(r1.prevHash == ReceiptStore.genesisHash)
        #expect(r2.prevHash == r1.hash)
        #expect(r3.prevHash == r2.hash)
        #expect(ReceiptStore.verifyChain(at: url))
    }

    @Test func editedLineBreaksVerification() async throws {
        let url = temporaryLogURL()
        let store = try ReceiptStore(url: url)
        _ = try await append(store, intent: "first")
        _ = try await append(store, intent: "second")
        _ = try await append(store, intent: "third")

        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "second", with: "SECOND")
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(!ReceiptStore.verifyChain(at: url))
    }

    @Test func deletedLineBreaksVerification() async throws {
        let url = temporaryLogURL()
        let store = try ReceiptStore(url: url)
        _ = try await append(store, intent: "first")
        _ = try await append(store, intent: "second")
        _ = try await append(store, intent: "third")

        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        lines.remove(at: 1)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(!ReceiptStore.verifyChain(at: url))
    }

    @Test func chainResumesAcrossReopen() async throws {
        let url = temporaryLogURL()
        var last: Receipt?
        do {
            let store = try ReceiptStore(url: url)
            _ = try await append(store, intent: "first")
            last = try await append(store, intent: "second")
        }

        let reopened = try ReceiptStore(url: url)
        let r3 = try await append(reopened, intent: "third")

        #expect(r3.prevHash == last?.hash)
        #expect(await reopened.all().count == 3)
        #expect(ReceiptStore.verifyChain(at: url))
    }

    @Test func corruptLogFailsClosedOnOpen() async throws {
        let url = temporaryLogURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "not json\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: ErgonError.self) {
            _ = try ReceiptStore(url: url)
        }
    }

    @Test func reopenRestoresIdempotencyIndexes() async throws {
        let url = temporaryLogURL()
        do {
            let store = try ReceiptStore(url: url)
            _ = try await append(store, intent: "done", outcome: .success("ok"), key: "key-success")
            _ = try await append(store, intent: "dying", outcome: .pending, key: "key-interrupted")
        }

        let reopened = try ReceiptStore(url: url)
        #expect(await reopened.successReceipt(for: "key-success") != nil)
        #expect(await reopened.hasUnresolvedPending(for: "key-interrupted"))
        #expect(await !reopened.hasUnresolvedPending(for: "key-success"))
    }
}
