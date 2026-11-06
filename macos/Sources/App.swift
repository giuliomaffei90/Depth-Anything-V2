import SwiftUI

@main
struct DepthAnythingApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Depth Anything", id: "main") {
            RootView(photos: delegate.photos, videos: delegate.videos, cinematic: delegate.cinematic)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            AppCommands()
        }
    }
}

/// Owns the stores so files from Finder's Open With arrive even before the window exists, all of them
/// (SwiftUI's onOpenURL only delivers the first).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let photos = PhotoStore()
    let videos = VideoStore()
    let cinematic = VideoStore(cinematic: true)
    @AppStorage("workspace") private var workspace = Workspace.photos

    func application(_ application: NSApplication, open urls: [URL]) {
        // Movies go to the Cinematic workspace only when it's the one showing.
        let movieWorkspace = workspace == .cinematic ? Workspace.cinematic : .videos
        let (images, movies) = (photos.add(urls), (movieWorkspace == .cinematic ? cinematic : videos).add(urls))
        if images == 0 && movies > 0 { workspace = movieWorkspace } else if images > 0 && movies == 0 { workspace = .photos }
    }
}

/// Three workspaces alike: photos (Depth Anything V2), videos (Video Depth Anything) and Cinematic mode videos
/// (the depth the iPhone recorded).
enum Workspace: String, CaseIterable, Identifiable {
    case photos, videos, cinematic
    var id: Self { self }
    var title: String { ["Photos", "Videos", "Cinematic"][Self.allCases.firstIndex(of: self)!] }
    var systemImage: String { ["photo", "film", "camera.aperture"][Self.allCases.firstIndex(of: self)!] }
}

struct RootView: View {
    let photos: PhotoStore, videos: VideoStore, cinematic: VideoStore
    @AppStorage("workspace") private var workspace = Workspace.photos

    var body: some View {
        switch workspace {
        case .photos: PhotoView(store: photos)
        case .videos: VideoView(store: videos)
        case .cinematic: VideoView(store: cinematic)
        }
    }
}

struct WindowActions {
    var add: () -> Void
    var export: (() -> Void)?      // nil = disabled
    var exportAll: (() -> Void)?
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

struct AppCommands: Commands {
    @FocusedValue(\.windowActions) private var actions
    @AppStorage("palette") private var palette = Palette.spectral
    @AppStorage("viewMode") private var mode = ViewMode.depth
    @AppStorage("workspace") private var workspace = Workspace.photos

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(workspace == .photos ? "Add Images…" : "Add Videos…") { actions?.add() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export…") { actions?.export?() }
                .keyboardShortcut("e")
                .disabled(actions?.export == nil)
            Button("Export All…") { actions?.exportAll?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportAll == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { i, w in
                Toggle(w.title, isOn: .init(get: { workspace == w }, set: { if $0 { workspace = w } }))
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            Divider()
            Picker("Show", selection: $mode) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Palette", selection: $palette) {
                ForEach(Palette.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }
    }
}

extension View {
    /// Tinted Liquid Glass for the one primary toolbar action; a bordered prominent button before macOS 26.
    @ViewBuilder func prominentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

extension ToolbarContent {
    /// Items without the shared glass capsule (e.g. a spinner); older systems have no capsule anyway.
    @ToolbarContentBuilder func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// A gap between toolbar groups on macOS 26; older toolbars have no glass groups to separate.
struct ToolbarGap: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }
}

/// Switches between the photo and video workspaces, at the leading edge of either toolbar.
struct WorkspaceToolbarItem: ToolbarContent {
    @AppStorage("workspace") private var workspace = Workspace.photos

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Workspace", selection: $workspace) {
                ForEach(Workspace.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Estimate the depth of photos or videos, or extract it from Cinematic mode videos")
        }
    }
}

struct ModePicker: View {
    @Binding var mode: ViewMode

    var body: some View {
        Picker("Show", selection: $mode) {
            ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .help("Show the depth map alone or next to the original")
    }
}

struct PaletteMenu: View {
    @Binding var palette: Palette

    var body: some View {
        Menu("Palette", systemImage: "paintpalette") {
            Picker("Palette", selection: $palette) {
                ForEach(Palette.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("Depth map colors")
    }
}
