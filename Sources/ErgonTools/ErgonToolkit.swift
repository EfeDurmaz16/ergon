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
                description: "appointments and meetings that occupy a time slot. Examples: book a dentist appointment tomorrow at 9, am I free Friday afternoon, move my meeting to 3, cancel my appointment, yarin 9'a randevu koy",
                tools: [CalendarQueryTool(), CalendarCreateTool(),
                        UpdateCalendarEventTool(), DeleteCalendarEventTool()],
                instructions: calendarInstructions)
    }

    /// Reminders domain: list, create, complete, delete.
    public static func reminders() -> Toolset {
        Toolset(name: "reminders",
                description: "a task the user wants to be reminded to do later. Examples: remind me to call the bank, remind me to buy milk, add it to my list, what are my reminders, mark buy milk done, bana hatirlat",
                tools: [ListRemindersTool(), ReminderCreateTool(),
                        CompleteReminderTool(), DeleteReminderTool()],
                instructions: stagingRule)
    }

    /// Maps domain: search places, geocode, travel time. All read-only.
    public static func maps() -> Toolset {
        Toolset(name: "maps",
                description: "places, addresses, and travel. Examples: coffee shops near me, where am I, what is the address of X, how long to drive to Ankara, yakinimda eczane",
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
                description: "weather and forecast. Examples: what is the weather, is it going to rain tomorrow, how cold is it in Ankara, hava nasil",
                tools: [WeatherTool()],
                instructions: "Reply in the language of the request. For the weather here or nearby, call getWeather with no coordinates: it uses the user's own location. Keep replies short.")
    }

    /// Contacts domain: find, create.
    public static func contacts() -> Toolset {
        Toolset(name: "contacts",
                description: "the address book itself: reading a saved person's phone number or email, or saving a new person. Examples: what is Ahmet's number, do I have an email for Ayse, add a contact named X. Not for reminding the user to contact someone.",
                tools: [FindContactTool(), CreateContactTool()],
                instructions: stagingRule)
    }

    /// Notes domain: list, read, write, delete. These notes live in Ergon's
    /// own sandbox. iOS exposes no public API for the Apple Notes app, so a
    /// note written here will never appear there, and both the model and the
    /// user have to be told that plainly.
    public static func notes() -> Toolset {
        Toolset(name: "notes",
                description: "short text notes kept inside Ergon. Examples: write a note about X, what do my notes say, read my shopping note, delete that note, not al",
                tools: [ListNotesTool(), ReadNoteTool(), WriteNoteTool(), DeleteNoteTool()],
                instructions: stagingRule + """

                These notes are stored inside Ergon only. You cannot read from or write to the Apple Notes app. If the user expects a note to show up in Apple Notes, tell them it stays in Ergon.
                """)
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
                description: "alarms that ring and countdown timers. Examples: set a timer for 10 minutes, wake me at 7:30, what timers are running, cancel my timer, 10 dakika sayac kur",
                tools: [CreateAlarmTool(), CreateTimerTool(), ListAlarmsTool(), CancelAlarmTool()],
                instructions: stagingRule)
    }
    #endif

    #if canImport(UIKit)
    /// Device and clipboard domain (iOS only).
    public static func device() -> Toolset {
        Toolset(name: "device",
                description: "the phone hardware itself: battery charge, Low Power Mode, and the clipboard. Examples: what is my battery level, am I in low power mode, what is on my clipboard, copy this text",
                tools: [BatteryStatusTool(), ReadClipboardTool(), CopyToClipboardTool()],
                instructions: stagingRule + """

                You can only report the battery percentage, charging state, and Low Power Mode. iOS exposes no battery health, cycle count, or temperature to apps: if the user asks for those, say you cannot read them. Never report a percentage as if it were battery health.
                """)
    }
    #endif
}
