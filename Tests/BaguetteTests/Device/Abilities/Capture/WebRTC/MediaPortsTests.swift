import Foundation
import Testing
@testable import BaguetteDevice

private struct Taken: Error, Equatable { let port: UInt16 }

@Suite("MediaPorts")
struct MediaPortsTests {
    @Test func `should read a range of ports the way an operator writes one`() {
        #expect(MediaPorts(parsing: "8190-8194") == MediaPorts(8190...8194))
        #expect(MediaPorts(parsing: "8190") == MediaPorts(8190...8190))
    }

    @Test func `should read no range from what isn't one`() {
        for written in ["", "8194-8190", "0-10", "port", "8190-70000"] {
            #expect(MediaPorts(parsing: written) == nil, "\(written)")
        }
    }

    @Test func `should take the first port in its range that is free`() throws {
        let ports = MediaPorts(8190...8194)

        let bound = try ports.bind { port in
            guard port >= 8192 else { throw Taken(port: port) }
            return port
        }

        #expect(bound == 8192)
    }

    @Test func `should say why when every port in its range is taken`() {
        #expect(throws: Taken(port: 8191)) {
            try MediaPorts(8190...8191).bind { port -> UInt16 in throw Taken(port: port) }
        }
    }

    @Test func `should let the system pick when no range is given`() throws {
        #expect(try MediaPorts.any.bind { $0 } == 0)
    }
}
