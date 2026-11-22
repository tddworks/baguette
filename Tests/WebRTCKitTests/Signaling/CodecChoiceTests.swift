import Foundation
import Testing
@testable import WebRTCKit

/// Which codec a browser receives: H.265 only when its owner asked for it, the
/// offer carries Main-profile H.265 and the owner can send it; otherwise
/// High-profile H.264; neither, refused.
@Suite("CodecChoice")
struct CodecChoiceTests {
    static let highH264 = VideoCodec.h264(payloadType: 102, profileLevelID: "640c1f")
    static let baselineH264 = VideoCodec.h264(payloadType: 104, profileLevelID: "42e01f")
    static let mainH265 = VideoCodec.h265(payloadType: 49, profileID: 1, levelID: 93, tier: 0)
    static let main10H265 = VideoCodec.h265(payloadType: 51, profileID: 2, levelID: 93, tier: 0)
    static let both: Set<VideoCodec.Kind> = [.h264, .h265]

    @Test func `should send H.265 when asked for, offered in Main profile, and the owner can send it`() {
        #expect(CodecChoice.codec(asked: .h265, offered: [Self.highH264, Self.mainH265], sendable: Self.both) == Self.mainH265)
    }

    @Test func `should send H.264 to a browser asked for H.265 that doesn't offer it, never refusing it`() {
        #expect(CodecChoice.codec(asked: .h265, offered: [Self.highH264], sendable: Self.both) == Self.highH264)
    }

    @Test func `should send H.264 when the owner can't send H.265, whatever was asked`() {
        #expect(CodecChoice.codec(asked: .h265, offered: [Self.mainH265, Self.highH264], sendable: [.h264]) == Self.highH264)
    }

    @Test func `should choose H.265 for auto when the browser and the owner both can`() {
        #expect(CodecChoice.codec(asked: .auto, offered: [Self.highH264, Self.mainH265], sendable: Self.both) == Self.mainH265)
        #expect(CodecChoice.codec(asked: .auto, offered: [Self.highH264], sendable: Self.both) == Self.highH264)
    }

    @Test func `should send H.264 when nothing or H.264 is asked, though H.265 is offered`() {
        #expect(CodecChoice.codec(asked: nil, offered: [Self.mainH265, Self.highH264], sendable: Self.both) == Self.highH264)
        #expect(CodecChoice.codec(asked: .h264, offered: [Self.mainH265, Self.highH264], sendable: Self.both) == Self.highH264)
    }

    @Test func `should take only Main-profile H.265 and High-profile H.264`() {
        #expect(CodecChoice.codec(asked: .h265, offered: [Self.main10H265, Self.highH264], sendable: Self.both) == Self.highH264)
        #expect(CodecChoice.codec(asked: nil, offered: [Self.baselineH264, Self.highH264], sendable: Self.both) == Self.highH264)
    }

    @Test func `should refuse a browser that offers nothing the owner can send`() {
        #expect(CodecChoice.codec(asked: nil, offered: [Self.baselineH264], sendable: Self.both) == nil)
        #expect(CodecChoice.codec(asked: nil, offered: [Self.mainH265], sendable: Self.both) == nil)
        #expect(CodecChoice.codec(asked: .h265, offered: [Self.mainH265], sendable: [.h264]) == nil)
    }

    @Test func `should read what was asked as the switch spells it`() {
        #expect(CodecChoice(rawValue: "h265") == .h265)
        #expect(CodecChoice(rawValue: "h264") == .h264)
        #expect(CodecChoice(rawValue: "auto") == .auto)
        #expect(CodecChoice(rawValue: "vp9") == nil)
    }
}

/// A codec a browser offers, as a value: its kind, and the packetizer it takes.
@Suite("VideoCodec")
struct VideoCodecTests {
    @Test func `should cut each codec's pictures with its own packetizer`() {
        #expect(VideoCodec.h264(payloadType: 102, profileLevelID: "640c1f").packetizer is H264Packetizer)
        #expect(VideoCodec.h265(payloadType: 49, profileID: 1, levelID: 93, tier: 0).packetizer is H265Packetizer)
    }

    @Test func `should name its kind`() {
        #expect(VideoCodec.h264(payloadType: 102, profileLevelID: "640c1f").kind == .h264)
        #expect(VideoCodec.h265(payloadType: 49, profileID: 1, levelID: 93, tier: 0).kind == .h265)
    }
}
