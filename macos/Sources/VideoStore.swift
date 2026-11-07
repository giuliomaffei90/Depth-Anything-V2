import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    var progress = 0.0
    var depth: VideoDepth?
    /// First depth frame, for the sidebar.
    var thumbnail: CGImage?
    var error: String?

    init(url: URL) { self.url = url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The photo store's twin for videos: a queue that estimates one video at a time, or, for Cinematic mode clips,
/// reads the depth the iPhone recorded.
@MainActor @Observable final class VideoStore {
    let cinematic: Bool
    var items: [VideoItem] = []
    var selection: VideoItem.ID?
    private(set) var processed = 0
    private(set) var queued = 0
    private(set) var exporting = false

    @ObservationIgnored private lazy var estimator = Result { try VideoDepthEstimator() }
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(cinematic: Bool = false) { self.cinematic = cinematic }

    var selected: VideoItem? { items.first { $0.id == selection } }
    var isBusy: Bool { processed < queued || exporting }

    /// Videos, or folders of videos. Returns how many were added.
    @discardableResult func add(_ urls: [URL]) -> Int {
        let new = mediaFiles(in: urls, conformingTo: .movie).map(VideoItem.init)
        items += new
        if selection == nil { selection = new.first?.id }
        queued += new.count
        process(new)
        return new.count
    }

    func remove(_ id: VideoItem.ID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    private func process(_ new: [VideoItem]) {
        let previous = worker
        worker = Task {
            await previous?.value
            for item in new {
                await run(item)
                processed += 1
            }
        }
    }

    private func run(_ item: VideoItem) async {
        let source: (URL, (Double) -> Void) async throws -> VideoDepth
        if cinematic {
            source = cinematicDepth
        } else {
            guard case .success(let estimator) = estimator else { item.error = "The video depth model couldn't be loaded."; return }
            source = estimator.depth
        }

        let url = item.url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<VideoDepth, Error> in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                return .success(try await source(url) { p in Task { @MainActor in item.progress = p } })
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let depth): item.thumbnail = depth.frames[0].image(.spectral); item.depth = depth
        case .failure: item.error = cinematic ? "No Cinematic mode depth in this video." : "Couldn't read this video."
        }
    }

    /// Writes the depth map alone (side by side is only for checking), with the original audio, as an MPEG-4 movie.
    func export(_ items: [VideoItem], palette: Palette, to destination: (VideoItem) -> URL) async -> Bool {
        exporting = true
        defer { exporting = false }
        for item in items {
            guard let depth = item.depth else { continue }
            let url = destination(item)
            try? FileManager.default.removeItem(at: url)
            guard let asset = try? await videoAndAudio(of: AVURLAsset(url: item.url)),
                  let composition = try? await depthComposition(asset, depth, .depth, palette),
                  let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
            else { return false }
            session.videoComposition = composition
            session.outputURL = url
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else { return false }
        }
        return true
    }
}

/// The first video track and the audio of `asset`: export can't decode the extra tracks of a Cinematic mode clip
/// (disparity and metadata).
func videoAndAudio(of asset: AVAsset) async throws -> AVAsset {
    let composition = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
    let tracks = try await asset.loadTracks(withMediaType: .video).prefix(1) + asset.loadTracks(withMediaType: .audio)
    for track in tracks {
        let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try copy.insertTimeRange(range, of: track, at: .zero)
        copy.preferredTransform = try await track.load(.preferredTransform)
    }
    return composition
}

/// Plays or exports `asset` with each frame replaced by its depth map, or placed next to it like run.py does.
func depthComposition(_ asset: AVAsset, _ depth: VideoDepth, _ mode: ViewMode, _ palette: Palette) async throws -> AVVideoComposition {
    let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
        let size = mode == .depth ? request.renderSize : CGSize(width: (request.renderSize.width - 50) / 2,
                                                                height: request.renderSize.height)
        let frame = depth.frame(at: request.compositionTime.seconds)
        let map = CIImage(cgImage: frame.image(palette))
            .transformed(by: .init(scaleX: size.width / CGFloat(frame.width), y: size.height / CGFloat(frame.height)))
        guard mode == .sideBySide else { return request.finish(with: map, context: nil) }
        let white = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: request.renderSize))
        let original = request.sourceImage.cropped(to: CGRect(origin: .zero, size: size))
        request.finish(with: map.transformed(by: .init(translationX: size.width + 50, y: 0))
            .composited(over: original.composited(over: white)), context: nil)
    }.mutableCopy() as! AVMutableVideoComposition
    if mode == .sideBySide {
        // The source frames keep their size; the handler lays them out on the wider canvas.
        composition.renderSize.width = composition.renderSize.width * 2 + 50
    }
    return composition
}

/// Files of `type`, with folders expanded (run.py's directory mode).
func mediaFiles(in urls: [URL], conformingTo type: UTType) -> [URL] {
    urls.flatMap { url -> [URL] in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
        let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.sorted { $0.path < $1.path }
    }.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: type) == true }
}
