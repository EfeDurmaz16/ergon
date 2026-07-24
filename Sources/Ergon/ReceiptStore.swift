import Foundation

/// Append-only JSONL receipt log with a SHA-256 hash chain.
/// One JSON object per line. The chain resumes across launches: on init the
/// store replays the file to recover the last hash and the idempotency
/// indexes, and refuses to open a log that fails verification (fail closed).
actor ReceiptStore {
    static let genesisHash = String(repeating: "0", count: 64)

    private let url: URL
    private let handle: FileHandle
    private var lastHash: String
    private var receipts: [Receipt]
    private var successByKey: [String: Receipt] = [:]
    private var unresolvedPendingKeys: Set<String> = []

    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let loaded = try Self.loadAndVerify(url: url)
        self.receipts = loaded
        self.lastHash = loaded.last?.hash ?? Self.genesisHash
        var success: [String: Receipt] = [:]
        var pending: Set<String> = []
        for receipt in loaded {
            Self.applyIndex(receipt, success: &success, pending: &pending)
        }
        self.successByKey = success
        self.unresolvedPendingKeys = pending
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    private static func applyIndex(_ receipt: Receipt,
                                   success: inout [String: Receipt],
                                   pending: inout Set<String>) {
        guard let key = receipt.idempotencyKey else { return }
        switch receipt.outcome {
        case .pending:
            pending.insert(key)
        case .success:
            success[key] = receipt
            pending.remove(key)
        case .failure, .denied:
            pending.remove(key)
        }
    }

    private func index(_ receipt: Receipt) {
        Self.applyIndex(receipt, success: &successByKey, pending: &unresolvedPendingKeys)
    }

    @discardableResult
    func append(intent: String, toolName: String, argumentsJSON: String,
                idempotencyKey: String?, decision: Receipt.Decision,
                outcome: Receipt.Outcome, latencyMS: Int) throws -> Receipt {
        let receipt = Receipt(body: .init(
            id: UUID(), timestamp: Date(), intent: intent, toolName: toolName,
            argumentsJSON: argumentsJSON, idempotencyKey: idempotencyKey,
            decision: decision, outcome: outcome, latencyMS: latencyMS,
            prevHash: lastHash))
        var line = try Receipt.canonicalEncoder.encode(receipt)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
        lastHash = receipt.hash
        receipts.append(receipt)
        index(receipt)
        return receipt
    }

    func successReceipt(for idempotencyKey: String) -> Receipt? {
        successByKey[idempotencyKey]
    }

    func hasUnresolvedPending(for idempotencyKey: String) -> Bool {
        unresolvedPendingKeys.contains(idempotencyKey)
    }

    func all() -> [Receipt] {
        receipts
    }

    /// Decodes every line and re-verifies the whole chain: each receipt's
    /// hash must match its re-computed body hash, and each prevHash must
    /// equal the previous receipt's hash. Throws on any mismatch.
    static func loadAndVerify(url: URL) throws -> [Receipt] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        var result: [Receipt] = []
        var expectedPrev = genesisHash
        for (n, lineData) in data.split(separator: 0x0A).enumerated() {
            let receipt: Receipt
            do {
                receipt = try Receipt.decoder.decode(Receipt.self, from: lineData)
            } catch {
                throw ErgonError.corruptReceiptLog("line \(n + 1) is not a valid receipt")
            }
            guard receipt.prevHash == expectedPrev,
                  receipt.hash == Receipt.computeHash(of: receipt.body) else {
                throw ErgonError.corruptReceiptLog("hash chain broken at line \(n + 1)")
            }
            expectedPrev = receipt.hash
            result.append(receipt)
        }
        return result
    }

    static func verifyChain(at url: URL) -> Bool {
        (try? loadAndVerify(url: url)) != nil
    }
}
