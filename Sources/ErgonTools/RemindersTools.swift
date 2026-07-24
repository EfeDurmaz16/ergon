import Ergon
import FoundationModels
import EventKit
import Foundation

// EKReminder is not Sendable, so it must never cross the continuation
// boundary. Each tool does its fetch, filter, and mutation entirely inside
// the completion handler and resumes with a Sendable String result.

private func withReminders(
    _ body: @escaping @Sendable ([EKReminder]) throws -> String
) async throws -> String {
    let predicate = sharedEventStore.predicateForReminders(in: nil)
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
        sharedEventStore.fetchReminders(matching: predicate) { found in
            do {
                c.resume(returning: try body(found ?? []))
            } catch {
                c.resume(throwing: error)
            }
        }
    }
}

public struct ListRemindersTool: ReadTool {
    public let name = "listReminders"
    public let description = "Lists titles and due dates of incomplete reminders."

    // No arguments. The placeholder field this used to carry only gave the
    // model something meaningless to fill in and get wrong.
    @Generable
    public struct Arguments {}

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        do {
            try await Access.ensureReminders()
        } catch {
            return "Could not access reminders: \(error.localizedDescription)"
        }
        return try await withReminders { reminders in
            let incomplete = reminders.filter { !$0.isCompleted }
            guard !incomplete.isEmpty else { return "No incomplete reminders." }
            let lines = incomplete.map { reminder -> String in
                if let comps = reminder.dueDateComponents, let date = Calendar.current.date(from: comps) {
                    return "\(reminder.title ?? "Untitled") (due \(formatDay(date)))"
                }
                return "\(reminder.title ?? "Untitled") (no due date)"
            }
            return "Incomplete reminders: " + lines.joined(separator: ", ")
        }
    }
}

// ReminderCreateTool lives in ReminderTool.swift.

public struct CompleteReminderTool: ConsequentialTool {
    public let name = "completeReminder"
    public let description = "Marks the first incomplete reminder matching a title fragment as complete."
    public let isReversible = true

    @Generable
    public struct Arguments {
        @Guide(description: "Fragment of the reminder title to match, case-insensitive")
        var title: String
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Complete reminder", detail: arguments.title)
    }

    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureReminders()
        let fragment = arguments.title
        return try await withReminders { reminders in
            guard let match = reminders.first(where: {
                !$0.isCompleted && ($0.title?.localizedCaseInsensitiveContains(fragment) ?? false)
            }) else {
                throw ReminderToolError.notFound(fragment)
            }
            match.isCompleted = true
            try sharedEventStore.save(match, commit: true)
            return "Marked \"\(match.title ?? fragment)\" as complete."
        }
    }
}

public struct DeleteReminderTool: ConsequentialTool {
    public let name = "deleteReminder"
    public let description = "Deletes the first reminder matching a title fragment."
    public let isReversible = false

    @Generable
    public struct Arguments {
        @Guide(description: "Fragment of the reminder title to match, case-insensitive")
        var title: String
    }

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Delete reminder", detail: arguments.title)
    }

    public func call(arguments: Arguments) async throws -> String {
        try await Access.ensureReminders()
        let fragment = arguments.title
        return try await withReminders { reminders in
            // Deletion is irreversible, so it fails closed on ambiguity rather
            // than silently taking the first match, and it never reaches past
            // an open reminder to delete a completed one with a similar title.
            let matches = reminders.filter {
                !$0.isCompleted && ($0.title?.localizedCaseInsensitiveContains(fragment) ?? false)
            }
            guard !matches.isEmpty else { throw ReminderToolError.notFound(fragment) }
            guard matches.count == 1 else {
                throw ReminderToolError.ambiguous(matches.compactMap(\.title))
            }
            let match = matches[0]
            let matchedTitle = match.title ?? fragment
            try sharedEventStore.remove(match, commit: true)
            return "Deleted reminder \"\(matchedTitle)\"."
        }
    }
}

enum ReminderToolError: Error, LocalizedError {
    case notFound(String)
    case ambiguous([String])

    var errorDescription: String? {
        switch self {
        case .notFound(let fragment):
            return "No open reminder found matching \"\(fragment)\"."
        case .ambiguous(let titles):
            return "Several reminders match: \"\(titles.joined(separator: "\", \""))\". Ask the user which one."
        }
    }
}
