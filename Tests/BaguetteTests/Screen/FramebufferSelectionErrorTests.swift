import Testing
@testable import Baguette

/// What an operator reads when a plane will not bind. Until the CLI gained
/// `--display`, this error only ever reached a WebSocket handler, so it
/// surfaced as its own enum dump — `noMatchingPort(Baguette.DisplayKind.carPlay)`
/// — which names the failure but not the remedy, and leaks the module while
/// it's at it. On a terminal it is the whole of what the caller gets.
@Suite("FramebufferSelectionError")
struct FramebufferSelectionErrorTests {

    @Test func `an absent CarPlay plane names the menu that attaches one`() {
        let message = FramebufferSelectionError.noMatchingPort(.carPlay).message
        #expect(message.contains("CarPlay"))
        #expect(message.contains("External Displays"))
        // The remedy for an attached-but-black plane is a different one —
        // cycling it off and back — and it is the case most likely to
        // reach here, so the message has to distinguish them.
        #expect(message.contains("Disabled"))
        #expect(!message.contains("Baguette."))
    }

    @Test func `an absent device plane says the device has no framebuffer`() {
        let message = FramebufferSelectionError.noMatchingPort(.phone).message
        #expect(message.contains("device"))
        #expect(!message.contains("Baguette."))
    }

    @Test func `an unresolved screen id reads as a display still coming up`() {
        let message = FramebufferSelectionError.screenIdUnavailable.message
        #expect(message.contains("screen id"))
        #expect(!message.contains("Baguette."))
    }
}
