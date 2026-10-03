import Foundation

/// Production `ExternalDisplays` — clicks the host panel only when
/// CarPlay/TVOut is absent. A Connected Screens hit is enough to skip;
/// black-framebuffer recovery is a separate panel cycle (Disabled →
/// CarPlay) invoked explicitly when capture detects a wedge.
final class HostExternalDisplays: ExternalDisplays, @unchecked Sendable {
    private let panel: any ExternalDisplayPanel
    private let enumerateIO: () throws -> String
    private let lock = NSLock()
    private var enabledAfterSuccess = false

    init(
        panel: any ExternalDisplayPanel = SimulatorMenuExternalDisplayPanel(),
        enumerateIO: @escaping () throws -> String
    ) {
        self.panel = panel
        self.enumerateIO = enumerateIO
    }

    convenience init(udid: String, deviceSetPath: String? = nil) {
        self.init(enumerateIO: { try SimctlCapture.enumerate(udid: udid, deviceSetPath: deviceSetPath) })
    }

    var isCarPlayConnected: Bool {
        if let text = try? enumerateIO(),
            SimctlIOEnumerate.isCarPlayConnected(text)
        {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        return enabledAfterSuccess
    }

    func enableCarPlay() throws {
        if isCarPlayConnected { return }
        try panel.enableCarPlay()
        lock.lock()
        enabledAfterSuccess = true
        lock.unlock()
    }

    /// Deliberately does not consult the probe — see `ExternalDisplays`.
    /// The cached `enabledAfterSuccess` is reset first so a cycle that
    /// silently attaches nothing can't leave the probe insisting a
    /// display is there on the strength of a previous success.
    func reattachCarPlay() throws {
        lock.lock()
        enabledAfterSuccess = false
        lock.unlock()
        try panel.recoverCarPlay()
        lock.lock()
        enabledAfterSuccess = true
        lock.unlock()
    }
}
