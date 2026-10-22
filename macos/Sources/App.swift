import SwiftUI

@main
struct DepthAnythingApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Depth Anything", id: "main") {
            ContentView(store: delegate.store)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            AppCommands()
        }
    }
}

/// Owns the store so files from Finder's Open With arrive even before the window exists, all of them
/// (SwiftUI's onOpenURL only delivers the first).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    func application(_ application: NSApplication, open urls: [URL]) { store.add(urls) }
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Images…") { actions?.add() }
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
