import SwiftUI

@main
struct EPUBSwiftApp: App {
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    init() {
        OutFiles.clear()
        StoreManager.shared.start()
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

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label(L("Library"), systemImage: "books.vertical") }
            ToolsView()
                .tabItem { Label(L("Tools"), systemImage: "wrench.and.screwdriver") }
            SettingsView()
                .tabItem { Label(L("Settings"), systemImage: "gearshape") }
        }
        .onChange(of: scenePhase) { _, phase in
            // The tracking prompt only works once the app is active, so ads start from here.
            if phase == .active {
                AdManager.shared.start()
                Task { await StoreManager.shared.refreshEntitlements() }
            }
        }
        .onAppear { AdManager.shared.start() }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await LibraryStore.shared.importFiles([url]) }
        }
    }
}
