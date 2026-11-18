# Real devices: CoreDevice spike

> Status: **spike, not started**, 2026-10-07. No code on `main`. The feature's `README.md` arrives when something ships.

## Question

**Can an unentitled `baguette` process stream the screen of a CoreDevice-connected iPhone and send it touches, the way Xcode 27's Device Hub does?**

- **Yes:** one adapter gives baguette both physical iPhones and [vphone-cli](https://github.com/Lakr233/vphone-cli) virtual iPhones, because a vphone guest now presents itself to the Mac as a real device.
- **No:** baguette can still reach vphone VMs through their own guest API ([Fallback](#fallback-vphone-only-through-vphoned)), but not physical devices.

Proposed time box: 2 days. Output: the [Decision](#decision) table filled in, plus proof-of-concept code on a scratch branch.

## Background

### How vphone reached Device Hub

[vphone-cli PR #604](https://github.com/Lakr233/vphone-cli/pull/604) (merged 2026-10-07) adds no host-side Device Hub code. The guest passes as a USB-connected iPhone (usbmuxd, lockdownd, remoted, CoreDevice pairing), so Device Hub takes its normal **physical-device** path:

```
DeviceHub.app ──CoreDevice──▶ guest/device: dtremotedisplayd  (from the DDI)
                               service com.apple.coredevice.displayservice
                                 getmediasupportinfo
                                 getmediastreamserverstatus
                                 startmediastream / stopmediastream
                                 startvideooutput / startaudiooutput
               ◀── HEVC, encoded on the device (AVConference) ──
```

The PR fixed four places where that path stopped on a VM. All of the fixes are in the guest:

| Stage | Symptom | Fix |
|---|---|---|
| DDI mount (iOS 27) | "connected (no DDI)" forever: `cryptexd` gets `EPERM` from `F_SETPROTECTIONCLASS` | Report the error as `ENOTSUP`, which takes cryptexd's existing path for filesystems without protection classes |
| Feature query | `supportedFeatures: 0`; iPads and customer-restricted devices refused | `MediaStreamSupportedFeatures.current` answers `0x8c` (140, what a Mac reports); `isCustomerRestricted` answers false |
| Capture display (iOS 27) | Stream starts, view black: swaps go to a kernel port the capture display lacks | Patch the swap code so only the main display presents through the kernel |
| Display metadata (27.x iPhone) | Screen drawn over the bezel corners | `dtdeviceinfod` answers the `phone11` framebuffer mask |

Measured by the PR: the live view runs 30–150 ms behind the VM's own window. Under load it stalls for 1–3 s or falls seconds behind, because the HEVC encode is paravirtualized to the Mac and shared by every VM. Touch from Device Hub reaches the guest, checked by hand only. Full write-up: `Research/Guest/devicehub_screen_viewing.md` in vphone-cli.

### Not the Device Hub problem we already know

[device-hub](../device-hub/design.md) (#77) is Device Hub's **simulator** path: `dtuhidd` attaching to a simulator and SimulatorHID dropping our legacy touch service. This spike is about the **physical-device** path through CoreDevice, which baguette does not touch today. The one overlap: the [hinge](../hinge/design.md) research found CoreDevice's UniversalHID not callable from outside, which predicts a problem for input here.

## Hypotheses

Each one is proven or killed by an experiment below.

| # | Hypothesis | Killed if |
|---|---|---|
| H1 | Device Hub's screen view is a CoreDevice action any process can invoke through `CoreDevice.framework` | The call is refused for a missing entitlement (record which one) |
| H2 | The frames reach the client as something we can decode to a `CVPixelBuffer` / `IOSurface` (HEVC sample buffers or similar) | Frames are only rendered inside an AVConference view we cannot host |
| H3 | Device Hub's touches go over a CoreDevice service we can also call | Input needs an entitlement we can't have, or runs through UniversalHID (see hinge) |
| H4 | Whatever works on a physical iPhone works unchanged on a vphone VM | The VM needs host-side cooperation beyond PR #604 |

## Experiments

Run them in order; stop at the first kill of H1 and jump to [Fallback](#fallback-vphone-only-through-vphoned).

1. **Prerequisites.** A physical iPhone, paired with this Mac, Developer Mode on, its DDI mounted. `xcrun devicectl list devices` shows it connected. Xcode 27 is a beta here and isn't selected with `xcode-select`, so prefix commands with `DEVELOPER_DIR=…`.
2. **Watch Device Hub.** Open the device's live view in Device Hub while running `log stream` on the CoreDevice and `com.apple.dt` subsystems. Record: which host process opens the stream (DeviceHub itself or `CoreDeviceService`), the action names, the transport the frames arrive on, and what a touch in the view logs. Also dump `codesign -d --entitlements -` of DeviceHub.app and of CoreDeviceService.
3. **Map the API.** List `MediaStream*` and display-service symbols in `CoreDevice.framework` and the DDI's `CoreDeviceUtilities.framework`. Check whether `devicectl` already exposes any of them (`devicectl device --help` and its subcommands).
4. **Feature query from our own process (H1).** A Swift script on a scratch branch loads CoreDevice and invokes `getmediasupportinfo` on the device. Pass: `supportedFeatures: 140`. Fail: record the error and the entitlement it names.
5. **One frame (H2).** Invoke `startmediastream`, take the first video sample and write it to a PNG. Pass: a PNG of the home screen. Record latency against the device.
6. **One tap (H3).** Send a single touch down/up through whatever service step 2 found. Pass: the tap visibly lands (open an app from the home screen).
7. **Same again on a vphone VM (H4).** Only if a vphone VM is available. Needs `csrutil allow-research-guests enable` on the host, so it may run on another Mac.

## Decision

Filled in at the end of the spike.

| Outcome | Meaning | Next |
|---|---|---|
| Go: H1, H2, H3 pass | Screen and input both reachable | A `CoreDevicePhones` source in [Devices](../devices/design.md), registering `screen` and `input`; real iPhones and vphone VMs both appear |
| Partial: H1 and H2 pass, H3 fails | Watch-only real devices | Decide whether a view-only device is worth shipping; input for vphone still goes through vphoned |
| No-go: H1 fails | CoreDevice route closed to us | [Fallback](#fallback-vphone-only-through-vphoned); physical devices stay out of scope |

Result: _not run yet._

## Fallback: vphone only, through vphoned

vphone's guest daemon `vphoned` serves an HTTP / WebSocket API once a VM is launched with `--api-listen 127.0.0.1:<port>` (bearer token printed at launch). Baguette acts as a client; the VM host binary needs Apple-private virtualization entitlements, so it can never ship inside baguette.

| baguette | vphoned method | Fit |
|---|---|---|
| `Input.touch1` / `touch2` | `input.touch {phase,x,y}` / `input.touch2 {x1,y1,x2,y2}` | Direct; coordinates are 0..1, so divide by size as `IndigoHIDInput` does |
| tap, swipe, button, key, type, paste | `input.tap`, `swipe`, `button`, `hid {page,usage}`, `key`, `type`, `paste` | Direct |
| `Accessibility` | `ui.tree`, `ui.element_at` | Map onto `AXNode` |
| `Location`, `Pasteboard`, `Orientation`, apps, logs | `location.*`, `clipboard.*`, `display.rotation`, `apps.*`, `logs.syslog` | Good |
| `Screen` / `Stream` | `screen.screenshot` only, one image per call | **Gap:** live frames exist only inside the `vphone-vm` process |

Shape in baguette, following AGENTS.md: one `@Mockable` collaborator `Guest` for the vphoned conversation (integration-only concrete client); a `VirtualPhone` aggregate conforming to `Simulator` that refuses the verbs a VM lacks (status bar, motion, injection, hinge). The stream gap is closed by a vphone-cli PR adding a host-side frame stream from `vphone-vm`; polling `screen.screenshot` is the stopgap.

## Risks and open questions

- Is CoreDevice's display service gated by an entitlement only Apple-signed clients carry? H1 answers it.
- The stream is AVConference HEVC, not the IOSurface frames our `Stream` pipeline takes today. A decode step costs latency on top of the device's encode.
- vphoned deliberately breaks compatibility between versions; any vphoned client pins a version and checks the capability flags `/v1/health` returns.
- vphone runs patched iOS firmware in a security-research VM and needs weakened host security. Baguette stays a client and never installs or launches it.
- No paired iPhone and no vphone VM on the maintainer Mac as of 2026-10-07; experiment 1 needs one.
