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
    // Serial and userInitiated (the Arvos configuration): the default
    // queue competes with the extension's encode work and delivery
    // gaps were measured at 200+ ms on device.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let transport: TwinTransport

    init?(endpoint: String, deviceId: String) {
        guard let url = URL(string: "ws://\(endpoint)/devices/\(deviceId)/companion/motion") else {
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
        // Build marker so Console.app settles "is the new sender
        // running?" — cadence numbers alone cannot.
        NSLog("BaguetteTwin motion sender v3: 100 Hz, windowed sends")
        guard manager.isDeviceMotionAvailable else {
            NSLog("BaguetteTwin motion unavailable on this device")
            return
        }
        // 100 Hz: a denser trajectory for the host to interpolate —
        // the coalescing transport drops what the link can't carry,
        // and dropped samples cost nothing (each carries its timestamp).
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        // `.xArbitraryZVertical`: no compass dependency; the slow yaw
        // drift is corrected by the stage's re-zero.
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) {
            [transport] motion, _ in
            guard let q = motion?.attitude.quaternion,
                  let timestamp = motion?.timestamp else { return }
            transport.send(coalescedText: TwinWire.attitude(
                x: q.x, y: q.y, z: q.z, w: q.w, timestamp: timestamp
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        transport.close()
    }
}
