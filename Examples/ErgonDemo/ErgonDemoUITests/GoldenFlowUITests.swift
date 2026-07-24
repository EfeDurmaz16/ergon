import XCTest
import EventKit

/// The golden flow, driven end to end with real taps on the simulator:
/// Turkish intent in, conflict check, approval sheet, REAL event in the
/// calendar, receipt visible. Calendar permission is pre-granted via
/// `simctl privacy` so no system alert interrupts the run.
final class GoldenFlowUITests: XCTestCase {
    /// The demo now checks the REAL calendar, so a leftover event from a
    /// previous run would be a genuine conflict and the flow would correctly
    /// warn instead of staging. Clear tomorrow's window first so the golden
    /// path sees a free slot.
    @MainActor
    override func setUp() async throws {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { return }
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let start = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: tomorrow)!
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: tomorrow)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        for event in store.events(matching: predicate) {
            try? store.remove(event, span: .thisEvent, commit: true)
        }
    }

    @MainActor
    func testTurkishGoldenFlowCreatesRealEvent() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["Ask Ergon"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Ask field did not appear")
        field.tap()
        field.typeText("yarın 9'a diş randevusu koy, çakışma varsa haber ver\n")

        // On-device generation plus the conflict-check tool call.
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 180),
                      "Approval sheet never appeared: model did not stage the event")
        approve.tap()

        // The approval sheet closes and the receipt trail shows the execution.
        let receipts = app.buttons["Receipts"]
        XCTAssertTrue(receipts.waitForExistence(timeout: 15))
        receipts.tap()
        let approvedRow = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'approved'")).firstMatch
        XCTAssertTrue(approvedRow.waitForExistence(timeout: 15),
                      "No approved receipt visible after execution")

        // Ground truth: the event exists in the simulator's real EventKit
        // store. The runner queries a wide window around tomorrow 9:00.
        let store = EKEventStore()
        let granted = expectation(description: "calendar access")
        store.requestFullAccessToEvents { ok, _ in
            XCTAssertTrue(ok, "runner needs calendar access (pre-grant via simctl privacy)")
            granted.fulfill()
        }
        wait(for: [granted], timeout: 15)

        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let start = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)!
        let end = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: tomorrow)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        XCTAssertFalse(events.isEmpty, "No real calendar event found in tomorrow's window")
        let titles = events.map { $0.title ?? "untitled" }.joined(separator: ", ")
        print("GOLDEN FLOW EVENTS FOUND: \(titles)")
    }
}
