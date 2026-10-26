import SwiftUI
import StoreKit

struct SettingsView: View {
    @ObservedObject private var premium = Premium.shared
    @StateObject private var store = StoreManager.shared
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @State private var showPaywall = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Premium")) {
                    if premium.isPremium {
                        Label(L("Premium is active"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Link(L("Manage subscription"), destination: AppLinks.manageSubscriptions)
                    } else {
                        Button { showPaywall = true } label: {
                            Label(L("Unlock tools and remove ads"), systemImage: "crown.fill")
                        }
                    }
                    Button(L("Restore purchases")) { Task { await store.restore() } }
                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section(L("Appearance")) {
                    Picker(L("Theme"), selection: $appearanceRaw) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(L("Privacy")) {
                    Button(L("Ad and tracking choices")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Link(L("Privacy Policy"), destination: AppLinks.privacy)
                    Link(L("Terms of Use"), destination: AppLinks.terms)
                }
                Section(L("Storage")) {
                    Button(cleared ? L("Temporary files cleared") : L("Clear temporary files")) {
                        OutFiles.clear()
                        cleared = true
                    }
                    Text(L("Books stay on this device. Tool results are saved only when you share or add them."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text(L("Version"))
                        Spacer()
                        Text(version).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L("Settings"))
            .safeAreaInset(edge: .bottom) { BannerBar() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
