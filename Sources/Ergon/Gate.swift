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

typealias StageCallback = @Sendable (StagedAction) async -> UUID
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
        let id = await stage(action)
        return "Staged for user approval (id \(id.uuidString)). It will execute only if the user approves. Tell the user the action awaits their confirmation; do not claim it was performed."
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
