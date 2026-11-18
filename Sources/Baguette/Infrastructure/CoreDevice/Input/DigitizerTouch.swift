import Foundation

/// `Touch` for a device whose touches go to a `Digitizer`: each gesture
/// becomes the reports a finger makes — down, moves, up — in fractions of
/// the screen. Buttons, keys and scroll are other HID services a digitizer
/// doesn't send, so a device with only this has only `Touch`.
struct DigitizerTouch: Touch {
    private let digitizer: any Digitizer
    private let pause: @Sendable (Double) -> Void

    /// Reports in a drag, spread over its duration (Indigo's swipe uses 10).
    private static let steps = 12

    init(digitizer: any Digitizer, pause: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.digitizer = digitizer
        self.pause = pause
    }

    func tap(at point: Point, size: Size, duration: Double, edge: DeviceEdge?) -> Bool {
        let finger = [point.contact(on: size)]
        guard digitizer.report(finger, touching: true, edge: edge) else { return false }
        pause(max(duration, 0.05))
        return digitizer.report(finger, touching: false, edge: edge)
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        drag([(start, end)], size: size, duration: duration)
    }

    func twoFingerPath(start1: Point, end1: Point, start2: Point, end2: Point, size: Size, duration: Double) -> Bool {
        drag([(start1, end1), (start2, end2)], size: size, duration: duration)
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        digitizer.report([point.contact(on: size)], touching: phase != .up, edge: edge)
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        digitizer.report([first.contact(on: size), second.contact(on: size)], touching: phase != .up, edge: nil)
    }

    /// Fingers down at their starts, moved together to their ends, lifted there.
    private func drag(_ paths: [(Point, Point)], size: Size, duration: Double) -> Bool {
        let total = duration > 0 ? duration : 0.25
        let interval = total / Double(Self.steps)
        for step in 0...Self.steps {
            let t = Double(step) / Double(Self.steps)
            let fingers = paths.map { start, end in
                Point(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t).contact(on: size)
            }
            guard digitizer.report(fingers, touching: true, edge: nil) else { return false }
            pause(interval)
        }
        return digitizer.report(paths.map { $0.1.contact(on: size) }, touching: false, edge: nil)
    }
}
