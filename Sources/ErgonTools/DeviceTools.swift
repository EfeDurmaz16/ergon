#if canImport(UIKit)
import Ergon
import FoundationModels
import UIKit

/// Reads battery percentage, charging state, and low-power mode. Read-only.
public struct BatteryStatusTool: ReadTool {
    @Generable
    public struct Arguments {}

    public let name = "batteryStatus"
    public let description = "Get the device's battery percentage, charging state, and whether Low Power Mode is on."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard level >= 0 else {
                return "Battery level is unavailable on this device. Low Power Mode is \(lowPower ? "on" : "off")."
            }
            let percentage = Int((level * 100).rounded())
            let state: String
            switch UIDevice.current.batteryState {
            case .charging: state = "charging"
            case .full: state = "full, plugged in"
            case .unplugged: state = "not charging"
            case .unknown: state = "unknown charging state"
            @unknown default: state = "unknown charging state"
            }
            return "Battery at \(percentage)%, \(state). Low Power Mode is \(lowPower ? "on" : "off")."
        }
    }
}

/// Reads the current clipboard text. Read-only; triggers the system paste banner.
public struct ReadClipboardTool: ReadTool {
    @Generable
    public struct Arguments {}

    public let name = "readClipboard"
    public let description = "Read the current text on the clipboard."

    public init() {}

    public func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            UIPasteboard.general.string ?? "clipboard empty"
        }
    }
}

/// Overwrites the clipboard with the given text. Consequential, reversible
/// (the old clipboard content can simply be copied back).
public struct CopyToClipboardTool: ConsequentialTool {
    @Generable
    public struct Arguments {
        @Guide(description: "The text to copy to the clipboard")
        var text: String
    }

    public let name = "copyToClipboard"
    public let description = "Copy the given text to the clipboard, replacing whatever is there."
    public let isReversible = true

    public init() {}

    public func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Copy to clipboard", detail: arguments.text)
    }

    public func call(arguments: Arguments) async throws -> String {
        let text = arguments.text  // capture the String, not the non-Sendable Arguments
        await MainActor.run {
            UIPasteboard.general.string = text
        }
        return "Copied text to clipboard."
    }
}
#endif
