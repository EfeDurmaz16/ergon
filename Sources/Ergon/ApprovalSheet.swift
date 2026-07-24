import SwiftUI

extension View {
    /// Drop-in approval surface. Presents a sheet whenever the engine has a
    /// pending approval; approvals queue through it one at a time.
    /// Dismissing the sheet without deciding denies the shown approval:
    /// deny by default extends to the UI.
    public func approvalSheet(_ engine: Ergon) -> some View {
        modifier(ApprovalSheetModifier(
            pending: { engine.pendingApprovals },
            approve: { try await engine.approve($0) },
            deny: { try await engine.deny($0) }))
    }

    /// Router variant: one sheet over every domain's pending approvals.
    public func approvalSheet(_ router: Router) -> some View {
        modifier(ApprovalSheetModifier(
            pending: { router.pendingApprovals },
            approve: { try await router.approve($0) },
            deny: { try await router.deny($0) }))
    }
}

struct ApprovalSheetModifier: ViewModifier {
    let pending: () -> [Approval]
    let approve: @MainActor (UUID) async throws -> Receipt
    let deny: @MainActor (UUID) async throws -> Receipt

    func body(content: Content) -> some View {
        content.sheet(item: current) { approval in
            ApprovalSheetView(approval: approval, approve: approve, deny: deny)
                .id(approval.id)  // fresh working/error state per approval
                .presentationDetents([.medium])
        }
    }

    private var current: Binding<Approval?> {
        Binding(
            get: { pending().first },
            set: { newValue in
                if newValue == nil, let shown = pending().first {
                    Task { _ = try? await deny(shown.id) }
                }
            })
    }
}

struct ApprovalSheetView: View {
    let approval: Approval
    let approve: @MainActor (UUID) async throws -> Receipt
    let deny: @MainActor (UUID) async throws -> Receipt
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
                    decide { _ = try await approve(approval.id) }
                } label: {
                    Text("Approve").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .cancel) {
                    decide { _ = try await deny(approval.id) }
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
