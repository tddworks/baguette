# ListSimulators

A package that drives Baguette as a library: it depends on the `BaguetteKit`
product, not the `baguette` CLI, and prints this Mac's simulators.

```sh
cd examples/ListSimulators
swift run
```

To depend on Baguette from your own package:

```swift
.package(url: "https://github.com/tddworks/baguette", from: "<version>"),
// …
.product(name: "BaguetteKit", package: "baguette"),
```

A phone on a cable shows as devicectl stills with no touch. To drive it
live, add the `BaguetteCoreDevice` product and pass `coreDevice: .live` to
`DeviceKinds`. That product weak-links Xcode's CoreDevice with linker flags
SwiftPM accepts only from a dependency pinned by revision, branch or path:

```swift
.package(url: "https://github.com/tddworks/baguette", revision: "<commit>"),
```

3D device renders and the iPhone Duo hinge read files the CLI keeps in its
resource bundle. A library has no bundle: ship your own copies from
`Sources/Baguette/Resources/` and hand each to what uses it:

```swift
// HingeControl, the guest helper: the hinge, a foldable's keys, the frontmost app.
let simulators = CoreSimulators(hingeControl: shipped.appending(path: "HingeControl/HingeControl"))
// The 3D models, for a render of the device.
let models = try LiveDeviceModels(rootURLs: [shipped.appending(path: "Models3D")])
```
