import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

// The wire's `DeviceEdge` and the digitizer message's edge bitmask are
// two vocabularies for the same thing. One translation, shared by the
// one-shot tap and the streaming touch — when they disagreed, the same
// point reached iOS as two different messages.
@Suite("IOHIDDigitizerDispatch.Edge")
struct DigitizerEdgeTests {
    @Test func `should mark a touch with the bit for each screen edge it starts on`() {
        #expect(IOHIDDigitizerDispatch.Edge.from(.left).bit   == 0x02)
        #expect(IOHIDDigitizerDispatch.Edge.from(.top).bit    == 0x08)
        #expect(IOHIDDigitizerDispatch.Edge.from(.right).bit  == 0x04)
        #expect(IOHIDDigitizerDispatch.Edge.from(.bottom).bit == 0x01)
    }

    @Test func `should treat a touch as interior when no edge is named`() {
        #expect(IOHIDDigitizerDispatch.Edge.from(nil).bit == 0x00)
    }
}
