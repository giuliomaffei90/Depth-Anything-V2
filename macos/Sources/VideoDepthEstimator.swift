import AVFoundation
import CoreImage
import CoreML

/// Temporally consistent depth for a whole video: the Swift side of Video-Depth-Anything's
/// `infer_video_depth` + the global min-max normalisation in its `save_video`.
struct VideoDepth {
    /// Presentation time of each frame, in seconds.
    let times: [Double]
    /// One map per frame at the model's size, all normalised together so brightness doesn't flicker.
    let frames: [DepthMap]

    /// The map shown at `time`: the last frame that started at or before it.
    func frame(at time: Double) -> DepthMap {
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= time + 0.001 { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }
}

/// Video-Depth-Anything-Small converted by convert_video_model.py: 32-frame windows at a fixed size
/// (frames are stretched to it, like the photo model).
final class VideoDepthEstimator {
    // Video-Depth-Anything's inference settings ("do not change").
    static let inferLen = 32, overlap = 10, interpLen = 8
    static let keyframes = [0, 12, 24, 25, 26, 27, 28, 29, 30, 31]

    private let model: MLModel
    private let width: Int, height: Int
    private let context = CIContext()

    init() throws {
        guard let url = Bundle.main.url(forResource: "VideoDepthAnythingSmallF16", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // The Neural Engine compiler takes many minutes over this model on first load; the GPU is ready at once.
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: config)
        let shape = model.modelDescription.inputDescriptionsByName["frames"]!.multiArrayConstraint!.shape
        (height, width) = (shape[3].intValue, shape[4].intValue)
    }

    func depth(of url: URL, progress: (Double) -> Void) async throws -> VideoDepth {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let expected = max(Double(try await track.load(.nominalFrameRate)) * (try await asset.load(.duration)).seconds, 1)

        // A composition output applies the track's rotation, so portrait clips arrive upright.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        var times: [Double] = []
        func nextFrame() -> [Float]? {
            guard let sample = output.copyNextSampleBuffer(), let buffer = sample.imageBuffer else { return nil }
            times.append(sample.presentationTimeStamp.seconds)
            return planarRGB(CIImage(cvPixelBuffer: buffer))
        }

        // infer_video_depth, streamed: windows of 32 input frames advancing by 22, where the first 10 inputs are
        // the previous window's keyframes; the tail is padded with copies of the last frame.
        let (n, step) = (Self.inferLen, Self.inferLen - Self.overlap)
        let alignLen = Self.overlap - Self.interpLen
        var pending: [[Float]] = [], previous: [[Float]]?
        var start = 0
        var aligned: [[Float]] = [], reference: [[Float]] = []
        // ponytail: every aligned frame stays in memory as floats (~600 KB each) until the global min-max;
        // stream them to disk or Float16 if hour-long videos matter.
        while true {
            while pending.count < n, let frame = nextFrame() { pending.append(frame) }
            if start >= times.count { break }
            while pending.count < n { pending.append(pending.last!) }

            var input = pending
            if let previous { for (i, k) in Self.keyframes.enumerated() { input[i] = previous[k] } }
            let depth = try predict(input)

            if aligned.isEmpty {
                aligned = depth
                reference = Self.keyframes[..<alignLen].map { depth[$0] }
            } else {
                let (scale, shift) = scaleAndShift(Array(depth[..<alignLen]), to: reference)
                func fit(_ d: [Float]) -> [Float] { d.map { max($0 * scale + shift, 0) } }
                // Cross-fade the overlap: the old window's last frames into this window's re-estimate of them.
                let post = depth[alignLen..<Self.overlap].map(fit)
                for (i, p) in post.enumerated() {
                    let w = Float(i) / Float(Self.interpLen - 1), j = aligned.count - Self.interpLen + i
                    aligned[j] = zip(aligned[j], p).map { $0 * (1 - w) + $1 * w }
                }
                aligned += depth[Self.overlap...].map(fit)
                reference = [reference[0]] + Self.keyframes[1..<alignLen].map { fit(depth[$0]) }
            }

            previous = input
            pending.removeFirst(step)
            start += step
            progress(min(Double(times.count) / expected, 1))
        }
        guard reader.status != .failed, !times.isEmpty else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        aligned.removeLast(aligned.count - times.count)
        let lo = aligned.lazy.map { $0.min()! }.min()!, hi = aligned.lazy.map { $0.max()! }.max()!
        let range = max(hi - lo, .ulpOfOne)
        let frames = aligned.map { d in DepthMap(width: width, height: height, values: d.map { UInt8(($0 - lo) / range * 255) }) }
        return VideoDepth(times: times, frames: frames)
    }

    /// One frame stretched to the model size as planar RGB in 0…1.
    private func planarRGB(_ frame: CIImage) -> [Float] {
        let resized = frame.transformed(by: .init(scaleX: CGFloat(width) / frame.extent.width,
                                                  y: CGFloat(height) / frame.extent.height))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(resized, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let plane = width * height
        var rgb = [Float](repeating: 0, count: plane * 3)
        for i in 0..<plane {
            rgb[i] = Float(rgba[i * 4]) / 255
            rgb[plane + i] = Float(rgba[i * 4 + 1]) / 255
            rgb[2 * plane + i] = Float(rgba[i * 4 + 2]) / 255
        }
        return rgb
    }

    private func predict(_ window: [[Float]]) throws -> [[Float]] {
        let input = try MLMultiArray(shape: [1, NSNumber(value: window.count), 3, NSNumber(value: height), NSNumber(value: width)],
                                     dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for (i, frame) in window.enumerated() {
                _ = frame.withUnsafeBufferPointer { memcpy(buffer.baseAddress! + i * frame.count, $0.baseAddress!, $0.count * 4) }
            }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["frames": input]))
        let scalars = MLShapedArray<Float>(converting: output.featureValue(for: "depth")!.multiArrayValue!).scalars
        let plane = width * height
        return (0..<window.count).map { Array(scalars[$0 * plane..<($0 + 1) * plane]) }
    }
}

/// Least-squares scale and shift taking `prediction` onto `target` (compute_scale_and_shift).
func scaleAndShift(_ prediction: [[Float]], to target: [[Float]]) -> (Float, Float) {
    var a00 = 0.0, a01 = 0.0, a11 = 0.0, b0 = 0.0, b1 = 0.0
    for (p, t) in zip(prediction, target) {
        for (x, y) in zip(p, t) {
            let x = Double(x), y = Double(y)
            a00 += x * x; a01 += x; a11 += 1; b0 += x * y; b1 += y
        }
    }
    let det = a00 * a11 - a01 * a01
    guard det != 0 else { return (1, 0) }
    return (Float((a11 * b0 - a01 * b1) / det), Float((-a01 * b0 + a00 * b1) / det))
}
