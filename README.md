# Ergon

An experimental command line for your phone. Ask for something in plain language; Ergon turns it into defined actions across supported tools and services.

**Early alpha.** This is a Swift library and demo app, not an App Store release or a production-ready assistant. APIs and behavior can change. It does not control arbitrary apps or bypass the iOS sandbox.

## What it explores

- Typed commands for calendars, reminders, contacts, maps, weather, and notes stored inside Ergon.
- Small tool groups selected by a router, instead of giving one model every tool at once.
- Approval prompts for consequential actions and undo support for tools declared reversible.
- Local execution receipts and duplicate-execution checks.
- Native SwiftUI answers and action previews.
- JSON service descriptors, with GitHub as a reference integration.

The default model runs on device through Apple's FoundationModels. An optional Anthropic backend uses your own API key. When connected, the router can send requests spanning tool groups to that remote model. Remote models and network tools send data outside the device; this is not an offline-only system.

## Packages

| Product | Purpose |
| --- | --- |
| `Ergon` | Tool execution, routing, approvals, receipts, and model backends |
| `ErgonTools` | Reference device tools and service descriptors |
| `ErgonUI` | Generated SwiftUI answer screens |

## Requirements

- Package targets: iOS 26.1+ or macOS 26.0+.
- Xcode 26 with a compatible Swift toolchain; the package manifest requires Swift tools 6.1.
- Apple Intelligence-capable hardware with the model available for on-device flows.
- Relevant system permissions for each tool. Alarms and device tools depend on platform availability.

Check `Ergon.availability` before offering on-device features. Language and model availability also depend on the device and OS. A connected remote backend does not establish support on otherwise unsupported devices.

## Try the library

```swift
import Ergon
import ErgonTools

let router = try Router(toolsets: ErgonToolkit.allToolsets())

for try await event in router.run("am I free tomorrow morning?") {
    if case .partial(let text) = event {
        print(text)
    }
}
```

For write actions, integrate the approval and undo UI before using real data. The demo shows the complete interaction flow.

## Demo app

```sh
cd Examples/ErgonDemo
xcodegen generate
open ErgonDemo.xcodeproj
```

The demo uses XcodeGen. Choose your own signing team in Xcode and run on a supported device. Tool permissions are requested as needed. See [the demo guide](Examples/ErgonDemo/README.md).

## Development

```sh
swift build
swift test
```

Tests cover approval gating, reversible actions, receipts, routing, descriptors, and model backends. Passing unit tests does not verify live provider responses, device permissions, or the complete iOS demo flow.

## Execution boundaries

Read tools run without an action approval. Consequential tools are staged for approval; tools declared reversible can run immediately with undo support. The tool author's classification is part of the trust boundary, so an approval prompt is not guaranteed for every write.

Receipts use a local hash chain and a sidecar head anchor. They can detect some edits and truncation, but cannot prevent a writer from replacing both the log and anchor. These controls are experimental, not a security certification. Review tool implementations before granting access to real accounts or data.

Notes are files in Ergon's own sandbox, not Apple Notes integration. Supported app actions depend on public APIs and permissions.

## License

[MIT](LICENSE)
