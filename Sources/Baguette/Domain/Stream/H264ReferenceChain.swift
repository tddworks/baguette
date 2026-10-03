/// A decoder can accept deltas only after the current session supplied a keyframe and configuration.
struct H264ReferenceChain {
    private(set) var generation = 0
    private(set) var needsKeyframe = true

    mutating func reset() {
        generation += 1
        needsKeyframe = true
    }

    mutating func accepts(generation: Int, keyframe: Bool, hasDescription: Bool) -> Bool {
        guard generation == self.generation else { return false }
        guard !needsKeyframe || (keyframe && hasDescription) else { return false }
        needsKeyframe = false
        return true
    }
}
