import Foundation

/// A tool as a model backend sees it: a name, a description, and a JSON Schema.
///
/// Both tool kinds reduce to this. FoundationModels' own `GenerationSchema` is
/// `Codable` and encodes to standard JSON Schema, so a hand-written Swift tool
/// and a descriptor-defined one arrive at the same representation without a
/// second schema language.
public struct BackendTool: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments object.
    public let jsonSchema: String

    public init(name: String, description: String, jsonSchema: String) {
        self.name = name
        self.description = description
        self.jsonSchema = jsonSchema
    }
}

/// Runs one tool the model asked for and returns what it produced.
///
/// The backend never touches a tool directly: it hands the name and the
/// arguments back, and the engine decides whether that call executes, stages an
/// approval, or offers an undo. Gating stays in one place no matter which model
/// is driving.
public typealias ToolInvocation = @Sendable (_ name: String, _ argumentsJSON: String) async throws -> String

/// Where a model runs.
///
/// The on-device model is the default: private, free, offline, and enough for
/// a single-step intent. A capable model is for the requests it cannot serve,
/// and it runs on the user's own account rather than ours.
public protocol ModelBackend: Sendable {
    /// Resolve an intent, calling `invoke` for each tool the model chooses.
    /// Returns the final reply text.
    func respond(to intent: String,
                 instructions: String,
                 tools: [BackendTool],
                 invoke: @escaping ToolInvocation) async throws -> String
}
