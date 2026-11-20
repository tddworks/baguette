import Foundation
import Mockable
import Testing
@testable import BaguetteDevice

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var value: Int { lock.withLock { made } }
    func increment() { lock.withLock { made += 1 } }
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DeviceState = .ready
    var value: DeviceState {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A device whose touch counts each time it is made (a new HID connection,
/// for a simulator), in whatever state `state` holds.
private func device(_ id: DeviceID, made: Count, state: State = State()) -> MockDevice {
    var abilities = Abilities(device: "iPhone 17")
    abilities.register(.touch) { made.increment(); return MockTouch() }
    let device = MockDevice()
    given(device).id.willReturn(id)
    given(device).name.willReturn("iPhone 17")
    given(device).state.willProduce { state.value }
    given(device).abilities.willReturn(abilities)
    return device
}

@Suite("DeviceInputs")
struct DeviceInputsTests {
    @Test func `should make a device's input once and keep it for the next gesture`() throws {
        let inputs = DeviceInputs(), made = Count()
        let phone = device("U", made: made)

        let first = try inputs.input(of: phone)
        let second = try inputs.input(of: phone)

        #expect(made.value == 1)
        #expect((try first.require(.touch) as AnyObject) === (try second.require(.touch) as AnyObject))
    }

    @Test func `should make it afresh once the device has stopped running`() throws {
        let inputs = DeviceInputs(), made = Count(), state = State()
        let phone = device("U", made: made, state: state)
        _ = try inputs.input(of: phone)

        state.value = .off
        #expect(throws: DeviceError.self) { try inputs.input(of: phone) }
        state.value = .ready
        _ = try inputs.input(of: phone)

        #expect(made.value == 2)
    }

    @Test func `should keep each device's input apart`() throws {
        let inputs = DeviceInputs(), made = Count()

        _ = try inputs.input(of: device("A", made: made))
        _ = try inputs.input(of: device("B", made: made))

        #expect(made.value == 2)
    }
}
