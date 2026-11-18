import Testing
@testable import Baguette
@testable import BaguetteDevice

/// What an operator reads when a plane will not bind. Until the CLI gained
/// `--display`, this error only ever reached a WebSocket handler, so it
/// surfaced as its own enum dump — `noMatchingPort(Baguette.DisplayKind.carPlay)`
/// — which names the failure but not the remedy, and leaks the module while
/// it's at it. On a terminal it is the whole of what the caller gets.
@Suite("FramebufferSelectionError")
struct FramebufferSelectionErrorTests {

    @Test func `should point to the External Displays menu when no CarPlay screen is attached`() {
        let message = FramebufferSelectionError.noMatchingPort(.carPlay).message
        #expect(message.contains("CarPlay"))
        #expect(message.contains("External Displays"))
        // The remedy for an attached-but-black plane is a different one —
        // cycling it off and back — and it is the case most likely to
        // reach here, so the message has to distinguish them.
        #expect(message.contains("Disabled"))
        #expect(!message.contains("Baguette."))
    }

    @Test func `should say the device has no framebuffer when its screen is absent`() {
        let message = FramebufferSelectionError.noMatchingPort(.phone).message
        #expect(message.contains("device"))
        #expect(!message.contains("Baguette."))
    }

    @Test func `should explain a missing screen id as a display still coming up`() {
        let message = FramebufferSelectionError.screenIdUnavailable.message
        #expect(message.contains("screen id"))
        #expect(!message.contains("Baguette."))
    }
}
