import Foundation

/// A named group of tools that one model session carries. The on-device
/// model has a 4096-token context shared with output, and tool selection
/// degrades as the catalog grows, so tools ship in small domain sets and a
/// ``Router`` picks the right one per intent.
public struct Toolset {
    /// Classifier label, e.g. "calendar". Also names the domain's receipt log.
    public let name: String
    /// One sentence the classifier reads to decide routing.
    public let description: String
    public let tools: [any Tool]
    /// Domain instructions for the engine (Ergon appends date and time).
    public let instructions: String?

    public init(name: String, description: String, tools: [any Tool],
                instructions: String? = nil) {
        self.name = name
        self.description = description
        self.tools = tools
        self.instructions = instructions
    }
}
