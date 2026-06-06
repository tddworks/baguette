import Testing
@testable import BaguetteNetKit

@Suite("NetworkProfile")
struct NetworkProfileTests {
    @Test("clamps packet loss into 0…1 and floors negative latency")
    func clamps() {
        #expect(NetworkProfile(latencyMillis: -10, packetLoss: 2.5).packetLoss == 1.0)
        #expect(NetworkProfile(packetLoss: -1).packetLoss == 0.0)
        #expect(NetworkProfile(latencyMillis: -10).latencyMillis == 0)
    }

    @Test("zero bandwidth + zero latency + zero loss is unthrottled")
    func unthrottled() {
        #expect(NetworkProfile.unthrottled.isUnthrottled)
        #expect(!NetworkProfile(latencyMillis: 50).isUnthrottled)
    }

    @Test("100% loss reads as offline")
    func offline() {
        #expect(NetworkProfile.presets["airplane"]!.isOffline)
        #expect(!NetworkProfile.presets["3g"]!.isOffline)
    }

    @Test("3g preset resolves to its documented three fields")
    func preset3g() {
        let p = NetworkProfile.presets["3g"]!
        #expect(p.bandwidthInBytes == 97_500)
        #expect(p.latencyMillis == 300)
        #expect(p.packetLoss == 0)
    }
}

@Suite("ThrottleEngine")
struct ThrottleEngineTests {
    @Test("unlimited profile allows every chunk")
    func unlimitedAllows() {
        let e = ThrottleEngine(profile: .unthrottled)
        #expect(e.verdict(forBytes: 1000, totalBytesSoFar: 1000) == .allow)
    }

    @Test("offline profile drops")
    func offlineDrops() {
        let e = ThrottleEngine(profile: NetworkProfile(packetLoss: 1))
        #expect(e.verdict(forBytes: 1, totalBytesSoFar: 1) == .drop)
    }

    @Test("bandwidth pauses for total bytes ÷ rate plus first-chunk latency")
    func pausesByBandwidth() {
        // 10_000 bytes at 10_000 B/s = 1s transmit, +0.5s latency on the
        // first chunk = 1.5s.
        let e = ThrottleEngine(profile: NetworkProfile(bandwidthInBytes: 10_000, latencyMillis: 500))
        #expect(e.verdict(forBytes: 10_000, totalBytesSoFar: 10_000) == .pause(seconds: 1.5))
    }

    @Test("latency-only profile pauses on the first chunk, then allows")
    func latencyOnly() {
        let e = ThrottleEngine(profile: NetworkProfile(latencyMillis: 200))
        #expect(e.verdict(forBytes: 100, totalBytesSoFar: 100) == .pause(seconds: 0.2))
        #expect(e.verdict(forBytes: 100, totalBytesSoFar: 300) == .allow)
    }
}

@Suite("PacketLossGate")
struct PacketLossGateTests {
    @Test("25% loss drops every 4th packet")
    func quarterLoss() {
        let g = PacketLossGate(packetLoss: 0.25)
        let dropped = (0..<8).map { g.shouldDrop(index: $0) }
        #expect(dropped == [false, false, false, true, false, false, false, true])
    }

    @Test("zero loss never drops, full loss always drops")
    func edges() {
        #expect(!PacketLossGate(packetLoss: 0).shouldDrop(index: 99))
        #expect(PacketLossGate(packetLoss: 1).shouldDrop(index: 0))
    }
}
