import Foundation
import ReplayKit
import TwinWire

/// The broadcast upload extension: receives system-wide screen sample
/// buffers, speaks the twin protocol to the baguette host configured
/// by the companion app through the shared App Group.
final class SampleHandler: RPBroadcastSampleHandler {
    private var transport: TwinTransport?
    private var sender: H264Sender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let defaults = UserDefaults(suiteName: TwinWire.appGroup)
        guard let endpoint = defaults?.string(forKey: TwinWire.endpointKey)
                  .map(TwinWire.normalizedEndpoint),
              let url = URL(string: "ws://\(endpoint)/devices/companion/video") else {
            finishBroadcastWithError(NSError(
                domain: "baguette.twin", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Set the Mac's address in the Baguette Twin app first."]
            ))
            return
        }
        let deviceId = defaults?.string(forKey: TwinWire.deviceIdKey) ?? "unknown-device"
        let transport = TwinTransport(url: url)
        transport.connect()
        transport.send(text: TwinWire.hello(
            udid: deviceId,
            name: UIDevice.current.name,
            model: UIDevice.current.model,
            capabilities: ["screen"]
        ))
        self.transport = transport
        self.sender = H264Sender(transport: transport)
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }
        sender?.encode(sampleBuffer, orientation: Self.orientation(of: sampleBuffer))
    }

    override func broadcastFinished() {
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
