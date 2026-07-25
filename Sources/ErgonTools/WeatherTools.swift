import Ergon
import FoundationModels
import Foundation

/// Weather data via Open-Meteo (https://open-meteo.com), keyless, CC-BY licensed.
/// No API key, no entitlement, pure Foundation + URLSession, cross-platform.

/// Maps a WMO weather code to a short human phrase.
func weatherPhrase(forCode code: Int) -> String {
    switch code {
    case 0: return "clear sky"
    case 1...3: return "partly cloudy"
    case 45, 48: return "fog"
    case 51...67: return "rain"
    case 71...77: return "snow"
    case 80...82: return "showers"
    case 95...99: return "thunderstorm"
    default: return "unknown conditions"
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        var temperature_2m: Double
        var relative_humidity_2m: Double
        var apparent_temperature: Double
        var weather_code: Int
        var wind_speed_10m: Double
    }
    struct Daily: Decodable {
        var time: [String]
        var weather_code: [Int]
        var temperature_2m_max: [Double]
        var temperature_2m_min: [Double]
        // Open-Meteo sends null entries here for days it has no probability
        // for. A non-optional [Double] fails the whole decode, which used to
        // turn a working forecast into "Could not fetch weather".
        var precipitation_probability_max: [Double?]
    }
    var current: Current
    var daily: Daily
}

/// Weather as a data-defined tool. It is a remote HTTP service with no
/// platform API behind it, which is exactly the class the descriptor path
/// exists for, so it is defined as a value rather than as a Swift type.
public func weatherTool() -> DynamicTool {
    DynamicTool(
        name: "getWeather",
        description: "Get current weather conditions and a 3-day forecast. Omit the coordinates to use where the user is now.",
        arguments: [
            SchemaProperty(name: "latitude",
                           description: "Latitude of the location, e.g. 41.0082. Omit for the user's current location.",
                           schema: .number(minimum: -90, maximum: 90),
                           isOptional: true),
            SchemaProperty(name: "longitude",
                           description: "Longitude of the location, e.g. 28.9784. Omit for the user's current location.",
                           schema: .number(minimum: -180, maximum: 180),
                           isOptional: true),
        ],
        effect: .read,
        run: { arguments in
            await forecast(latitude: arguments.number("latitude"),
                           longitude: arguments.number("longitude"))
        })
}

/// Returns a described failure instead of throwing: a thrown read-tool error
/// aborts the whole generation, while a sentence lets the model explain it.
func forecast(latitude: Double?, longitude: Double?) async -> String {
    let point: (lat: Double, lon: Double)
    if let latitude, let longitude {
        point = (latitude, longitude)
    } else {
        // No coordinate means "here": ask the device rather than making the
        // model invent one or the user paste one.
        switch await CurrentLocation.fix() {
        case .unavailable(let message): return message
        case .at(let location):
            point = (location.coordinate.latitude, location.coordinate.longitude)
        }
    }
    guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(point.lat)&longitude=\(point.lon)&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=3") else {
        return "Could not build weather request URL."
    }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let c = decoded.current
        var out = "Now: \(weatherPhrase(forCode: c.weather_code)), \(Int(c.temperature_2m.rounded()))°C" +
            " (feels \(Int(c.apparent_temperature.rounded()))°C), humidity \(Int(c.relative_humidity_2m))%," +
            " wind \(Int(c.wind_speed_10m.rounded())) km/h."
        let d = decoded.daily
        let days = min(3, d.time.count, d.weather_code.count, d.temperature_2m_max.count, d.temperature_2m_min.count)
        for i in 0..<days {
            out += " \(d.time[i]): \(weatherPhrase(forCode: d.weather_code[i]))," +
                " \(Int(d.temperature_2m_min[i].rounded()))-\(Int(d.temperature_2m_max[i].rounded()))°C"
            if i < d.precipitation_probability_max.count,
               let precipitation = d.precipitation_probability_max[i] {
                out += ", \(Int(precipitation))% precip"
            }
            out += "."
        }
        return out
    } catch {
        return "Could not fetch weather: \(error.localizedDescription)"
    }
}
