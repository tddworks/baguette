import Foundation

/// Version 2 retains the AVCC tag and binds each visual payload to its render.
enum DeviceAVCCEnvelope {
    static let maximumPayloadBytes = 16 * 1024 * 1024

    static func description(_ avcc: Data) throws -> Data {
        try packet(metadata: ["version": 2, "type": "description"], tag: AVCCEnvelope.descriptionTag, payload: avcc)
    }

    static func frame(frameID: Int, placement: DeviceFramePlacement?, tag: UInt8, payload: Data) throws -> Data {
        guard frameID > 0, frameID <= 9_007_199_254_740_991,
            [AVCCEnvelope.keyframeTag, AVCCEnvelope.deltaTag, AVCCEnvelope.seedTag].contains(tag)
        else { throw DeviceModelError.renderFailed }
        if tag == AVCCEnvelope.seedTag {
            guard payload.count >= 4, payload.prefix(2) == Data([0xff, 0xd8]),
                payload.suffix(2) == Data([0xff, 0xd9])
            else { throw DeviceModelError.renderFailed }
        }
        var metadata: [String: Any] = ["version": 2, "type": "frame", "frameId": frameID, "placement": NSNull()]
        if let placement { metadata["placement"] = placement.json }
        return try packet(metadata: metadata, tag: tag, payload: payload)
    }

    private static func packet(metadata: [String: Any], tag: UInt8, payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count < maximumPayloadBytes else { throw DeviceModelError.renderFailed }
        let json = try JSONSerialization.data(withJSONObject: metadata)
        guard json.count <= DeviceFrameEnvelope.maximumMetadataBytes else { throw DeviceModelError.renderFailed }
        let count = UInt32(json.count)
        var result = Data([
            UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        result.append(json)
        result.append(tag)
        result.append(payload)
        return result
    }
}
