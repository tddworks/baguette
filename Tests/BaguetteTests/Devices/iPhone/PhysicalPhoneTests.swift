import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("PhysicalPhone")
struct PhysicalPhoneTests {
    @Test func `should list a paired phone on a cable as ready`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone()]))

        #expect(phones == [PhysicalPhone(
            udid: "00008160-001239C43AA0000A", name: "han's iPhone",
            productType: "iPhone19,7", marketingName: "iPhone 18 Pro Max",
            platform: .iOS, state: .ready,
            coreDeviceIdentifier: UUID(uuidString: "30546CC9-90DC-5F06-87D3-42D2C2E913D1"),
            osVersion: "27.0.1")])
    }

    @Test func `should know a connected phone's tunnel address`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone(tunnel: "connected", tunnelAddress: "fdd3:48cf:f69f::1")]))

        #expect(phones.first?.tunnelAddress == "fdd3:48cf:f69f::1")
    }

    @Test func `should know no tunnel address while the tunnel is down`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone()]))

        #expect(phones.first?.tunnelAddress == nil)
    }

    @Test func `should leave simulators out of the physical phones`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([simulator(), phone()]))

        #expect(phones.map(\.udid) == ["00008160-001239C43AA0000A"])
    }

    @Test func `should read a phone CoreDevice can't reach as unavailable`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone(tunnel: "unavailable")]))

        #expect(phones.first?.state == .unavailable(reason: "not connected"))
    }

    @Test func `should read an unpaired phone as unavailable`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone(pairing: "unpaired")]))

        #expect(phones.first?.state == .unavailable(reason: "not paired with this Mac"))
    }

    @Test func `should read a phone with Developer Mode off as unavailable`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone(developerMode: "disabled")]))

        #expect(phones.first?.state == .unavailable(reason: "Developer Mode is off"))
    }

    @Test func `should read a phone that is still booting as starting`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([phone(boot: "booting")]))

        #expect(phones.first?.state == .starting)
    }

    @Test func `should read an iPad's platform as iOS and a watch's as watchOS`() throws {
        let phones = try PhysicalPhone.list(fromDevicectlJSON: listing([
            phone(udid: "IPAD", platform: "iOS"), phone(udid: "WATCH", platform: "watchOS"),
        ]))

        #expect(phones.map(\.platform) == [.iOS, .watchOS])
    }

    @Test func `should refuse output that isn't devicectl's device list`() {
        #expect(throws: (any Error).self) {
            try PhysicalPhone.list(fromDevicectlJSON: Data("not json".utf8))
        }
    }
}

extension PhysicalPhoneTests {
    private func listing(_ devices: [String]) -> Data {
        Data(#"{"info":{"outcome":"success"},"result":{"devices":[\#(devices.joined(separator: ","))]}}"#.utf8)
    }

    private func phone(
        udid: String = "00008160-001239C43AA0000A", tunnel: String = "disconnected", tunnelAddress: String? = nil,
        pairing: String = "paired", developerMode: String = "enabled", boot: String = "booted",
        platform: String = "iOS"
    ) -> String {
        #"""
        {"identifier":"30546CC9-90DC-5F06-87D3-42D2C2E913D1",
         "connectionProperties":{"pairingState":"\#(pairing)","tunnelState":"\#(tunnel)","transportType":"wired"\#(tunnelAddress.map { #","tunnelIPAddress":"\#($0)""# } ?? "")},
         "deviceProperties":{"name":"han's iPhone","bootState":"\#(boot)","developerModeStatus":"\#(developerMode)","osVersionNumber":"27.0.1"},
         "hardwareProperties":{"udid":"\#(udid)","reality":"physical","productType":"iPhone19,7",
           "marketingName":"iPhone 18 Pro Max","platform":"\#(platform)","deviceType":"iPhone"}}
        """#
    }

    private func simulator() -> String {
        #"""
        {"identifier":"139EAA99-7C84-43A1-9F43-DDCEDA236457",
         "connectionProperties":{"pairingState":"paired","tunnelState":"disconnected"},
         "deviceProperties":{"name":"iPhone 18 Pro Max","bootState":"booted"},
         "hardwareProperties":{"udid":"139EAA99-7C84-43A1-9F43-DDCEDA236457","reality":"simulated",
           "productType":"iPhone19,3","marketingName":"iPhone 18 Pro Max","platform":"iOS"}}
        """#
    }
}

@Suite("PhysicalPhone screen")
struct PhysicalPhoneScreenTests {
    private func displays(_ entries: String) -> Data {
        Data(#"{"info":{"outcome":"success"},"result":{"displays":[\#(entries)]}}"#.utf8)
    }

    @Test func `should read the phone's screen size in pixels from its primary display`() {
        let info = displays(#"""
            {"displayId":2,"primary":false,"nativeSize":[1920,1080]},
            {"displayId":1,"primary":true,"name":"LCD","nativeSize":[1320,2868],"bounds":[[0,0],[1320,2868]]}
            """#)

        #expect(PhysicalPhone.screenPixels(fromDisplaysJSON: info) == Size(width: 1320, height: 2868))
    }

    @Test func `should read no screen size when the phone lists no primary display`() {
        #expect(PhysicalPhone.screenPixels(fromDisplaysJSON: displays("")) == nil)
        #expect(PhysicalPhone.screenPixels(fromDisplaysJSON: Data("not json".utf8)) == nil)
    }
}
