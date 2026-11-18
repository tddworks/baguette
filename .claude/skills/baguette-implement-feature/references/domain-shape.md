# Think the domain first

Before any change, a fix too, ask how the domain should be, not only where the
line fits. The aim is a domain that is **easy to understand**: someone new
reads a type's surface and can explain it in the user's words. Borrow from DDD
only what serves that; no pattern is added for its own sake.

The tree, the words, every law and its owner are in
[CANONICAL_MODEL.md](../../../../docs/CANONICAL_MODEL.md); the Swift patterns
in [domain-models.md](domain-models.md).

## Five questions, of every type the change touches

**1. Would the user say it?**
Names come from the CLI, the wire and the page (CANONICAL §0), never the
mechanism. If the facts need a concept the code doesn't have, it is hiding as
an optional or a flag. *iPhone Duo's "lit panel" is a word users meet
(`GET /hinge` answers `litPanel`); `0x40000003` is not — it stays inside
`IndigoHIDTouchTarget`.*

**2. Does the thing decide about itself?**
A rule lives on the thing it is about; callers tell it, they don't read its
state and decide. *#124: four callers wrote `hinge.angle()?.litPanel ??
.primary`; the rule is `Hinge.litPanel`, and callers ask for it.*

**3. Can you see every state?**
Each state a user can meet is a case with its data; one value never means two
things. *`PoseDelivery` is `delivered · rejected · unconfirmed`: a timed-out
fold may have landed, so it is not `rejected` (exit 3, not 1).
`InterfaceReading` answers `unknown` / `unsupported` instead of throwing.*

**4. Is it as small as it can be?**
A value when it is data with rules; a class only when it changes over time; a
`@Mockable` protocol only at the outside world (SimulatorKit, `simctl`, a
process, the guest), named for its role. No type, layer or flag the change
doesn't need — but never drop a rule the hardware keeps. *#124: `DeviceKeys`
had two `press` methods for one act; it has one, with modifiers. Dropping
"a touch stays on the digitizer it went down on" to make `LitPanelInput` a
struct was too small: an `up` on the other panel leaves a contact nobody
releases.*

**5. Is what differs between devices data?**
A profile, a chrome, a 3D model, a registration — never `if deviceTypeName ==
"iPhone Duo"` or a subclass per device. *A foldable is a device whose
`Chromes` lists two panels; the Duo's keys are a table of HID usages in
`FoldableInput.key(for:)`, not a branch per model.*

## Check by context

The five questions look at one type. To find what is wrong across the domain,
check each **context** (CANONICAL §5) as a whole. Each row names a smell you can
grep for; each example is one CANONICAL §6 lists.

| # | Ask | The smell | Example |
|---|---|---|---|
| 1 | **Does anything cross the fence?** Only a reference (an id, a kernel value) may | another context's aggregate or adapter inside this one | the App builds `SimctlInputSurface()` itself instead of asking the `Simulator` |
| 2 | **Does every word mean one thing here?** | one name for two facts | "folded" for the device's hinge and for an offline render's default pose (`?? 180`) |
| 3 | **Does every law have one owner?** | the same rule twice, drifting; a caller reading state to decide | "is this a foldable" answered three ways; the phone target picked in two places |
| 4 | **Is the business above, and the technique below?** | private API, argv or JSON assembled by the caller; a domain decision in `Server` | `Server` building `LitPanelInput` from two panels and a hinge (#124 moved it to `Simulator.litPanelInput()`); Domain's `StreamFormat` constructing Infrastructure streams |
| 5 | **Does a new case add data, not an edit?** (SRP, OCP) | a `switch` on a device name; one type changing for several reasons | `GuestHingeMotor` changes for poses *and* keyboard keys |
| 6 | **Does the question have a home?** | a context's rule only in a doc or in `Server` | "IndigoHID runs on the MainActor" was enforced by one hop in `Server.streamWS` and owned by no type (now `IndigoHIDInput`'s, for the build alone) |

A finding is a row in CANONICAL §6 when a law already says what is right, or a
line in §7 (Open) when the design must decide first.

## An example: input after a fold ([#124](https://github.com/tddworks/baguette/pull/124))

The bug: on iPhone Duo's 3D page, taps and typing stopped landing after a
fold. A fix at the socket — rebuild the input on every hinge message — would
have worked. Asking the questions of the types it touches finds the shape:

| Question | What it finds |
|---|---|
| 1. Would the user say it? | *the lit panel* — yes, a word already on the wire |
| 2. Does the thing decide about itself? | no: callers computed the lit panel from the angle; `Hinge.litPanel` owns it |
| 3. Every state? | a touch has a state — *down on a panel* — that a per-gesture lookup forgot |
| 4. As small as it can be? | one Domain decorator, `LitPanelInput`, a class only because a touch changes over time |
| 5. Data? | yes: two pinned panels from `Displays.panel(_:)`, no Duo branch |

```text
 NOW                                         PROPOSED
 Server.streamWS                             Server.streamWS
  └─ input = sim.input()   (bound once)       └─ input = sim.litPanelInput()
                                             Simulator.litPanelInput()
                                              └─ LitPanelInput(cover:, unfolded:, hinge:)
                                                  ├─ each gesture → hinge.litPanel
                                                  └─ a touch keeps its panel until up
```

## Keep it in scope

- Fix what these questions find **in the types the change touches**, test
  first. Leave the rest as a row in CANONICAL §6 for its own change.
- A new aggregate, a moved law or a changed owner is a design change: write it
  into CANONICAL_MODEL.md first, and get it approved in Phase 0 before code.
  The feature's `design.md` changes only when the change brings research with
  it (a private API, a measured constant) that the code can't explain.
