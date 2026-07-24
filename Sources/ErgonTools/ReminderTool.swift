import EventKit
import Foundation
import FoundationModels
import Ergon

/// Creates a real reminder. Consequential: never runs without approval.
public struct ReminderCreateTool: ConsequentialTool {
    public struct Arguments: Generable {
        public var title: String
        public var dueISO8601: String?
        public var notes: String?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(type: Self.self, description: "A reminder to create.", properties: [
                .init(name: "title", description: "Short reminder title in the user's language", type: String.self),
                .init(name: "dueISO8601",
                      description: "Optional due time, ISO 8601 with offset, like 2026-07-25T09:00:00+03:00",
                      type: String?.self),
                .init(name: "notes", description: "Optional notes", type: String?.self),
            ])
        }

        public init(_ content: GeneratedContent) throws {
            title = try content.value(forProperty: "title")
            dueISO8601 = try content.value(String?.self, forProperty: "dueISO8601")
            notes = try content.value(String?.self, forProperty: "notes")
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(properties: ["title": title, "dueISO8601": dueISO8601, "notes": notes])
        }
    }

    public let name = "createReminder"
    public let description = "Create a reminder with a title and an optional due time."
    public let isReversible = true

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        let due = arguments.dueISO8601.flatMap { try? parseISO($0) }.map { ", due \(formatDay($0))" } ?? ""
        return ActionPreview(title: "Create reminder", detail: arguments.title + due)
    }

    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureReminders()
        guard let calendar = sharedEventStore.defaultCalendarForNewReminders() else {
            throw ToolError.noCalendar
        }
        let reminder = EKReminder(eventStore: sharedEventStore)
        reminder.title = arguments.title
        reminder.notes = arguments.notes
        reminder.calendar = calendar
        if let raw = arguments.dueISO8601 {
            let due = try parseISO(raw)
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        try sharedEventStore.save(reminder, commit: true)
        let dueText = (arguments.dueISO8601.flatMap { try? parseISO($0) }).map { ", due \(formatDay($0))" } ?? ""
        return "Created reminder '\(arguments.title)'\(dueText)."
    }
}
