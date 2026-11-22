import CoreMedia
import Testing
@testable import BaguetteDevice
import WebRTCKit

/// The codec a session was answered with, as baguette encodes it.
@Suite("Codecs")
struct CodecsTests {
    @Test func `should encode H.264 for a session answered with H.264`() {
        #expect(Codecs.of(.h264).codecType == kCMVideoCodecType_H264)
    }

    @Test func `should encode HEVC for a session answered with H.265`() {
        #expect(Codecs.of(.h265).codecType == kCMVideoCodecType_HEVC)
    }

    @Test func `should count a codec as encodable when this Mac has an encoder for it`() {
        #expect(Codecs.encodable(among: [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_JPEG]) == [.h264, .h265])
    }

    @Test func `should leave H.265 out when this Mac has no HEVC encoder`() {
        #expect(Codecs.encodable(among: [kCMVideoCodecType_H264]) == [.h264])
    }

    // A socket stream has no offer: the browser's ask (`?codec=`) and this Mac's encoders decide.
    @Test func `should encode a socket stream in HEVC when it asks for H.265 and this Mac can encode it`() {
        #expect(Codecs.asked(.h265, encodable: [.h264, .h265]).codecType == kCMVideoCodecType_HEVC)
        #expect(Codecs.asked(.auto, encodable: [.h264, .h265]).codecType == kCMVideoCodecType_HEVC)
    }

    @Test func `should encode a socket stream in H.264 when this Mac has no HEVC encoder`() {
        #expect(Codecs.asked(.h265, encodable: [.h264]).codecType == kCMVideoCodecType_H264)
    }

    @Test func `should encode a socket stream in H.264 when it asks for H.264 or nothing`() {
        #expect(Codecs.asked(.h264, encodable: [.h264, .h265]).codecType == kCMVideoCodecType_H264)
        #expect(Codecs.asked(nil, encodable: [.h264, .h265]).codecType == kCMVideoCodecType_H264)
    }
}
