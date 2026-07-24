import Foundation
import Observation
import NaturalLanguage
import os
import Ergon
import ErgonTools

/// The demo's single source of truth. Owns the Ergon engine, the visible
/// transcript, the diagnostics list, and the inline error banner. Everything
/// stays on the main actor: the engine is @MainActor, so the views are too.
@MainActor
@Observable
final class AppModel {
    struct Turn: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    /// One logged resolution failure: a run that resolved to no action and no
    /// conflict warning. Kept in memory and shown in the debug section.
    struct Diagnostic: Identifiable {
        let id = UUID()
        let timestamp: Date
        let language: String
        let intent: String
        let reply: String
    }

    /// nil when the engine failed to start; the reason lives in initErrorMessage.
    let engine: Ergon?
    let initErrorMessage: String?

    var transcript: [Turn] = []
    var diagnostics: [Diagnostic] = []
    var banner: String?

    private static let logger = Logger(subsystem: "dev.efedurmaz.ErgonDemo", category: "resolution")

    init() {
        do {
            self.engine = try Ergon(
                tools: [CalendarQueryTool(), CalendarCreateTool(), ReminderCreateTool()],
                instructions: ErgonToolkit.calendarInstructions)
            self.initErrorMessage = nil
        } catch let error as ErgonError {
            self.engine = nil
            self.initErrorMessage = error.errorDescription ?? "The runtime could not start."
        } catch {
            self.engine = nil
            self.initErrorMessage = error.localizedDescription
        }
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    /// Resolve one intent. Appends a user turn and an assistant turn, then
    /// streams the reply into the assistant turn (partial carries the whole
    /// text so far, so we replace, never append). Approval, if any, is handled
    /// by the drop-in sheet attached at the root.
    func submit(_ intent: String) {
        guard let engine, !intent.isEmpty else { return }
        banner = nil
        transcript.append(Turn(role: .user, text: intent))
        let assistant = Turn(role: .assistant, text: "")
        transcript.append(assistant)
        let assistantID = assistant.id

        Task {
            var sawApproval = false
            var sawExecuted = false
            var finalReply = ""
            do {
                for try await event in engine.run(intent) {
                    switch event {
                    case .partial(let text):
                        finalReply = text
                        setAssistant(id: assistantID, text: text)
                    case .reply(let text):
                        finalReply = text
                        setAssistant(id: assistantID, text: text)
                    case .needsApproval:
                        sawApproval = true
                    case .executed:
                        // Read-tool receipts arrive here during the stream.
                        sawExecuted = true
                    }
                }
            } catch let error as ErgonError {
                banner = error.errorDescription ?? "Something went wrong."
            } catch {
                banner = error.localizedDescription
            }
            logResolutionIfNeeded(intent: intent, reply: finalReply,
                                  sawApproval: sawApproval, sawExecuted: sawExecuted)
        }
    }

    private func setAssistant(id: UUID, text: String) {
        guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
    }

    /// If the run staged nothing, executed nothing, and did not warn about a
    /// conflict, it did not resolve to an action. Log it per detected language.
    private func logResolutionIfNeeded(intent: String, reply: String,
                                       sawApproval: Bool, sawExecuted: Bool) {
        guard !sawApproval, !sawExecuted, !looksLikeConflictWarning(reply) else { return }
        let language = detectedLanguage(intent)
        Self.logger.log("resolution failure: no action taken, language=\(language, privacy: .public)")
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
}
