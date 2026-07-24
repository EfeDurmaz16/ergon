import Foundation
import FoundationModels
import Observation

/// Turns an intent (and any grounding text, e.g. tool output already gathered)
/// into a streamed ``ErgonScreen``. This is a read-only presentation pass: it
/// generates structured content, never actions, so it needs no approval. Use
/// it for informational answers where a native layout beats prose.
@MainActor
@Observable
public final class ScreenPresenter {
    /// The screen as it streams in. Fields populate top to bottom; bind this
    /// straight into a view and it assembles itself.
    public private(set) var screen: ErgonScreen.PartiallyGenerated?
    public private(set) var isPresenting = false
    public private(set) var errorText: String?

    @ObservationIgnored private let session: LanguageModelSession

    public init(instructions: String? = nil) {
        let base = instructions ?? "You turn information into a compact screen. Answer in the language of the request. Keep the title to a few words and the summary to one or two sentences. Put concrete numbers and names in facts. Suggestions are short next actions the user might tap."
        self.session = LanguageModelSession(instructions: base)
    }

    /// Whether the on-device model can render screens here.
    public nonisolated static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func prewarm() {
        session.prewarm()
    }

    /// Generate a screen. `grounding` is optional context the model should
    /// present (for example, the text a read tool already returned), which
    /// keeps the model from inventing facts.
    public func present(_ intent: String, grounding: String? = nil) async {
        guard !isPresenting else { return }
        isPresenting = true
        errorText = nil
        screen = nil
        defer { isPresenting = false }

        var prompt = intent
        if let grounding, !grounding.isEmpty {
            prompt += "\n\nUse only this information, do not invent details:\n\(grounding)"
        }
        do {
            let stream = session.streamResponse(to: prompt, generating: ErgonScreen.self,
                                                includeSchemaInPrompt: true)
            for try await partial in stream {
                screen = partial.content
            }
        } catch let error as LanguageModelSession.GenerationError {
            errorText = presentable(error)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func presentable(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal:
            "The system safety layer declined this request."
        case .exceededContextWindowSize:
            "That was too much to summarize at once."
        case .unsupportedLanguageOrLocale:
            "This language is not supported on this device."
        default:
            "Could not render the answer."
        }
    }
}
