import Foundation
import Testing
@testable import Ergon
@testable import ErgonTools

/// Routing is prompt-shaped, so it only holds if something exercises the real
/// classifier over the real toolset menu. This caught two defects a unit test
/// could not see: "remind me to call the bank" following the noun into the
/// contacts domain, and the classifier session accumulating transcript until
/// every route died on a context overflow.
@MainActor
@Suite struct RoutingTests {
    /// Only assert domains that exist on the platform under test: alarms and
    /// device are iOS-only, so on macOS they are not in the menu at all and
    /// their intents have nowhere correct to go.
    private static let cases: [(intent: String, domain: String)] = [
        ("remind me to call the bank tomorrow at 10", "reminders"),
        ("remind me to buy milk", "reminders"),
        ("what are my reminders", "reminders"),
        ("book a dentist appointment tomorrow at 9", "calendar"),
        ("am I free on Friday afternoon", "calendar"),
        ("yarin 9'a dis randevusu koy", "calendar"),
        ("what is Ahmet's phone number", "contacts"),
        ("add a contact named Test", "contacts"),
        ("find coffee shops near me", "maps"),
        ("where am I right now", "maps"),
        ("how long does it take to drive to Ankara", "maps"),
        ("what is the weather here", "weather"),
        ("will it rain tomorrow", "weather"),
        ("set a timer for 10 minutes", "alarms"),
        ("wake me up at 7:30", "alarms"),
        ("cancel my timer", "alarms"),
        ("what is my battery level", "device"),
        ("what is on my clipboard", "device"),
        ("write a note about the trip", "notes"),
        ("read my notes", "notes"),
    ]

    @Test func intentsReachTheDomainThatOwnsThem() async throws {
        guard case .ready = Ergon.availability else { return }
        let toolsets = ErgonToolkit.allToolsets()
        let available = Set(toolsets.map(\.name))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ergon-routing-\(UUID().uuidString)")
        let router = try Router(toolsets: toolsets, receiptsDirectory: directory)

        for (intent, expected) in Self.cases where available.contains(expected) {
            let actual = try await router.route(intent)
            #expect(actual == expected, "\"\(intent)\" routed to \(actual)")
        }
    }

    /// The classifier used to keep one session forever, so its transcript grew
    /// with every request and crossed the 4096-token window after roughly a
    /// dozen intents, killing routing for the rest of the app's life.
    @Test func classifyingManyIntentsDoesNotExhaustTheContextWindow() async throws {
        guard case .ready = Ergon.availability else { return }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ergon-routing-\(UUID().uuidString)")
        let router = try Router(toolsets: ErgonToolkit.allToolsets(), receiptsDirectory: directory)
        for index in 0..<25 {
            _ = try await router.route("what is the weather in city number \(index)")
        }
    }
}
