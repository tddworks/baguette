import ArgumentParser
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// `baguette camera-inject --udid <UDID> --input <file> [--loop]`
///
/// Injects an image or video file into the simulator's camera feed
/// using the shared-memory pipeline (`/tmp/SimCam.bgra`). The
/// VirtualCamera dylib must be armed on the target simulator first
/// (happens automatically when streaming via `baguette serve`'s
/// camera WS route, or can be done manually with `simctl spawn`).
///
/// For images: pushes the same frame at 30 fps until interrupted.
/// For videos: decodes at native frame rate; `--loop` restarts from
/// the beginning when the file ends.
struct CameraInjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera-inject",
        abstract: "Inject an image or video file into a simulator's camera"
    )

    @OptionGroup var options: DeviceOption

    @Option(name: .shortAndLong, help: "Path to image (JPEG, PNG) or video (MP4, MOV, M4V, AVI) file")
    var input: String

    @Flag(name: .long, help: "Loop video from the beginning when it ends (images always stream until Ctrl+C)")
    var loop = false

    /// File extensions recognised as video (decoded via AVAssetReader).
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi"]

    /// Thread-safe cancellation flag shared between the SIGINT handler
    /// and the frame-writing loops. Using a reference type avoids the
    /// Swift 6 exclusivity issues with mutating a local `var Bool`
    /// from an escaping `DispatchSource` closure while also passing
    /// it as `inout` to an async function.
    private final class CancelFlag: @unchecked Sendable {
        var cancelled = false
    }

    /// Entry point — installs the VirtualCamera dylib, arms the
    /// simulator, then streams frames from the input file to the
    /// shared-memory sink at `/tmp/SimCam.bgra`.
    func run() async throws {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            throw ExitCode.failure
        }

        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: input) else {
            log("File not found: \(input)")
            throw ExitCode.failure
        }

        guard let dylibPath = VirtualCameraInstaller.installIfNeeded() else {
            log("VirtualCamera dylib not bundled in this build.")
            log("Build baguette with: ./VirtualCamera/build.sh && make")
            throw ExitCode.failure
        }

        log("Arming virtual camera on simulator...")
        let injection = SimctlSimulatorInjection()
        try await injection.arm(dylibPath: dylibPath, on: simulator)
        defer { Task { try? await injection.disarm(on: simulator) } }

        let sinkPath = "/tmp/SimCam.bgra"
        let sink = try SharedMemoryFrameSink(path: sinkPath)
        log("Writing frames to \(sinkPath)")

        let cancel = CancelFlag()
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler { cancel.cancelled = true }
        signalSource.resume()

        let flags = CameraFlags()
        let ext = inputURL.pathExtension.lowercased()

        if Self.videoExts.contains(ext) {
            try await injectVideo(url: inputURL, sink: sink, flags: flags, cancel: cancel)
        } else {
            try await injectImage(url: inputURL, sink: sink, flags: flags, cancel: cancel)
        }

        log("Camera injection stopped")
    }

    // MARK: - Image

    /// Decode a still image via ImageIO, render it to a tightly-packed
    /// BGRA buffer, then push the same frame at ~30 fps until the user
    /// presses Ctrl+C.
    private func injectImage(
        url: URL,
        sink: SharedMemoryFrameSink,
        flags: CameraFlags,
        cancel: CancelFlag
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log("Failed to load image: \(url.path)")
            throw ExitCode.failure
        }

        let (imgW, imgH) = Self.fitToCanvas(cgImage.width, cgImage.height)
        let bpr = imgW * 4
        var pixels = Data(count: bpr * imgH)
        pixels.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress,
               let ctx = CGContext(
                   data: base, width: imgW, height: imgH,
                   bitsPerComponent: 8, bytesPerRow: bpr,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
               ) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
            }
        }

        log("Injecting \(url.lastPathComponent) (\(imgW)×\(imgH))...")
        log("Press Ctrl+C to stop")

        var seq: UInt32 = 0
        let w = UInt32(imgW)
        let h = UInt32(imgH)
        while !cancel.cancelled {
            let frame = try CameraFrame(
                sequence: seq,
                timestampMs: UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000)),
                width: w, height: h, pixels: pixels
            )
            try sink.write(frame, flags: flags)
            seq &+= 1
            if seq % 30 == 0 { log("Frame \(seq) (\(w)×\(h))") }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
    }

    // MARK: - Video

    /// Decode a video file frame-by-frame via `AVAssetReader`, convert
    /// each `CVPixelBuffer` to a `CameraFrame` through `BGRAConverter`,
    /// and write to the shared-memory sink at the video's native frame
    /// rate. When `loop` is true the reader is re-created from the
    /// beginning each time the file ends.
    private func injectVideo(
        url: URL,
        sink: SharedMemoryFrameSink,
        flags: CameraFlags,
        cancel: CancelFlag
    ) async throws {
        var seq: UInt32 = 0

        repeat {
            let asset = AVAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                log("No video track in: \(url.path)")
                throw ExitCode.failure
            }

            let naturalSize = try await track.load(.naturalSize)
            let nominalRate = try await track.load(.nominalFrameRate)
            let fps = nominalRate > 0 ? Double(nominalRate) : 30.0
            let frameDuration: UInt64 = UInt64((1.0 / fps) * 1_000_000_000)

            let (targetW, targetH) = Self.fitToCanvas(
                Int(naturalSize.width), Int(naturalSize.height)
            )

            log("Injecting \(url.lastPathComponent) (\(targetW)×\(targetH) @ \(Int(fps))fps, loop=\(loop))...")
            if seq == 0 { log("Press Ctrl+C to stop") }

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetW,
                kCVPixelBufferHeightKey as String: targetH,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)
            reader.startReading()

            while reader.status == .reading && !cancel.cancelled {
                guard let sampleBuffer = output.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                let base = CVPixelBufferGetBaseAddress(pixelBuffer)
                let w = UInt32(CVPixelBufferGetWidth(pixelBuffer))
                let h = UInt32(CVPixelBufferGetHeight(pixelBuffer))
                let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)

                if let base {
                    let frame = try BGRAConverter.convert(
                        baseAddress: base, width: w, height: h, bytesPerRow: bpr,
                        sequence: seq,
                        timestampMs: UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))
                    )
                    try sink.write(frame, flags: flags)
                    seq &+= 1
                    if seq % 30 == 0 { log("Frame \(seq) (\(w)×\(h))") }
                }

                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                try await Task.sleep(nanoseconds: frameDuration)
            }

            if reader.status == .failed {
                log("Video reader failed: \(reader.error?.localizedDescription ?? "unknown error")")
                throw ExitCode.failure
            }

            if !loop { break }
            if !cancel.cancelled { log("Looping video...") }
        } while !cancel.cancelled
    }

    // MARK: - Helpers

    /// Scale dimensions down to fit within `SharedFrameLayout.maxCanvas`
    /// while preserving aspect ratio. Returns the original size when
    /// already within bounds.
    private static func fitToCanvas(_ srcW: Int, _ srcH: Int) -> (Int, Int) {
        let maxW = SharedFrameLayout.maxCanvasWidth
        let maxH = SharedFrameLayout.maxCanvasHeight
        if srcW <= maxW && srcH <= maxH { return (srcW, srcH) }
        let scale = min(Double(maxW) / Double(srcW), Double(maxH) / Double(srcH))
        return (max(1, Int(Double(srcW) * scale)), max(1, Int(Double(srcH) * scale)))
    }
}
