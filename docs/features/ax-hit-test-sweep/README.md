---
description: Explains why describe-ui returns the complete on-screen tree — status bar, tab-bar buttons and all — and what that costs. Use when an element seems missing from describe-ui or its latency matters.
---

# How `describe-ui` finds every element (the hit-test sweep)

`describe-ui` returns the **complete** on-screen tree — app content, the
SpringBoard status bar (clock / Wi-Fi / battery), and the items inside
otherwise-childless SwiftUI containers (tab bars, nav bars, toolbars).
Every flag: [commands.md#baguette-describe-ui](../../commands.md#baguette-describe-ui).
The wire surface is in [Accessibility](../accessibility/README.md).

> The walk gives you the precise deep tree; the grid sprays the screen
> finely enough that every normal-sized element the walk couldn't reach
> still gets hit; merge de-dups the spray and grafts the survivors into
> the right place.

## Quick start

```bash
baguette describe-ui --udid <UDID>
```

A recovered tab button is grafted *inside* its `AXGroup "Tab Bar"`, so
a client-side hit-test on the tree resolves the **button**, not the
group that would otherwise shadow it.

## Reading the log line

```
[ax] hit-test sweep: probed=259 discovered=255
```

- **probed (259)** — grid points actually hit-tested. See
  [where the sweep looks](design.md#where-the-sweep-looks).
- **discovered (255)** — probes that returned an element; the rest
  landed in genuine empty gaps.
- These are **mostly duplicates** — a 100 pt-wide tab button gets ~3
  probes across it, all returning the same button. They're collapsed,
  so only a handful of *new* nodes graft in; the recursive walk already
  supplied the rest.

## Gotchas

- **Latency.** The sweep usually sends 50–200 XPC round-trips. A page of web
  content needs a full look and sends about 400, so Safari reads in about 2 s
  against about 0.6 s for Settings.
- **Tiny isolated elements can be missed.** "Finds everything" means
  every element of normal interactive size (≥ ~32 pt both ways). An
  element *smaller* than the 32 pt grid step that sits entirely between
  four samples can fall through — rare in practice.
- If the sweep's time budget runs out, sampling is top-down, so the
  status bar is captured first.

## See also

- [design.md](design.md) — the walk + sweep pipeline, why a grid, the tuning constants
- [Accessibility](../accessibility/README.md) · [AX inspector](../ax-inspector/README.md)
