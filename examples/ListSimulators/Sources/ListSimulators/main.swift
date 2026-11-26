import BaguetteKit

// Every simulator in Xcode's default device set, as `baguette list` shows
// them: one JSON line, each device with its kind, state and abilities.
let kinds = DeviceKinds(simulators: CoreSimulators())
print(kinds.simulators.listJSON)
