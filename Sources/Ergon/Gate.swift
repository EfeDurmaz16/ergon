import Foundation
import FoundationModels

/// A consequential call captured mid-generation, waiting for a decision.
struct StagedAction: Sendable {
    let toolName: String
    let preview: ActionPreview
    let isReversible: Bool
    let argumentsJSON: String
    /// Runs the underlying tool. Called by the engine only after approval.
    let execute: @Sendable () async throws -> String
}

/// A reversible call, executed during generation instead of being staged.
/// Carries its own undo so the engine can offer one without knowing the tool.
struct AutoAction: Sendable {
    let toolName: String
    let preview: ActionPreview
    let argumentsJSON: String
    let execute: @Sendable () async throws -> String
    let undo: @Sendable () async throws -> String
}

typealias StageCallback = @Sendable (StagedAction) async -> UUID
typealias AutoRunCallback = @Sendable (AutoAction) async throws -> String

/// A gate reached by name and raw JSON instead of by its Swift argument type.
///
/// FoundationModels drives tools through typed generics, which a remote model
/// cannot: it returns a tool name and a JSON object. This is the narrow door
/// that lets both backends run the same gate, so approval, undo, idempotency,
/// and receipts stay in one implementation rather than two.
protocol JSONInvokable: Sendable {
    var toolName: String { get }
    var toolDescription: String { get }
    /// JSON Schema for the arguments, as a model backend needs it.
    var toolJSONSchema: String { get }
    func invoke(argumentsJSON: String) async throws -> String
}

/// FoundationModels' `GenerationSchema` is `Codable` and encodes to standard
/// JSON Schema, so the schema a typed Swift tool already declares is the same
/// document a remote model wants. No second schema language.
func jsonSchema(of schema: GenerationSchema) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(schema),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"type":"object","properties":{}}"#
    }
    return text
}
typealias ReadRecordCallback = @Sendable (_ toolName: String, _ argumentsJSON: String,
                                          _ outcome: Receipt.Outcome, _ latencyMS: Int) async -> Void

/// Wraps a consequential tool for the model session. When the model calls it,
/// nothing executes: the typed call is staged and the model is told so.
/// Arguments survive as `GeneratedContent` (Sendable) and are re-materialized
/// at execution time, which is the same round trip the framework itself uses.
final class ConsequentialGate<T: Tool>: FoundationModels.Tool {
    typealias Arguments = T.Arguments
    typealias Output = String

    private let tool: T
    private let reversible: Bool
    private let makePreview: @Sendable (T.Arguments) -> ActionPreview
    private let stage: StageCallback

    init(_ tool: T, isReversible: Bool,
         preview: @escaping @Sendable (T.Arguments) -> ActionPreview,
         stage: @escaping StageCallback) {
        self.tool = tool
        self.reversible = isReversible
        self.makePreview = preview
        self.stage = stage
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.parameters }
    var includesSchemaInInstructions: Bool { tool.includesSchemaInInstructions }

    func call(arguments: T.Arguments) async throws -> String {
        let content = arguments.generatedContent
        let action = StagedAction(
            toolName: tool.name,
            preview: makePreview(arguments),
            isReversible: reversible,
            argumentsJSON: content.jsonString,
            execute: { [tool] in
                let arguments = try T.Arguments(content)
                return summarize(try await tool.call(arguments: arguments))
            })
        _ = await stage(action)
        // Deliberately short, blunt, and free of identifiers. A small model
        // parrots whatever this returns straight into its reply: the earlier
        // version carried the approval UUID, which surfaced verbatim to the
        // user, and its softer wording still let the model open with "your
        // note has been added".
        return "NOT DONE. Nothing happened yet. This only asked the user to approve. Reply with one short sentence saying it is waiting for their approval."
    }
}

/// Wraps a reversible tool: runs it during generation and hands the engine an
/// undo. The model sees the tool's real output, so it can report what actually
/// happened instead of announcing a pending approval that never comes.
final class ReversibleGate<T: ReversibleTool>: FoundationModels.Tool {
    typealias Arguments = T.Arguments
    typealias Output = String

    private let tool: T
    private let makePreview: @Sendable (T.Arguments) -> ActionPreview
    private let run: AutoRunCallback

    init(_ tool: T,
         preview: @escaping @Sendable (T.Arguments) -> ActionPreview,
         run: @escaping AutoRunCallback) {
        self.tool = tool
        self.makePreview = preview
        self.run = run
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.parameters }
    var includesSchemaInInstructions: Bool { tool.includesSchemaInInstructions }

    func call(arguments: T.Arguments) async throws -> String {
        let content = arguments.generatedContent
        let action = AutoAction(
            toolName: tool.name,
            preview: makePreview(arguments),
            argumentsJSON: content.jsonString,
            execute: { [tool] in summarize(try await tool.call(arguments: try T.Arguments(content))) },
            undo: { [tool] in try await tool.undo(try T.Arguments(content)) })
        return try await run(action)
    }
}

/// Wraps a read tool: executes immediately, forwards the tool's own output
/// to the model untouched, and leaves an autoRead receipt.
final class ReadGate<T: ReadTool>: FoundationModels.Tool {
    typealias Arguments = T.Arguments
    typealias Output = T.Output

    private let tool: T
    private let record: ReadRecordCallback

    init(_ tool: T, record: @escaping ReadRecordCallback) {
        self.tool = tool
        self.record = record
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { tool.parameters }
    var includesSchemaInInstructions: Bool { tool.includesSchemaInInstructions }

    func call(arguments: T.Arguments) async throws -> T.Output {
        let argsJSON = arguments.generatedContent.jsonString
        let start = ContinuousClock.now
        do {
            let output = try await tool.call(arguments: arguments)
            await record(tool.name, argsJSON, .success(summarize(output)), latencyMS(since: start))
            return output
        } catch {
            await record(tool.name, argsJSON, .failure(String(describing: error)), latencyMS(since: start))
            throw error
        }
    }
}

func summarize(_ output: some PromptRepresentable) -> String {
    output as? String ?? String(describing: output)
}

func latencyMS(since start: ContinuousClock.Instant) -> Int {
    let elapsed = start.duration(to: .now).components
    return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
}

extension ConsequentialTool {
    func gate(stage: @escaping StageCallback) -> any FoundationModels.Tool {
        ConsequentialGate(self, isReversible: isReversible,
                          preview: { self.preview($0) }, stage: stage)
    }
}

extension ReversibleTool {
    func gate(run: @escaping AutoRunCallback) -> any FoundationModels.Tool {
        ReversibleGate(self, preview: { self.preview($0) }, run: run)
    }
}

extension ReadTool {
    func gate(record: @escaping ReadRecordCallback) -> any FoundationModels.Tool {
        ReadGate(self, record: record)
    }
}

extension Tool {
    /// Deny by default: a tool that declared no classification is treated as
    /// consequential and irreversible, with a generic preview.
    func fallbackGate(stage: @escaping StageCallback) -> any FoundationModels.Tool {
        let toolName = name
        return ConsequentialGate(self, isReversible: false,
                                 preview: { ActionPreview(title: toolName, detail: $0.generatedContent.jsonString) },
                                 stage: stage)
    }
}

// MARK: - Reaching a gate by name and JSON

extension ConsequentialGate: JSONInvokable {
    var toolName: String { name }
    var toolDescription: String { description }
    var toolJSONSchema: String { jsonSchema(of: parameters) }

    func invoke(argumentsJSON: String) async throws -> String {
        try await call(arguments: try T.Arguments(GeneratedContent(json: argumentsJSON)))
    }
}

extension ReversibleGate: JSONInvokable {
    var toolName: String { name }
    var toolDescription: String { description }
    var toolJSONSchema: String { jsonSchema(of: parameters) }

    func invoke(argumentsJSON: String) async throws -> String {
        try await call(arguments: try T.Arguments(GeneratedContent(json: argumentsJSON)))
    }
}

extension ReadGate: JSONInvokable {
    var toolName: String { name }
    var toolDescription: String { description }
    var toolJSONSchema: String { jsonSchema(of: parameters) }

    func invoke(argumentsJSON: String) async throws -> String {
        summarize(try await call(arguments: try T.Arguments(GeneratedContent(json: argumentsJSON))))
    }
}

extension DynamicGate: JSONInvokable {
    var toolName: String { name }
    var toolDescription: String { description }
    var toolJSONSchema: String { jsonSchema(of: parameters) }

    func invoke(argumentsJSON: String) async throws -> String {
        try await call(arguments: try GeneratedContent(json: argumentsJSON))
    }
}
