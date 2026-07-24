import Foundation

/// A staged consequential call, waiting for the user's decision.
/// Nothing behind an Approval has executed yet, and nothing ever will
/// unless `Ergon.approve(_:)` is called with its id.
public struct Approval: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    public let preview: ActionPreview
    public let isReversible: Bool
    /// The resolved typed arguments, canonical JSON. What you approve is
    /// exactly what executes.
    public let argumentsJSON: String
    /// Derived from (intent, tool, arguments). Re-running a confirmed
    /// intent produces the same key, and a key that already succeeded is
    /// never executed again.
    public let idempotencyKey: String
}
