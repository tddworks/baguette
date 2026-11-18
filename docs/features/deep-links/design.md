---
description: How baguette finds an installed app's URL schemes (simctl listapps plus each bundle's Info.plist), and why ranking lives server-side.
---

# Deep links — design

## Path

- `baguette openurl`, `POST /devices/:udid/openurl` (or `/simulators/…`) and the `deeplink`
  plugin → `DeepLink` (names the routing: `app` vs `browser`, which is where
  the `https://` warning comes from) → `simctl openurl`.
- `baguette schemes`, `GET /devices/:udid/schemes.json` → `SimctlApps` →
  `xcrun simctl listapps` + a read of each bundle's `Info.plist`.

## How the schemes are found

Two reads, no private API, because neither source has the whole picture:

1. `xcrun simctl listapps <udid>` — the authoritative roster: which apps are
   installed, what they're called, and each one's real `Path` on disk. It
   reports a curated metadata subset that **does not include
   `CFBundleURLTypes`** (verified against Xcode 26), so it cannot answer the
   question on its own.
2. `<Path>/Info.plist` — the schemes, from the key the app declared them
   under, unioned across every `CFBundleURLTypes` entry.

Taking the path from step 1 is what makes step 2 safe. Reading `Info.plist`
means touching CoreSimulator's container layout, whose
`…/Containers/Bundle/Application/<uuid>/` shape is undocumented and whose UUID
changes on every reinstall — but it never has to be *guessed*, because
`listapps` just reported it. An app whose bundle has vanished keeps its roster
entry and simply contributes no schemes.

Both parses are pure (`InstalledApp.all(fromListApps:)` /
`InstalledApp.schemes(inInfoPlist:)`); `SimctlApps` runs the child, reads the
file, and composes them.

## Ranking is server-side

Ranking happens server-side so there is one ordering rule, tested once, rather
than a copy in every client that drifts. The panel fetches the inventory once
when it opens (a plugin command is a subprocess with a ten-second budget, so
per-keystroke re-runs are the wrong shape) and filters in the page.

## Why `open-url` is its own capability

Being separate from `apps` is deliberate. That capability installs software;
this one only launches what is already there, and a plugin that wants to fire
a deep link shouldn't have to be trusted to put an executable on the device.
