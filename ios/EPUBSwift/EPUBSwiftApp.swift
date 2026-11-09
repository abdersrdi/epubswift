import SwiftUI

@main
struct EPUBSwiftApp: App {
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    init() {
        OutFiles.clear()
        if ScreenshotMode.isActive {
            ScreenshotMode.prepareDefaults()
            Premium.shared.set(ScreenshotMode.premium)
        } else {
            StoreManager.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Palette.indigo)
                .preferredColorScheme((Appearance(rawValue: appearanceRaw) ?? .system).scheme)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = ScreenshotMode.tab

    var body: some View {
        Group {
            if ScreenshotMode.showsPaywall {
                PaywallView()
            } else {
                TabView(selection: $tab) {
                    LibraryView()
                        .tabItem { Label(L("Library"), systemImage: "books.vertical") }
                        .tag(0)
                    BookMakerView()
                        .tabItem { Label(L("Create"), systemImage: "square.and.pencil") }
                        .tag(3)
                    ToolsView()
                        .tabItem { Label(L("Tools"), systemImage: "wrench.and.screwdriver") }
                        .tag(1)
                    SettingsView()
                        .tabItem { Label(L("Settings"), systemImage: "gearshape") }
                        .tag(2)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The tracking prompt only works once the app is active, so ads start from here.
            if phase == .active && !ScreenshotMode.isActive {
                AdManager.shared.start()
                Task { await StoreManager.shared.refreshEntitlements() }
            }
        }
        .onAppear { if !ScreenshotMode.isActive { AdManager.shared.start() } }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await LibraryStore.shared.importFiles([url]) }
        }
    }
}
