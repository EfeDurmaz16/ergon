import Foundation
import Ergon

public enum ErgonToolkit {
    /// System instructions for the calendar golden flow. Pass as the
    /// `instructions` parameter of `Ergon.init` (or a Toolset).
    public static let calendarInstructions = """
    You help the user manage their calendar and reminders.
    Always reply in the language of the user's request.
    Before creating a calendar event, always call queryCalendar for the requested time window.
    If existing events overlap the requested time, do not create the event: tell the user about the conflict and suggest two nearby free times instead.
    If the window is free, create the event with createCalendarEvent.
    Name events in the language of the user's request.
    Calling createCalendarEvent does NOT create the event: it only asks the user for permission. After calling it, tell the user the event is waiting for their approval. Never say it was created or scheduled.
    Pass times to tools as ISO 8601 with the user's timezone offset, like 2026-07-25T09:00:00+03:00.
    Keep replies to one or two short sentences.
    """

    /// A shared line every action toolset needs: consequential tools stage an
    /// approval, they do not execute, so the model must not claim success.
    static let stagingRule = """
    Reply in the language of the request. A tool that changes something does not run when you call it: it asks the user to approve first. After calling such a tool, say the action is waiting for approval. Never claim it was done. Keep replies to one or two short sentences. Pass times as ISO 8601 with offset like 2026-07-25T09:00:00+03:00.
    """

    /// Calendar domain: query, create, update, delete.
    public static func calendar() -> Toolset {
        Toolset(name: "calendar",
                description: "calendar events: check, create, reschedule, or delete appointments and meetings",
                tools: [CalendarQueryTool(), CalendarCreateTool(),
                        UpdateCalendarEventTool(), DeleteCalendarEventTool()],
                instructions: calendarInstructions)
    }

    /// Reminders domain: list, create, complete, delete.
    public static func reminders() -> Toolset {
        Toolset(name: "reminders",
                description: "reminders and to-dos: list, add, complete, or delete tasks",
                tools: [ListRemindersTool(), ReminderCreateTool(),
                        CompleteReminderTool(), DeleteReminderTool()],
                instructions: stagingRule)
    }

    /// Maps domain: search places, geocode, travel time. All read-only.
    public static func maps() -> Toolset {
        Toolset(name: "maps",
                description: "places and travel: find nearby spots, look up an address, or get travel time",
                tools: [CurrentLocationTool(), SearchPlacesTool(),
                        GeocodeAddressTool(), ReverseGeocodeTool(), TravelETATool()],
                instructions: """
                Reply in the language of the request. Use the tools to answer, keep replies short.
                For anything about here, nearby, or where the user is, call currentLocation first and answer with the city and street it returns, never with invented coordinates.
                searchPlaces already searches near the user when you omit the coordinates, so do not guess a coordinate.
                Report the place names and distances the tools return, unchanged.
                """)
    }

    /// Weather domain (Open-Meteo, keyless). Read-only.
    public static func weather() -> Toolset {
        Toolset(name: "weather",
                description: "weather: current conditions and forecast for a place",
                tools: [WeatherTool()],
                instructions: "Reply in the language of the request. For the weather here or nearby, call getWeather with no coordinates: it uses the user's own location. Keep replies short.")
    }

    /// Contacts domain: find, create.
    public static func contacts() -> Toolset {
        Toolset(name: "contacts",
                description: "contacts: look up someone's number or email, or add a new contact",
                tools: [FindContactTool(), CreateContactTool()],
                instructions: stagingRule)
    }

    /// Notes/files domain: list, read, write, delete.
    public static func notes() -> Toolset {
        Toolset(name: "notes",
                description: "notes: list, read, write, or delete short text notes",
                tools: [ListNotesTool(), ReadNoteTool(), WriteNoteTool(), DeleteNoteTool()],
                instructions: stagingRule)
    }

    /// Every toolset available on this platform, ready for a `Router`.
    /// iOS-only domains (alarms, device) are included only where they compile.
    public static func allToolsets() -> [Toolset] {
        var sets = [calendar(), reminders(), maps(), weather(), contacts(), notes()]
        #if canImport(AlarmKit)
        sets.append(alarms())
        #endif
        #if canImport(UIKit)
        sets.append(device())
        #endif
        return sets
    }

    #if canImport(AlarmKit)
    /// Alarms and timers domain (iOS only).
    public static func alarms() -> Toolset {
        Toolset(name: "alarms",
                description: "alarms and timers: set an alarm, start a countdown, or cancel one",
                tools: [CreateAlarmTool(), CreateTimerTool(), ListAlarmsTool(), CancelAlarmTool()],
                instructions: stagingRule)
    }
    #endif

    #if canImport(UIKit)
    /// Device and clipboard domain (iOS only).
    public static func device() -> Toolset {
        Toolset(name: "device",
                description: "device: battery status, low power mode, and the clipboard",
                tools: [BatteryStatusTool(), ReadClipboardTool(), CopyToClipboardTool()],
                instructions: stagingRule)
    }
    #endif
}
