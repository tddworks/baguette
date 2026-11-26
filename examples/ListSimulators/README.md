# ListSimulators

A package that drives Baguette as a library: it depends on the `BaguetteKit`
product, not the `baguette` CLI, and prints this Mac's simulators.

```sh
cd examples/ListSimulators
swift run
```

To depend on Baguette from your own package:

```swift
.package(url: "https://github.com/tddworks/baguette", revision: "<commit>"),
// …
.product(name: "BaguetteKit", package: "baguette"),
```

Pin a revision, not a version: the device families link CoreDevice with
linker flags SwiftPM only accepts from a package depended on by revision,
branch or local path.
