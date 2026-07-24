import Foundation
import Observation
import NaturalLanguage
import os
import Ergon
import ErgonTools
import ErgonUI

/// The demo's single source of truth. Owns the Router (many tool domains
/// behind an on-device classifier), a ScreenPresenter for generative UI, the
/// visible transcript, the diagnostics list, and the inline error banner.
/// Everything stays on the main actor: the runtime is @MainActor, so the
/// views are too.
@MainActor
@Observable
final class AppModel {
    struct Turn: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// The domain the router picked, shown on assistant turns.
        var domain: String?
    }

    struct Diagnostic: Identifiable {
        let id = UUID()
        let timestamp: Date
        let language: String
        let intent: String
        let reply: String
    }

    /// nil when the runtime failed to start; the reason lives in initErrorMessage.
    let router: Router?
    let presenter = ScreenPresenter()
    let initErrorMessage: String?

    var transcript: [Turn] = []
    var diagnostics: [Diagnostic] = []
    var banner: String?

    private static let logger = Logger(subsystem: "dev.efedurmaz.ErgonDemo", category: "resolution")

    init() {
        do {
            self.router = try Router(toolsets: ErgonToolkit.allToolsets())
            self.initErrorMessage = nil
        } catch let error as ErgonError {
            self.router = nil
            self.initErrorMessage = error.errorDescription ?? "The runtime could not start."
        } catch {
            self.router = nil
            self.initErrorMessage = error.localizedDescription
        }
    }

    var isRunning: Bool { (router?.isRunning ?? false) || presenter.isPresenting }

    func prewarm() {
        router?.prewarm()
        presenter.prewarm()
    }

    /// Resolve one intent. Streams the reply into an assistant turn (partial
    /// carries the whole text so far, so we replace). If the run stages no
    /// approval, it was informational, so present a rich generative screen
    /// grounded in the reply. Approval, when needed, is handled by the
    /// drop-in sheet attached at the root.
    func submit(_ intent: String) {
        guard let router, !intent.isEmpty else { return }
        banner = nil
        transcript.append(Turn(role: .user, text: intent))
        let assistant = Turn(role: .assistant, text: "")
        transcript.append(assistant)
        let assistantID = assistant.id

        Task {
            var sawApproval = false
            var sawExecuted = false
            var finalReply = ""
            var domain: String?
            do {
                for try await event in router.run(intent) {
                    switch event {
                    case .routed(let name):
                        domain = name
                        setDomain(id: assistantID, domain: name)
                    case .partial(let text):
                        finalReply = text
                        setAssistant(id: assistantID, text: text)
                    case .reply(let text):
                        finalReply = text
                        setAssistant(id: assistantID, text: text)
                    case .needsApproval:
                        sawApproval = true
                    case .executed:
                        sawExecuted = true
                    }
                }
            } catch let error as ErgonError {
                banner = error.errorDescription ?? "Something went wrong."
            } catch {
                banner = error.localizedDescription
            }

            // Informational answer: render it as a native screen.
            if !sawApproval, !finalReply.isEmpty {
                await presenter.present(intent, grounding: finalReply)
            }
            logResolutionIfNeeded(intent: intent, reply: finalReply, domain: domain,
                                  sawApproval: sawApproval, sawExecuted: sawExecuted)
        }
    }

    private func setAssistant(id: UUID, text: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
    }

    private func setDomain(id: UUID, domain: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].domain = domain
    }

    /// If the run staged nothing, executed nothing, and did not warn about a
    /// conflict, it did not resolve to an action. Log it per detected language.
    private func logResolutionIfNeeded(intent: String, reply: String, domain: String?,
                                       sawApproval: Bool, sawExecuted: Bool) {
        guard !sawApproval, !sawExecuted, !looksLikeConflictWarning(reply) else { return }
        let language = detectedLanguage(intent)
        Self.logger.log("resolution: no action, language=\(language, privacy: .public), domain=\(domain ?? "none", privacy: .public)")
        diagnostics.insert(Diagnostic(timestamp: Date(), language: language,
                                      intent: intent, reply: reply), at: 0)
    }

    private func detectedLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "und"
    }

    private func looksLikeConflictWarning(_ reply: String) -> Bool {
        let lower = reply.lowercased()
        let markers = ["conflict", "çakış", "cakis", "already", "busy", "instead",
                       "alternative", "alternatif", "dolu", "yerine", "başka", "meşgul"]
        return markers.contains { lower.contains($0) }
    }

    func receipts() async -> [Receipt] {
        await router?.receipts() ?? []
    }
}
