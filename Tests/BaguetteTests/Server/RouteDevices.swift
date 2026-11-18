import Mockable
@testable import Baguette

/// The devices a route asks: one device under `id`, ready unless told
/// otherwise, with only the abilities `register` gives it.
func routeDevices(
    _ id: DeviceID = "U", name: String = "iPhone 17", state: DeviceState = .ready,
    _ register: (inout Abilities) -> Void = { _ in }
) -> any Devices {
    var abilities = Abilities(device: name)
    register(&abilities)
    let device = MockDevice()
    given(device).id.willReturn(id)
    given(device).name.willReturn(name)
    given(device).state.willReturn(state)
    given(device).abilities.willReturn(abilities)
    let devices = MockDevices()
    given(devices).all.willReturn([device])
    given(devices).find(id: .any).willProduce { asked in asked == id ? device : nil }
    return devices
}
