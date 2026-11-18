import BaguetteDevice
import Foundation

/// Picks which live framebuffer surface to emit for a display binding.
/// The external plane never falls back to a phone-sized plane — better
/// to emit nothing than to mirror SpringBoard into the external pane.
enum FramebufferSurfacePick {
    /// Below this, a surface is a stub or a scratch buffer, not a screen.
    private static let minExternalArea = 50_000.0

    static func index(
        binding: DisplayBinding?,
        candidates: [Size]
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }
        guard let binding else {
            return candidates.indices.max { candidates[$0].area < candidates[$1].area }
        }
        switch binding.kind {
        case .phone:
            return closestIndex(to: binding.size, in: candidates)
        case .carPlay:
            let eligible = candidates.indices.filter { acceptsExternal(candidates[$0]) }
            guard !eligible.isEmpty else { return nil }
            return eligible.min { a, b in
                distance(candidates[a], binding.size) < distance(candidates[b], binding.size)
            }
        }
    }

    /// Whether a surface could be the external display.
    ///
    /// Landscape, and big enough to be a screen. There used to be an
    /// upper bound too — `800 × 480 × 4` — from when this plane was
    /// only ever CarPlay, whose screen is 720×480. But the plane binds
    /// whatever the External Displays menu attached, and that menu
    /// offers ordinary resolutions: a 1080p display is a real display,
    /// and refusing it reported "nothing attached" for a screen the user
    /// was looking at.
    ///
    /// The landscape test is the one that matters and stays. It is what
    /// keeps a portrait phone plane out of the external pane — mirroring
    /// SpringBoard there is worse than showing nothing, because it looks
    /// like it worked.
    ///
    /// Strictly wider than tall: a square is not a display's shape, and
    /// `>=` let any square scratch buffer over the area floor bind as
    /// the external plane.
    static func acceptsExternal(_ size: Size) -> Bool {
        size.width > size.height && size.area >= minExternalArea
    }

    private static func closestIndex(to target: Size, in candidates: [Size]) -> Int? {
        candidates.indices.min {
            distance(candidates[$0], target) < distance(candidates[$1], target)
        }
    }

    private static func distance(_ a: Size, _ b: Size) -> Double {
        let dw = a.width - b.width
        let dh = a.height - b.height
        return dw * dw + dh * dh
    }
}

extension Size {
    var area: Double { width * height }
}
