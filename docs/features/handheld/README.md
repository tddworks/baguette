---
description: Hold the simulator in your hand — open the serve stream on a phone and the live screen fills it, no bezel or toolbar. Use when demoing or testing an app on a phone instead of a Mac window.
---

# Handheld

Open a simulator's stream page on a phone and the page is a workbench: a
toolbar, rails, and the device drawn in its bezel, so the live screen gets
about half the glass. Handheld mode drops all of that. The screen takes the
whole view, black around it, and touches land on it the way they would on the
phone it is shown on.

## Quick start

1. Run `baguette serve` so the phone can reach it (every flag:
   [commands.md#baguette-serve](../../commands.md#baguette-serve)):

   ```bash
   baguette serve --host 0.0.0.0
   ```

2. On the phone, open `http://<mac-ip>:8421/devices/<UDID>` and tap
   **⛶ Handheld** next to the 3D cube in the toolbar.

Or link straight to it: `http://<mac-ip>:8421/simulators/<UDID>?handheld=1`.

## Truly full screen

How much of the browser goes away depends on the phone:

| Phone | What you get |
|---|---|
| Android (Chrome) | Tapping **Handheld** also asks for browser fullscreen, so the address bar and navigation bar go too. |
| iPhone, in a browser tab | The address bar and toolbar stay, tinted black so they recede. Every iPhone browser, Chrome included, is WebKit, and WebKit only lets video go fullscreen. The screen fills the space between the bars, and a one-time hint points to the Home Screen. |
| iPhone, from the Home Screen | While in handheld mode, **Share → Add to Home Screen** (Safari or Chrome). The icon opens straight into handheld mode with no browser around it; only the iPhone's own status bar draws on top. |

The phone's screen stays on for as long as handheld mode is showing.

## Controls

Nothing sits on the glass but one floating button, the AssistiveTouch kind:
a small glass square resting against a side edge, faded until touched.

- **Tap it** for a menu in the middle of the screen: **Home**, **App
  Switcher**, **Rotate** and **Exit Handheld**. Tap outside the menu to close
  it; the simulator never sees taps aimed at the menu.
- **Drag it** anywhere it is in the way. Let go and it settles against the
  nearer side edge, and it stays there the next time handheld mode opens,
  Home Screen launches included.

Exiting inside a Home Screen launch brings the full toolbar back in the same
window, laid out below the iPhone's status bar.

## Gotchas

- **Match the model for a perfect fit.** The screen keeps the simulated
  device's shape. Run an iPhone 17 Pro simulator on an iPhone 17 Pro and a
  Home Screen launch fills the glass edge to edge; any other pairing leaves
  black bars.
- **The real phone keeps its own edge swipes.** Swiping up from the bottom of
  a Home Screen launch goes home on the phone in your hand, not in the
  simulator. Use **Home** in the pill. In a browser tab the bottom of the view
  sits above the browser's bar, so the simulator's own home swipe works there.
- **Typing needs the simulator's keyboard.** Turn off *I/O → Keyboard →
  Connect Hardware Keyboard* in Simulator.app so the on-screen keyboard comes
  up when a field is focused.
- **Not on a foldable.** iPhone Duo's main view is the 3D book, so the button
  is hidden there.

## See also

- [stream](../stream/README.md) — the stream handheld mode shows
- [touches](../touches/README.md) — how a finger on the glass becomes a touch
- [deep-links](../deep-links/README.md) — the `/devices/<UDID>` page
