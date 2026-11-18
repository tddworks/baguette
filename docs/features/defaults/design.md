---
description: How baguette defaults finds an app's preferences plist through simctl, edits it through the guest's cfprefsd, and hears which preferences a running app looks up, with the measurements and dead ends. Read before changing the defaults adapter or DefaultsLookups.dylib.
---

# Defaults: design

## Path

- CLI `baguette defaults read|write|delete`, `GET /devices/<UDID>/defaults.json`,
  `POST|DELETE /devices/<UDID>/defaults` (or `/simulators/…`)
- → `PreferenceSuite` (which container, which plist) + `PreferenceValue` (typed value)
  → `PreferenceEdit` (the optional quit / relaunch around a change)
- → `Defaults` (`Simulator.defaults()` vends a fresh handle) → `SimctlDefaults`, two
  `Subprocess` children per operation:
  1. `xcrun simctl get_app_container <udid> <bundle> data | groups`
  2. `xcrun simctl spawn <udid> defaults export <plist> - | write <plist> <key> <fragment> | delete <plist> <key>`
- Relaunch: `Apps.terminate` / `Apps.launch` → `simctl terminate | launch`, the
  launch carrying `DefaultsLookups.dylib` (below).
- Settings nobody stored: `Defaults.lookups(of:)` → the running app's answer in
  `/tmp/BaguetteLookups-<udid>-<bundle id>.plist` → `PreferenceLookups(answer:)`
  → `unset(in:suite:)`.

## Why `spawn defaults`, not a host-side plist edit

The plist is reachable from the Mac, but the guest's `cfprefsd` caches it. A
host-side write can be overwritten by the daemon's next flush, and a host-side
read can miss a change the daemon hasn't flushed yet. Running the guest's own
`defaults` tool goes through `cfprefsd`, so it agrees with what the daemon
holds. `defaults` accepts an absolute plist path as its domain. That is how
both a sandboxed app's container and a group container are addressed without
running inside the app.

## Typed writes

`defaults write <domain> <key> <value>` parses `<value>` as a property list
when it is one. Writing the XML element (`<false/>`, `<integer>3</integer>`,
`<real>1.0</real>`, `<date>…Z</date>`, `<data>base64</data>`, `<array>`,
`<dict>`) stores that exact type. All eight were checked with `defaults
read-type` against an iOS 27.0 simulator (Xcode 27). Strings are always written
as an escaped `<string>` element, so a string that looks like markup stays a
string. `defaults export <plist> -` returns the whole domain as an XML plist,
which keeps the types on the way back. `CFBoolean` tells a stored bool from an
integer, and `CFNumberIsFloatType` tells a real from an integer.

## Measured exit codes (Xcode 27)

| command | exit | meaning | maps to |
|---|---|---|---|
| `get_app_container … data / groups` | `2` | no such app installed | `appNotInstalled` (404) |
| any `simctl` on a shut-down device | `149` | SimError 405, not booted | `deviceNotBooted` (409) |
| `defaults delete` of an absent key | `1` | "Could not find key" | avoided: `PreferenceEdit` reads first |
| `simctl terminate` of an app not running | `3` | "found nothing to terminate" | treated as done |

## Dead end: `get_app_container <bundle> <group id>`

simctl's help offers a named-group form. On Xcode 27 it exits `117` and prints
usage even for a group the app *does* have (Safari and
`group.com.apple.BrowserKit`, which `… groups` lists). The adapter therefore
asks for `groups`, which prints `<group id>\t<path>` lines, and picks the
suite out of them (`PreferenceSuite.plistPath(inContainerOutput:)`). A suite
missing from that listing is `groupNotFound`. That keeps a misspelt or
unentitled group from silently landing in standard defaults.

Only a suite starting `group.` is looked up this way. Apple requires that
prefix on every App Group id, so any other suite
(`UserDefaults(suiteName: "com.x.debug")`) is the app's own: CFPreferences
keeps it in the app's data container as `Library/Preferences/<suite>.plist`.
The split is decided by the name alone (`PreferenceSuite.group`), never by
whether a lookup happened to succeed.

## Identifiers

The bundle id and suite become a path component and a simctl argument, so
`PreferenceSuite` refuses empty values, `/`, `..` and a leading `-` before
either sees them. That matters on the HTTP route, where they come from a query
string.

## Settings nobody has stored

An app stores a setting only once it changes. Until then the key is a string
literal in its code (too short to survive as text in the binary: Swift builds
`"desk"` into an instruction), and an `@AppStorage` default never leaves
Swift. The one moment the setting is visible from outside is when the app
reads it, so the panel **asks the running app** which preferences it has
looked up. There is no history: the answer is about the process running now.

`DefaultsLookups.dylib` listens inside the app and keeps the answer in memory,
rewriting the plist whole (atomically, coalesced 200 ms) as it grows, with the
app's `pid`. `SimctlDefaults.lookups(of:)` reads it and trusts it only while
that pid is alive (`kill(pid, 0)`; simulator apps are host processes), so a
quit app's leftover file answers nothing. The plist records facts and
`PreferenceLookups` owns the rules.

Measured on iOS 27.0 (Xcode 27) against a SwiftUI app, Unveil:

| what | result |
|---|---|
| `@AppStorage("k") var x: SomeStringEnum` | read through `-[NSUserDefaults stringForKey:]`, called from `SwiftUI` |
| `UserDefaults.standard.bool(forKey:)` in app code | called from the app's image (`<App>.debug.dylib` in a debug build) |
| UIKit, Metal, CoreText, UIFoundation, DesignLibrary | ~50 reads of their own keys, called from their own images |
| SwiftUI's own flags (`UseSetNeedsLayoutForUpdates`, `com.apple.SwiftUI.*`) | read from `SwiftUI` too, but **never observed** |
| `@AppStorage` keys | **observed** by SwiftUI's `UserDefaultObserver` (`addObserver:forKeyPath:`) |
| `addObserver:forKeyPath:options:context:` | **inherited** from NSObject, not defined by NSUserDefaults |

So a read counts when its *immediate* caller is an image inside the app
bundle, or SwiftUI for a key SwiftUI also observes. The getter names the type;
`object(forKey:)` / `url(forKey:)` leave it open.

The launch: simctl hands a launched app `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`
**in place of** the device-wide `DYLD_INSERT_LIBRARIES` (measured: a library
armed with `launchctl setenv` did not load into an app launched with a
`SIMCTL_CHILD_` list). `SimctlApps.launch` therefore passes the armed list
plus `DefaultsLookups.dylib` (`InjectedDylibs.adding`), through `env` so it
applies to that simctl child alone. Nothing is armed device-wide, so there is
nothing to disarm.

Dead ends and traps:

- **Interposing `_CFPreferencesCopyAppValueWithContainerAndConfiguration`**
  catches nothing useful. Foundation's calls into CoreFoundation stay inside
  the shared cache, which dyld interposing doesn't patch.
- **A stack walk to find "the app's" reads** marks every read as the app's: in
  a debug build `main` lives in `<App>.debug.dylib`, so every stack passes it.
  Only the immediate caller works.
- **`valueForKey:` on NSUserDefaults inside a hook** recurses: KVC on defaults
  routes through `objectForKey:`. The hooks never read defaults, and a
  thread-local guard stops re-entry.
- **Swizzling an inherited method** changes it for every class. The getters
  are swizzled only where NSUserDefaults defines them itself; the observer
  method gets an NSUserDefaults override (`class_addMethod`) that forwards to
  NSObject's.

## Live or relaunch

A write through the guest's `defaults` tool reaches a running app that
watches the key: cfprefsd tells the app's `NSUserDefaults`, KVO fires, and
SwiftUI redraws an `@AppStorage` view. Measured on Unveil (iOS 27.0): writing
`unveil-ios-appearance` from Dark to Light with no relaunch switched the open
project to light mode, same pid (42586), same screen. A key the app copied into
state (`DirectorsChair` reads `desk` when a project opens) didn't change on the
open screen; leaving and reopening the project showed it, still the same pid.
One read only at launch would need a relaunch.

`Relaunch.whenNeeded` uses the one fact visible from outside: which keys
SwiftUI observes (`PreferenceLookup.live`, from the dylib's `observed`). It
writes those in place and relaunches for everything else, since "read when a
screen is built" and "read once at launch" look the same from outside. With no
running app to ask, it relaunches. Observers made through
`didChangeNotification` or Combine aren't recorded yet, so those keys
relaunch when they needn't.

## Known limits

- A running app's in-memory `UserDefaults` is out of reach. `--relaunch` is the
  supported way to make it observe a change.
- Unset settings come only from a running app baguette launched, and only the
  keys it has read so far. An unset `@AppStorage` value can't be shown; a
  `register(defaults:)` fallback can. A future Foundation that implements
  `UserDefaults` without these Objective-C methods would go quiet here.
- Managed preferences, the Keychain and app databases are out of scope.
