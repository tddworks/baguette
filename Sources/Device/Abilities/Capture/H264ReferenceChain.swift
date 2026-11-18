/// A decoder can accept deltas only after the current session supplied a keyframe and configuration.
public struct H264ReferenceChain {
    public private(set) var generation = 0
    public private(set) var needsKeyframe = true

    public mutating func reset() {
        generation += 1
        needsKeyframe = true
    }

    public mutating func accepts(generation: Int, keyframe: Bool, hasDescription: Bool) -> Bool {
        guard generation == self.generation else { return false }
        guard !needsKeyframe || (keyframe && hasDescription) else { return false }
        needsKeyframe = false
        return true
    }
}
