import Foundation

/// The only error type Ergon's public API throws. FoundationModels error
/// types never leak through: Apple already deprecated its iOS 26 error enum
/// for iOS 27, so hosts should not couple to it.
public enum ErgonError: Error, LocalizedError, Equatable, Sendable {
    /// The on-device model cannot run on this device or is not ready.
    case modelUnavailable(Ergon.UnavailableReason)
    /// The intent's language or locale is not supported by the model.
    /// Turkish requires iOS 26.1 or later.
    case unsupportedLanguage
    /// The session transcript outgrew the model's context window.
    case contextOverflow
    /// The system safety layer refused the request. Happens on benign
    /// input occasionally; surface it as an exception state, not a crash.
    case guardrailRefusal
    /// approve/deny was called with an id that is not pending.
    case unknownApproval
    /// A previous execution with the same idempotency key was interrupted
    /// before recording an outcome. Ergon fails closed instead of risking a
    /// double execution; the user should check the target app.
    case unresolvedExecution(idempotencyKey: String)
    /// The receipt log failed hash-chain verification or does not decode.
    case corruptReceiptLog(String)
    /// Any other generation failure, with a debug description.
    case generation(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(.deviceNotEligible):
            "This device does not support Apple Intelligence."
        case .modelUnavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled. Turn it on in Settings."
        case .modelUnavailable(.modelNotReady):
            "The on-device model is still downloading. Try again shortly."
        case .modelUnavailable(.unknown):
            "The on-device model is unavailable."
        case .unsupportedLanguage:
            "The on-device model does not support this language on this device."
        case .contextOverflow:
            "The conversation is too long for the on-device model. Start a new one."
        case .guardrailRefusal:
            "The system safety layer declined this request."
        case .unknownApproval:
            "No pending approval matches this id."
        case .unresolvedExecution(let key):
            "A previous run of this action (key \(key.prefix(8))) was interrupted before its outcome was recorded. Refusing to run it again automatically; please verify in the target app."
        case .corruptReceiptLog(let detail):
            "Receipt log failed verification: \(detail)"
        case .generation(let detail):
            "Generation failed: \(detail)"
        }
    }
}
