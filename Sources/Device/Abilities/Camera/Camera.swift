import Foundation
import Mockable

/// What a device's apps see when they open the camera, fed by baguette
/// from a source — a webcam, an image, a video. A simulator has no camera
/// of its own, so it gets one by injection; a phone on a cable has a real
/// camera baguette can't feed, and has no `Camera` at all.
@Mockable
public protocol Camera: Sendable {
    /// The device it belongs to, for messages.
    var device: String { get }
    /// Apps launched from now on see the fed frames.
    func connect(dylibPath: String) async throws
    /// Apps launched from now on see no fed frames.
    func disconnect(dylibPath: String) async throws
}

public extension Ability where Role == any Camera {
    static var camera: Self { .init(name: "camera") }
}
