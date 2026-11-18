import CoreMedia

/// Accumulated durations keep timestamps increasing when the live FPS changes.
public struct H264Timeline {
    private var time = CMTime.zero

    public mutating func next(fps: Int32) -> CMTime {
        time = CMTimeAdd(time, CMTime(value: 1, timescale: fps))
        return time
    }
}
