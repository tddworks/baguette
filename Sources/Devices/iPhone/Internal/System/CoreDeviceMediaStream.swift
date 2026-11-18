import Foundation

/// `MediaStreamStarter` through CoreDevice: the phone as CoreDevice lists
/// it, asked to start its media stream. Integration-only.
struct CoreDeviceMediaStream: MediaStreamStarter {
    func start(on phone: UUID, request: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any] {
        guard let device = CoreDeviceFramework.device(phone) else { throw MediaStreamScreen.StreamError.notListed }
        return try device.startMediaStream(request)
    }
}
