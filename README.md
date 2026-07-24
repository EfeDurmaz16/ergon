# Ergon

Give your app hands. Ergon turns natural language into real, typed actions on device, built on Apple's FoundationModels. You define tools, the user states an intent, Ergon resolves it into typed calls and executes them. Approval gating, tamper-evident receipts, and idempotent execution are the built-in defaults.

Runs entirely on device. No backend, no analytics, no cloud fallback.

## Quickstart

```swift
import SwiftUI
import Ergon
import ErgonTools

struct AskView: View {
    @State private var engine = try! Ergon(
        tools: [CalendarQueryTool(), CalendarCreateTool(), ReminderCreateTool()],
        instructions: ErgonToolkit.calendarInstructions)
    @State private var input = ""
    @State private var reply = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(reply)
            TextField("Ask", text: $input)
                .onSubmit { Task { try? await ask(input) } }
        }
        .approvalSheet(engine)
    }

    func ask(_ intent: String) async throws {
        for try await event in engine.run(intent) {
            if case .partial(let text) = event { reply = text }
        }
    }
}
```

Type "yarın 9'a diş randevusu koy, çakışma varsa haber ver" or "book a dentist appointment tomorrow at 9". The model checks the window with the read tool. On conflict it answers with alternatives. When the window is free it stages the event, the approval sheet renders the exact typed call, and approving creates the real event in Calendar.

## Your own tools

```swift
struct SendInvoice: ConsequentialTool {
    let name = "sendInvoice"
    let description = "Send an invoice to a client."
    let isReversible = false

    @Generable
    struct Arguments {
        @Guide(description: "Client email address")
        var to: String
        @Guide(description: "Amount in EUR cents")
        var amountCents: Int
    }

    func preview(_ arguments: Arguments) -> ActionPreview {
        ActionPreview(title: "Send invoice",
                      detail: "\(arguments.amountCents / 100) EUR to \(arguments.to)")
    }

    func call(arguments: Arguments) async throws -> String {
        // your side effect; throwing means nothing was sent
        "Invoice queued."
    }
}
```

## Three nouns

- **Tool**: what your app can do. `ReadTool` runs freely during generation. `ConsequentialTool` can never execute without an approval; a tool that declares neither is gated anyway. Both refine the native `FoundationModels.Tool`, so your tools also work in a bare `LanguageModelSession`. Note the flip side: a bare session has no gates, so only hand it tools you would run unsupervised.
- **Approval**: a staged consequential call. The sheet (or your own UI over `engine.pendingApprovals`) shows what will happen, to what, and whether it is reversible. `approve(_:)` executes exactly once; `deny(_:)` and swiping the sheet away execute nothing.
- **Receipt**: every execution, denial, refusal, and read lands in an append-only JSONL log with a SHA-256 hash chain and a sidecar head anchor; approved executions write a pending marker line first, then the outcome line. `Ergon.verifyReceipts(at:)` re-checks chain and anchor: it catches edits, deletions, and trailing truncation, though a writer who rewrites file and anchor together with recomputed hashes is out of scope for v0.1. Confirmed intents carry idempotency keys (exact intent + tool + canonical arguments): re-running one never double-executes, and an execution interrupted mid-flight fails closed instead of running again.

That is the whole API surface. No orchestration DSL, no configuration object.

## Availability

FoundationModels needs Apple Intelligence hardware and iOS 26. Check before you promise:

```swift
switch Ergon.availability {
case .ready: break
case .unavailable(let reason): showUnsupported(reason)
}
Ergon.supports(Locale(identifier: "tr"))  // Turkish needs iOS 26.1 or later
```

Unsupported languages, guardrail refusals, and context overflow surface as typed `ErgonError` cases, not crashes.

## How it fits

Start with bare `FoundationModels` if you only need generation; Ergon is for when tools touch the real world. Next to the ecosystem: [SwiftAgent](https://github.com/SwiftedMind/SwiftAgent) is a multi-provider agent loop, [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) swaps model backends under the same API, [FoundationModelsKit](https://github.com/rryam/FoundationModelsKit) is a utility kit. Ergon is the safety and audit layer: because its tools are native `FoundationModels.Tool`s, it composes with rather than competes against all three.

## Demo app

```
cd Examples/ErgonDemo
xcodegen generate
open ErgonDemo.xcodeproj
```

Requires Xcode 26 and an Apple Intelligence capable device or simulator. The demo needs calendar and reminders access; both usage strings are set in the generated project.

## Requirements

- iOS 26.0+ or macOS 26.0+ (Turkish intents need 26.1+)
- Swift 6, Xcode 26
- A device with Apple Intelligence enabled

## License

MIT
