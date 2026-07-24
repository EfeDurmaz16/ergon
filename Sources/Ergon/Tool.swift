import FoundationModels

/// Base marker for Ergon tools. Do not conform to this directly; conform to
/// ``ReadTool`` or ``ConsequentialTool``. A tool that conforms only to `Tool`
/// is still accepted by ``Ergon`` but is gated as consequential, because an
/// unclassified effect is treated as a real effect (deny by default).
public protocol Tool: FoundationModels.Tool where Arguments: Generable {}

/// Disambiguation alias for code that imports both Ergon and
/// FoundationModels, where the bare name `Tool` is ambiguous and
/// `Ergon.Tool` is shadowed by the engine class.
public typealias ErgonTool = Tool

/// A tool with no side effects. Executes freely during generation and leaves
/// an `autoRead` receipt.
public protocol ReadTool: Tool {}

/// A tool with real-world effects. It can never execute during generation.
/// The model's call is staged as an ``Approval``; the underlying tool runs
/// only after `Ergon.approve(_:)`.
public protocol ConsequentialTool: Tool {
    /// Whether the effect can be undone afterwards (shown to the user).
    var isReversible: Bool { get }

    /// A human-readable rendering of what this call will do, to what.
    /// Shown verbatim on the approval sheet, so write it for the user,
    /// not for the model.
    func preview(_ arguments: Arguments) -> ActionPreview
}

/// What the approval sheet shows for a staged call.
public struct ActionPreview: Sendable, Equatable, Codable {
    /// Short imperative headline, e.g. "Create calendar event".
    public var title: String
    /// The specifics, e.g. "Dis randevusu, Fri Jul 25, 09:00-10:00".
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}
