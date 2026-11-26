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

3D device renders, the injected camera, motion and network dylibs, and the
iPhone Duo hinge helper read files the CLI keeps in its resource bundle.
A library has no bundle: copy the folders you need from
`Sources/Baguette/Resources/` (`Models3D/`, `VirtualCamera/`, …) into one
folder you ship, and name it before driving a device:

```swift
BaguetteResources.use(folder: URL(fileURLWithPath: "/path/to/baguette-resources"))
```
