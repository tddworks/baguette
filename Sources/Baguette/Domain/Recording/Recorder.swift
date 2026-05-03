import Foundation

/// Records the simulator's framebuffer to a playable file. Owns its own
/// `Screen` subscription so the recording is independent of whatever
/// wire format (MJPEG / AVCC) the live stream is currently using. Two
/// parallel screen subscribers see the same `IOSurface` callbacks and
/// can paint / encode the frames on their own cadences.
///
/// Lifecycle:
///   start(on:)  — wire up the screen, prepare the writer; first
///                 surface seeds the file's dimensions.
///   stop()      — finalise the writer; returns the produced artifact
///                 (URL + duration + bytes). May suspend while the
///                 writer flushes the moov atom.
///   cancel()    — abort without producing a usable artifact; partial
///                 file may remain on disk for debugging.
///
/// All implementations are thread-safe — `Server` calls these from the
/// WS task while the screen callback runs on its own queue.
protocol Recorder: AnyObject, Sendable {
    func start(on screen: any Screen) throws
    func stop() async throws -> RecordingArtifact
    func cancel()
}
