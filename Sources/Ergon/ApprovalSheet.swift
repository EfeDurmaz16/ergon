import SwiftUI

extension View {
    /// Drop-in approval surface. Presents a sheet whenever the engine has a
    /// pending approval; approvals queue through it one at a time.
    /// Dismissing the sheet without deciding denies the shown approval:
    /// deny by default extends to the UI.
    public func approvalSheet(_ engine: Ergon) -> some View {
        modifier(ApprovalSheetModifier(engine: engine))
    }
}

struct ApprovalSheetModifier: ViewModifier {
    @Bindable var engine: Ergon

    func body(content: Content) -> some View {
        content.sheet(item: current) { approval in
            ApprovalSheetView(approval: approval, engine: engine)
                .presentationDetents([.medium])
        }
    }

    private var current: Binding<Approval?> {
        Binding(
            get: { engine.pendingApprovals.first },
            set: { newValue in
                if newValue == nil, let shown = engine.pendingApprovals.first {
                    Task { try? await engine.deny(shown.id) }
                }
            })
    }
}

struct ApprovalSheetView: View {
    let approval: Approval
    let engine: Ergon
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(approval.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Text(approval.preview.title)
                    .font(.title3.weight(.semibold))
                Text(approval.preview.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Label(approval.isReversible ? "Reversible" : "Not reversible",
                  systemImage: approval.isReversible ? "arrow.uturn.backward" : "exclamationmark.triangle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(approval.isReversible ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Button {
                    decide { try await engine.approve(approval.id) }
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .cancel) {
                    decide { try await engine.deny(approval.id) }
                } label: {
                    Text("Reject")
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .disabled(working)
    }

    private func decide(_ op: @escaping @MainActor () async throws -> Void) {
        working = true
        errorText = nil
        Task {
            do {
                try await op()
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
