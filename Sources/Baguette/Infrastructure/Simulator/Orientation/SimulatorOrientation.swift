import Foundation

/// Foldable simulators consume Device Hub pose events; other devices use Purple.
final class SimulatorOrientation: Orientation, @unchecked Sendable {
    private let isFoldable: () throws -> Bool
    private let motor: any HingeMotor
    private let standard: any Orientation

    init(isFoldable: @escaping () throws -> Bool, motor: any HingeMotor, standard: any Orientation) {
        self.isFoldable = isFoldable
        self.motor = motor
        self.standard = standard
    }

    func set(_ orientation: DeviceOrientation) -> PoseDelivery {
        do {
            guard try isFoldable() else { return standard.set(orientation) }
            try motor.turn(to: orientation)
            return .delivered
        } catch {
            let delivery = PoseDelivery(failure: error)
            logErr("Orientation change \(delivery == .unconfirmed ? "unconfirmed" : "failed"): \(error)")
            return delivery
        }
    }
}
