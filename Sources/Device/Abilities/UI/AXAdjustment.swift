import Foundation

/// A slider, stepper or picker stepped through accessibility — its
/// increment and decrement actions, as VoiceOver's swipe up and down sends
/// them — never by dragging, so how far a step moves is the control's own
/// business. Each step is sent once and its value read back; a step the
/// element refuses, or whose outcome can't be read, ends the run and is not
/// retried, since sending it again could move the value twice.
public struct AXAdjustment: Equatable, Sendable {
    /// The signed count asked for: up when positive, down when negative.
    public let requested: Int
    /// The steps sent and seen, out of `abs(requested)`.
    public let completed: Int
    public let valueBefore: String?
    public let valueAfter: String?
    /// Why the run stopped short; nil when every step landed.
    public let failure: String?

    public var ok: Bool { failure == nil }

    public init(requested: Int, completed: Int, valueBefore: String?, valueAfter: String?, failure: String?) {
        self.requested = requested
        self.completed = completed
        self.valueBefore = valueBefore
        self.valueAfter = valueAfter
        self.failure = failure
    }

    /// The element as a run sees it: its value, whether it can still be
    /// used, and one step.
    public struct Element: Sendable {
        let value: @Sendable () -> String?
        let usable: @Sendable () -> Bool
        let step: @Sendable (_ increment: Bool) -> Bool

        public init(
            value: @escaping @Sendable () -> String?,
            usable: @escaping @Sendable () -> Bool,
            step: @escaping @Sendable (_ increment: Bool) -> Bool
        ) {
            self.value = value
            self.usable = usable
            self.step = step
        }
    }

    /// Steps `element` `steps` times, waiting after each for its value to
    /// settle (`settle`, given the value before the step).
    public static func run(
        steps: Int,
        on element: Element,
        deadline: Date,
        now: () -> Date = Date.init,
        settle: (_ prior: String?) -> Void
    ) -> AXAdjustment {
        let before = element.value()
        guard steps != 0 else {
            return AXAdjustment(requested: 0, completed: 0, valueBefore: before, valueAfter: before,
                                failure: "a step count of zero moves nothing")
        }
        var value = before
        var completed = 0
        var failure: String?
        for _ in 0..<abs(steps) {
            guard now() < deadline else { failure = "deadline passed"; break }
            guard element.usable() else { failure = "element became disabled or hidden"; break }
            guard element.step(steps > 0) else { failure = "step refused; not retried"; break }
            completed += 1
            settle(value)
            guard let read = element.value() else {
                failure = "value unreadable after the step; outcome unknown, not retried"
                break
            }
            value = read
        }
        return AXAdjustment(
            requested: steps, completed: completed, valueBefore: before, valueAfter: value, failure: failure)
    }

    /// Why `node` can't be stepped `steps` times — no count, or no step that
    /// way on offer — or nil when it can.
    public static func refusal(stepping node: AXNode, by steps: Int) -> String? {
        guard steps != 0 else { return "a step count of zero moves nothing" }
        let action = steps > 0 ? "AXIncrement" : "AXDecrement"
        return node.adjustmentActions.contains(action) ? nil : "the element offers no \(action)"
    }

    /// A run that never started, for `reason`.
    public static func refused(_ node: AXNode, by steps: Int, because reason: String) -> AXAdjustment {
        AXAdjustment(requested: steps, completed: 0, valueBefore: node.value, valueAfter: node.value, failure: reason)
    }

    /// Whether a step has shown: the value reads, and differs from `prior`.
    /// No value yet means the app is still redrawing, not that it moved.
    public static func settled(after prior: String?, now current: String?) -> Bool {
        current != nil && current != prior
    }

    /// The answer a wire or HTTP caller gets.
    public var json: String {
        let object: [String: Any] = [
            "ok": ok,
            "requestedSteps": requested,
            "completedActions": completed,
            "before": valueBefore as Any? ?? NSNull(),
            "after": valueAfter as Any? ?? NSNull(),
            "error": failure as Any? ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
