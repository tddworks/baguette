import BaguetteDevice
import Foundation
import Mockable

/// Apple's accessibility translator (AccessibilityPlatformTranslation's
/// `AXPTranslator`), which builds the same element tree for a phone that it
/// builds for a simulator, asking its questions of whoever answers for a
/// token. Decides nothing — the answers come from the phone's pushed tree
/// (`RemoteAXAccessibility`). The real one is `AXPTranslation`.
@Mockable
protocol AccessibilityTranslator: Sendable {
    /// Whether this Mac has the translator.
    var isAvailable: Bool { get }

    /// An empty `AXPTranslatorResponse`, for an answer to fill in.
    func response() -> NSObject?

    /// The element tree the translator builds from `root` (the phone's app),
    /// its questions for `token` answered by `answering`, walked by `deadline`.
    func tree(from root: NSObject, token: String, deadline: Date,
              answering: @escaping @Sendable (AnyObject) -> AnyObject?) -> AXNode?
}
