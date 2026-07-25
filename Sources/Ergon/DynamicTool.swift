import Foundation
import FoundationModels

/// A tool defined by data instead of by a Swift type.
///
/// Hand-written tools stay the right answer for platform APIs: EventKit has no
/// Android equivalent, so nothing is gained by making it a descriptor. Remote
/// services are the opposite. They are identical on every platform, there is
/// an unbounded number of them, and adding one must not require an app
/// release. Those arrive here.
///
/// Effect is declared, not inferred, and it decides everything downstream:
/// whether the call runs during generation, stops to ask, or offers an undo.
public struct DynamicTool: Sendable {
    public enum Effect: Sendable, Equatable {
        /// No side effects. Runs during generation.
        case read
        /// Changes the world and cannot be put back. Stages an approval.
        case irreversible
        /// Changes the world and can be put back, so it runs and offers an
        /// undo rather than interrupting.
        case reversible
    }

    public let name: String
    public let description: String
    public let arguments: [SchemaProperty]
    public let effect: Effect

    let previewFor: @Sendable (ToolArguments) -> ActionPreview
    let run: @Sendable (ToolArguments) async throws -> String
    let undoRun: (@Sendable (ToolArguments) async throws -> String)?

    /// - Parameters:
    ///   - preview: what the approval sheet or the undo bar shows. Defaults to
    ///     the tool name and its arguments, which is honest but not friendly,
    ///     so pass one for anything a user will actually see.
    ///   - undo: required for `.reversible` and ignored otherwise. A tool that
    ///     claims reversibility without one is rejected at construction, since
    ///     the whole point of running unasked is that the undo exists.
    public init(name: String,
                description: String,
                arguments: [SchemaProperty],
                effect: Effect,
                preview: (@Sendable (ToolArguments) -> ActionPreview)? = nil,
                run: @escaping @Sendable (ToolArguments) async throws -> String,
                undo: (@Sendable (ToolArguments) async throws -> String)? = nil) {
        precondition(effect != .reversible || undo != nil,
                     "\(name) declares itself reversible but implements no undo")
        self.name = name
        self.description = description
        self.arguments = arguments
        self.effect = effect
        self.previewFor = preview ?? { arguments in
            ActionPreview(title: name, detail: arguments.jsonString)
        }
        self.run = run
        self.undoRun = undo
    }

    /// The argument shape as one object schema, which is what a model backend
    /// needs to constrain generation.
    public var schema: ErgonSchema {
        .object(name: name, properties: arguments)
    }
}

/// Renders an ``ErgonSchema`` into what FoundationModels constrains generation
/// with. This function is the entire Apple-specific surface of the data-driven
/// catalog: another backend implements the same mapping against its own
/// grammar, and nothing else has to change.
func generationSchema(for schema: ErgonSchema) throws -> GenerationSchema {
    try GenerationSchema(root: dynamicSchema(for: schema, named: "arguments"), dependencies: [])
}

private func dynamicSchema(for schema: ErgonSchema, named name: String) -> DynamicGenerationSchema {
    switch schema {
    case .string(let choices):
        // A closed set becomes an anyOf, which the runtime enforces during
        // decoding. Left as free text, the model invents a fourth option.
        return choices.isEmpty
            ? DynamicGenerationSchema(type: String.self)
            : DynamicGenerationSchema(name: name, anyOf: choices)
    case .number(let minimum, let maximum):
        guard let minimum, let maximum else { return DynamicGenerationSchema(type: Double.self) }
        return DynamicGenerationSchema(type: Double.self, guides: [.range(minimum...maximum)])
    case .integer(let minimum, let maximum):
        guard let minimum, let maximum else { return DynamicGenerationSchema(type: Int.self) }
        return DynamicGenerationSchema(type: Int.self, guides: [.range(minimum...maximum)])
    case .boolean:
        return DynamicGenerationSchema(type: Bool.self)
    case .array(let element):
        return DynamicGenerationSchema(arrayOf: dynamicSchema(for: element, named: name + "Item"))
    case .object(let objectName, let properties):
        return DynamicGenerationSchema(name: objectName, properties: properties.map {
            DynamicGenerationSchema.Property(name: $0.name,
                                             description: $0.description,
                                             schema: dynamicSchema(for: $0.schema, named: $0.name),
                                             isOptional: $0.isOptional)
        })
    }
}

/// Wraps a ``DynamicTool`` for the session. Arguments stay as
/// `GeneratedContent` and are decoded to ``ToolArguments`` here, so the tool
/// itself never touches a FoundationModels type.
final class DynamicGate: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let tool: DynamicTool
    private let schema: GenerationSchema
    private let stage: StageCallback
    private let record: ReadRecordCallback
    private let autoRun: AutoRunCallback

    init(_ tool: DynamicTool,
         stage: @escaping StageCallback,
         record: @escaping ReadRecordCallback,
         autoRun: @escaping AutoRunCallback) throws {
        self.tool = tool
        self.schema = try generationSchema(for: tool.schema)
        self.stage = stage
        self.record = record
        self.autoRun = autoRun
    }

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema { schema }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments content: GeneratedContent) async throws -> String {
        let json = content.jsonString
        let decoded = ToolArguments(jsonString: json)
        let tool = self.tool

        switch tool.effect {
        case .read:
            let start = ContinuousClock.now
            do {
                let output = try await tool.run(decoded)
                await record(tool.name, json, .success(output), latencyMS(since: start))
                return output
            } catch {
                await record(tool.name, json, .failure(String(describing: error)), latencyMS(since: start))
                throw error
            }

        case .irreversible:
            _ = await stage(StagedAction(
                toolName: tool.name,
                preview: tool.previewFor(decoded),
                isReversible: false,
                argumentsJSON: json,
                execute: { try await tool.run(decoded) }))
            return "NOT DONE. Nothing happened yet. This only asked the user to approve. Reply with one short sentence saying it is waiting for their approval."

        case .reversible:
            guard let undo = tool.undoRun else {
                throw ErgonError.generation("\(tool.name) is reversible but has no undo")
            }
            return try await autoRun(AutoAction(
                toolName: tool.name,
                preview: tool.previewFor(decoded),
                argumentsJSON: json,
                execute: { try await tool.run(decoded) },
                undo: { try await undo(decoded) }))
        }
    }
}
