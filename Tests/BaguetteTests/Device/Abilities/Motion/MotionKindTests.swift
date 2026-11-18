import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `MotionKind` — the classification an app reads
/// back as `CMMotionActivity`.
///
/// The device never tells us what it's doing; a walk vector does. The
/// browser's Walk mode already asks the question in the user's language —
/// its speed presets are `Walk 1.4 · Run 3.5 · Cycle 6 · Drive 13.4 ·
/// Highway 29` (m/s) — so the classification is pinned to those presets
/// rather than invented. If a preset ever stops classifying as its own
/// label, the thresholds have drifted and these tests say so.
///
/// The frontend stays a dumb sender: it keeps posting the same walk
/// vector it always did, and the speed is classified here.
@Suite("MotionKind")
struct MotionKindTests {

    @Test func `should classify each of the browser's speed presets as its own label`() {
        #expect(MotionKind.from(speed: 1.4) == .walking)
        #expect(MotionKind.from(speed: 3.5) == .running)
        #expect(MotionKind.from(speed: 6) == .cycling)
        #expect(MotionKind.from(speed: 13.4) == .automotive)
        #expect(MotionKind.from(speed: 29) == .automotive)
    }

    @Test func `should read a standstill as stationary`() {
        // Releasing the joystick pins the device — `location set` reports
        // `speed,-1 course,-1`, and the app should see "not moving".
        #expect(MotionKind.from(speed: 0) == .stationary)
    }

    @Test func `should treat a negative speed as unknown, not as a standstill`() {
        // CoreLocation spells "I don't know the speed" as -1. That is not
        // the same claim as "the device is still", and an app that gates on
        // `stationary` deserves the difference.
        #expect(MotionKind.from(speed: -1) == .unknown)
    }

    @Test func `should keep a slow drift stationary rather than calling it a walk`() {
        // Dead-reckoning jitter around the pin shouldn't read as walking.
        #expect(MotionKind.from(speed: 0.1) == .stationary)
    }

    /// These five numbers are **measured**, not documented: the private
    /// `CLMotionActivity.type` field was swept 0…9 against a booted iOS
    /// 26.5 / 27.0 runtime and the public `CMMotionActivity` flags read
    /// back. They live here, under test, so the injected dylib never has
    /// to know them — it copies the number it is handed.
    ///
    /// The enum is not dense: `2` also reads as stationary, and `3` / `7` /
    /// `9` read as no flags at all. Only the values below are trusted.
    @Test func `should carry the measured Core Motion activity type for each kind`() {
        #expect(MotionKind.unknown.coreMotionType == 0)
        #expect(MotionKind.stationary.coreMotionType == 1)
        #expect(MotionKind.walking.coreMotionType == 4)
        #expect(MotionKind.automotive.coreMotionType == 5)
        #expect(MotionKind.cycling.coreMotionType == 6)
        #expect(MotionKind.running.coreMotionType == 8)
    }

    @Test func `should never map a kind onto one of the untrusted activity type values`() {
        // 2 / 3 / 7 / 9 exist in the enum but either duplicate another
        // state or read as nothing. If a future kind lands on one of them
        // that's a mapping bug, not a new capability.
        let untrusted: Set<Int32> = [2, 3, 7, 9]
        for kind in MotionKind.allCases {
            #expect(!untrusted.contains(kind.coreMotionType))
        }
    }
}
