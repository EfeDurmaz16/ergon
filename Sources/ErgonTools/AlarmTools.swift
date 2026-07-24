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
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: config)
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
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: config)
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
            return "Scheduled: " + alarms.map { $0.id.uuidString.prefix(8) }.joined(separator: ", ")
        } catch {
            return "Could not read alarms: \(error.localizedDescription)"
        }
    }
}

/// Cancels a scheduled alarm by its short id prefix. Consequential, reversible.
public struct CancelAlarmTool: ConsequentialTool {
    public let name = "cancelAlarm"
    public let description = "Cancel a scheduled alarm or timer by its short id shown in the list."
    public let isReversible = true

    @Generable
    public struct Arguments {
        @Guide(description: "The short id prefix of the alarm to cancel, from listAlarms")
        var idPrefix: String
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Cancel alarm", detail: arguments.idPrefix)
    }

    public func call(arguments: Arguments) async throws -> String {
        try await AlarmAccess.ensure()
        let alarms = try AlarmManager.shared.alarms
        guard let match = alarms.first(where: {
            $0.id.uuidString.lowercased().hasPrefix(arguments.idPrefix.lowercased())
        }) else {
            throw AlarmToolError.notFound(arguments.idPrefix)
        }
        try AlarmManager.shared.cancel(id: match.id)
        return "Cancelled alarm \(match.id.uuidString.prefix(8))."
    }
}
#endif
