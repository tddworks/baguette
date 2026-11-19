import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The named presets, pinned to Network Link Conditioner's own numbers.
///
/// Borrowing NLC's vocabulary *and* its figures is the point: `3g` then
/// means what every iOS developer already means by 3G, and nobody has to
/// defend a number baguette invented. These tests exist so the figures
/// can't drift silently — a preset quietly getting faster would make a
/// passing test suite while apps stopped being tested against 3G.
///
/// Two deliberate translations from NLC, both covered below:
///
/// - **NLC's delay is one-way.** A request pays it outbound and again
///   inbound, so a preset's `latencyMs` — which baguette applies once, before
///   the first byte — is twice NLC's figure.
/// - **NLC conditions uplink and downlink separately.** baguette paces the
///   response body only, so a preset carries NLC's *downlink* bandwidth.
@Suite("NetworkProfile")
struct NetworkProfileTests {

    @Test func `should pin every preset to Network Link Conditioner's numbers`() {
        // (profile, NLC downlink kbps, NLC one-way delay ms, loss %)
        let pinned: [(NetworkProfile, Double, Double, Double)] = [
            (.wifi, 40_000, 1, 0),
            (.dsl, 2_000, 5, 0),
            (.lte, 50_000, 65, 0),
            (.threeG, 780, 100, 0),
            (.edge, 240, 400, 0),
            (.veryBadNetwork, 1_000, 500, 10),
        ]
        for (profile, kbps, oneWayDelay, loss) in pinned {
            let condition = profile.condition
            #expect(condition.bandwidthKbps == kbps, "\(profile.rawValue) bandwidth")
            #expect(condition.latencyMs == oneWayDelay * 2, "\(profile.rawValue) latency")
            #expect(condition.lossPercent == loss, "\(profile.rawValue) loss")
            #expect(condition.isOffline == false, "\(profile.rawValue) offline")
        }
    }

    @Test func `should drop everything without going offline on the hundred percent loss preset`() {
        // NLC's "100% Loss" drops packets rather than reporting no
        // connection, so it stays a loss figure — an app that special-cases
        // "not connected to the internet" must not get that shortcut here.
        let condition = NetworkProfile.totalLoss.condition
        #expect(condition.lossPercent == 100)
        #expect(condition.isOffline == false)
    }

    @Test func `should name every preset in the vocabulary the CLI takes`() {
        #expect(NetworkProfile.threeG.rawValue == "3g")
        #expect(NetworkProfile.veryBadNetwork.rawValue == "very-bad-network")
        #expect(NetworkProfile.totalLoss.rawValue == "100-loss")
        #expect(NetworkProfile.wifi.rawValue == "wifi")
        #expect(NetworkProfile.dsl.rawValue == "dsl")
        #expect(NetworkProfile.lte.rawValue == "lte")
        #expect(NetworkProfile.edge.rawValue == "edge")
    }

    @Test func `should reject a profile nobody has heard of`() {
        // A silent fallback to some default would arm a condition the user
        // never asked for, and they'd spend the afternoon wondering why
        // their app was slow.
        #expect(NetworkProfile(rawValue: "2g") == nil)
        #expect(NetworkProfile(rawValue: "3G") == nil)
    }

    @Test func `should order the presets from worst network to best`() {
        // The ordering is the property that actually matters when someone
        // reaches for a preset: edge must hurt more than 3g, which must
        // hurt more than lte.
        let slowest = NetworkProfile.edge.condition
        let middle = NetworkProfile.threeG.condition
        let fastest = NetworkProfile.lte.condition
        #expect(slowest.latencyMs > middle.latencyMs)
        #expect(middle.latencyMs > fastest.latencyMs)
        #expect(slowest.bandwidthKbps! < middle.bandwidthKbps!)
        #expect(middle.bandwidthKbps! < fastest.bandwidthKbps!)
    }

    @Test func `should offer every preset for the CLI and the browser to list`() {
        #expect(NetworkProfile.allCases.count == 7)
    }

    @Test func `should recognise an applied condition as the preset it came from`() {
        // The card posts a preset's *name* and the device reports back
        // *numbers*, so without this the browser cannot tell that what is
        // applied is still the preset the user picked — and the pill it
        // lit deselects itself the moment the answer arrives.
        for profile in NetworkProfile.allCases {
            #expect(NetworkProfile.matching(profile.condition) == profile,
                    "\(profile.rawValue) unmatched")
        }
    }

    @Test func `should not mistake a hand-tuned condition for a preset`() {
        #expect(NetworkProfile.matching(
            NetworkCondition(latencyMs: 317, bandwidthKbps: 411, lossPercent: 3)!) == nil)
        #expect(NetworkProfile.matching(.unconditioned) == nil)
        #expect(NetworkProfile.matching(.offline) == nil)
    }
}
