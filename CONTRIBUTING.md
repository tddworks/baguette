# Contributing

## Requirements

Apple Silicon and **Xcode 26.4.1 or later**. baguette links Xcode's private `CoreSimulator` / `SimulatorKit` frameworks, so it builds and runs only where they exist. Earlier Xcode 26 Swift compilers have async stack-allocation bugs that crash `baguette serve` with `freed pointer was not the last allocation` ([#85](https://github.com/tddworks/baguette/issues/85)).

## Build & test

```bash
make                     # release build via ./build.sh → ./Baguette
./Injected/build.sh      # refresh the guest helpers before a direct swift build / test
swift build              # debug build (carries the MOCKING flag + mocks)
swift test               # the Swift Testing suite; no booted simulator needed
swift test --filter Simulators                   # one suite
swift test --filter "GestureRegistry/parses tap" # one test
make test-web            # JS unit tests for Resources/Web/ (node --test)
make docs                # regenerate docs/commands.md, docs/README.md, the skill references
make check-docs          # links, line budgets, changelog shape
make test-changelog      # the release-time changelog scripts
```

The build is hybrid: SPM fetches the dependencies (`ArgumentParser`, `Mockable`, `Hummingbird`, `HummingbirdWebSocket`) and compiles for `arm64e-apple-macos26.0` with an Objective-C bridging header, linking `CoreSimulator`, `SimulatorKit`, `IOSurface`, `VideoToolbox`, `CoreGraphics` and `ImageIO` from Xcode's private frameworks. `build.sh` builds the guest helpers and injected dylibs under `Injected/` first, then runs `swift build -c release`. A direct `swift build` or `swift test` after a change under `Injected/*/Sources` needs `./Injected/build.sh` first; SPM otherwise bundles the previously staged binaries.

## Troubleshooting the Homebrew install

If `brew install baguette` on an Apple Silicon Mac says:

```text
baguette requires Apple Silicon Homebrew running natively as arm64.

Your brew process is running under Rosetta 2, usually from Intel
Homebrew in /usr/local. Intel Homebrew cannot install baguette.
```

your `brew` is Intel Homebrew running under Rosetta 2 from `/usr/local`. Use native Homebrew instead:

```bash
/opt/homebrew/bin/brew install baguette
```

If that path doesn't exist, install native Apple Silicon Homebrew from https://brew.sh first, then run the command above.

## How code is organised

Three layers with imports flowing inward: `App/` (CLI + use-case orchestration) → `Domain/` (pure Swift value types and `@Mockable` abstractions) + `Infrastructure/` (the only place private-API code lives). `Domain/` and `Infrastructure/` split into the same bounded contexts, and `Tests/BaguetteTests/` mirrors them. The tap-to-`UITouch` path and the layer diagram are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Rules

- **TDD first, always.** Every behaviour change to a Domain or Infrastructure type starts with a failing `@Test`, then the smallest change that turns it green. The pre-implementation gate is in [AGENTS.md](AGENTS.md#tdd-is-non-negotiable-read-this-first).
- **Name abstractions for their role in the domain** (`Simulators`, `Input`, `Subprocess`), never `XxxPort` / `XxxService` / `XxxManager`. Details in [AGENTS.md](AGENTS.md#naming-the-abstractions).

## Testing

The rules — Swift Testing, never XCTest; Chicago-school, state-based; every boundary an `@Mockable` protocol faked with its generated `MockXxx` — are in [AGENTS.md](AGENTS.md#testing-approach), and apply to people as much as to agents. JS conventions for `Resources/Web/` are in [js-testing.md](.claude/skills/baguette-implement-feature/references/js-testing.md).

Adapters over private SimulatorKit / CoreSimulator / AccessibilityPlatformTranslation symbols take `any DeviceHost` rather than the concrete simulator aggregate, so their error paths (not booted, idempotent stop, host gone) are unit-tested via `MockDeviceHost` without a booted simulator. Only the irreducible private-API call stays integration-only, smoke-tested through the CLI and the `serve` UI against a booted simulator.

## Docs

Each fact has one home. Before changing a doc, find the change in the [update rules](docs/documentation-design/README.md#update-rules): a new flag touches nothing (`make docs` regenerates it), a new wire message touches [docs/wire.md](docs/wire.md), a new route [docs/serve.md](docs/serve.md), a new feature its own `docs/features/<x>/README.md`.
