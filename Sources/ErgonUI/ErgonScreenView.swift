import SwiftUI

/// Renders an ``ErgonScreen`` as it streams. Each part appears as the model
/// fills it, fading in rather than popping. Neutral surface, a single accent
/// reserved for tappable suggestions, and the fact value set as the hero in
/// tabular figures.
public struct ErgonScreenView: View {
    let screen: ErgonScreen.PartiallyGenerated
    /// Called when the user taps a suggestion chip.
    let onSuggestion: (String) -> Void

    public init(_ screen: ErgonScreen.PartiallyGenerated,
                onSuggestion: @escaping (String) -> Void = { _ in }) {
        self.screen = screen
        self.onSuggestion = onSuggestion
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title = screen.title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .transition(.opacity)
            }
            if let summary = screen.summary, !summary.isEmpty {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let facts = screen.facts, !facts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        FactRow(fact: fact)
                    }
                }
                .transition(.opacity)
            }
            if let suggestions = screen.suggestions, !suggestions.isEmpty {
                FlowChips(suggestions: suggestions.filter { !$0.isEmpty },
                          onTap: onSuggestion)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: screen)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FactRow: View {
    let fact: ErgonFact.PartiallyGenerated

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let label = fact.label {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let value = fact.value {
                Text(value)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

private struct FlowChips: View {
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        // A simple wrapping layout: chips flow and wrap by line.
        FlexibleStack(spacing: 8) {
            ForEach(suggestions, id: \.self) { text in
                Button {
                    onTap(text)
                } label: {
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Minimal wrapping HStack using Layout, so chips flow onto new lines.
///
/// Every measurement is taken against the container width, never
/// `.unspecified`. Measured unconstrained, a chip reports the width its text
/// wants on one line, and a long one is then placed wider than the screen and
/// runs off the right edge: wrapping between chips does not help if a single
/// chip cannot fit. Constrained, its text wraps inside the capsule instead.
struct FlexibleStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var lineWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if lineWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                lineWidth = 0
            }
            rows[rows.count - 1].append(size)
            lineWidth += size.width + spacing
        }
        let height = rows.reduce(0) { partial, row in
            partial + (row.map(\.height).max() ?? 0) + spacing
        } - spacing
        return CGSize(width: maxWidth == .infinity ? lineWidth : maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
