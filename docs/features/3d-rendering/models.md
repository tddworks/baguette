---
description: How 3D device models are packaged, found and defined — model bundles, definition.json schema, foldable keys, USD vs material variants, and adding a model. Use when adding or fixing a 3D device model.
---

# 3D device models

Scene node names, screen geometry, device matching, and USD variant
selections live in model definitions rather than Swift enums.

## Model bundles

A model is a directory containing one versioned definition and either a local
USDZ asset or a verified download descriptor:

```text
iphone-17-pro/
├── definition.json
└── device.usdz
```

Definitions are resolved in precedence order:

1. `BAGUETTE_3D_MODEL_DIR`
2. `~/Library/Application Support/com.tddworks.baguette/3d-models`
3. bundled definitions under `Resources/Models3D`

An ID found in a higher-precedence directory replaces the same ID below it.
Two definitions at the same precedence that match one simulator are an error.
Simulator lookup checks the stable device type name before the editable display
name, so renaming a simulator does not change its hardware model.

The third entry is the one that surprises people: "bundled definitions" means
the SPM resource bundle, which sits beside the binary in `.build/`. `build.sh`
copies only the binary to `./Baguette`, so a release build has no bundle to
read and nothing creates the application-support directory either — a fresh
`./Baguette render-3d` 404s until `BAGUETTE_3D_MODEL_DIR` points somewhere.
`swift run` is unaffected.

The asset block may contain `file`, or `downloadURL` plus a required SHA-256,
or both. A local file wins. Downloaded assets are staged to a temporary name,
verified, and atomically moved into the application-support cache.

Apple USDZ binaries should not be committed to this repository until their
redistribution terms have been verified. Bundled definitions may point at the
same Apple-hosted assets used by 3dsg.

## Definition schema

```json
{
  "schemaVersion": 1,
  "id": "macbook-pro-14-inch",
  "displayName": "MacBook Pro 14-inch",
  "matches": {
    "simulatorDeviceTypes": [],
    "deviceNames": ["MacBook Pro 14-inch"],
    "deviceModels": ["Mac14,5"]
  },
  "asset": {
    "file": "macbook-pro-14-in-space-black-variant.usdz",
    "downloadURL": "https://example.invalid/model.usdz",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "scene": {
    "rootNode": "XCnTRSzLPcVVRyt",
    "screenNode": "Screen",
    "screenMaterial": "ScreenMaterial",
    "nativeOrientation": "landscape",
    "textureSize": {
      "width": 3024,
      "height": 1964
    },
    "usesScreenOverlay": false
  },
  "variantSets": [
    {
      "id": "finish",
      "displayName": "Device finish",
      "primPath": "/XCnTRSzLPcVVRyt",
      "usdName": "Color",
      "default": "space-black",
      "choices": [
        {
          "id": "space-black",
          "displayName": "Space Black",
          "usdValue": "Space_Black",
          "previewColor": "#2f3033"
        },
        {
          "id": "silver",
          "displayName": "Silver",
          "usdValue": "Silver",
          "previewColor": "#d3d4d5"
        }
      ]
    }
  ]
}
```

`matches.deviceModels` is optional and holds physical hardware
identifiers (`utsname.machine`, e.g. `"iPhone14,3"`) for the
device-twin path — see
[Device twin](../device-twin/README.md); the two simulator keys are
unchanged and a definition may declare any mix of the three.

`id` and choice IDs are baguette's stable public vocabulary.
`usdName`, `usdValue`, and `primPath` are private model instructions. Render
requests select only declared public IDs, so callers cannot author arbitrary
USD paths.

A definition is rejected when:

- `schemaVersion` is unsupported;
- IDs are empty or duplicated;
- dimensions are not positive;
- a variant default does not name one of its choices;
- a downloaded asset has no valid SHA-256;
- neither a local file, a download URL nor an Xcode resource is present;
- a fold names no clip, a non-positive shut time or an open pose outside 0–180;
- a texture rotation is not a quarter turn;
- a button has no id or joint.

## Foldables and Apple's own models

iPhone Duo's definition ([iPhone Duo](../iphone-duo/README.md)) uses the
optional keys a book needs:

| Key | Meaning |
|-----|---------|
| `asset.xcodeResource` | The asset's path under the selected Xcode's `Contents/` (DeviceKit's `V68.usdz`); read in place, never copied |
| `scene.restRotation` | Turns a model authored lying flat, screen up, to face the camera before any requested rotation |
| `scene.textureRotation` | Quarter turns (degrees) the framebuffer needs on the mesh when its UVs run the other way |
| `scene.fold` | `clip` (the shutting clip), `shutTime` (its time when shut; flat at 0), `coverMaterial`, `coverTextureSize`, `coverTextureRotation`, `openPoseDegrees` (Device Hub's open pose, from where up the bend is centred) |
| `scene.buttons` | `[{id, joint}]` — the wire button name and the skeleton joint that sits on it; the page draws a control beside the device there |

A foldable's 3D socket binds both panels and the hinge, poses the
clip at `(180 − angle) / 180 · shutTime` and turns the whole device
back by half the fold above the open pose (`FoldPose`); its
`screen_quad` carries `pieces` (each with corners in framebuffer
order and the `u`/`v` range it shows), `buttons` and `litPanel`, and
`set_3d_camera` names the `orientation` the page turned the book to,
and the scene rolls the model to stand that way (`InterfaceRoll`);
`set_pose` moves the device's hinge ([Hinge](../hinge/README.md)) and `screen_quad`
reports the `pose` shown;
`set_3d_camera` may also name an `orientation` outright.

## Offline folded screenshots

A saved capture can be rendered without contacting a simulator:

```bash
baguette render-3d --screen inner-landscape.png --device iphone-duo \
  --hinge-degrees 130 --screen-orientation landscape-left --output folded.png
```

The fold angle runs from 0 (closed) to 180 (flat). Below 90 degrees the
capture is placed on the cover; otherwise it goes on the inner display.
Supply a capture of that panel. This explicit pose does not infer simulator
state or reproduce hinge hysteresis. Short of shut, the cover faces away from
the default camera; turn the model toward it with `--rotation` (at 60°,
`--rotation 0,60,0`).

`--screen-orientation` names the interface orientation the capture was taken
in: `portrait`, `landscape-left`, `landscape-right` or `portrait-upside-down`.
The image is turned back onto the panel and the model rolled the way the
device was held, so the capture renders upright, on ordinary phone models too;
`--rotation` turns the model further. The canvas defaults to the capture's own
size, which then matches the render's shape. Without the flag the image is
placed as the panel's own buffer, as before. Both new flags require
`--screen`; `--hinge-degrees` also requires a model with a foldable scene.

On foldable models, `--screen-glass` applies only to the inner screen; it is
left out when `--hinge-degrees` below 90° selects the cover panel.

## Variants

Variants use one public set/choice vocabulary with two definition strategies:
`"kind": "usd"` (the default) authors a native USD variant selection, while
`"kind": "materials"` applies a declared map of authored material names to
hex colors, replacing the material's base texture so the declared finish is
exact rather than a tint multiplied into the original texture. The latter supports models such as Matte's iPhone 17 Pro, whose
Cosmic Orange, Deep Blue, and Silver appearances are material adjustments
rather than native USD variants. One model may expose independent finish,
keyboard, stand, Pencil, or other sets.

When a request omits a set, its declared default is applied. For a USD set, the
renderer creates a temporary USDA overlay that sublayers the USDZ and pins the
selection before RealityKit loads the scene. Material selections are applied to
the loaded entity tree. Changing a variant reloads that model; the UI renders on
control commit rather than on every pointer-move event.

Bundled local models currently cover iPhone 17, iPhone Air, iPhone 17 Pro,
iPhone 17 Pro Max, iPad Pro 11/13-inch M4, Apple Watch Series 11 42/46mm, and
Apple Watch Ultra 3. The MacBook Pro 14-inch definition demonstrates a
downloaded, SHA-256-verified model with a native USD finish variant.

## Adding a model

1. Create a model directory with `definition.json`.
2. Add a local `device.usdz`, or declare `downloadURL` and `sha256`.
3. Copy it into the application-support model directory or point
   `BAGUETTE_3D_MODEL_DIR` at its parent.
4. Render a known screenshot (`baguette render-3d --screen <png> --device <id>`)
   before adding simulator-name matching.

## Limits

- Model definitions depend on opaque node/material names that Apple may change
  when replacing an asset at the same URL; SHA-256 verification prevents an
  unnoticed replacement.
- Models without a declared and measurable screen surface cannot be used.
- USD variants are chosen before RealityKit loads the scene; changing them
  requires a model reload.
