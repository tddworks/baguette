# Apps & data — put apps and their data in place

Read when: installing a build, launching or relaunching it, adding photos or
videos, opening a deep link, or reading or seeding an app's settings. Flags: that command's `## baguette <cmd>` section of `commands.md`.

## Install and add media

```bash
baguette install   --udid <X> MyApp.app      # .app or .ipa
baguette add-media --udid <X> photo.heic     # png jpg jpeg gif heic heif mov mp4 m4v → Photos
```

During `serve`, `POST /simulators/<X>/files?name=<file>` takes the raw bytes
and routes by extension (app → install, a `.zip` holding one `.app` →
extract and install, media → Photos); anything else is `415`. See
[file upload](https://github.com/tddworks/baguette/blob/main/docs/features/file-upload/README.md).

## Launch and relaunch

```bash
baguette launch --udid <X> --bundle-id com.example.app --describe-ui              # open it, answer with its first screen
baguette launch --udid <X> --bundle-id com.example.app --relaunch --describe-ui   # start it fresh
```

`--describe-ui` replaces a sleep and polling: it waits for the app's first real
screen, usually 4 to 5 seconds, most of it iOS. Write settings (below)
before the first launch and the app starts from them; no relaunch flag is needed.

## Deep links

```bash
baguette schemes --udid <X> --json             # URL schemes installed apps answer to
baguette openurl --udid <X> myapp://profile/42
```

See [deep links](https://github.com/tddworks/baguette/blob/main/docs/features/deep-links/README.md).

## Settings (UserDefaults)

```bash
baguette defaults read   --udid <X> --bundle-id com.example.app [--key onboarded] [--json]
baguette defaults write  --udid <X> --bundle-id com.example.app --key onboarded --type bool --value true
baguette defaults delete --udid <X> --bundle-id com.example.app --key onboarded
baguette defaults export --udid <X> --bundle-id com.example.app > seed.json
baguette defaults import --udid <X> --bundle-id com.example.app --file seed.json
```

- `--suite group.…` targets an App Group suite. `--type` is `bool | int |
  float | string | date | data | plist`. With `--key`, `--json` reads
  `{"key","present":true,"type","value"}` for a stored key and
  `{"key","present":false}` for one never stored.
- **A running app may not see a write.** `--relaunch-if-needed` changes an
  `@AppStorage` key live and relaunches only for keys read once;
  `--relaunch` always relaunches.
- For an app baguette launched, `read` also lists settings the app reads but
  hasn't stored (`@AppStorage` defaults on a fresh install) as `… is not set`
  (`lookups.unset` in JSON); write them like any key.
- `export` / `import` save and restore a set of keys for repeatable setup.

HTTP: `GET /simulators/<X>/defaults.json?bundleId=…[&key=…]`,
`POST /simulators/<X>/defaults` with `{"bundleId","key","type","value"}` in the
body, `DELETE /simulators/<X>/defaults?bundleId=…&key=…`.
See [defaults](https://github.com/tddworks/baguette/blob/main/docs/features/defaults/README.md).
