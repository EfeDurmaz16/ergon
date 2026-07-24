import SwiftUI
import Ergon
import ErgonUI

/// The single Ask screen: transcript above, one input field below. The primary
/// action and the live streaming indicator are the only things that carry the
/// accent color; everything else is weight and text hierarchy.
struct AskView: View {
    let model: AppModel

    @State private var input = ""
    @State private var showReceipts = false
    @FocusState private var focused: Bool

    private let turkishSupported = Ergon.supports(Locale(identifier: "tr"))

    private let examples = [
        "yarın 9'a diş randevusu koy, çakışma varsa haber ver",
        "set a timer for 10 minutes",
        "find coffee shops near me",
        "what is my battery level",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                inputArea
            }
            .navigationTitle("Ergon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Receipts") { showReceipts = true }
                }
            }
            .sheet(isPresented: $showReceipts) {
                ReceiptsView(model: model)
            }
            .task {
                model.prewarm()
                focused = true
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !turkishSupported {
                    Text("Turkish needs iOS 26.1 or later. English works on this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.transcript.isEmpty {
                    emptyState
                } else {
                    ForEach(model.transcript) { turn in
                        turnView(turn)
                    }
                    if let screen = model.presenter.screen {
                        ErgonScreenView(screen) { suggestion in
                            model.submit(suggestion)
                        }
                        .padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("generativeScreen")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ask in plain language. Ergon routes to calendar, reminders, maps, weather, contacts, notes, alarms, or the device, and stages any real change for your approval.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        model.submit(example)
                    } label: {
                        Text(example)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    private func turnView(_ turn: AppModel.Turn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(turn.role == .user ? "You" : "Ergon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let domain = turn.domain, turn.role == .assistant {
                    Text(domain)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(turn.text)
                .font(.body)
                .foregroundStyle(turn.role == .user ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                bannerView(banner)
            }
            HStack(spacing: 12) {
                TextField("Ask Ergon", text: $input)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                sendControl
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sendControl: some View {
        if model.isRunning {
            ProgressView()
                .tint(.accentColor)
                .frame(width: 28)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .tint(.accentColor)
            .disabled(trimmedInput.isEmpty)
            .frame(width: 28)
        }
    }

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        input = ""
        model.submit(text)
    }
}
