import Ergon
import FoundationModels
import EventKit
import Foundation

private func findSingleEvent(
    titleContains: String,
    start: Date,
    end: Date
) throws -> EKEvent {
    let predicate = sharedEventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
    let matches = sharedEventStore.events(matching: predicate).filter {
        $0.title?.localizedCaseInsensitiveContains(titleContains) == true
    }
    guard !matches.isEmpty else {
        throw ErgonToolError.message("No event found with title containing \"\(titleContains)\" in the given window.")
    }
    guard matches.count == 1 else {
        let titles = matches.map { $0.title ?? "untitled" }.joined(separator: "\", \"")
        throw ErgonToolError.message("Multiple events match \"\(titleContains)\": \"\(titles)\". Be more specific.")
    }
    return matches[0]
}

enum ErgonToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): return m
        }
    }
}

public struct UpdateCalendarEventTool: ConsequentialTool {
    public let name = "updateCalendarEvent"
    public let description = "Updates the start time, duration, or title of an upcoming calendar event found by matching its current title."

    @Generable
    public struct Arguments {
        @Guide(description: "Substring to match against the current event title, used to find the single event to update")
        var titleContains: String
        @Guide(description: "New start time as ISO 8601 with offset, e.g. 2026-07-25T09:00:00+03:00")
        var newStartISO8601: String?
        @Guide(description: "New duration in minutes, replacing the event's current duration", .range(1...1440))
        var newDurationMinutes: Int?
        @Guide(description: "New title to replace the event's current title")
        var newTitle: String?
    }

    public var isReversible: Bool { true }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        var changes: [String] = []
        if let s = arguments.newStartISO8601 { changes.append("start time to \(s)") }
        if let d = arguments.newDurationMinutes { changes.append("duration to \(d) minutes") }
        if let t = arguments.newTitle { changes.append("title to \"\(t)\"") }
        let detail = changes.isEmpty
            ? "No changes specified for event matching \"\(arguments.titleContains)\"."
            : "Change \(changes.joined(separator: ", ")) for event matching \"\(arguments.titleContains)\"."
        return ActionPreview(title: "Update calendar event", detail: detail)
    }

    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureEvents()

        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: 60, to: now) else {
            throw ErgonToolError.message("Could not compute search window.")
        }

        let event = try findSingleEvent(titleContains: arguments.titleContains, start: now, end: horizon)

        if let newStartISO8601 = arguments.newStartISO8601 {
            let newStart = try parseISO(newStartISO8601)
            let originalDuration = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = newStart
            event.endDate = newStart.addingTimeInterval(originalDuration)
        }
        if let minutes = arguments.newDurationMinutes {
            event.endDate = event.startDate.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if let newTitle = arguments.newTitle {
            event.title = newTitle
        }

        do {
            try sharedEventStore.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ErgonToolError.message("Failed to save updated event: \(error.localizedDescription)")
        }

        return "Updated event \"\(event.title ?? arguments.titleContains)\" on \(formatDay(event.startDate))."
    }
}

public struct DeleteCalendarEventTool: ConsequentialTool {
    public let name = "deleteCalendarEvent"
    public let description = "Deletes a calendar event found by matching its title near a given start time."

    @Generable
    public struct Arguments {
        @Guide(description: "Substring to match against the event title, used to find the event to delete")
        var titleContains: String
        @Guide(description: "Approximate start time of the event as ISO 8601 with offset, used to disambiguate")
        var startISO8601: String
    }

    public var isReversible: Bool { false }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(
            title: "Delete calendar event",
            detail: "Permanently delete the event matching \"\(arguments.titleContains)\" near \(arguments.startISO8601). This cannot be undone."
        )
    }

    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureEvents()

        let anchor = try parseISO(arguments.startISO8601)
        guard
            let windowStart = Calendar.current.date(byAdding: .day, value: -1, to: anchor),
            let windowEnd = Calendar.current.date(byAdding: .day, value: 1, to: anchor)
        else {
            throw ErgonToolError.message("Could not compute search window.")
        }

        let event = try findSingleEvent(titleContains: arguments.titleContains, start: windowStart, end: windowEnd)
        let title = event.title ?? arguments.titleContains
        let day = formatDay(event.startDate)

        do {
            try sharedEventStore.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw ErgonToolError.message("Failed to delete event: \(error.localizedDescription)")
        }

        return "Deleted event \"\(title)\" on \(day)."
    }
}
