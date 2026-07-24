import SwiftUI
import Ergon

@main
struct ErgonDemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Gates the whole app on model availability first, then on whether the engine
/// actually started. Each dead end is a full screen, not an alert.
struct RootView: View {
    var body: some View {
        switch Ergon.availability {
        case .ready:
            ReadyView()
        case .unavailable(let reason):
            MessageScreen(title: unavailableTitle(reason),
                          message: ErgonError.modelUnavailable(reason).errorDescription
                            ?? "The on-device model is unavailable.")
        }
    }

    private func unavailableTitle(_ reason: Ergon.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: "Not supported on this device"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .modelNotReady: "Model is getting ready"
        case .unknown: "Model unavailable"
        }
    }
}

struct ReadyView: View {
    @State private var model = AppModel()

    var body: some View {
        if let engine = model.engine {
            AskView(model: model)
                .approvalSheet(engine)
        } else {
            MessageScreen(title: "Ergon could not start",
                          message: model.initErrorMessage ?? "Unknown error.")
        }
    }
}

/// Neutral, centered full-screen state used for every unavailable or error case.
struct MessageScreen: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
