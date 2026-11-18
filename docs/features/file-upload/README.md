---
description: Put a file on a booted simulator by type: install an .ipa/.app (or a dropped .app folder) or add a photo/video to Photos, via CLI, HTTP or drag-and-drop onto the page. Use when testing needs a real app build or photos on the device.
---

# File upload (drag-and-drop to device)

Hand the device a file and **the device decides where it goes by its type**: an
app is installed onto the Home screen, a photo or video lands in Photos. It's
the same mechanism as dropping a file on Xcode's Simulator window
(`simctl install` / `simctl addmedia`). Every flag:
[commands.md#baguette-install](../../commands.md#baguette-install) ·
[commands.md#baguette-add-media](../../commands.md#baguette-add-media).

## Quick start

```bash
baguette install   --udid <UDID> MyApp.ipa      # or MyApp.app
baguette add-media --udid <UDID> beach.heic
```

In the browser: open `/simulators/<UDID>` and drag files onto the device. The
device's screen gets a dashed highlight; on drop each file is uploaded and a
toast says `Installed …`, `Added …` or the server's error. Dropping a
folder-form `.app` bundle works too: the page zips it and uploads the zip.

| File | Goes to |
|---|---|
| `.ipa`, `.app` | Installed (Home screen) |
| `.zip` carrying one `.app` at its top level | Extracted, then installed |
| `png jpg jpeg gif heic heif mov mp4 m4v` | Photos |
| anything else | Refused (`415`) |

Extensions are matched case-insensitively.

## HTTP

```
POST /devices/<UDID>/files?name=<filename>
     body = raw file bytes (application/octet-stream)
```

A simulator answers under its old `/simulators/<UDID>/files` too; plugins use
that spelling, with `/apps` and `/media`.

```bash
curl -X POST --data-binary @MyApp.ipa \
  "http://127.0.0.1:8421/devices/<UDID>/files?name=MyApp.ipa"
```

| Status | Body / meaning |
|---|---|
| 200 | `{"ok":true,"kind":"app"}` or `{"ok":true,"kind":"media"}` |
| 400 | Upload too large (> 1 GiB) or unreadable |
| 404 | Unknown udid |
| 422 | The device can't take that kind of file (no apps or Photos), named |
| 415 | `no home for .<ext> …`; or a zip that isn't an installable app: corrupt, over the 4 GiB decompression cap, or not exactly one top-level `.app` (the reason is in `error`) |
| 500 | simctl failed (device not booted, bad bundle) |

`name` is reduced to its last path component. An unknown extension is rejected
before the body is read, so a junk drop never uploads megabytes. A folder
`.app` is posted as a stored zip named `<Name>.app.zip`.

## Gotchas

- **The `.app` must sit at the zip's top level.** `Payload/MyApp.app` (ipa
  layout) or `SomeFolder/MyApp.app` is refused with "no single `.app` bundle at
  the top level"; drop the `.ipa` itself for the former. Two apps in one zip are
  refused as ambiguous; `__MACOSX` and dotfiles are ignored.
- **Generic documents have no home.** `.pdf`, `.json` etc. are refused with
  `415` rather than silently dropped: `simctl` offers no clean path into the
  Files app.
- **A dropped `.app` folder loses symlinks and empty directories**, and every
  file comes out mode `0755` (the browser can't read permission bits). iOS-style
  shallow bundles carry neither, and the spare exec bits are harmless.
- **Drop UI is focus-mode only.** The device-farm grid doesn't mount the drop
  target; the route and both CLI verbs work for any device.
- **Uploads are buffered in memory** (≤ 1 GiB), and a dropped `.app` folder is
  also buffered in the browser while packing. Fine for a localhost dev tool; not
  a public upload endpoint.
- The device must be booted; otherwise simctl fails and you get `500`.

## See also

[design.md](design.md): extraction, zip safety and the browser packer ·
[deep links](../deep-links/README.md) · [status bar](../status-bar/README.md)
