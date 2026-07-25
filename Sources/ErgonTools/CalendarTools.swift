import EventKit
import Foundation
import FoundationModels
import Ergon

// Argument structs conform to Generable by hand instead of via @Generable:
// the macro plugin ships only inside Xcode and this package also builds
// under plain Command Line Tools. The conformances mirror what the macro
// generates, using public API only. Your own tools should use @Generable.

/// Finds events in a time window. Read-only: runs during generation so the
/// model can detect conflicts before proposing an event.
public struct CalendarQueryTool: ReadTool {
    public struct Arguments: Generable {
        public var startISO8601: String
        public var endISO8601: String

        public static var generationSchema: GenerationSchema {
            GenerationSchema(type: Self.self, description: "A time window to search.", properties: [
                .init(name: "startISO8601",
                      description: "Window start, ISO 8601 with offset, like 2026-07-25T09:00:00+03:00",
                      type: String.self),
                .init(name: "endISO8601",
                      description: "Window end, ISO 8601 with offset",
                      type: String.self),
            ])
        }

        public init(_ content: GeneratedContent) throws {
            startISO8601 = try content.value(forProperty: "startISO8601")
            endISO8601 = try content.value(forProperty: "endISO8601")
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(properties: ["startISO8601": startISO8601, "endISO8601": endISO8601])
        }
    }

    public let name = "queryCalendar"
    public let description = "Find existing calendar events between two times. Use it before creating an event to detect conflicts."

    public init() {}

    // Errors come back as strings, not throws: a thrown read-tool error
    // aborts the whole generation, while a described problem lets the model
    // explain it to the user.
    public func call(arguments: Arguments) async throws -> String {
        do {
            try await Access.ensureEvents()
            let start = try parseISO(arguments.startISO8601)
            let end = try parseISO(arguments.endISO8601)
            let predicate = sharedEventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = sharedEventStore.events(matching: predicate)
            guard !events.isEmpty else {
                return "No events between \(formatWindow(start, end)). The window is free."
            }
            let lines = events.map { event in
                "- \(event.title ?? "Untitled"): \(formatWindow(event.startDate, event.endDate))"
            }
            return "Existing events in that window (possible conflicts):\n" + lines.joined(separator: "\n")
        } catch {
            return "Could not check the calendar: \(error.localizedDescription)"
        }
    }
}

/// Creates a real calendar event. Reversible, so it runs during generation
/// and offers an undo instead of interrupting with an approval sheet.
public struct CalendarCreateTool: ReversibleTool {
    public struct Arguments: Generable {
        public var title: String
        public var startISO8601: String
        public var durationMinutes: Int
        public var notes: String?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(type: Self.self, description: "A calendar event to create.", properties: [
                .init(name: "title", description: "Short event title in the user's language", type: String.self),
                .init(name: "startISO8601",
                      description: "Start time, ISO 8601 with offset, like 2026-07-25T09:00:00+03:00",
                      type: String.self),
                .init(name: "durationMinutes", description: "Event length in minutes",
                      type: Int.self, guides: [.range(5...480)]),
                .init(name: "notes", description: "Optional notes", type: String?.self),
            ])
        }

        public init(_ content: GeneratedContent) throws {
            title = try content.value(forProperty: "title")
            startISO8601 = try content.value(forProperty: "startISO8601")
            durationMinutes = try content.value(forProperty: "durationMinutes")
            notes = try content.value(String?.self, forProperty: "notes")
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(properties: ["title": title, "startISO8601": startISO8601,
                                          "durationMinutes": durationMinutes, "notes": notes])
        }
    }

    public let name = "createCalendarEvent"
    public let description = "Create a calendar event with a title, start time, and duration. Check the window with queryCalendar first; on conflict do not create, tell the user instead."

    public init() {}

    /// Re-finds the event by title in a window around its start and removes
    /// it. `findSingleEvent` fails closed when several match, so an undo can
    /// never delete a neighbouring event by accident.
    public func undo(_ arguments: Arguments) async throws -> String {
        try await Access.ensureEvents()
        let start = try parseISO(arguments.startISO8601)
        let event = try findSingleEvent(titleContains: arguments.title,
                                        start: start.addingTimeInterval(-60),
                                        end: start.addingTimeInterval(TimeInterval(arguments.durationMinutes * 60) + 60))
        try sharedEventStore.remove(event, span: .thisEvent, commit: true)
        return "Removed '\(arguments.title)'."
    }

    public func preview(_ arguments: Arguments) -> ActionPreview {
        let when = (try? parseISO(arguments.startISO8601)).map(formatDay) ?? arguments.startISO8601
        return ActionPreview(title: "Create calendar event",
                             detail: "\(arguments.title), \(when), \(arguments.durationMinutes) min")
    }

    // Contract: throwing means no event was saved. EKEventStore.save is
    // atomic per event, so a throw here cannot leave a half-created event.
    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureEvents()
        let start = try parseISO(arguments.startISO8601)
        guard let calendar = sharedEventStore.defaultCalendarForNewEvents else {
            throw ToolError.noCalendar
        }
        let event = EKEvent(eventStore: sharedEventStore)
        event.title = arguments.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(arguments.durationMinutes * 60))
        event.notes = arguments.notes
        event.calendar = calendar
        try sharedEventStore.save(event, span: .thisEvent, commit: true)
        return "Created event '\(arguments.title)' on \(formatDay(start))."
    }
}
