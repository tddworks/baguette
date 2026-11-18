import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

@Suite("PluginGrants")
struct PluginGrantsTests {

    @Test func `should grant exactly the capabilities the plugin declared`() throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "a11y", capabilities: [.describeUI, .screenshot])
        #expect(grants.capabilities(for: token) == [.describeUI, .screenshot])
    }

    @Test func `should give each grant its own unguessable token`() throws {
        let grants = PluginGrants()
        let a = grants.issue(plugin: "a11y", capabilities: [.describeUI])
        let b = grants.issue(plugin: "expo", capabilities: [.input])
        #expect(a != b)
        #expect(a.count >= 32)
        // A token is bound to its own plugin's grant, not the other's.
        #expect(grants.capabilities(for: a) == [.describeUI])
        #expect(grants.capabilities(for: b) == [.input])
    }

    @Test func `should stop honouring a token once it is revoked`() throws {
        // The grant lives exactly as long as the command invocation, so
        // a leaked token is useless once the command exits.
        let grants = PluginGrants()
        let token = grants.issue(plugin: "a11y", capabilities: [.describeUI])
        grants.revoke(token)
        #expect(grants.capabilities(for: token) == nil)
    }

    @Test func `should grant nothing to an unknown token`() throws {
        let grants = PluginGrants()
        #expect(grants.capabilities(for: "made-up") == nil)
    }

    // MARK: - the authorization question

    @Test func `should allow a token a capability its plugin declared`() throws {
        let grants = PluginGrants()
        let token = grants.issue(plugin: "expo", capabilities: [.input])
        #expect(grants.allows(token: token, capability: .input))
    }

    @Test func `should refuse a token a capability its plugin did not declare`() throws {
        // The whole point: the a11y plugin reads the screen, so it must
        // not be able to drive the device.
        let grants = PluginGrants()
        let token = grants.issue(plugin: "a11y", capabilities: [.describeUI])
        #expect(!grants.allows(token: token, capability: .input))
    }

    @Test func `should refuse every capability when no token is presented`() throws {
        let grants = PluginGrants()
        #expect(!grants.allows(token: nil, capability: .describeUI))
        #expect(!grants.allows(token: "", capability: .describeUI))
    }
}
