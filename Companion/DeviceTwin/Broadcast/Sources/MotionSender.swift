import CoreMotion
import Foundation
import TwinWire
import UIKit

/// Streams the phone's attitude to the host's motion socket while the
/// broadcast runs. Lives in the broadcast EXTENSION, not the app, so
/// the gyro keeps flowing when the user backgrounds the companion —
/// the twin is on screen exactly while the mirror is. Rides its own
/// socket per the separate-sockets rule: video bursts must never
/// delay a 16-byte pose sample.
final class MotionSender {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let transport: TwinTransport

    init?(endpoint: String, deviceId: String) {
        guard let url = URL(string: "ws://\(endpoint)/devices/companion/motion") else {
            return nil
        }
        transport = TwinTransport(url: url)
        transport.connect()
        transport.send(text: TwinWire.hello(
            udid: deviceId,
            name: UIDevice.current.name,
            model: TwinWire.hardwareIdentifier,
            capabilities: ["motion"]
        ))
    }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            NSLog("BaguetteTwin motion unavailable on this device")
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        // `.xArbitraryZVertical`: no compass dependency; the slow yaw
        // drift is corrected by the stage's re-zero.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [transport] motion, _ in
            guard let q = motion?.attitude.quaternion,
                  let timestamp = motion?.timestamp else { return }
            transport.send(text: TwinWire.attitude(
                x: q.x, y: q.y, z: q.z, w: q.w, timestamp: timestamp
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        transport.close()
    }
}
