import SwiftUI
import Ergon

/// The audit surface: the verified receipt trail (newest first) plus the
/// in-memory resolution diagnostics. Machine values use monospaced digits so
/// they line up and read as data, not prose.
struct ReceiptsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [Receipt] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Receipts") {
                    if receipts.isEmpty {
                        Text("No receipts yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(receipts) { receipt in
                            receiptRow(receipt)
                        }
                    }
                }
                if !model.diagnostics.isEmpty {
                    Section("Diagnostics (debug)") {
                        ForEach(model.diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                    }
                }
            }
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let all = await model.engine?.receipts() ?? []
                receipts = Array(all.reversed())
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
