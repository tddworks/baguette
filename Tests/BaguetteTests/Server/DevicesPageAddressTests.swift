import Testing
@testable import Baguette

/// What `baguette serve` prints when it starts: where its devices list is.
@Suite("Devices page address")
struct DevicesPageAddressTests {

    @Test func `should point at the devices list on the host and port it serves`() {
        #expect(Server.devicesPage(host: "0.0.0.0", port: 8421) == "http://0.0.0.0:8421/devices")
    }
}
