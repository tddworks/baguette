import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// Counts the values of it that are still alive, to see one destroyed.
private final class Alive: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var now: Int { lock.withLock { count } }
    func born() { lock.withLock { count += 1 } }
    func died() { lock.withLock { count -= 1 } }
}

private final class Tracked: OpaqueCapability {
    let alive: Alive
    init(_ alive: Alive) { self.alive = alive; alive.born() }
    deinit { alive.died() }
}

@Suite("CoreDeviceFramework")
struct CoreDeviceFrameworkTests {
    @Test func `should read a value's size from its type's metadata`() {
        let int = unsafeBitCast(Int.self as Any.Type, to: UnsafeRawPointer.self)
        let pair = unsafeBitCast((Int64, Int32).self as Any.Type, to: UnsafeRawPointer.self)

        #expect(CoreDeviceFramework.valueSize(int) == 8)
        #expect(CoreDeviceFramework.valueSize(pair) == 12)
    }

    @Test func `should name what CoreDevice didn't do in time`() {
        #expect(CoreDeviceError.unavailable.description == "CoreDevice is not available on this Mac")
        #expect(CoreDeviceError.noAnswer("starting the stream").description
            == "CoreDevice didn't answer starting the stream in time")
    }

    @Test func `should open Universal HID by its own type and conformance`() {
        #expect(CapabilityKind.universalHID.typeSymbol == "$s10CoreDevice29UniversalHIDServiceCapabilityVN")
        #expect(CapabilityKind.universalHID.conformanceSymbol
            == "$s10CoreDevice29UniversalHIDServiceCapabilityVAA0bE0AAWP")
    }

    @Test func `should release what CoreDevice opened when the capability is let go`() {
        let alive = Alive()
        do {
            let capability = OpenedCapability()
            capability.existential.initializeMemory(as: (any OpaqueCapability).self, repeating: Tracked(alive), count: 1)
            capability.isOpen = true
            #expect(alive.now == 1)
        }

        #expect(alive.now == 0)
    }

    @Test func `should release nothing for a capability CoreDevice never opened`() {
        let capability = OpenedCapability()

        #expect(!capability.isOpen)
    }
}

@Suite("CoreDeviceListing")
struct CoreDeviceListingTests {
    private final class Listing: @unchecked Sendable {
        var lists: [[Int]]
        var completeAfter: Int
        private(set) var looks = 0
        init(_ lists: [[Int]], completeAfter: Int = .max) { self.lists = lists; self.completeAfter = completeAfter }
        func listed() -> [Int] { looks += 1; return looks <= lists.count ? lists[looks - 1] : lists.last ?? [] }
        var isComplete: Bool { looks >= completeAfter }
    }

    @Test func `should find a phone as soon as CoreDevice lists it`() {
        let listing = Listing([[], [1, 7], [7]])
        var pauses = 0

        let found = CoreDeviceListing.find(where: { $0 == 7 }, listed: listing.listed,
                                           isComplete: { listing.isComplete }, pause: { pauses += 1 })

        #expect(found == 7)
        #expect(pauses == 1)
    }

    @Test func `should stop looking once CoreDevice has listed everything and the phone isn't there`() {
        let listing = Listing([[1], [1, 2]], completeAfter: 2)
        var pauses = 0

        let found = CoreDeviceListing.find(where: { $0 == 7 }, listed: listing.listed,
                                           isComplete: { listing.isComplete }, pause: { pauses += 1 })

        #expect(found == nil)
        #expect(listing.looks == 2)
        #expect(pauses == 1)
    }

    @Test func `should give up after fifty looks when CoreDevice never finishes listing`() {
        let listing = Listing([[1]])

        let found = CoreDeviceListing.find(where: { $0 == 7 }, listed: listing.listed,
                                           isComplete: { false }, pause: {})

        #expect(found == nil)
        #expect(listing.looks == 50)
    }
}

@Suite("CoreDeviceAnswer")
struct CoreDeviceAnswerTests {
    private struct Refused: Error, Equatable {}

    @Test func `should hand back CoreDevice's answer when it comes in time`() throws {
        let answer = try CoreDeviceAnswer.wait(upTo: 5, for: "opening") { 42 }

        #expect(answer == 42)
    }

    @Test func `should pass on what CoreDevice failed with`() {
        #expect(throws: Refused()) {
            try CoreDeviceAnswer.wait(upTo: 5, for: "opening") { () async throws -> Int in throw Refused() }
        }
    }

    @Test func `should give up on CoreDevice when it doesn't answer in time`() {
        #expect {
            try CoreDeviceAnswer.wait(upTo: 0.05, for: "opening") { () async throws -> Int in
                try await Task.sleep(for: .seconds(2))
                return 1
            }
        } throws: { error in
            (error as? CoreDeviceError)?.description == CoreDeviceError.noAnswer("opening").description
        }
    }
}

@Suite("RuntimeValue")
struct RuntimeValueTests {
    private struct Request: Decodable, Equatable { let name: String }
    private struct Response: Codable, Equatable { let port: Int }
    private struct Opaque { let alive: Tracked }

    @Test func `should hold a value at an address for a call that borrows it`() {
        let held = BorrowedValue(Request(name: "video") as Any)
        defer { held.release() }

        #expect(held.pointer.assumingMemoryBound(to: Request.self).pointee == Request(name: "video"))
    }

    @Test func `should let go of a held value once the call is done`() {
        let alive = Alive()
        let held = BorrowedValue(Opaque(alive: Tracked(alive)) as Any)
        #expect(alive.now == 1)

        held.release()

        #expect(alive.now == 0)
    }

    @Test func `should read a value moved out of an address as JSON`() {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: Response.self, repeating: Response(port: 61501), count: 1)

        let json = RuntimeValue.json(movingFrom: pointer, as: Response.self)

        #expect(json?["port"] as? Int == 61501)
    }

    @Test func `should read no JSON from a value that can't be encoded, and still destroy it`() {
        let alive = Alive()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: Opaque.self, repeating: Opaque(alive: Tracked(alive)), count: 1)

        #expect(RuntimeValue.json(movingFrom: pointer, as: Opaque.self) == nil)
        #expect(alive.now == 0)
    }

    @Test func `should destroy a value at an address`() {
        let alive = Alive()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: Opaque.self, repeating: Opaque(alive: Tracked(alive)), count: 1)

        RuntimeValue.destroy(at: pointer, as: Opaque.self)

        #expect(alive.now == 0)
    }
}

@Suite("MediaStreamHandshake")
struct MediaStreamHandshakeTests {
    private struct Support { let alive: Tracked }
    private struct Request: Decodable, Equatable { let receiverPort: Int }
    private struct Response: Codable { let streamConfig: [String: String] }
    private struct Refused: Error, Equatable {}

    private final class Calls: @unchecked Sendable {
        var said: [String] = []
        var request: Request?
    }

    private func handshake() -> MediaStreamHandshake {
        MediaStreamHandshake(requestType: Request.self, responseType: Response.self, supportType: Support.self)
    }

    @Test func `should ask for support info, then start the stream with the request, and read the answer as JSON`() async throws {
        let alive = Alive()
        let calls = Calls()

        let json = try await handshake().run(
            supportInfo: {
                calls.said.append("support")
                $0.initializeMemory(as: Support.self, repeating: Support(alive: Tracked(alive)), count: 1)
            },
            start: { result, request in
                calls.said.append("start")
                calls.request = request.assumingMemoryBound(to: Request.self).pointee
                result.initializeMemory(as: Response.self, repeating: Response(streamConfig: ["SourceIP": "fd77::1"]), count: 1)
            },
            makeRequest: { calls.said.append("request"); return ["receiverPort": 50001] })

        #expect(calls.said == ["support", "request", "start"])
        #expect(calls.request == Request(receiverPort: 50001))
        #expect((json?["streamConfig"] as? [String: String]) == ["SourceIP": "fd77::1"])
        #expect(alive.now == 0)
    }

    @Test func `should not start the stream when its request can't be made`() async {
        let calls = Calls()

        await #expect(throws: Refused()) {
            _ = try await handshake().run(
                supportInfo: { $0.initializeMemory(as: Support.self, repeating: Support(alive: Tracked(Alive())), count: 1) },
                start: { _, _ in calls.said.append("start") },
                makeRequest: { throw Refused() })
        }
        #expect(calls.said.isEmpty)
    }

    @Test func `should not start the stream when CoreDevice can't tell its support`() async {
        let calls = Calls()

        await #expect(throws: Refused()) {
            _ = try await handshake().run(
                supportInfo: { _ in throw Refused() },
                start: { _, _ in calls.said.append("start") },
                makeRequest: { calls.said.append("request"); return [:] })
        }
        #expect(calls.said.isEmpty)
    }
}
