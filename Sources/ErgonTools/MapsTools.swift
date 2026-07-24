import Ergon
import FoundationModels
import MapKit
import CoreLocation

// Cross-platform: MapKit/CoreLocation compile on macOS too, so this file is
// not wrapped in #if os(iOS). MKLocalSearch, MKDirections, and the geocoding
// requests all need network access and can fail offline; every tool here
// returns a described string on failure instead of throwing, per ReadTool
// contract (a throw aborts the whole generation).

/// One-line "name - address" summary for a map item. iOS 26 deprecates
/// CLGeocoder's synchronous placemark fields in favor of MKMapItem.address,
/// but that API differs across MapKit versions, so this falls back to the
/// always-available placemark.title when address is unavailable.
private func describe(_ item: MKMapItem) -> String {
    let name = item.name ?? "Unknown place"
    let address = item.placemark.title ?? "no address"
    return "\(name) - \(address)"
}

private func transportType(for mode: String) -> MKDirectionsTransportType {
    switch mode {
    case "walking": return .walking
    case "transit": return .transit
    default: return .automobile
    }
}

/// Searches nearby places by name or category. Read-only.
public struct SearchPlacesTool: ReadTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Natural language search query, like 'coffee shops' or 'Eiffel Tower'")
        public var query: String
        @Guide(description: "Optional latitude to bias the search near")
        public var nearLatitude: Double?
        @Guide(description: "Optional longitude to bias the search near")
        public var nearLongitude: Double?
    }

    public let name = "searchPlaces"
    public let description = "Search for places matching a query, optionally biased near a coordinate."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = arguments.query
        if let lat = arguments.nearLatitude, let lon = arguments.nearLongitude {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                latitudinalMeters: 10_000, longitudinalMeters: 10_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !response.mapItems.isEmpty else {
                return "No places found for '\(arguments.query)'."
            }
            let lines = response.mapItems.prefix(5).map(describe)
            return "Places matching '\(arguments.query)':\n" + lines.joined(separator: "\n")
        } catch {
            return "Could not search places: \(error.localizedDescription)"
        }
    }
}

/// Turns an address into a coordinate. Read-only.
public struct GeocodeAddressTool: ReadTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Address or place name to geocode, like '1 Infinite Loop, Cupertino'")
        public var address: String
    }

    public let name = "geocodeAddress"
    public let description = "Look up the coordinate and formatted address for a given address or place name."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        guard let request = MKGeocodingRequest(addressString: arguments.address) else {
            return "Could not build a geocoding request for '\(arguments.address)'."
        }
        do {
            guard let item = try await request.mapItems.first else {
                return "No location found for '\(arguments.address)'."
            }
            let coordinate = item.placemark.coordinate
            return "\(describe(item)) at \(coordinate.latitude), \(coordinate.longitude)"
        } catch {
            return "Could not geocode '\(arguments.address)': \(error.localizedDescription)"
        }
    }
}

/// Turns a coordinate into an address. Read-only.
public struct ReverseGeocodeTool: ReadTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Latitude of the point to reverse geocode")
        public var latitude: Double
        @Guide(description: "Longitude of the point to reverse geocode")
        public var longitude: Double
    }

    public let name = "reverseGeocode"
    public let description = "Look up the address at a given latitude and longitude."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let location = CLLocation(latitude: arguments.latitude, longitude: arguments.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return "Could not build a reverse geocoding request for that coordinate."
        }
        do {
            guard let item = try await request.mapItems.first else {
                return "No address found for \(arguments.latitude), \(arguments.longitude)."
            }
            return describe(item)
        } catch {
            return "Could not reverse geocode that coordinate: \(error.localizedDescription)"
        }
    }
}

/// Estimates travel time and distance between two points. Read-only.
public struct TravelETATool: ReadTool {
    @Generable
    public struct Arguments {
        @Guide(description: "Starting latitude")
        public var fromLatitude: Double
        @Guide(description: "Starting longitude")
        public var fromLongitude: Double
        @Guide(description: "Destination latitude")
        public var toLatitude: Double
        @Guide(description: "Destination longitude")
        public var toLongitude: Double
        @Guide(description: "Travel mode", .anyOf(["driving", "walking", "transit"]))
        public var mode: String
    }

    public let name = "travelETA"
    public let description = "Estimate travel time and distance between two coordinates for a given travel mode."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        let source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: arguments.fromLatitude, longitude: arguments.fromLongitude)))
        let destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: arguments.toLatitude, longitude: arguments.toLongitude)))

        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = transportType(for: arguments.mode)

        do {
            let eta = try await MKDirections(request: request).calculateETA()
            let minutes = Int((eta.expectedTravelTime / 60).rounded())
            let km = eta.distance / 1000
            return "About \(minutes) min, \(String(format: "%.1f", km)) km by \(arguments.mode)."
        } catch {
            return "Could not estimate travel time: \(error.localizedDescription)"
        }
    }
}
