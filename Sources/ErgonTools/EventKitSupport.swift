import EventKit
import Foundation

// EKEventStore is documented thread-safe (individual calendar items are not).
// One shared store: stores are expensive to create and Apple recommends
// long-lived instances.
nonisolated(unsafe) let sharedEventStore = EKEventStore()

// ISO8601DateFormatter is documented thread-safe.
nonisolated(unsafe) private let offsetISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

nonisolated(unsafe) private let localISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate,
                               .withTime, .withColonSeparatorInTime]
    formatter.timeZone = .current
    return formatter
}()

enum ToolError: Error, LocalizedError {
    case calendarAccessDenied
    case remindersAccessDenied
    case unparseableDate(String)
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .calendarAccessDenied:
            "Calendar access is not granted. Enable it in Settings."
        case .remindersAccessDenied:
            "Reminders access is not granted. Enable it in Settings."
        case .unparseableDate(let raw):
            "Could not parse date '\(raw)'. Expected ISO 8601, like 2026-07-25T09:00:00+03:00."
        case .noCalendar:
            "No default calendar is available."
        }
    }
}

enum Access {
    static func ensureEvents() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                sharedEventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw ToolError.calendarAccessDenied }
        default:
            throw ToolError.calendarAccessDenied
        }
    }

    static func ensureReminders() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                sharedEventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else { throw ToolError.remindersAccessDenied }
        default:
            throw ToolError.remindersAccessDenied
        }
    }
}

/// Accepts ISO 8601 with an offset ("2026-07-25T09:00:00+03:00") and,
/// because the model sometimes omits the offset, plain local wall time
/// ("2026-07-25T09:00:00") interpreted in the user's time zone.
func parseISO(_ raw: String) throws -> Date {
    if let date = offsetISO.date(from: raw) ?? localISO.date(from: raw) {
        return date
    }
    throw ToolError.unparseableDate(raw)
}

func formatDay(_ date: Date) -> String {
    date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
}

func formatWindow(_ start: Date, _ end: Date) -> String {
    "\(formatDay(start)) to \(end.formatted(.dateTime.hour().minute()))"
}
