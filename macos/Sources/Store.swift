import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@Observable final class ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    var original: CGImage?
    /// The depth map in each palette, made once so redraws don't recolour millions of pixels.
    var depth: [Palette: CGImage]?
    var error: String?

    init(url: URL) { self.url = url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isDone: Bool { depth != nil || error != nil }
}

@MainActor @Observable final class Store {
    var items: [ImageItem] = []
    var selection: ImageItem.ID?
    private(set) var processed = 0
    private(set) var queued = 0

    @ObservationIgnored private lazy var estimator = Result { try DepthEstimator() }
    @ObservationIgnored private var worker: Task<Void, Never>?

    var selected: ImageItem? { items.first { $0.id == selection } }
    var isBusy: Bool { processed < queued }

    /// Images, or folders of images (run.py's `--img-path` directory mode).
    func add(_ urls: [URL]) {
        let files = urls.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
            let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return all.sorted { $0.path < $1.path }
        }.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }

        let new = files.map(ImageItem.init)
        items += new
        if selection == nil { selection = new.first?.id }
        queued += new.count
        process(new)
    }

    func remove(_ id: ImageItem.ID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    private func process(_ new: [ImageItem]) {
        let previous = worker
        worker = Task {
            await previous?.value
            for item in new {
                await run(item)
                processed += 1
            }
        }
    }

    private func run(_ item: ImageItem) async {
        guard case .success(let estimator) = estimator else { item.error = "The depth model couldn't be loaded."; return }

        let url = item.url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(CGImage, [Palette: CGImage]), Error> in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return Result {
                guard let image = loadImage(url) else { throw CocoaError(.fileReadCorruptFile) }
                let depth = try estimator.depth(of: image)
                return (image, Dictionary(uniqueKeysWithValues: Palette.allCases.map { ($0, depth.image($0)) }))
            }
        }.value
        switch result {
        case .success(let (image, depth)): item.original = image; item.depth = depth
        case .failure: item.error = "Couldn't read this image."
        }
    }
}

/// Upright image (EXIF orientation applied), capped at 4096 px on the long side.
// ponytail: 4096 cap keeps memory bounded for huge photos; raise it if full-res exports matter.
private func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ] as CFDictionary)
}

enum ViewMode: String, CaseIterable, Identifiable {
    case depth, sideBySide
    var id: Self { self }
    var title: String { self == .depth ? "Depth" : "Side by Side" }
}

extension ImageItem {
    /// What run.py writes: the depth map alone (`--pred-only`) or original | 50 px white | depth.
    func rendered(_ mode: ViewMode, _ palette: Palette) -> CGImage? {
        guard let map = depth?[palette], let original else { return nil }
        guard mode == .sideBySide else { return map }
        let gap = 50, w = original.width * 2 + gap, h = original.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: h))
        ctx.draw(map, in: CGRect(x: original.width + gap, y: 0, width: original.width, height: h))
        return ctx.makeImage()
    }
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

struct PNGFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}
