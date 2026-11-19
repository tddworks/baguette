import BaguetteDevice
import Foundation

/// `AccessibilityTranslator` through AccessibilityPlatformTranslation, as
/// `AXPTranslatorBridge` loads it. Integration-only.
struct AXPTranslation: AccessibilityTranslator {
    var isAvailable: Bool { AXPTranslatorBridge.translator != nil }

    func response() -> NSObject? {
        (NSClassFromString("AXPTranslatorResponse") as? NSObject.Type)?.init()
    }

    func tree(from root: NSObject, token: String, deadline: Date,
              answering: @escaping @Sendable (AnyObject) -> AnyObject?) -> AXNode? {
        guard let translator = AXPTranslatorBridge.translator else { return nil }
        AXPTranslatorBridge.dispatcher.register(token: token, deadline: .distantFuture, source: answering)
        root.setValue(token, forKey: "bridgeDelegateToken")
        guard let element = AXPTranslatorBridge.macPlatformElement(translator: translator, translation: root) else {
            return nil
        }
        return AXNode.walk(from: element, transform: AXFrameTransform(pointSize: .zero, orientation: .portrait),
                           deadline: deadline).onItsAppsScreen
    }
}
