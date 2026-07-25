# ADR 0001: Remote tool layer, model tiers, and a portable core

Status: accepted
Date: 2026-07-25

## Goal

Let Ergon serve requests that span several third-party services and depend on
each other's results, on mobile first and on other platforms later, without
turning the product into a compliance artifact nobody wants to use.

## System model today

One `Ergon` engine owns a `LanguageModelSession`, a set of gated tools, and a
hash-chained receipt log. A `Router` classifies each intent to one of eight
domains because the on-device model has a 4096-token context and degrades when
shown more than a handful of tools at once. All 26 tools are hand-written Swift
structs whose `Arguments` are `@Generable`, so the catalog is code, not data.
Consequential calls stage an `Approval` carrying the resolved arguments and
execute only after the user accepts.

Measured: core `Ergon` is ~910 lines, native tools ~1394 lines, UI ~209 lines.
The whole tool surface costs the model ~1159 tokens. The core's only real
Apple lock-ins are FoundationModels and one SwiftUI file.

## Decisions

1. **Receipts and policy are not product surface.** The receipt log stays as an
   internal logging and debugging facility. It is removed from the app's main
   surface. Tamper-evidence matters when a counterparty must be convinced;
   Ergon has no counterparty, so it is plumbing, not a feature. Both Claude
   Code auto mode and Codex converged on one switch plus an automated reviewer
   rather than user-authored policy, which confirms policy is not a surface
   users want.

2. **Gate on reversibility, not on consequence.** Auto modes work because their
   blast radius is undoable. Ergon's is not. The response is to manufacture
   reversibility rather than to ask more often: reversible actions run without
   a prompt and offer an undo, irreversible ones still ask. `isReversible`
   becomes behavioural instead of decorative.

3. **Third-party services are reached over their HTTP APIs.** iOS exposes no
   way for one app to enumerate or invoke another app's App Intents; App
   Intents is a contract between an app and the system. HTTP is therefore the
   only route, and it is identical on every platform.

4. **The catalog is split.** Native OS tools stay hand-written per platform,
   because EventKit has no Android equivalent and nothing is gained by making
   them data. Remote services become data-driven descriptors executed by one
   generic HTTP executor, because they are identical on every platform and
   adding a service must not require an app release.

5. **Two model tiers.** The on-device model serves local, single-step, private
   intents. A capable model serves multi-step orchestration. This is not a
   consequence of choosing code mode: no calling convention lets a 3B model
   with a 4096-token window carry a data-dependent chain across three services.

6. **Two calling conventions over one catalog.** Guided tool calls for the
   on-device tier, where schema-constrained decoding is the only thing making a
   small model reliable. Code mode for the capable tier, where composition and
   branching are the point.

7. **The script runtime is a platform adapter, not core.** App Store guideline
   2.5.2 permits downloaded interpreted code only through WebKit or
   JavaScriptCore. A program authored by a cloud model arrives over the network
   and is downloaded code, so on Apple platforms it must run in `JSContext`.
   Other platforms use their own engine. The core requests execution and does
   not know which engine ran it.

8. **The core stays Swift for now and becomes descriptor-driven.** Extracting
   FoundationModels behind a protocol and making the catalog data are
   prerequisites for every other option, so they are done first, in place,
   while the existing demo keeps working.

## Alternatives considered

**Lua or WebAssembly for the script runtime.** Rejected twice over. Models have
seen far less Lua than JavaScript, and code mode's entire premise is training
data volume, so Lua optimises the runtime while sabotaging the model. More
decisively, 2.5.2 names only WebKit and JavaScriptCore as exceptions for
downloaded scripts; a bundled Lua VM running cloud-authored code is outside the
carve-out. Lua would make sense for a rule DSL authored by us, not by a model.

**Rust core behind UniFFI now.** Attractive and probably where this ends up:
once the catalog is data, the core is descriptor parsing, routing, gating, HTTP
and hashing, which is textbook Rust, and UniFFI is production-proven in Firefox.
Rejected as sequencing, not as direction. Rewriting 910 lines today means
weeks of no user-visible progress on a product that has none to spare, and it
would change the design and the language at the same time. Trigger to revisit:
the day a second platform is actually committed. By then the core is already
free of Apple types and the port is mechanical.

**Re-implementing the core per platform in each native language.** Rejected.
Native tools are unavoidably per-platform, but the router, approval state
machine, idempotency and catalog logic are not, and native and remote tools
must be usable inside one request, which forces a single catalog and a single
planner. Three planners that must behave identically is where correctness rots.

**Keeping every tool hand-written in Swift.** Rejected for the remote half
only. It does not survive the second service or the second platform.

## Public interface changes

- `Tool` stops being `FoundationModels.Tool` with `Generable` arguments and
  becomes a name, a description, a schema, and an execution kind.
- Execution kind is `.native` (dispatched to a platform adapter) or `.http`
  (executed by the core from a descriptor).
- The model backend becomes a protocol; FoundationModels is one implementation.
- `Router` gains a tier decision alongside its domain decision.

## Invariants to preserve

- An irreversible action never runs without the user seeing its resolved
  arguments first. What is approved is exactly what executes.
- An idempotency key that already succeeded never executes twice, and a key
  whose execution was interrupted fails closed.
- Model-authored code never observes a credential. Tokens live behind the
  executor; the sandbox has no general network access.
- The existing iOS demo keeps working through every step of the refactor.

## Failure modes to design for

- The generic HTTP executor gives worse argument guidance and worse error
  messages than a hand-written tool. Tool quality drives model success, as this
  session repeatedly showed. Mitigation: wrap the two or three most used
  services by hand if measurement shows degradation.
- A program's branch depends on real data, so a dry-run preview shows the
  intended path, not a guarantee. Mitigation: preview the plan, and still stage
  any step that diverges from it.
- The capable model is remote, so orchestration fails without network and leaks
  intent metadata to a provider. The tier boundary must be visible to the user.

## Test plan

- Routing suite over the real classifier stays, extended with tier decisions.
- One descriptor-driven remote service exercised end to end against a real API.
- Idempotency and fail-closed tests continue to pass unchanged; they are the
  contract that must not regress.
- Every slice is demonstrated with at least one concrete request at the time it
  is built. Infrastructure with no demonstrable request is not merged.

## Open questions

- Where the capable model comes from: our own API in front of a provider, or
  the provider directly.
- Undo mechanics per action type, and which actions can be made reversible that
  are not today.
- Whether descriptors are OpenAPI subsets or MCP tool descriptors.
