import Foundation
import FoundationModels
import Synchronization
@testable import Ergon

// The test argument struct conforms to Generable by hand instead of using
// @Generable: the FoundationModelsMacros plugin ships only inside Xcode, and
// these tests must also run under plain Command Line Tools. This is the same
// shape the macro generates, built from public API only.
struct SpyArguments: Generable {
    var value: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Spy arguments",
                         properties: [.init(name: "value", type: String.self)])
    }

    init(value: String) {
        self.value = value
    }

    init(_ content: GeneratedContent) throws {
        self.value = try content.value(forProperty: "value")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["value": value])
    }
}

/// A reversible tool: runs during generation, and counts how often it was
/// put back. Reversibility is the reason it never asks, so the undo count is
/// the thing worth asserting on.
final class SpyReversibleTool: ReversibleTool {
    typealias Arguments = SpyArguments

    let name = "spyReversible"
    let description = "Test tool that runs immediately and can be undone."
    let executions = Mutex(0)
    let undos = Mutex(0)

    init() {}

    func preview(_ arguments: SpyArguments) -> ActionPreview {
        ActionPreview(title: "Spy reversible", detail: arguments.value)
    }

    func call(arguments: SpyArguments) async throws -> String {
        executions.withLock { $0 += 1 }
        return "did \(arguments.value)"
    }

    func undo(_ arguments: SpyArguments) async throws -> String {
        undos.withLock { $0 += 1 }
        return "undid \(arguments.value)"
    }

    var executionCount: Int { executions.withLock { $0 } }
    var undoCount: Int { undos.withLock { $0 } }
}

/// A consequential tool that counts executions. The count is the whole test:
/// it must stay at zero until approval, and never exceed one per key.
final class SpyConsequentialTool: ConsequentialTool {
    typealias Arguments = SpyArguments

    let name = "spy"
    let description = "Test tool that records the fact it ran."
    let isReversible = false
    let executions = Mutex(0)
    let attempts = Mutex(0)
    let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func preview(_ arguments: SpyArguments) -> ActionPreview {
        ActionPreview(title: "Spy action", detail: arguments.value)
    }

    func call(arguments: SpyArguments) async throws -> String {
        attempts.withLock { $0 += 1 }
        if shouldThrow {
            throw TestError.boom
        }
        executions.withLock { $0 += 1 }
        return "ran with \(arguments.value)"
    }

    var executionCount: Int {
        executions.withLock { $0 }
    }
}

/// A tool claiming BOTH classifications. Deny by default: the consequential
/// gate must win, or a "both" tool would run freely during generation.
final class SpyBothTool: ReadTool, ConsequentialTool {
    typealias Arguments = SpyArguments

    let name = "spyBoth"
    let description = "Test tool conforming to both classifications."
    let isReversible = true
    let executions = Mutex(0)

    func preview(_ arguments: SpyArguments) -> ActionPreview {
        ActionPreview(title: "Both action", detail: arguments.value)
    }

    func call(arguments: SpyArguments) async throws -> String {
        executions.withLock { $0 += 1 }
        return "ran"
    }
}

/// A tool that opts into no classification at all. Must be gated.
final class UnclassifiedTool: ErgonTool {
    typealias Arguments = SpyArguments

    let name = "unclassified"
    let description = "Test tool with no read/consequential classification."
    let executions = Mutex(0)

    func call(arguments: SpyArguments) async throws -> String {
        executions.withLock { $0 += 1 }
        return "ran"
    }
}

final class SpyReadTool: ReadTool {
    typealias Arguments = SpyArguments

    let name = "spyRead"
    let description = "Test read tool."
    let executions = Mutex(0)

    func call(arguments: SpyArguments) async throws -> String {
        executions.withLock { $0 += 1 }
        return "read result"
    }
}

enum TestError: Error {
    case boom
}

func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ergon-tests-\(UUID().uuidString)/receipts.jsonl")
}
