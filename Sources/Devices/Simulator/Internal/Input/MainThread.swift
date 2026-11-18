import BaguetteDevice
import Foundation

/// Build an Indigo message on the main thread — the call alone, not the
/// gesture around it. `IndigoHIDMessageForMouseNSEvent` reads AppKit's
/// thread-local event state, and a message built anywhere else is
/// malformed and silently dropped. Gestures themselves run on their
/// device's `GestureQueues` lane, so a drag's waits never hold the main
/// thread; only each build hops here. Already on it (a CLI command), the
/// build runs in place.
func onMainThread<T>(_ build: () -> T) -> T {
    if Thread.isMainThread { return build() }
    return DispatchQueue.main.sync(execute: build)
}
