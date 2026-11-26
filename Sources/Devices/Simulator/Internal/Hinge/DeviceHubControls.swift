import BaguetteDevice
import Foundation

/// `HingeMotor` through Device Hub's controls: the `DeviceHubControls`
/// program, kept serving in the guest, plays the hinge slider (`sweep <from>
/// <to> <ms>`) and the orientation picker (`orientation <native-value>`) as
/// Device Hub sends them (see `Injected/DeviceHubControls/Sources/main.m`).
/// The runtime folds, SpringBoard swaps panels, and `CoreMotionHinge` reads
/// the sweep back like any other.
final class DeviceHubControls: HingeMotor, @unchecked Sendable {
    private let session: SimctlSpawnSession

    init(session: SimctlSpawnSession) {
        self.session = session
    }

    /// One per device, however many displays and hinges ask for it.
    static func forDevice(_ udid: String, deviceSetPath: String? = nil, path: @escaping () -> String?) -> DeviceHubControls {
        DeviceHubControls(session: .forDevice(udid, deviceSetPath: deviceSetPath, program: "DeviceHubControls", path: path))
    }

    func fold(from: Double, to: Double, over duration: TimeInterval) throws {
        let line = "sweep \(SimctlSpawnSession.number(from)) \(SimctlSpawnSession.number(to)) \(SimctlSpawnSession.number(duration * 1000))"
        try play(line, playing: duration)
    }

    func turn(to orientation: DeviceOrientation) throws {
        let name: String
        // Native landscape labels are opposite the public home-button convention.
        switch orientation {
        case .portrait: name = "portrait"
        case .portraitUpsideDown: name = "pud"
        case .landscapeLeft: name = "landscape-right"
        case .landscapeRight: name = "landscape-left"
        }
        try play("orientation \(name)", playing: 0)
    }

    /// The hinge's own errors, which pose delivery and the routes read.
    private func play(_ line: String, playing duration: TimeInterval) throws {
        do {
            try session.send(line, playing: duration)
        } catch let error as InjectedProgramError {
            switch error {
            case .missing: throw HingeError.toolMissing
            case .failed(_, let status): throw HingeError.toolFailed(status: status)
            case .timedOut: throw HingeError.toolTimedOut
            case .startedLate: throw HingeError.toolStartedLate
            }
        }
    }
}
