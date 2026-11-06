import SwiftUI
import UniformTypeIdentifiers

struct PhotoView: View {
    @Bindable var store: PhotoStore
    @AppStorage("palette") private var palette = Palette.spectral
    @AppStorage("viewMode") private var mode = ViewMode.depth
    @State private var importing = false
    @State private var choosingFolder = false
    @State private var exportFile: PNGFile?
    @State private var exportFailed = false

    var body: some View {
        NavigationSplitView {
            List(store.items, selection: $store.selection) { item in
                SidebarRow(item: item)
                    .contextMenu { Button("Remove") { store.remove(item.id) } }
            }
            .onDeleteCommand { if let id = store.selection { store.remove(id) } }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .navigationTitle(store.selected?.name ?? "No Image")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in store.add(urls) > 0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
        .fileExporter(isPresented: .init(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      item: exportFile, contentTypes: [.png],
                      defaultFilename: (store.selected?.name ?? "depth") + "-depth") { _ in }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { exportAll(to: folder) }
        }
        .alert("Couldn't Export All Images", isPresented: $exportFailed) {} message: {
            Text("Check that you can write to the chosen folder.")
        }
        .focusedSceneValue(\.windowActions, WindowActions(
            add: { importing = true },
            export: store.selected?.depth == nil ? nil : export,
            exportAll: store.items.contains { $0.depth != nil } ? { choosingFolder = true } : nil))
    }

    @ViewBuilder private var detail: some View {
        if let item = store.selected {
            if let error = item.error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if let original = item.original, let depth = item.depth {
                let map = Image(decorative: depth[palette]!, scale: 1)
                Group {
                    if mode == .depth {
                        map.resizable().scaledToFit()
                    } else {
                        HStack(spacing: 16) {
                            Image(decorative: original, scale: 1).resizable().scaledToFit()
                            map.resizable().scaledToFit()
                        }
                    }
                }
                .padding()
            } else {
                ProgressView("Estimating Depth…")
            }
        } else {
            ContentUnavailableView {
                Label("No Images", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Drop images or folders here to estimate their depth.")
            } actions: {
                Button("Add Images…") { importing = true }
            }
        }
    }

    private var subtitle: String {
        store.isBusy ? "Processing \(store.processed + 1) of \(store.queued)"
            : store.items.isEmpty ? "" : "\(store.items.count) image\(store.items.count == 1 ? "" : "s")"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        WorkspaceToolbarItem()
        ToolbarItem(placement: .principal) { ModePicker(mode: $mode) }
        if store.isBusy {
            ToolbarItem { ProgressView().controlSize(.small) }
                .withoutSharedBackground()
        }
        ToolbarItemGroup {
            Button("Add Images…", systemImage: "plus") { importing = true }
                .help("Add images or folders")
            PaletteMenu(palette: $palette)
        }
        ToolbarGap()
        ToolbarItem {
            Button("Export…", action: export)
                .prominentButton()
                .disabled(store.selected?.depth == nil)
                .help("Save the current view as a PNG")
        }
    }

    private func export() {
        guard let image = store.selected?.rendered(mode, palette) else { return }
        exportFile = PNGFile(data: pngData(image))
    }

    /// run.py's batch output: one PNG per image in the chosen folder.
    private func exportAll(to folder: URL) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        do {
            for item in store.items {
                guard let image = item.rendered(mode, palette) else { continue }
                try pngData(image).write(to: folder.appending(path: item.name + "-depth.png"))
            }
        } catch {
            exportFailed = true
        }
    }
}

private struct SidebarRow: View {
    let item: ImageItem

    var body: some View {
        Label {
            Text(item.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            if item.error != nil {
                Image(systemName: "exclamationmark.triangle")
            } else if let depth = item.depth {
                Image(decorative: depth[.spectral]!, scale: 1).resizable().scaledToFill()
                    .frame(width: 20, height: 20).clipShape(.rect(cornerRadius: 4))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
