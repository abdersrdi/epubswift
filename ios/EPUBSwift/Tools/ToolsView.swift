import SwiftUI

struct ToolsView: View {
    @ObservedObject private var premium = Premium.shared
    @State private var showPaywall = false
    @State private var path: [Tool] = ScreenshotMode.tool.map { [$0] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !premium.isPremium {
                    Section {
                        Button { showPaywall = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "lock.open.fill").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("Unlock all tools")).font(.headline)
                                    Text(L("Premium also removes every ad. Your library and reader stay free."))
                                        .font(.caption).opacity(0.9).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                        }
                        .listRowBackground(Palette.gradient)
                    }
                }
                Section(L("Convert")) { rows(Tool.convert) }
                Section(L("Edit and fix")) { rows(Tool.editing) }
            }
            .navigationTitle(L("Tools"))
            .navigationDestination(for: Tool.self) { ToolDestination(tool: $0) }
            .safeAreaInset(edge: .bottom) { BannerBar() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    @ViewBuilder
    private func rows(_ tools: [Tool]) -> some View {
        ForEach(tools) { tool in
            if premium.isPremium {
                NavigationLink(value: tool) { row(tool, locked: false) }
            } else {
                Button { showPaywall = true } label: { row(tool, locked: true) }
            }
        }
    }

    private func row(_ tool: Tool, locked: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: tool.icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(tool.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if locked { Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}
