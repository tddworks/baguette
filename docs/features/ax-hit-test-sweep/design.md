---
description: The describe-ui pipeline — a recursive walk of the frontmost app plus a 32 pt positional hit-test sweep, merged and grafted — and why each part and tuning constant is what it is. Read before changing the sweep or merge.
---

# Hit-test sweep — design

## Path

`describeAll()` → ① `AXNode.walk` of the frontmost app + ②
`AXHitTestGrid` sample points → `objectAtPoint:displayId:bridgeDelegateToken:`
(the XPC call, integration-only), at the points `AXSweep` picks → ③
`merging(discovered:)` (`dedupKey`, graft).

## The pipeline

```
                         ┌─────────────────────────┐
                         │      describeAll()       │
                         └────────────┬────────────┘
                                      │
                ┌─────────────────────┴─────────────────────┐
                │                                            │
                ▼                                            ▼
   ┌────────────────────────┐                  ┌──────────────────────────┐
   │  ① RECURSIVE WALK      │                  │  ② GRID HIT-TEST SWEEP   │
   │  frontmost app only    │                  │  whole screen, by point  │
   │                        │                  │                          │
   │  walk accessibility-   │                  │  AXHitTestGrid →          │
   │  Children depth-first  │                  │  sample points (32pt)    │
   └───────────┬────────────┘                  └────────────┬─────────────┘
               │                                            │
               ▼                                            ▼
   ┌────────────────────────┐                  ┌──────────────────────────┐
   │  base tree             │                  │  look where AXSweep says │
   │  (precise, deep,       │   unseen-        │  status strip, childless │
   │   but process-scoped)  │──Regions()──────▶│  containers, then scouts │
   │                        │                  │  (full look if a scout   │
   │  • all app content     │                  │  finds something new)    │
   │  • tab bar = empty     │                  └────────────┬─────────────┘
   │    AXGroup (childless) │                               │
   │  • NO status bar       │                               ▼
   └───────────┬────────────┘                  ┌──────────────────────────┐
               │                                │  for each kept point:    │
               │                                │  objectAtPoint(x,y)      │
               │                                │  → deepest element       │
               │                                │    (crosses processes)   │
               │                                └────────────┬─────────────┘
               │                                             │
               │                                             ▼
               │                                ┌──────────────────────────┐
               │                                │  discovered[] (raw)      │
               │                                │  • status bar items      │
               │                                │  • tab-bar buttons       │
               │                                │  • MANY duplicates       │
               │                                │    (adjacent points hit  │
               │                                │     the same element)    │
               │                                └────────────┬─────────────┘
               │                                             │
               └──────────────────┬──────────────────────────┘
                                  ▼
                    ┌──────────────────────────────┐
                    │  ③ merging(discovered:)      │
                    │                              │
                    │  a. dedupKey: drop anything  │
                    │     already in tree OR a     │
                    │     repeat of another probe  │
                    │  b. graft each survivor under│
                    │     the DEEPEST container    │
                    │     that holds its centre    │
                    └───────────────┬──────────────┘
                                    ▼
                    ┌──────────────────────────────┐
                    │  COMPLETE, SELECTABLE TREE   │
                    │  walk's deep tree  +  status │
                    │  bar  +  tab buttons inside  │
                    │  their group                 │
                    └──────────────────────────────┘
```

## Why a *grid* finds (almost) everything

`objectAtPoint:displayId:bridgeDelegateToken:` is a **positional**
hit-test: give it a screen point, it returns the *deepest* accessibility
element whose frame covers that point — regardless of which process owns
it. Sample the whole screen densely enough and every element bigger than
the spacing is guaranteed to contain at least one sample.

Each `·` below is a 32 pt grid sample:

```
   ·    ·    ·    ·    ·    ·       ← status bar strip (cross-process)
   ┌───────┐ ·    ·  ┌──────┐
   ·  4:51 │·    ·   │battery·      clock & battery each catch a sample
   └───────┘ ·    ·  └──────┘
   ·    ·    ·    ·    ·    ·
        ┌────────────────────┐
   ·    │   "June, 2026"  ·  │·     big elements → many samples
        └────────────────────┘
   ·    ·    ·    ·    ·    ·
   ┌────┬────┬────┬────┬────┐
   │ ·1 │ ·2 │ ·3 │ 4· │ 5· │      each date cell ≥32pt → ≥1 sample
   └────┴────┴────┴────┴────┘
   ┌──────────────────────────┐
   │  Tab Bar (empty AXGroup) │      walk sees an EMPTY group here…
   │ ┌────┐┌────┐┌────┐┌────┐ │
   │ │Cal·││Lst·││Ana·││Set·│ │      …but each button catches a sample
   │ └────┘└────┘└────┘└────┘ │      → hit-test recovers them
   └──────────────────────────┘
```

- Grid step = **32 pt**. Apple's HIG minimum tap target is 44×44 pt and
  most controls are larger, so any element ≥ ~32 pt in both dimensions
  contains at least one sample → it's found.
- **Miss case:** an element *smaller* than the spacing that happens to
  sit entirely between four samples can fall through. Rare in practice;
  a tighter step trades completeness for more XPC round-trips (cost ∝
  points²).

So "finds everything" precisely means "finds every element of normal
interactive size."

## Why both sources are needed

```
                        │ in app's        │ answers a
   element              │ accessibility-  │ positional
                        │ Children walk?  │ hit-test?     →  recovered by
   ─────────────────────┼─────────────────┼───────────────┼────────────────
   normal app content   │   ✅ yes        │   ✅ yes      │  ① walk
   tab/nav bar buttons  │   ❌ no (empty  │   ✅ yes      │  ② sweep
   (childless container)│      container) │               │
   status bar (clock,   │   ❌ no (other  │   ✅ yes      │  ② sweep
    wifi, battery)      │      process)   │               │
   tiny <32pt isolated  │   ✅ if in walk │   ⚠ maybe miss│  ① walk
   ─────────────────────┴─────────────────┴───────────────┴────────────────
            ①  exact + deep, but blind across process / empty groups
            ②  flat + sampled, but sees by position regardless of owner
            ①⊎②  union → complete & selectable
```

The grid is only the **gap-filler**. The walk supplies the bulk
precisely (no sampling); the sweep adds only what the walk structurally
can't reach.

## Where the sweep looks

`AXSweep` looks in three stages, because every probe is an XPC round-trip:

1. **Always, on the fine grid:** the status strip and every childless
   non-leaf node (`unseenRegions`). A leaf lying beneath one doesn't exempt it:
   list rows run under a floating tab bar, and skipping points above known
   leaves is what used to hide the tab buttons. A full-screen map image hid
   Maps' controls the same way.
2. **Scouts:** a 64 pt grid over the gaps between known leaves.
3. **In full:** the 32 pt grid over those gaps, only when a scout found
   something the walk didn't know. Web content is why this stage exists: it
   lives in another process, so the walk reports nothing there, not even a
   childless container. A hit on a bare group doesn't count.

A walk that found nothing gets the fine grid everywhere.

The stages cost a known risk: a small element alone in a gap, with nothing else
new for a scout to land on, is found only if a 64 pt scout hits it. We compared
15 screens against the previous sweep, on iOS 27.0 (SwiftUI tabs, an alert and
a sheet; Settings, Files, Reminders, Contacts, Health, Photos, Maps, Safari and
the Home Screen). Nothing that said anything was lost.

## Why discoveries are grafted under a container

`merging()` doesn't just append discoveries to the root — it inserts
each one under the **deepest existing node that contains its centre**.
That matters for selection: a recovered `Calendar` tab button is grafted
*inside* the `AXGroup "Tab Bar"`, so a client-side hit-test descends into
the group and resolves the **button**, not the group that would
otherwise shadow it.

## Tuning constants

The sweep adds latency (50–400 XPC round-trips). Bounding constants live
in `AXPTranslatorAccessibility`:

| Constant              | Default | Role                                            |
| --------------------- | ------- | ----------------------------------------------- |
| `gridStep`            | 32 pt   | sample spacing — smaller = more complete, slower |
| `scoutStep`           | 64 pt   | spacing of the coarse look at the gaps           |
| `gridCap`             | 600     | hard ceiling on probe count                     |
| `sweepBudgetSeconds`  | 2.5 s   | wall-clock budget; top-down sampling captures the status bar first even if cut short |
| `sweepDepth`          | 0       | each probe reads one element, not a deep subtree (keeps each hit-test cheap) |
