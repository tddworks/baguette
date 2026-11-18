import Testing
import Foundation
@testable import Baguette

/// Which capability each plugin-reachable route demands.
///
/// The table is deliberately a *closed* list: a path it doesn't name is
/// unreachable by a plugin, so a route added to the server later is
/// locked out until someone names it here. The drift direction is
/// "plugins can't get in yet", never "plugins got in silently".
@Suite("PluginRoute")
struct PluginRouteTests {

    @Test func `should demand the same capability on the devices tree as on a simulator's old one`() {
        for leaf in ["screenshot.jpg", "describe-ui.json", "input", "status-bar", "location", "openurl", "logs"] {
            #expect(PluginRoute.capability(path: "/devices/U/\(leaf)")
                == PluginRoute.capability(path: "/simulators/U/\(leaf)"), "\(leaf)")
            #expect(PluginRoute.capability(path: "/devices/U/\(leaf)") != nil, "\(leaf)")
        }
    }

    @Test func `should keep the device page and the device list out of a plugin's reach`() {
        #expect(PluginRoute.capability(path: "/devices/U") == nil)
        #expect(PluginRoute.capability(path: "/devices.json") == nil)
    }

    @Test func `should demand the screenshot capability to read the screen`() {
        #expect(PluginRoute.capability(path: "/simulators/U/screenshot.jpg") == .screenshot)
    }

    @Test func `should demand the describe-ui capability to read the accessibility tree`() {
        #expect(PluginRoute.capability(path: "/simulators/U/describe-ui.json") == .describeUI)
    }

    @Test func `should demand the input capability to drive the device`() {
        #expect(PluginRoute.capability(path: "/simulators/U/input") == .input)
    }

    @Test func `should demand the status-bar capability to change the status bar`() {
        // One capability covers read, override and clear — they're the
        // same authority over the same surface, and GET/POST/DELETE
        // share the path.
        #expect(PluginRoute.capability(path: "/simulators/U/status-bar") == .statusBar)
    }

    @Test func `should demand the location capability to set the simulated location`() {
        #expect(PluginRoute.capability(path: "/simulators/U/location") == .location)
    }

    @Test func `should demand separate capabilities to install an app and to add media`() {
        // Putting a photo in the library and installing an executable
        // are not the same authority, and bundling them meant a plugin
        // that wanted to seed test images had to be trusted to install
        // software.
        #expect(PluginRoute.capability(path: "/simulators/U/apps") == .apps)
        #expect(PluginRoute.capability(path: "/simulators/U/media") == .media)
    }

    @Test func `should close the browser's drag-and-drop upload to plugins`() {
        // `/files` routes by extension, so the capability it demands
        // would depend on the bytes rather than the path — and a
        // content-dependent check is exactly what this table exists to
        // avoid. Plugins name the kind they mean.
        #expect(PluginRoute.capability(path: "/simulators/U/files") == nil)
    }

    @Test func `should demand the logs capability to read the log feed`() {
        #expect(PluginRoute.capability(path: "/simulators/U/logs") == .logs)
    }

    @Test func `should demand the simulators capability to list devices`() {
        #expect(PluginRoute.capability(path: "/simulators.json") == .simulators)
    }

    @Test func `should demand the interface capability to change appearance, contrast and text size`() {
        // One capability for the whole `simctl ui` family: a plugin that
        // can darken the screen can already restyle it, so splitting
        // read from write would be a distinction without a difference.
        #expect(PluginRoute.capability(path: "/simulators/U/interface") == .interface)
        #expect(PluginRoute.capability(path: "/simulators/U/interface.json") == .interface)
    }

    @Test func `should demand the open-url capability to open a link and list schemes`() {
        // One capability for the pair, on the `interface` precedent: a
        // plugin that can open *any* URL is not meaningfully restrained
        // by hiding the list of which ones an app registered.
        #expect(PluginRoute.capability(path: "/simulators/U/openurl") == .openURL)
        #expect(PluginRoute.capability(path: "/simulators/U/schemes.json") == .openURL)
    }

    @Test func `should not let the app-install capability open a link`() {
        // `apps` puts an executable on the device; `open-url` launches
        // one that's already there. A plugin that only wants to fire a
        // deep link must not have to be trusted to install software.
        #expect(PluginCapability.openURL != .apps)
        #expect(PluginRoute.capability(path: "/simulators/U/openurl") != .apps)
    }

    @Test func `should recognise a route when the path carries a real udid`() {
        #expect(
            PluginRoute.capability(path: "/simulators/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/input")
                == .input
        )
    }

    @Test func `should recognise a route when the path carries a query string`() {
        #expect(
            PluginRoute.capability(path: "/simulators/U/screenshot.jpg?scale=0.5") == .screenshot
        )
    }

    // MARK: - closed by default

    @Test func `should keep booting and shutting down the device out of a plugin's reach`() {
        // No capability spells "boot and shut down devices", so no
        // manifest can ask for it and every plugin token is refused.
        #expect(PluginRoute.capability(path: "/simulators/U/boot") == nil)
        #expect(PluginRoute.capability(path: "/simulators/U/shutdown") == nil)
    }

    @Test func `should keep routes no capability names out of a plugin's reach`() {
        for path in [
            "/simulators/U/orientation",
            "/simulators/U/camera-source",
            "/simulators/U/render-3d.png",
            "/simulators/U/chrome.json",
            "/simulators/U/bezel.png",
            "/simulators/U/3d-model.json",
        ] {
            #expect(PluginRoute.capability(path: path) == nil, "\(path) should be closed")
        }
    }

    @Test func `should keep the plugin and bakery surfaces for the browser, not for plugins`() {
        // A plugin must not be able to run other plugins, or install new
        // ones — that's the user's consent to give, from the browser.
        #expect(PluginRoute.capability(path: "/plugins.json") == nil)
        #expect(PluginRoute.capability(path: "/plugins/a11y/commands/audit") == nil)
        #expect(PluginRoute.capability(path: "/bakeries/install") == nil)
    }

    @Test func `should not treat the pages and static assets as plugin routes`() {
        #expect(PluginRoute.capability(path: "/") == nil)
        #expect(PluginRoute.capability(path: "/simulators") == nil)
        #expect(PluginRoute.capability(path: "/simulators/U") == nil)
        #expect(PluginRoute.capability(path: "/sim-plugins.js") == nil)
    }
}
