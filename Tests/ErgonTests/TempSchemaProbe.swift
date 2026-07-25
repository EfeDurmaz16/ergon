import Foundation
import Testing
import FoundationModels
@testable import Ergon
@testable import ErgonTools

@Suite struct TempSchemaProbe {
    @Test func encodeSchemas() throws {
        let dynamic = try generationSchema(for: .object(name: "probe", properties: [
            SchemaProperty(name: "query", description: "what to find", schema: .string(oneOf: [])),
            SchemaProperty(name: "count", description: "how many", schema: .integer(minimum: 1, maximum: 9), isOptional: true),
        ]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("DYNAMIC=\(String(data: try encoder.encode(dynamic), encoding: .utf8)!)")

        let typed = CalendarCreateTool().parameters
        print("TYPED=\(String(data: try encoder.encode(typed), encoding: .utf8)!)")
    }
}
