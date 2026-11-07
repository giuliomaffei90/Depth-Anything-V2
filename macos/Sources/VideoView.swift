import AVKit
import SwiftUI

/// The photo workspace's twin for videos: same sidebar, toolbar and commands, with a player as the detail.
struct VideoView: View {
    @Bindable var store: VideoStore
    @AppStorage("palette") private var palette = Palette.spectral
    @AppStorage("viewMode") private var mode = ViewMode.depth
    @State private var importing = false
    @State private var choosingFolder = false
    @State private var exportFailed = false
    @State private var player = AVPlayer()

    var body: some View {
        NavigationSplitView {
            List(store.items, selection: $store.selection) { item in
                VideoRow(item: item)
                    .contextMenu { Button("Remove") { store.remove(item.id) } }
            }
            .onDeleteCommand { if let id = store.selection { store.remove(id) } }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .navigationTitle(store.selected?.name ?? "No Video")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in store.add(urls) > 0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { exportAll(to: folder) }
        }
        .alert("Couldn't Export the Video", isPresented: $exportFailed) {} message: {
            Text("Check that you can write to the chosen location.")
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            add: { importing = true },
            export: store.selected?.depth == nil || store.exporting ? nil : export,
            exportAll: store.items.contains { $0.depth != nil } && !store.exporting ? { choosingFolder = true } : nil))
        .task(id: PreviewKey(item: store.selected?.id, ready: store.selected?.depth != nil, mode: mode, palette: palette)) {
            await updatePreview()
        }
    }

    @ViewBuilder private var detail: some View {
        if let item = store.selected {
            if let error = item.error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if item.depth != nil {
                PlayerView(player: player).padding()
            } else {
                ProgressView(store.cinematic ? "Reading Depth…" : "Estimating Depth…", value: item.progress).frame(maxWidth: 300)
            }
        } else {
            ContentUnavailableView {
                Label(store.cinematic ? "No Cinematic Videos" : "No Videos", systemImage: "film.stack")
            } description: {
                Text(store.cinematic ? "Drop iPhone videos shot in Cinematic mode to extract the depth they recorded."
                                     : "Drop videos or folders here to estimate their depth.")
            } actions: {
                Button("Add Videos…") { importing = true }
            }
        }
    }

    private var subtitle: String {
        store.exporting ? "Exporting…"
            : store.isBusy ? "Processing \(store.processed + 1) of \(store.queued)"
            : store.items.isEmpty ? "" : "\(store.items.count) video\(store.items.count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        WorkspaceToolbarItem()
        ToolbarItem(placement: .principal) { ModePicker(mode: $mode) }
        if store.isBusy {
            ToolbarItem { ProgressView().controlSize(.small) }
                .withoutSharedBackground()
        }
        ToolbarItemGroup {
            Button("Add Videos…", systemImage: "plus") { importing = true }
                .help("Add videos or folders")
            PaletteMenu(palette: $palette)
        }
        ToolbarGap()
        ToolbarItem {
            Button("Export…", action: export)
                .prominentButton()
                .disabled(store.selected?.depth == nil || store.exporting)
                .help("Save the depth map as an MPEG-4 movie")
        }
    }

    /// Swaps the player's composition when the video, view mode or palette changes, keeping the playhead.
    private func updatePreview() async {
        guard let item = store.selected, let depth = item.depth else { player.replaceCurrentItem(with: nil); return }
        let asset = AVURLAsset(url: item.url)
        guard let composition = try? await depthComposition(asset, depth, mode, palette) else { return }
        if let current = player.currentItem, (current.asset as? AVURLAsset)?.url == item.url {
            current.videoComposition = composition
        } else {
            let playerItem = AVPlayerItem(asset: asset)
            playerItem.videoComposition = composition
            player.replaceCurrentItem(with: playerItem)
        }
    }

    private func export() {
        guard let item = store.selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = item.name + "-depth.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { exportFailed = await !store.export([item], palette: palette) { _ in url } }
    }

    /// One movie per video in the chosen folder, like the photo workspace's Export All.
    private func exportAll(to folder: URL) {
        Task {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            exportFailed = await !store.export(store.items, palette: palette) {
                folder.appending(path: $0.name + "-depth.mp4")
            }
        }
    }
}

/// AVKit's player view. SwiftUI's VideoPlayer aborts at launch in a SwiftPM-built app: its overlay loads
/// without AVKit, so AVPlayerView's metadata is missing.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

private struct PreviewKey: Equatable {
    let item: VideoItem.ID?, ready: Bool, mode: ViewMode, palette: Palette
}

private struct VideoRow: View {
    let item: VideoItem

    var body: some View {
        Label {
            Text(item.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            if item.error != nil {
                Image(systemName: "exclamationmark.triangle")
            } else if let thumbnail = item.thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                    .frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 4))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
