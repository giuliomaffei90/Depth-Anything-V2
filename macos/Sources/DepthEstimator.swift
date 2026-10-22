import CoreImage
import CoreML

/// Relative depth for one image: the Swift side of `DepthAnythingV2.infer_image` + the min-max
/// normalisation and colouring in run.py.
struct DepthMap {
    let width: Int, height: Int
    /// Normalised depth, 0 = far, 255 = near (run.py's uint8 map).
    let values: [UInt8]

    func image(_ palette: Palette) -> CGImage {
        let lut = palette.lut
        var rgba = [UInt8](repeating: 255, count: values.count * 4)
        for (i, v) in values.enumerated() {
            let c = lut[Int(v)]
            rgba[i * 4] = c.0; rgba[i * 4 + 1] = c.1; rgba[i * 4 + 2] = c.2
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

enum Palette: String, CaseIterable, Identifiable {
    case spectral, grayscale
    var id: Self { self }
    var title: String { self == .spectral ? "Spectral" : "Grayscale" }

    /// matplotlib's `Spectral_r` (run.py's default) or plain gray (`--grayscale`).
    var lut: [(UInt8, UInt8, UInt8)] {
        guard self == .spectral else { return (0...255).map { (UInt8($0), UInt8($0), UInt8($0)) } }
        let stops: [UInt32] = [0x5e4fa2, 0x3288bd, 0x66c2a5, 0xabdda4, 0xe6f598, 0xffffbf,
                               0xfee08b, 0xfdae61, 0xf46d43, 0xd53e4f, 0x9e0142]
        return (0...255).map { i in
            let x = Double(i) / 255 * Double(stops.count - 1)
            let k = min(Int(x), stops.count - 2), t = x - Double(k)
            func ch(_ shift: UInt32) -> UInt8 {
                let a = Double((stops[k] >> shift) & 0xff), b = Double((stops[k + 1] >> shift) & 0xff)
                return UInt8((a + (b - a) * t).rounded())
            }
            return (ch(16), ch(8), ch(0))
        }
    }
}

/// Apple's Core ML port of Depth-Anything-V2-Small (fixed 518×392 input, stretched like Apple's evaluation).
final class DepthEstimator {
    private let model: MLModel
    private let inputName: String, outputName: String
    private let inputSize: CGSize
    private let context = CIContext()

    init() throws {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        model = try MLModel(contentsOf: url)
        let input = model.modelDescription.inputDescriptionsByName.first!.value
        inputName = input.name
        outputName = model.modelDescription.outputDescriptionsByName.first!.key
        let c = input.imageConstraint!
        inputSize = CGSize(width: c.pixelsWide, height: c.pixelsHigh)
    }

    func depth(of image: CGImage) throws -> DepthMap {
        let source = CIImage(cgImage: image)
        let resized = source.transformed(by: .init(scaleX: inputSize.width / source.extent.width,
                                                   y: inputSize.height / source.extent.height))
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(inputSize.width), Int(inputSize.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        context.render(resized, to: buffer!)

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: buffer!]))
        let depth = CIImage(cvPixelBuffer: output.featureValue(for: outputName)!.imageBufferValue!)

        // Back to the original size (run.py: bilinear interpolate), read as floats, then min-max to 0…255.
        let (w, h) = (image.width, image.height)
        let full = depth.samplingLinear().transformed(by: .init(scaleX: CGFloat(w) / depth.extent.width,
                                                                y: CGFloat(h) / depth.extent.height))
        var floats = [Float](repeating: 0, count: w * h)
        context.render(full, toBitmap: &floats, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .Rf, colorSpace: nil)
        let lo = floats.min() ?? 0, range = max((floats.max() ?? 1) - lo, .ulpOfOne)
        return DepthMap(width: w, height: h, values: floats.map { UInt8(($0 - lo) / range * 255) })
    }
}
