import Foundation
import Synchronization

/// Append-only JSONL receipt log with a SHA-256 hash chain.
/// One JSON object per line. The chain resumes across launches: on init the
/// store replays the file to recover the last hash and the idempotency
/// indexes, and refuses to open a log that fails verification (fail closed).
/// A torn final line without its newline (crash mid-append) is truncated,
/// not treated as tamper: its append never returned, so nothing executed on
/// its behalf.
actor ReceiptStore {
    static let genesisHash = String(repeating: "0", count: 64)

    /// One writer per file per process. A second store on the same path
    /// would hold its own in-memory lastHash and fork the chain.
    private static let openPaths = Mutex<Set<String>>([])

    private let url: URL
    private let ownedPath: String
    private let handle: FileHandle
    private var lastHash: String
    private var receipts: [Receipt]
    private var successByKey: [String: Receipt] = [:]
    private var unresolvedPendingKeys: Set<String> = []

    init(url: URL) throws {
        let path = url.standardizedFileURL.path
        let claimed = Self.openPaths.withLock { $0.insert(path).inserted }
        guard claimed else {
            throw ErgonError.receiptLogInUse(path)
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let (loaded, validLength) = try Self.loadAndVerify(url: url)
            var success: [String: Receipt] = [:]
            var pending: Set<String> = []
            for receipt in loaded {
                Self.applyIndex(receipt, success: &success, pending: &pending)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(validLength))
            try handle.seekToEnd()

            self.url = url
            self.ownedPath = path
            self.receipts = loaded
            self.lastHash = loaded.last?.hash ?? Self.genesisHash
            self.successByKey = success
            self.unresolvedPendingKeys = pending
            self.handle = handle
        } catch {
            Self.openPaths.withLock { _ = $0.remove(path) }
            throw error
        }
    }

    deinit {
        try? handle.close()
        let path = ownedPath
        Self.openPaths.withLock { _ = $0.remove(path) }
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

    enum Reservation {
        case reserved
        case alreadySucceeded(Receipt)
    }

    /// Atomic check-and-reserve for one idempotency key. This must be a
    /// single actor call with no internal suspension: two approvals sharing
    /// a key (the model staged the same call twice) race here, and exactly
    /// one may pass. The loser sees the winner's pending marker and fails
    /// closed, or gets the winner's receipt once it succeeded.
    func reserve(intent: String, toolName: String, argumentsJSON: String,
                 idempotencyKey: String) throws -> Reservation {
        if let prior = successByKey[idempotencyKey] {
            return .alreadySucceeded(prior)
        }
        if unresolvedPendingKeys.contains(idempotencyKey) {
            throw ErgonError.unresolvedExecution(idempotencyKey: idempotencyKey)
        }
        try append(intent: intent, toolName: toolName, argumentsJSON: argumentsJSON,
                   idempotencyKey: idempotencyKey, decision: .approved,
                   outcome: .pending, latencyMS: 0)
        return .reserved
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

    /// Decodes every complete line and re-verifies the whole chain: each
    /// receipt's hash must match its re-computed body hash, and each
    /// prevHash must equal the previous receipt's hash. Throws on any
    /// mismatch. A trailing segment with no terminating newline is a torn
    /// append from a crash: it is reported via the returned valid length so
    /// the caller can truncate it, because an append that never completed
    /// provably executed nothing (the pending marker protocol writes and
    /// syncs the marker before any execution).
    static func loadAndVerify(url: URL) throws -> (receipts: [Receipt], validLength: Int) {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return ([], 0) }
        var result: [Receipt] = []
        var expectedPrev = genesisHash
        var offset = data.startIndex
        var line = 1
        while offset < data.endIndex {
            guard let newline = data[offset...].firstIndex(of: 0x0A) else {
                return (result, offset - data.startIndex)
            }
            let lineData = data[offset..<newline]
            guard let receipt = try? Receipt.decoder.decode(Receipt.self, from: lineData),
                  receipt.prevHash == expectedPrev,
                  receipt.hash == Receipt.computeHash(of: receipt.body) else {
                throw ErgonError.corruptReceiptLog("hash chain broken at line \(line)")
            }
            expectedPrev = receipt.hash
            result.append(receipt)
            offset = data.index(after: newline)
            line += 1
        }
        return (result, data.count)
    }

    static func verifyChain(at url: URL) -> Bool {
        (try? loadAndVerify(url: url)) != nil
    }
}
