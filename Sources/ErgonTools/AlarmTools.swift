#if canImport(AlarmKit)
import Ergon
import FoundationModels
import AlarmKit
import Foundation
import SwiftUI

/// Empty metadata: AlarmKit requires a Metadata type conforming to
/// AlarmMetadata (Codable, Hashable, Sendable). We carry none.
public struct ErgonAlarmMetadata: AlarmMetadata {
    public init() {}
}

enum AlarmToolError: Error, LocalizedError {
    case notAuthorized
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Alarm permission was not granted. Enable it in Settings."
        case .notFound(let label):
            "No scheduled alarm matches \"\(label)\"."
        }
    }
}

/// AlarmKit hands back an `Alarm` with an id, a schedule, a countdown, and a
/// state, but no label: the title lives in the presentation, which the
/// framework keeps to itself. Labels are therefore kept alongside, so a listed
/// alarm reads as "Pizza, 10 min timer" instead of a bare UUID, and so the
/// user can cancel one by name.
enum AlarmLabels {
    private static let key = "ErgonAlarmLabels"

    static func name(for id: UUID) -> String? {
        stored()[id.uuidString]
    }

    static func set(_ label: String, for id: UUID) {
        var map = stored()
        map[id.uuidString] = label
        UserDefaults.standard.set(map, forKey: key)
    }

    static func forget(_ id: UUID) {
        var map = stored()
        map[id.uuidString] = nil
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

/// One human line per alarm. No UUID: a small model prints identifiers it is
/// shown straight into its reply, and the user has no use for them.
func describe(_ alarm: Alarm) -> String {
    var parts = [AlarmLabels.name(for: alarm.id) ?? "Alarm"]
    switch alarm.schedule {
    case .fixed(let date):
        parts.append("at \(formatDay(date))")
    case .relative(let relative):
        parts.append(String(format: "at %02d:%02d", relative.time.hour, relative.time.minute))
    default:
        if let seconds = alarm.countdownDuration?.preAlert {
            parts.append("\(Int((seconds / 60).rounded())) min timer")
        }
    }
    switch alarm.state {
    case .scheduled: parts.append("scheduled")
    case .countdown: parts.append("counting down")
    case .paused: parts.append("paused")
    case .alerting: parts.append("ringing now")
    @unknown default: break
    }
    return parts.joined(separator: ", ")
}

private enum AlarmAccess {
    static func ensure() async throws {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return
        case .notDetermined:
            let state = try await AlarmManager.shared.requestAuthorization()
            guard state == .authorized else { throw AlarmToolError.notAuthorized }
        case .denied:
            throw AlarmToolError.notAuthorized
        @unknown default:
            throw AlarmToolError.notAuthorized
        }
    }

    // ponytail: no countdown/paused presentation and no widget extension, so
    // these are plain one-shot alerts. Add a widget + countdown presentation
    // if the demo needs the Live Activity / Dynamic Island timer UI.
    static func attributes(title: String) -> AlarmAttributes<ErgonAlarmMetadata> {
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        return AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                               metadata: ErgonAlarmMetadata(),
                               tintColor: .accentColor)
    }
}

/// Schedules a one-shot alarm at a fixed time. Consequential, reversible.
public struct CreateAlarmTool: ConsequentialTool {
    public let name = "createAlarm"
    public let description = "Schedule an alarm that fires once at a specific date and time."
    public let isReversible = true

    @Generable
    public struct Arguments {
        @Guide(description: "Short label shown when the alarm fires")
        var label: String
        @Guide(description: "When it fires, ISO 8601 with offset, e.g. 2026-07-25T07:00:00+03:00")
        var atISO8601: String
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        let when = (try? parseISO(arguments.atISO8601)).map(formatDay) ?? arguments.atISO8601
        return ActionPreview(title: "Create alarm", detail: "\(arguments.label), \(when)")
    }

    public func call(arguments: Arguments) async throws -> String {
        try await AlarmAccess.ensure()
        let date = try parseISO(arguments.atISO8601)
        let config = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(date),
            attributes: AlarmAccess.attributes(title: arguments.label))
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        AlarmLabels.set(arguments.label, for: id)
        return "Alarm \"\(arguments.label)\" set for \(formatDay(date))."
    }
}

/// Starts a countdown timer. Consequential, reversible.
public struct CreateTimerTool: ConsequentialTool {
    public let name = "createTimer"
    public let description = "Start a countdown timer for a number of minutes."
    public let isReversible = true

    @Generable
    public struct Arguments {
        @Guide(description: "Short label for the timer")
        var label: String
        @Guide(description: "Length in minutes", .range(1...600))
        var minutes: Int
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Start timer", detail: "\(arguments.label), \(arguments.minutes) min")
    }

    public func call(arguments: Arguments) async throws -> String {
        try await AlarmAccess.ensure()
        let config = AlarmManager.AlarmConfiguration.timer(
            duration: TimeInterval(arguments.minutes * 60),
            attributes: AlarmAccess.attributes(title: arguments.label))
        let id = UUID()
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        AlarmLabels.set(arguments.label, for: id)
        return "Timer \"\(arguments.label)\" started for \(arguments.minutes) minutes."
    }
}

/// Lists scheduled alarms. Read-only.
public struct ListAlarmsTool: ReadTool {
    public let name = "listAlarms"
    public let description = "List the alarms and timers currently scheduled."

    @Generable
    public struct Arguments {}

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            try await AlarmAccess.ensure()
            let alarms = try AlarmManager.shared.alarms
            guard !alarms.isEmpty else { return "No alarms or timers are scheduled." }
            return "Scheduled:\n" + alarms.map(describe).joined(separator: "\n")
        } catch {
            return "Could not read alarms: \(error.localizedDescription)"
        }
    }
}

/// Cancels a scheduled alarm by its label. Consequential, reversible.
public struct CancelAlarmTool: ConsequentialTool {
    public let name = "cancelAlarm"
    public let description = "Cancel a scheduled alarm or timer by its label, as shown by listAlarms."
    public let isReversible = true

    @Generable
    public struct Arguments {
        @Guide(description: "The label of the alarm or timer to cancel, like 'Pizza' or 'Wake up'")
        var label: String
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Cancel alarm", detail: arguments.label)
    }

    /// Matches on the label the user actually sees. Falls back to the only
    /// scheduled alarm when there is exactly one, since "cancel my timer" is
    /// unambiguous then even if the model paraphrases the label.
    public func call(arguments: Arguments) async throws -> String {
        try await AlarmAccess.ensure()
        let alarms = try AlarmManager.shared.alarms
        let wanted = arguments.label.lowercased()
        let match = alarms.first {
            (AlarmLabels.name(for: $0.id) ?? "").lowercased().contains(wanted)
        } ?? (alarms.count == 1 ? alarms.first : nil)
        guard let match else { throw AlarmToolError.notFound(arguments.label) }
        try AlarmManager.shared.cancel(id: match.id)
        let name = AlarmLabels.name(for: match.id) ?? "alarm"
        AlarmLabels.forget(match.id)
        return "Cancelled \(name)."
    }
}
#endif
