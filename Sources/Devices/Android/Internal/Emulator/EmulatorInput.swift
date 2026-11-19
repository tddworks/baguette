import BaguetteDevice
import Foundation

/// An emulator's touchscreen through its control API, playing `Touch` and
/// `Scroll`. Points arrive in the page's device points and go out in the
/// emulator's pixels (`screen`). Fingers are multitouch slots by identifier,
/// so two fingers are two touches; a finger with no pressure is lifted. A
/// scroll is a finger dragging the content, as on the phone itself: a
/// phone-shaped emulator has no mouse, so the control API's wheel reaches
/// nothing. Buttons and keys go through adb (`AdbKeys`): an emulator booted
/// without a hardware keyboard drops the control API's key events.
final class EmulatorInput: Touch, Scroll, @unchecked Sendable {
    private let connection: EmulatorConnection
    private let screen: Size
    private let pixelsPerPoint: Double
    private let pause: @Sendable (Double) -> Void
    private static let tapHold = 0.05
    private static let stepsPerSecond = 60.0

    init(connection: EmulatorConnection, screen: Size, pixelsPerPoint: Double,
         pause: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.connection = connection
        self.screen = screen
        self.pixelsPerPoint = pixelsPerPoint
        self.pause = pause
    }

    // MARK: - Touch

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        guard touch([(point, 1, true)], size) else { return false }
        pause(duration > 0 ? duration : Self.tapHold)
        return touch([(point, 1, false)], size)
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        twoPath([(start, end)], size: size, duration: duration)
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        touch([(point, 1, phase != .up)], size)
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        touch([(first, 1, phase != .up), (second, 2, phase != .up)], size)
    }

    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        twoPath([(start1, end1), (start2, end2)], size: size, duration: duration)
    }

    /// Each finger down at its start, moved in steps to its end, and lifted.
    private func twoPath(_ fingers: [(start: Point, end: Point)], size: Size, duration: Double) -> Bool {
        let steps = max(2, Int(duration * Self.stepsPerSecond))
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let points = fingers.enumerated().map { index, finger in
                (Point(x: finger.start.x + (finger.end.x - finger.start.x) * t,
                       y: finger.start.y + (finger.end.y - finger.start.y) * t), index + 1, true)
            }
            guard touch(points, size) else { return false }
            if step < steps { pause(duration / Double(steps)) }
        }
        return touch(fingers.enumerated().map { ($1.end, $0 + 1, false) }, size)
    }

    private func touch(_ fingers: [(point: Point, identifier: Int, down: Bool)], _ size: Size) -> Bool {
        let touches = fingers.map { finger in
            EmulatorControl.TouchEvent.Touch(x: Self.pixel(finger.point.x / size.width, across: screen.width),
                                             y: Self.pixel(finger.point.y / size.height, across: screen.height),
                                             identifier: finger.identifier, pressure: finger.down ? 1 : 0)
        }
        return send("sendTouch", EmulatorControl.TouchEvent(touches: touches).bytes)
    }

    /// The pixel `fraction` of the way across `length`; a finger off the
    /// screen (an edge swipe, a drag past the frame) on its edge.
    private static func pixel(_ fraction: Double, across length: Double) -> Int {
        Int((min(max(fraction, 0), 1) * length).rounded())
    }

    // MARK: - Scroll

    /// A wheel's distance, in points, as a quick drag through the screen's
    /// middle: the content follows the finger, so scrolling down drags up.
    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        let middle = Point(x: screen.width / 2, y: screen.height / 2)
        let end = Point(x: min(max(middle.x - deltaX * pixelsPerPoint, 0), screen.width),
                        y: min(max(middle.y - deltaY * pixelsPerPoint, 0), screen.height))
        return twoPath([(middle, end)], size: screen, duration: Self.scrollDrag)
    }

    private static let scrollDrag = 0.1

    private func send(_ method: String, _ message: Data) -> Bool {
        do {
            try connection.send(method, message)
            return true
        } catch {
            log("[android] \(method) failed: \(error)")
            return false
        }
    }
}
