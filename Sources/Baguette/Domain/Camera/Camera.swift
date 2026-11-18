import Foundation
import Mockable

/// What a device's apps see when they open the camera, fed by baguette
/// from a source — a webcam, an image, a video. A simulator has no camera
/// of its own, so it gets one by injection; a phone on a cable has a real
/// camera baguette can't feed, and has no `Camera` at all.
@Mockable
protocol Camera: Sendable {
    /// The device it belongs to, for messages.
    var device: String { get }
    /// Apps launched from now on see the fed frames.
    func connect(dylibPath: String) async throws
    /// Apps launched from now on see no fed frames.
    func disconnect(dylibPath: String) async throws
}

extension Ability where Role == any Camera {
    static var camera: Self { .init(name: "camera") }
}

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
