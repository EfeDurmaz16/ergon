import FoundationModels

/// A model-authored native screen. The model fills this instead of prose so
/// the app can render a real layout, and because the fields are generated in
/// declaration order, the screen assembles top to bottom as tokens arrive:
/// title, then summary, then facts, then follow-up chips.
///
/// The schema is deliberately small. The on-device model shares a 4096-token
/// budget across instructions, tool output, and this schema, so the vocabulary
/// is four fields, not an open component tree.
@Generable
public struct ErgonScreen: Equatable, Sendable {
    @Guide(description: "A short headline for the answer, a few words.")
    public var title: String

    @Guide(description: "One or two plain sentences summarizing the answer.")
    public var summary: String

    @Guide(description: "The key facts, each a short label and its value.", .maximumCount(4))
    public var facts: [ErgonFact]

    @Guide(description: "Up to three short tappable follow-up suggestions, imperative phrasing.", .maximumCount(3))
    public var suggestions: [String]
}

/// One label/value row. `value` is the hero on a data surface, so keep it the
/// concrete number or name and let `label` carry the context.
@Generable
public struct ErgonFact: Equatable, Sendable {
    @Guide(description: "Short context label, e.g. 'Now' or 'High'.")
    public var label: String

    @Guide(description: "The value itself, e.g. '21 C' or 'Cafe Nero'.")
    public var value: String
}
