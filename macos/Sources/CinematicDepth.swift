import AVFoundation
import Cinematic
import CoreImage

/// The depth an iPhone records in Cinematic mode: the clip's own disparity track, no model involved.
/// Throws for videos without one (not Cinematic, or shared without "All Photos Data").
func cinematicDepth(of url: URL, progress: (Double) -> Void) async throws -> VideoDepth {
    let asset = AVURLAsset(url: url)
    let info = try await CNAssetInfo(asset: asset)
    let track = info.cinematicDisparityTrack
    let expected = max(Double(try await track.load(.nominalFrameRate)) * info.timeRange.duration.seconds, 1)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_DisparityFloat16,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

    // preferredTransform is in y-down coordinates; Core Image is y-up, so its rotation runs the other way.
    let t = info.preferredTransform
    let upright = CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d, tx: 0, ty: 0)
    let context = CIContext()
    var times: [Double] = [], maps: [[Float]] = [], width = 0, height = 0
    // ponytail: every frame stays in memory as floats until the global min-max, like the video workspace.
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = sample.imageBuffer else { continue }
        let rotated = CIImage(cvPixelBuffer: buffer).transformed(by: upright)
        let image = rotated.transformed(by: .init(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        (width, height) = (Int(image.extent.width), Int(image.extent.height))
        var floats = [Float](repeating: 0, count: width * height)
        context.render(image, toBitmap: &floats, rowBytes: width * 4, bounds: image.extent, format: .Rf, colorSpace: nil)
        times.append(sample.presentationTimeStamp.seconds)
        maps.append(floats)
        progress(min(Double(times.count) / expected, 1))
    }
    guard reader.status != .failed, !times.isEmpty else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

    // Disparity is already "near = large", run.py's convention; holes (NaN) count as far.
    let finite = maps.lazy.flatMap { $0 }.filter(\.isFinite)
    let lo = finite.min() ?? 0, range = max((finite.max() ?? 1) - lo, .ulpOfOne)
    let frames = maps.map { d in
        DepthMap(width: width, height: height, values: d.map { $0.isFinite ? UInt8(min(max(($0 - lo) / range, 0), 1) * 255) : 0 })
    }
    return VideoDepth(times: times, frames: frames)
}
