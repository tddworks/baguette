import BaguetteDevice
import CoreVideo
import Foundation
import IOSurface

/// `Mirroring` through AVConference, in-process: its mode-5 negotiator for
/// the offer and answer, an `AVCVideoStream` run in this process on a
/// `LoopbackRelay`, its pictures pushed through a `DecodedPictureTap` and
/// made BGRA by `PictureConversion` on a queue of their own (the newest
/// waiting picture wins, so AVConference's thread is never held). Integration-only; what goes where is
/// `AVConferenceScreen`'s.
final class AVConferenceMirroring: Mirroring, @unchecked Sendable {
    /// CoreDevice's screen sharing, in AVConference's negotiator.
    private static let screenSharingMode = 5

    private let negotiator: AnyObject
    private let relay: LoopbackRelay
    private let conversion = PictureConversion()
    private let lock = NSLock()
    private var stream: AnyObject?
    private var tap: DecodedPictureTap?
    private let pictures = DispatchQueue(label: "baguette.avconference.pictures", qos: .userInteractive)
    private var waiting: CVPixelBuffer?

    init() throws {
        var error: NSError?
        guard let negotiator = AVConferenceRuntime.negotiator(mode: Self.screenSharingMode, error: &error) else {
            throw AVConferenceRefusal(step: "its negotiator", error: error)
        }
        self.negotiator = negotiator
        relay = try LoopbackRelay()
    }

    func offer() throws -> Data {
        guard AVConferenceRuntime.bool(negotiator, "createOffer"),
              let offer = AVConferenceRuntime.object(negotiator, "offer") as? Data
        else { throw AVConferenceRefusal(step: "the offer", error: nil) }
        return offer
    }

    func accept(answer: Data) throws {
        var error: NSError?
        guard AVConferenceRuntime.setAnswer(negotiator, answer, error: &error) else {
            throw AVConferenceRefusal(step: "the phone's answer", error: error)
        }
    }

    func start(croppedTo screen: Size?, onPicture: @escaping @Sendable (IOSurface) -> Void) throws {
        var error: NSError?
        guard let configuration = AVConferenceRuntime.generate(
                  negotiator, "generateMediaStreamConfigurationWithError:", error: &error),
              let generated = AVConferenceRuntime.generate(
                  negotiator, "generateMediaStreamInitOptionsWithError:", error: &error) as? NSDictionary
        else { throw AVConferenceRefusal(step: "the stream's configuration", error: error) }
        let options = NSMutableDictionary(dictionary: generated)
        options.addEntries(from: AVConferenceRuntime.negotiatorOptions as! [AnyHashable: Any])
        options["avcMediaStreamOptionRunInProcess"] = true
        let sockets = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_fd(sockets, "avcKeySharedSocket", relay.avconferenceEnd)

        guard let stream = AVConferenceRuntime.stream(sockets: sockets, options: options, error: &error),
              AVConferenceRuntime.configure(stream, configuration, error: &error)
        else { throw AVConferenceRefusal(step: "the in-process stream", error: error) }
        let tap = DecodedPictureTap(stream: stream) { [weak self] buffer in
            self?.decoded(buffer, croppedTo: screen, onPicture)
        }
        guard let tap else {
            throw AVConferenceRefusal(step: "its decoded pictures", error: nil)
        }
        AVConferenceRuntime.void(stream, "start")
        lock.withLock { self.stream = stream; self.tap = tap }
    }

    func deliver(_ datagram: Data) { relay.deliver(datagram) }

    func nextReport() -> Data? { relay.nextReport() }

    /// On AVConference's thread: keep the picture, and convert it on ours.
    private func decoded(_ buffer: CVPixelBuffer, croppedTo screen: Size?,
                         _ onPicture: @escaping @Sendable (IOSurface) -> Void) {
        let idle = lock.withLock { defer { waiting = buffer }; return waiting == nil }
        guard idle else { return }
        pictures.async { [self] in
            guard let picture = lock.withLock({ defer { waiting = nil }; return waiting }),
                  let surface = conversion.bgra(picture, croppedTo: screen)
            else { return }
            onPicture(surface)
        }
    }

    func stop() {
        let (stream, tap) = lock.withLock {
            defer { self.stream = nil; self.tap = nil }
            return (self.stream, self.tap)
        }
        tap?.close()
        if let stream { AVConferenceRuntime.void(stream, "stop") }
        relay.close()
    }
}
