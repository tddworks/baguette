import Foundation
import Testing
@testable import WebRTCKit

@Suite("DatagramAddress")
struct DatagramAddressTests {
    @Test func `should write an address the way people read one`() {
        #expect("\(DatagramAddress(ip: [192, 168, 2, 221], port: 59739))" == "192.168.2.221:59739")
        #expect("\(DatagramAddress(ip: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1], port: 443))"
            == "[2001:db8:0:0:0:0:0:1]:443")
    }
}
