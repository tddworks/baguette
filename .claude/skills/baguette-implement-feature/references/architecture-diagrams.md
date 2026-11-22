# Architecture Diagram Patterns

ASCII diagrams for documenting feature architecture before implementation.

## Table of Contents

- [The tree, outside in](#the-tree-outside-in)
- [Data Flow Diagrams](#data-flow-diagrams)
- [Sequence Diagrams](#sequence-diagrams)
- [Component Interaction Tables](#component-interaction-tables)

---

## The tree, outside in

### Where a feature lands

```
┌──────────────────────────────────────────────────────────────────────┐
│ FEATURE: [Feature Name]                                               │
├──────────────────────────────────────────────────────────────────────┤
│  THE WAYS IN        Commands/<Verb>Command.swift   Server/Server<X>Routes │
│                     (parse, require, call)          (both trees, refusals) │
│                            │                              │            │
│                            └────────── devices.require(.x, of: id) ──┐ │
│                                                                     ▼ │
│  THE FAMILY         Devices/<Family>/  registers `.x` in its Abilities │
│                     Internal/<x>/<Adapter>     decides (tested, Mock)  │
│                     Internal/System/<Concrete> the bare call (≤100)    │
│                                                                     ▲ │
│  THE ABILITY        Device/Abilities/<x>/  the role, its values, its  │
│  (BaguetteDevice)   `Ability` key — imports nothing of ours           │
└──────────────────────────────────────────────────────────────────────┘
```

### A worked one: the H.264 stream

```
Device/Abilities/Capture/
├── H264Tuning.swift                 CompressionProperty values a tuning sets (pure)
├── AVCDecoderConfigurationRecord.swift   avcC from SPS/PPS (pure)
└── Internal/
    ├── VideoEncoder.swift            when to open, keyframes, which answer counts
    ├── CompressionSession.swift     @Mockable role: open / set / prepare / submit / close
    └── System/
        ├── VideoToolboxSession.swift          one VT call per method
        └── CompressedFrame+SampleBuffer.swift reading a CMSampleBuffer back
```

---

## Data Flow Diagrams

### A gesture, from either way in

```
browser (sim-stream.js)           baguette input (stdin)
  {type:"tap",x,y,width,height}     {type:"tap",…}
          │ WS                              │
          ▼                                 ▼
  Server.deviceStream ──────────▶ GestureDispatcher.dispatch(line:)
                                    │ GestureRegistry.standard.parse
                                    ▼
                                  Tap (needs .touch) ── device.input() ──▶ Touch role
                                                                             │
                                  Devices/Simulator/Internal/Input/IndigoHIDInput
                                    which messages, in what order, at what points
                                                                             │ IndigoChannel
                                  Devices/Simulator/Internal/System/SimulatorKitIndigoChannel
                                    9-arg IndigoHIDMessageForMouseNSEvent, built on main
```

### A stream

```
Screen (onFrame IOSurface) ─▶ AVCCStream ─▶ VideoEncoder ─▶ CompressionSession ─▶ VideoToolbox
                                   │              (decides)        (role)          (System/)
                                   ▼
                              FrameSink: StdoutSink (CLI) · WebSocketFrameSink (serve)
```

---

## Sequence Diagrams

### A route, refused or served

```
Browser        Server router          Devices            Device / role
  │ GET /devices/U/orientation        │                    │
  │──────────────▶│ trust + grant     │                    │
  │               │ checks            │                    │
  │               │── role(.orientation, of: U) ──────────▶│
  │               │                   │  unknown → 404     │
  │               │                   │  unable  → 422     │
  │               │                   │  not ready → 409   │
  │               │◀────────────── the role ───────────────│
  │◀── 200 JSON ──│ (a /simulators/U/… request also gets Deprecation: true)
```

---

## Component Interaction Tables

### Standard Table Format

```
| Component        | Purpose                 | Inputs           | Outputs         | Dependencies      |
|------------------|-------------------------|------------------|-----------------|-------------------|
| Hinge            | Reads and moves the fold| —                | HingeAngle      | GuestHinge        |
| LitPanelInput    | Gestures to the lit panel| a gesture       | Bool (sent)     | Input ×2, Hinge   |
| Simulator        | Hands out the roles     | —                | litPanelInput() | Displays, Hinge   |
```

### Files to Create/Modify Table

```
| File Path                                                     | Action | Description                                  |
|---------------------------------------------------------------|--------|----------------------------------------------|
| Sources/Device/Abilities/<x>/<Value>.swift                    | Create | the value and its rich methods               |
| Sources/Device/Abilities/<x>/<Role>.swift                     | Create | @Mockable role + `Ability<Role>` key         |
| Sources/Devices/Simulator/Internal/<x>/<Adapter>.swift        | Create | what the simulator decides                   |
| Sources/Devices/Simulator/Internal/System/<Concrete>.swift    | Create | the private call, ≤100 lines                 |
| Sources/Devices/Simulator/SimulatorDevice.swift               | Modify | register `.x`                                |
| Sources/Commands/<Verb>Command.swift · Server/Server<X>Routes | Create | the ways in                                  |
| Tests/BaguetteTests/<same paths>Tests.swift                   | Create | one suite per source, same folder            |
```

---

## Approval Prompt Template

After presenting the architecture, ask for user approval:

```
## Architecture Review

I've designed the architecture for [Feature Name]:

[Diagram Here]

### Components Summary

| Component | Purpose |
|-----------|---------|
| [Name]    | [Desc]  |

### Files to Create/Modify

- `Sources/.../NewFile.swift` - [Description]
- `Tests/.../NewTests.swift` - [Description]

**Ready to proceed with TDD implementation?**
```

Use AskUserQuestion with:
- "Approve - proceed with implementation"
- "Modify - I have feedback on the design"
