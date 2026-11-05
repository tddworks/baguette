import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("AppLaunch")
struct AppLaunchTests {
    private static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
    private static let home = AXNode(
        role: "AXApplication", label: "Home", frame: frame, children: [AXNode(role: "AXButton", frame: frame)])
    private static let app = AXNode(
        role: "AXApplication", label: "Skylark", frame: frame, children: [AXNode(role: "AXButton", frame: frame)])
    private static let immediate = AXFirstScreen.Timing(quiet: 0, patience: 0, limit: 0, poll: 0, wakeEvery: 0)

    private func parsed(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func accessibility() -> MockAccessibility {
        let ax = MockAccessibility()
        var glances = [Self.home, Self.app]
        given(ax).glance().willProduce { glances.count > 1 ? glances.removeFirst() : glances[0] }
        given(ax).describeAll().willReturn(Self.app)
        given(ax).wake().willReturn(())
        return ax
    }

    @Test func `should launch the app and answer with its first screen`() async throws {
        let apps = MockApps()
        given(apps).launch(bundleID: .any).willReturn(())

        let result = try parsed(await AppLaunch.perform(
            bundleID: "dev.example", relaunch: false, thenDescribeUI: true, apps: apps,
            accessibility: accessibility(), timing: Self.immediate))

        #expect(result["ok"] as? Bool == true)
        #expect(result["action"] as? String == "launch")
        #expect(result["changed"] as? Bool == true)
        #expect((result["tree"] as? [String: Any])?["label"] as? String == "Skylark")
        verify(apps).launch(bundleID: .value("dev.example")).called(1)
        verify(apps).terminate(bundleID: .any).called(0)
    }

    @Test func `should offer the next commands with the first screen`() async throws {
        let apps = MockApps()
        given(apps).launch(bundleID: .any).willReturn(())
        let screen = AXScreen(width: 402, height: 874, orientation: .portrait)
        let ax = MockAccessibility()
        given(ax).glance().willReturn(Self.home)
        given(ax).describeAll().willReturn(AXNode(
            role: "AXApplication", label: "Skylark", frame: Self.frame,
            children: [AXNode(role: "AXButton", label: "Go", frame: Self.frame)], screen: screen))
        given(ax).wake().willReturn(())

        let result = try parsed(await AppLaunch.perform(
            bundleID: "dev.example", relaunch: false, thenDescribeUI: true, apps: apps, accessibility: ax,
            affordances: .commandLine(program: "baguette", udid: "X", deviceSet: nil), timing: Self.immediate))

        #expect(result["affordances"] != nil)
    }

    @Test func `should only launch when no read was asked for`() async throws {
        let apps = MockApps()
        given(apps).launch(bundleID: .any).willReturn(())
        let ax = MockAccessibility()

        let result = try parsed(await AppLaunch.perform(
            bundleID: "dev.example", relaunch: false, thenDescribeUI: false, apps: apps,
            accessibility: ax, timing: Self.immediate))

        #expect(result["ok"] as? Bool == true)
        #expect(result["tree"] == nil)
        verify(ax).glance().called(0)
    }

    @Test func `should quit the app first when asked to relaunch`() async throws {
        let apps = MockApps()
        given(apps).terminate(bundleID: .any).willReturn(())
        given(apps).launch(bundleID: .any).willReturn(())

        _ = await AppLaunch.perform(
            bundleID: "dev.example", relaunch: true, thenDescribeUI: false, apps: apps,
            accessibility: MockAccessibility(), timing: Self.immediate)

        verify(apps).terminate(bundleID: .value("dev.example")).called(1)
    }

    @Test func `should report a launch that fails`() async throws {
        let apps = MockApps()
        given(apps).launch(bundleID: .any).willThrow(AppsError.launchFailed(status: 4))
        let ax = MockAccessibility()
        given(ax).glance().willReturn(Self.home)

        let result = try parsed(await AppLaunch.perform(
            bundleID: "dev.example", relaunch: false, thenDescribeUI: true, apps: apps,
            accessibility: ax, timing: Self.immediate))

        #expect(result["ok"] as? Bool == false)
        #expect(result["action"] as? String == "launch")
        #expect(result["error"] != nil)
    }

    @Test func `should accept the bundle id and flags on the command line`() throws {
        let command = try LaunchCommand.parse([
            "--udid", "X", "--bundle-id", "dev.example", "--relaunch", "--then-describe-ui",
        ])

        #expect(command.bundleId == "dev.example")
        #expect(command.relaunch)
        #expect(command.thenDescribeUI)
    }
}
