import SwiftUI
import Ergon
import ErgonTools

/// What the user came for is their notes. The receipt trail and the
/// resolution diagnostics are developer tooling, so they sit collapsed under
/// an activity log rather than occupying the product surface: a hash chain
/// means nothing to someone who can just open their calendar and look.
struct ReceiptsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [Receipt] = []
    @State private var notes: [(name: String, text: String)] = []

    var body: some View {
        NavigationStack {
            List {
                // Notes live in Ergon's own storage, not the Apple Notes app,
                // so this is the only place the user can actually see them.
                Section("Notes in Ergon") {
                    if notes.isEmpty {
                        Text("No notes saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notes, id: \.name) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.name)
                                    .font(.subheadline.weight(.medium))
                                Text(note.text)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section {
                    DisclosureGroup("Activity log (debug)") {
                        ForEach(receipts) { receipt in
                            receiptRow(receipt)
                        }
                        ForEach(model.diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                        if receipts.isEmpty && model.diagnostics.isEmpty {
                            Text("Nothing yet.").foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let all = await model.receipts()
                receipts = Array(all.reversed())
                notes = savedNotes()
            }
        }
    }

    private func receiptRow(_ receipt: Receipt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(receipt.toolName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(decisionLabel(receipt.decision))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(outcomeLabel(receipt.outcome))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("\(receipt.latencyMS) ms")
                    .monospacedDigit()
                Text(receipt.hash.prefix(8))
                    .monospaced()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func diagnosticRow(_ diagnostic: AppModel.Diagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("no action")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(diagnostic.language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(diagnostic.intent)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(diagnostic.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func decisionLabel(_ decision: Receipt.Decision) -> String {
        switch decision {
        case .approved: "approved"
        case .denied: "denied"
        case .autoRead: "read"
        case .autoRun: "ran, undoable"
        case .undone: "undone"
        case .refused: "refused"
        }
    }

    private func outcomeLabel(_ outcome: Receipt.Outcome) -> String {
        switch outcome {
        case .pending: "pending"
        case .success(let summary): summary.isEmpty ? "success" : "success: \(summary)"
        case .failure(let reason): "failed: \(reason)"
        case .denied: "denied"
        }
    }
}
