// The library's one public face. A host imports `BaguetteKit` and gets the
// device model (`Device`, its `Abilities`, `Devices`) and every device
// family (`DeviceKinds`, `CoreSimulators`, …) — the same code `baguette`
// and `baguette serve` run, without the CLI or the HTTP server.
@_exported import BaguetteDevice
@_exported import BaguetteDeviceFamilies
