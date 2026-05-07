import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("MacApp")
struct MacAppTests {

    // MARK: - identity & state

    @Test func `holds bundleID pid name and active flag`() {
        let app = MacApp(
            bundleID: "com.apple.TextEdit",
            pid: 4242,
            name: "TextEdit",
            isActive: true,
            host: MockMacApps()
        )
        #expect(app.bundleID == "com.apple.TextEdit")
        #expect(app.pid == 4242)
        #expect(app.name == "TextEdit")
        #expect(app.isActive == true)
    }

    @Test func `equality ignores the host`() {
        let a = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true, host: MockMacApps())
        let b = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true, host: MockMacApps())
        #expect(a == b)
    }

    @Test func `equality differs on stored fields`() {
        let host = MockMacApps()
        let active   = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true,  host: host)
        let inactive = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: false, host: host)
        #expect(active != inactive)
    }

    // MARK: - rich-domain verbs

    @Test func `screen delegates to the host`() {
        let host = MockMacApps()
        let stub = MockScreen()
        given(host).screen(for: .any).willReturn(stub)
        let app = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true, host: host)

        let screen = app.screen()

        #expect(screen === stub)
        verify(host).screen(for: .value(app)).called(1)
    }

    @Test func `accessibility delegates to the host`() {
        let host = MockMacApps()
        let stub = MockAccessibility()
        given(host).accessibility(for: .any).willReturn(stub)
        let app = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true, host: host)

        let ax = app.accessibility()

        #expect(ax === stub)
        verify(host).accessibility(for: .value(app)).called(1)
    }

    @Test func `input delegates to the host`() {
        let host = MockMacApps()
        let stub = MockInput()
        given(host).input(for: .any).willReturn(stub)
        let app = MacApp(bundleID: "com.x", pid: 1, name: "X", isActive: true, host: host)

        _ = app.input()

        verify(host).input(for: .value(app)).called(1)
    }

    // MARK: - presentation

    @Test func `json shape matches the mac list subcommand contract`() {
        let app = MacApp(
            bundleID: "com.apple.TextEdit",
            pid: 4242,
            name: "TextEdit",
            isActive: true,
            host: MockMacApps()
        )
        // Field order is part of the contract — callers grep for it.
        #expect(app.json ==
            "{\"bundleID\":\"com.apple.TextEdit\",\"pid\":4242,\"name\":\"TextEdit\",\"active\":true}")
    }

    // MARK: - factory from RunningAppSnapshot

    @Test func `from(snapshot:) maps every field across`() {
        let snap = RunningAppSnapshot(
            bundleID: "com.apple.TextEdit", pid: 4242,
            name: "TextEdit", isActive: true
        )
        let app = MacApp.from(snapshot: snap, host: MockMacApps())
        #expect(app?.bundleID == "com.apple.TextEdit")
        #expect(app?.pid == 4242)
        #expect(app?.name == "TextEdit")
        #expect(app?.isActive == true)
    }

    @Test func `from(snapshot:) returns nil when bundleID is empty`() {
        let snap = RunningAppSnapshot(
            bundleID: "", pid: 1, name: "Mystery", isActive: false
        )
        #expect(MacApp.from(snapshot: snap, host: MockMacApps()) == nil)
    }

    @Test func `json escapes quotes in name`() {
        let app = MacApp(
            bundleID: "com.x",
            pid: 1,
            name: "Foo \"Bar\"",
            isActive: false,
            host: MockMacApps()
        )
        #expect(app.json.contains(#"Foo \"Bar\""#))
    }
}
