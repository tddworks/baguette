import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Pure-value coverage for `InjectedDylibs` — the contents of a
/// simulator's `DYLD_INSERT_LIBRARIES`.
///
/// The problem this value exists to solve: that env var is **one string
/// for the whole simulator**, and baguette now has more than one feature
/// that wants a dylib inside apps (the virtual camera, and motion). The
/// old code wrote a single path and unset the whole variable on teardown,
/// so a second feature arming would silently disarm the first, and either
/// one stopping would disarm the other.
///
/// Merging is modelled as a value so the arithmetic is tested here and the
/// adapter stays a thin read-modify-write around `launchctl`.
@Suite("InjectedDylibs")
struct InjectedDylibsTests {

    private let camera = "/Users/x/Library/Application Support/Baguette/builds/abc123/VirtualCamera.dylib"
    private let motion = "/Users/x/Library/Application Support/Baguette/builds/def456/BaguetteMotion.dylib"

    @Test func `should treat a missing or empty value as nothing armed`() {
        #expect(InjectedDylibs.parsing(nil).isEmpty)
        #expect(InjectedDylibs.parsing("").isEmpty)
        #expect(InjectedDylibs.parsing("   \n").isEmpty)
        #expect(InjectedDylibs.parsing(nil).environmentValue == "")
    }

    @Test func `should read a colon-joined value as several dylibs`() {
        let dylibs = InjectedDylibs.parsing("\(camera):\(motion)")
        #expect(dylibs.paths == [camera, motion])
    }

    @Test func `should ignore empty segments and surrounding whitespace`() {
        // `launchctl getenv` output arrives with a trailing newline, and a
        // stray colon shouldn't become an empty dylib path that dyld then
        // complains about.
        let dylibs = InjectedDylibs.parsing(" \(camera)::\(motion) \n")
        #expect(dylibs.paths == [camera, motion])
    }

    @Test func `should arm a second dylib alongside the first`() {
        // The headline: turning on motion must not turn off the camera.
        let dylibs = InjectedDylibs.parsing(camera).adding(motion)
        #expect(dylibs.paths == [camera, motion])
        #expect(dylibs.environmentValue == "\(camera):\(motion)")
    }

    @Test func `should replace an earlier build of the same dylib rather than stack it`() {
        // Every release installs under a fresh sha-keyed directory (iOS 26's
        // dyld page-hash cache rejects a replaced dylib at the same path),
        // so the same dylib legitimately arrives under a new path. Two
        // copies of one dylib in dyld's list is a load error, not a merge.
        let older = "/Users/x/Library/Application Support/Baguette/builds/000aaa/VirtualCamera.dylib"
        let dylibs = InjectedDylibs.parsing(older).adding(camera)
        #expect(dylibs.paths == [camera])
    }

    @Test func `should change nothing when the same path is armed twice`() {
        let dylibs = InjectedDylibs.parsing(camera).adding(camera)
        #expect(dylibs.paths == [camera])
    }

    @Test func `should disarm one dylib and leave the others armed`() {
        let dylibs = InjectedDylibs.parsing("\(camera):\(motion)").removing(camera)
        #expect(dylibs.paths == [motion])
        #expect(!dylibs.isEmpty)
    }

    @Test func `should be empty once the last dylib is disarmed`() {
        // Empty is what tells the adapter to `unsetenv` rather than set an
        // empty string — dyld treats an empty entry as a path it can't load.
        let dylibs = InjectedDylibs.parsing(camera).removing(camera)
        #expect(dylibs.isEmpty)
    }

    @Test func `should preserve a dylib baguette did not arm`() {
        // Someone may have armed their own dylib by hand. Read-modify-write
        // means we must hand it back untouched rather than clobbering it.
        let theirs = "/opt/theirs/Instrument.dylib"
        let dylibs = InjectedDylibs.parsing("\(theirs):\(camera)").removing(camera)
        #expect(dylibs.paths == [theirs])
    }

    @Test func `should keep only absolute dylib paths when the value is polluted with log noise`() {
        // Not hypothetical: a simulator's stdout channel carries leftover
        // output from *previously* spawned processes, so
        // `simctl spawn … launchctl getenv` can hand back log lines — even
        // truncated mid-line — with the real value appended. Captured
        // verbatim from a booted iOS 26.5 sim with an injected dylib loaded.
        //
        // Parsing that naively would write the noise back into
        // DYLD_INSERT_LIBRARIES, and it would grow on every arm.
        let polluted = """
            2026-08-17 21:50:52.592 launchctl[34422:19519657] [VirtualMotion] activity hooks installed
            2026-08-17 21:50:36.156 launchctl[33979:\(motion)
            """
        #expect(InjectedDylibs.parsing(polluted).paths == [motion])
    }

    @Test func `should ignore a relative path`() {
        // dyld needs an absolute path, and a bare word is far more likely to
        // be noise than a library anyone meant to inject.
        #expect(InjectedDylibs.parsing("VirtualCamera.dylib").isEmpty)
    }

    @Test func `should ignore a path that is not a dylib`() {
        #expect(InjectedDylibs.parsing("/usr/lib/thing.txt").isEmpty)
    }

    @Test func `should disarm a dylib by its file name whatever folder it sits in`() {
        // The sha-keyed install directory differs per release; the filename
        // is what identifies the feature's dylib.
        #expect(InjectedDylibs.parsing(camera).removing(
            "/somewhere/else/VirtualCamera.dylib").isEmpty)
    }
}
