import Foundation
import CryptoKit

/// One line in the append-only execution log. Every consequential execution,
/// denial, and read-tool call produces a receipt. Receipts form a hash chain:
/// each hash covers the receipt body plus the previous receipt's hash, so
/// any edit or deletion inside the log is detectable.
public struct Receipt: Codable, Sendable, Equatable, Identifiable {
    public enum Decision: String, Codable, Sendable {
        case approved
        case denied
        case autoRead
        /// The user approved, but the runtime refused to execute: a prior
        /// execution of the same idempotency key is unresolved or in flight.
        case refused
    }

    public enum Outcome: Codable, Sendable, Equatable {
        /// Approval was granted and execution is in flight. A `pending`
        /// receipt with no later terminal receipt for the same idempotency
        /// key means the process died mid-execution; Ergon then refuses to
        /// re-execute that key (fail closed).
        case pending
        /// The tool ran; the payload is the tool's own summary of what happened.
        case success(String)
        /// The tool threw; by contract that means it made no external effect.
        case failure(String)
        /// The user rejected the staged call. Nothing executed.
        case denied
    }

    public let id: UUID
    public let timestamp: Date
    public let intent: String
    public let toolName: String
    public let argumentsJSON: String
    public let idempotencyKey: String?
    public let decision: Decision
    public let outcome: Outcome
    public let latencyMS: Int
    public let prevHash: String
    public let hash: String

    /// Canonical JSON of everything except `hash`, hashed with SHA-256.
    /// Including `prevHash` in the body is what links the chain.
    static func computeHash(of body: Body) -> String {
        let data = try! Self.canonicalEncoder.encode(body)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Body: Codable {
        let id: UUID
        let timestamp: Date
        let intent: String
        let toolName: String
        let argumentsJSON: String
        let idempotencyKey: String?
        let decision: Decision
        let outcome: Outcome
        let latencyMS: Int
        let prevHash: String
    }

    var body: Body {
        Body(id: id, timestamp: timestamp, intent: intent, toolName: toolName,
             argumentsJSON: argumentsJSON, idempotencyKey: idempotencyKey,
             decision: decision, outcome: outcome, latencyMS: latencyMS,
             prevHash: prevHash)
    }

    init(body: Body) {
        self.id = body.id
        self.timestamp = body.timestamp
        self.intent = body.intent
        self.toolName = body.toolName
        self.argumentsJSON = body.argumentsJSON
        self.idempotencyKey = body.idempotencyKey
        self.decision = body.decision
        self.outcome = body.outcome
        self.latencyMS = body.latencyMS
        self.prevHash = body.prevHash
        self.hash = Self.computeHash(of: body)
    }

    /// Deterministic encoder: sorted keys, second-precision ISO 8601 dates.
    /// Hash verification re-encodes a decoded receipt, so encoding must be
    /// stable across encode/decode round trips.
    static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
