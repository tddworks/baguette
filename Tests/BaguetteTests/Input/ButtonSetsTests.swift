import Foundation
import Testing
import Mockable
@testable import Baguette

@Suite("Navigations and hardware buttons")
struct ButtonSetsTests {

    @Test(arguments: [
        ("home", DeviceButton.navigation(.home)),
        ("app-switcher", .navigation(.appSwitcher)),
        ("swipe-to-app-switcher", .navigation(.swipeToAppSwitcher)),
        ("swipe-to-home", .navigation(.swipeToHome)),
        ("pull-down-to-lock-screen", .navigation(.pullDownToLockScreen)),
        ("pull-down-to-notification-center", .navigation(.pullDownToNotificationCenter)),
        ("software-keyboard", .navigation(.softwareKeyboard)),
        ("lock", .hardware(.lock)),
        ("power", .hardware(.power)),
        ("action", .hardware(.action)),
        ("volume-up", .hardware(.volumeUp)),
        ("volume-down", .hardware(.volumeDown)),
        ("digital-crown", .hardware(.digitalCrown)),
        ("side-button", .hardware(.sideButton)),
        ("left-side-button", .hardware(.leftSideButton)),
    ])
    func `should read every wire button name as a navigation or a hardware button`(wire: String, button: DeviceButton) {
        #expect(DeviceButton(rawValue: wire) == button)
        #expect(button.rawValue == wire)
    }

    @Test func `should read a name that is no button as none`() {
        #expect(DeviceButton(rawValue: "siri") == nil)
    }

    @Test func `should refuse a navigation the device doesn't have, naming it`() {
        let buttons = MockPress()
        given(buttons).available.willReturn([.hardware(.power)])
        let dispatcher = GestureDispatcher(input: .input(of: "Apple Watch", touch: MockTouch(), press: buttons))

        let ack = dispatcher.dispatch(line: #"{"type":"button","button":"app-switcher"}"#)

        #expect(ack == #"{"ok":false,"error":"Apple Watch can't do app-switcher"}"#)
        verify(buttons).button(.any, duration: .any).called(0)
    }

    @Test func `should press a button the device has`() {
        let buttons = MockPress()
        given(buttons).available.willReturn([.hardware(.power)])
        given(buttons).button(.any, duration: .any).willReturn(true)
        let dispatcher = GestureDispatcher(input: .input(of: "iPhone 17", touch: MockTouch(), press: buttons))

        let ack = dispatcher.dispatch(line: #"{"type":"button","button":"power"}"#)

        #expect(ack == #"{"ok":true}"#)
        verify(buttons).button(.value(.hardware(.power)), duration: .value(0)).called(1)
    }

    @Test func `should offer every navigation and button on an iOS simulator, as it always has`() {
        #expect(DeviceButton.onSimulator.count == Navigation.allCases.count + HardwareButton.allCases.count)
    }
}
