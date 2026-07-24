# ErgonDemo

A one-screen SwiftUI app that drives the on-device `Ergon` runtime: natural
language in, real approved actions out.

## Golden flow

Type (English) `book a dentist appointment tomorrow at 9, warn me about conflicts`
or (Turkish, needs iOS 26.1+) `yarin 9'a dis randevusu koy, cakisma varsa haber ver`.
Ergon checks the calendar with a read tool. If there is a conflict it replies
with alternatives. If the slot is clear it stages a calendar event, the built-in
approval sheet appears, and approving creates a real event and appends a receipt.

## Build

Requires the model on device (iOS 26, Apple Intelligence on). Generate the
Xcode project with [xcodegen](https://github.com/yonaskolb/XcodeGen):

```sh
cd Examples/ErgonDemo
xcodegen generate
open ErgonDemo.xcodeproj
```

Run on a device or simulator that supports Apple Intelligence. On a device that
does not, the app shows the matching full-screen unavailable state.

## Files

- `ErgonDemoApp.swift` App entry, availability gating, error screens.
- `AppModel.swift` Engine ownership, transcript, run orchestration, resolution logging.
- `AskView.swift` The Ask screen: input, transcript, live reply, error banner.
- `ReceiptsView.swift` Receipt trail and resolution diagnostics.
