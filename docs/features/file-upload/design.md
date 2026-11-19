---
description: How uploads route to the Apps and PhotoLibrary collections, why ditto extracts .app zips, the zip-bomb checks, and how the browser packs a dropped .app folder. Read before changing install, add-media or the drop target.
---

# File upload: design

## Path

- `baguette install`, `baguette add-media`, `POST /devices/<UDID>/files?name=…` (or `/simulators/…`)
  (the drop target posts here)
- → classify by extension on the values: `AppBundle.at` / `AppArchive.at` / `MediaItem.at` (pure)
- → `Apps.install` / `Apps.install(archive:)` / `PhotoLibrary.add`
  (`simulator.apps()` / `simulator.photos()`, next to `statusBar()` / `orientation()`)
- → `HostSubprocess`: `ditto -x -k` | `xcrun simctl install` | `xcrun simctl addmedia`

Like the status bar, this is **not** a SimulatorHID path: one-shot
subprocesses through the `Subprocess` collaborator, so the orchestration is
unit-covered via `MockSubprocess`.

## Two collections, not one classifier

The user's mental model isn't "a file to be classified". It's two plain acts:
**install an app** and **add a photo**. So the domain is the two things that
live on a phone, each a small collection you add to: `Apps` (takes `AppBundle`
`.ipa`/`.app`, or `AppArchive`, a `.zip` carrying one `.app`) and
`PhotoLibrary` (takes `MediaItem`). Classification lives on the values
themselves, by extension only (case-insensitive); there is no separate "content
classifier" object. `Server.addFile` is the thin "which collection?" router,
the only place the two collections meet:

```
AppBundle.at(path)?   → apps().install(app)          → {"ok":true,"kind":"app"}
AppArchive.at(path)?  → apps().install(archive:)     → {"ok":true,"kind":"app"}
MediaItem.at(path)?   → photos().add(media)          → {"ok":true,"kind":"media"}
else                  → 415 "no home for .<ext> …"
```

## `.app` archives

`AppArchive` is how a **folder-form `.app` bundle** travels over HTTP: a browser
can't upload a directory as one file, so the drop target packs the bundle into a
stored zip and posts that (a user-zipped `.app` arrives the same way). simctl
can't take a zip directly, so `apps().install(archive:)`:

1. extracts it with `/usr/bin/ditto -x -k <zip> <tempdir>`, chosen over `unzip`
   because it restores the unix modes in the zip's external attributes: the app
   binary must come out executable;
2. locates the app with the pure `AppArchive.installableApp(amongExtracted:)`:
   exactly one top-level `.app`, `__MACOSX` / dotfiles ignored, two apps refused
   as ambiguous;
3. installs it through the normal `AppBundle` path
   (`xcrun simctl install <udid> <tempdir>/<Name>.app`), deleting the
   extraction temp dir regardless of outcome.

`.ipa` stays an `AppBundle`: it installs directly, no extraction step.

A zip that turns out not to carry an app fails **as the upload's fault**, not the
device's: extraction failure ("corrupt zip?"), contents over the 4 GiB
decompression cap ("zip bomb?", checked against the central directory's
declared sizes *before* extraction, with the extracted bytes re-measured
afterwards as the backstop against forged headers), and no-single-`.app`-inside
all come back `415`, while a simctl failure after a good extraction stays `500`.
In tests, the ditto stub materialises fake entries in the destination dir.

## Staging the upload

The route closure materialises the upload into a unique temp directory,
preserving the filename so the extension (and simctl's bundle detection)
survives, dispatches, then deletes the temp dir regardless of outcome. `?name=`
is reduced to its last path component, so `?name=../../etc/x` can't escape the
temp dir. An unknown extension is rejected before the body is read.

## The browser drop target

`sim-file-drop.js` hangs `window.SimFileDrop`; `sim-native.js` calls
`SimFileDrop.attach(nativeDeviceFrame, {udid})` on the focus page. The drop
listeners live on the device frame, and the highlight **mirrors the bezel's
`screenArea` rect** (same percentage geometry and `clipRadius` corner radius the
`Bezel` part computes), so the dashed border traces the phone screen as a clean
rounded rectangle: no page-wide dim, no boxy bounding box, no side-button
protrusions. The geometry is re-read on each `dragenter`, so it tracks remounts,
orientation and viewport scaling. It's a **dumb sender**: no notion of which
simctl verb applies.

The one thing the browser *does* build is the transport for a dropped **`.app`
directory**:

- The drop handler reads `webkitGetAsEntry()` for every item synchronously: the
  dataTransfer store empties once the handler yields.
- It walks a `*.app` directory recursively, draining `readEntries`, which returns
  ~100 entries per call.
- It packs the tree into a **stored (uncompressed) zip** built in
  `sim-file-drop.js`: local headers + CRC-32 + central directory, no library, no
  bundler.
- Every entry is stamped unix mode `0755` in its external attributes (the
  file-system API can't say which files had the exec bit, and a spare exec bit
  on a plist is harmless), so `ditto -x -k` restores an executable binary.
- The file-system entry API resolves links and skips empty dirs, so neither
  survives. iOS-style shallow `.app` bundles carry neither; a macOS-shape bundle
  (`Contents/`, versioned frameworks) wouldn't install on a simulator anyway.
- A dropped directory that isn't a `.app` gets an error toast without an upload.
  Zipping is transport encoding, not domain logic: which zip carries an
  installable app is still decided on the Swift side. The packer is exposed as
  `SimFileDrop.pack` for round-trip verification.

## Adding a new added-to-device thing

1. **Domain value**: a `struct` in a new `Domain/<Thing>/` context with
   `static func at(_:) -> Self?` (extension classification, pure) and a
   `…Arguments(udid:)` argv projection. Test it first.
2. **`@Mockable` collection**: `protocol <Things>: Sendable { func add(_:) async throws }`,
   named as the plural collection noun, plus a `<Things>Error` enum.
3. **Orchestrator**: `Simctl<Things>` mirroring `SimctlApps`: build argv from
   the value, run via `Subprocess`, map non-zero exit to the error. Unit-test
   through `MockSubprocess`.
4. **Factory**: add `func <things>() -> any <Things>` to `Simulator` and return
   `Simctl<Things>(udid:)` from `CoreSimulator`.
5. **Wire**: add a branch to `Server.addFile` and, if it's CLI-worthy, a
   subcommand in `AddFileCommands.swift`.

Generic documents (`.pdf`, `.json`…) have no collection because `simctl` offers
no clean path to drop an arbitrary doc into the Files app.
