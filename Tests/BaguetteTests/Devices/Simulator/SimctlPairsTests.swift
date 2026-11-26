import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// `simctl list pairs -j` is the host's whole pairing table, not one
/// device's. A phone finds its watch by looking for the pair whose
/// phone side carries its own udid; every other row on the machine
/// belongs to somebody else's phone.
@Suite("SimctlPairs")
struct SimctlPairsTests {

    private let pairsJSON = """
        {
          "pairs" : {
            "5F1B0A00-0000-0000-0000-00000000AAAA" : {
              "watch" : {
                "name" : "Apple Watch Series 11 (46mm)",
                "udid" : "WATCH-1",
                "state" : "Booted"
              },
              "phone" : {
                "name" : "iPhone 17 Pro",
                "udid" : "PHONE-1",
                "state" : "Booted"
              },
              "state" : "(active, disconnected)"
            },
            "5F1B0A00-0000-0000-0000-00000000BBBB" : {
              "watch" : {
                "name" : "Apple Watch Ultra 3",
                "udid" : "WATCH-2",
                "state" : "Shutdown"
              },
              "phone" : {
                "name" : "iPhone 17",
                "udid" : "PHONE-2",
                "state" : "Shutdown"
              },
              "state" : "(active, disconnected)"
            }
          }
        }
        """

    @Test func `should find the watch paired with a phone in the host's pairs table`() {
        let watch = SimctlPairs.watch(pairedWith: "PHONE-2", in: pairsJSON)

        #expect(watch == PairedWatch(
            udid: "WATCH-2",
            name: "Apple Watch Ultra 3",
            state: .off
        ))
    }

    @Test func `should report a booted watch as booted`() {
        #expect(SimctlPairs.watch(pairedWith: "PHONE-1", in: pairsJSON)?.state == .ready)
    }

    @Test func `should find no watch when the phone is not paired`() {
        #expect(SimctlPairs.watch(pairedWith: "PHONE-3", in: pairsJSON) == nil)
    }

    @Test func `should find no watch when the pairs table is empty`() {
        #expect(SimctlPairs.watch(pairedWith: "PHONE-1", in: #"{"pairs":{}}"#) == nil)
    }

    @Test func `should find no watch when the output isn't JSON`() {
        #expect(SimctlPairs.watch(pairedWith: "PHONE-1", in: "xcrun: error: unable to find") == nil)
    }

    @Test func `should skip a pair that is missing either side`() {
        let partial = """
            {"pairs":{"P":{"phone":{"name":"iPhone 17","udid":"PHONE-1","state":"Booted"}}}}
            """
        #expect(SimctlPairs.watch(pairedWith: "PHONE-1", in: partial) == nil)
    }

    @Test func `should read an unrecognised watch state as shutdown`() {
        let odd = """
            {"pairs":{"P":{"phone":{"name":"iPhone","udid":"PHONE-1","state":"Booted"},
             "watch":{"name":"Apple Watch","udid":"WATCH-1","state":"Hibernating"}}}}
            """
        #expect(SimctlPairs.watch(pairedWith: "PHONE-1", in: odd)?.state == .off)
    }

    @Test func `should read back every simulator state from its printed name`() {
        for state in [
            SimulatorState.creating, .shutdown, .booting, .booted, .shuttingDown,
        ] {
            #expect(SimulatorState.named(state.description) == state)
        }
    }

    @Test func `should read the pairing table of the custom device set the phone lives in`() throws {
        let xcrun = try echoingXcrun()
        defer { try? FileManager.default.removeItem(at: xcrun.deletingLastPathComponent()) }
        #expect(try SimctlPairsCapture.list(deviceSetPath: "/custom set", xcrun: xcrun)
            == "simctl\n--set\n/custom set\nlist\npairs\n-j\n")
    }

    @Test func `should read the default pairing table when the phone lives in the default set`() throws {
        let xcrun = try echoingXcrun()
        defer { try? FileManager.default.removeItem(at: xcrun.deletingLastPathComponent()) }
        #expect(try SimctlPairsCapture.list(xcrun: xcrun) == "simctl\nlist\npairs\n-j\n")
    }

    /// A stand-in `xcrun` that prints its argv, one argument per line.
    private func echoingXcrun() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("xcrun")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
