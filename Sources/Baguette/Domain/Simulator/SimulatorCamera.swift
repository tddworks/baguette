import Foundation

/// A simulator's camera: VirtualCamera injected into what it launches next.
struct SimulatorCamera: Camera {
    let simulator: any Simulator
    let injection: any SimulatorInjection

    var device: String { simulator.udid }

    func connect(dylibPath: String) async throws {
        try await injection.arm(dylibPath: dylibPath, on: simulator)
    }

    func disconnect(dylibPath: String) async throws {
        try await injection.disarm(dylibPath: dylibPath, on: simulator)
    }
}
