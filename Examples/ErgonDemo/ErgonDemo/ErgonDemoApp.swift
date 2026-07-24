import SwiftUI
import Ergon
import ErgonUI

@main
struct ErgonDemoApp: App {
    var body: some Scene {
        WindowGroup {
            // A launch-argument path renders a canned generative screen with
            // no model call, so the ErgonUI rendering can be snapshot-tested
            // deterministically without waiting on on-device generation.
            if ProcessInfo.processInfo.arguments.contains("-previewScreen") {
                PreviewScreen()
            } else {
                RootView()
            }
        }
    }
}

struct PreviewScreen: View {
    private let sample = ErgonScreen(
        title: "Weather",
        summary: "Istanbul is currently 24 C and partly cloudy, with moderate humidity.",
        facts: [
            ErgonFact(label: "Now", value: "24 C"),
            ErgonFact(label: "Sky", value: "Partly cloudy"),
            ErgonFact(label: "Humidity", value: "60%"),
            ErgonFact(label: "Tomorrow", value: "26 C / 18 C"),
        ],
        suggestions: ["See the weekend", "Weather in Ankara", "Do I need an umbrella"])

    var body: some View {
        ScrollView {
            ErgonScreenView(sample.asPartiallyGenerated())
                .padding(16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("generativeScreen")
                .padding(20)
        }
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
        if let router = model.router {
            AskView(model: model)
                .approvalSheet(router)
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
