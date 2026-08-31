import Foundation

/// The per-device registry of twin ingest hubs, held by `Server` the
/// way `MotionSessions` is: the one piece of device-twin state that
/// must survive between socket connections. A companion's video socket
/// opens its device's hub; browser stream sockets find it; the video
/// socket closing tears it down. Reconnects replace the hub — the old
/// decoder session belongs to the dead connection.
final class TwinScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var hubs: [String: TwinScreen] = [:]
    private let makeDecoder: @Sendable () -> any H264Decoder

    init(makeDecoder: @escaping @Sendable () -> any H264Decoder = { VTH264Decoder() }) {
        self.makeDecoder = makeDecoder
    }

    func open(udid: String) -> TwinScreen {
        let hub = TwinScreen(decoder: makeDecoder())
        lock.lock()
        let replaced = hubs[udid]
        hubs[udid] = hub
        lock.unlock()
        replaced?.close()
        return hub
    }

    func find(udid: String) -> TwinScreen? {
        lock.lock()
        defer { lock.unlock() }
        return hubs[udid]
    }

    func close(udid: String) {
        lock.lock()
        let hub = hubs.removeValue(forKey: udid)
        lock.unlock()
        hub?.close()
    }
}
