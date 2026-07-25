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
    /// Tools defined by data. A domain can mix both: a remote service arriving
    /// from a descriptor sits beside a hand-written platform tool in the same
    /// session, which is the point, since one request routinely needs both.
    public let dynamicTools: [DynamicTool]
    /// Domain instructions for the engine (Ergon appends date and time).
    public let instructions: String?

    public init(name: String, description: String, tools: [any Tool] = [],
                dynamicTools: [DynamicTool] = [], instructions: String? = nil) {
        precondition(!tools.isEmpty || !dynamicTools.isEmpty, "\(name) has no tools")
        self.name = name
        self.description = description
        self.tools = tools
        self.dynamicTools = dynamicTools
        self.instructions = instructions
    }
}
