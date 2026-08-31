import Foundation
import ReplayKit
import TwinWire

/// The broadcast upload extension: receives system-wide screen sample
/// buffers, speaks the twin protocol to the baguette host configured
/// by the companion app through the shared App Group.
final class SampleHandler: RPBroadcastSampleHandler {
    private var transport: TwinTransport?
    private var sender: H264Sender?
    private var motion: MotionSender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = UserDefaults(suiteName: TwinWire.appGroup)
        let deviceId = defaults?.string(forKey: TwinWire.deviceIdKey) ?? "unknown-device"
        guard let endpoint = defaults?.string(forKey: TwinWire.endpointKey)
                  .map(TwinWire.normalizedEndpoint),
              let url = URL(string: "ws://\(endpoint)/devices/\(deviceId)/companion/video") else {
            finishBroadcastWithError(NSError(
                domain: "baguette.twin", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Set the Mac's address in the Baguette Twin app first."]
            ))
            return
        }
        NSLog("BaguetteTwin broadcast started → %@", url.absoluteString)
        let transport = TwinTransport(url: url)
        transport.connect()
        transport.send(text: TwinWire.hello(
            udid: deviceId,
            name: UIDevice.current.name,
            model: TwinWire.hardwareIdentifier,
            capabilities: ["screen"]
        ))
        self.transport = transport
        self.sender = H264Sender(transport: transport)
        // The gyro rides its own socket so video bursts never delay a
        // pose sample; endpoint is the bare host:port saved by the app.
        let bareEndpoint = TwinWire.normalizedEndpoint(
            defaults?.string(forKey: TwinWire.endpointKey) ?? ""
        )
        self.motion = MotionSender(endpoint: bareEndpoint, deviceId: deviceId)
        self.motion?.start()
    }

    private var sampleCount = 0

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }
        sampleCount += 1
        if sampleCount == 1 || sampleCount % 300 == 0 {
            NSLog("BaguetteTwin broadcast sample #%d", sampleCount)
        }
        let encoderAlive = sender?.encode(
            sampleBuffer, orientation: Self.orientation(of: sampleBuffer)
        ) ?? false
        if !encoderAlive {
            finishBroadcastWithError(NSError(
                domain: "baguette.twin", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "This device refused a hardware H.264 encoder for the broadcast."]
            ))
        }
    }

    override func broadcastPaused() {
        NSLog("BaguetteTwin broadcast paused at sample %d", sampleCount)
    }

    override func broadcastResumed() {
        NSLog("BaguetteTwin broadcast resumed")
    }

    override func broadcastFinished() {
        NSLog("BaguetteTwin broadcast finished after %d samples", sampleCount)
        motion?.stop()
        sender?.finish()
        transport?.close()
    }

    /// ReplayKit stamps each buffer with a `CGImagePropertyOrientation`
    /// raw value; the wire speaks `DeviceOrientation` names.
    private static func orientation(of sampleBuffer: CMSampleBuffer) -> String {
        guard let raw = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber else { return "portrait" }
        switch raw.uint32Value {
        case 3:      return "portrait-upside-down" // .down
        case 6:      return "landscape-right"      // .right
        case 8:      return "landscape-left"       // .left
        default:     return "portrait"             // .up and friends
        }
    }
}
