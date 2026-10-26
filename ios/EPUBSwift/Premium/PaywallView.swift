import SwiftUI
import StoreKit

enum AppLinks {
    static let privacy = URL(string: "https://epubswift.cc/privacy")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}

struct PaywallView: View {
    @StateObject private var store = StoreManager.shared
    @ObservedObject private var premium = Premium.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = PremiumProducts.yearly
    @State private var buying = false

    private var selected: Product? { store.products.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 10) {
                        Image(systemName: "crown.fill").font(.system(size: 40)).foregroundStyle(Palette.gold)
                        Text(L("EPUBSwift Premium")).font(.title.bold())
                        Text(L("Reading is free forever. Premium unlocks the tools.")).font(.subheadline)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        feature("wrench.and.screwdriver.fill", L("All 10 EPUB tools: convert, edit, repair, merge"))
                        feature("doc.richtext.fill", L("EPUB to PDF, PDF to EPUB, TXT and Markdown"))
                        feature("nosign", L("No ads anywhere in the app"))
                        feature("lock.shield.fill", L("Everything runs on your device"))
                    }
                    .card()

                    if store.loading && store.products.isEmpty {
                        ProgressView().padding()
                    } else if store.products.isEmpty {
                        VStack(spacing: 8) {
                            Text(store.message ?? L("Premium is not available yet. Please try again later.")).font(.footnote)
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(L("Try again")) { store.refresh() }.buttonStyle(.bordered)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.products, id: \.id) { product in plan(product) }
                        }
                    }

                    if premium.isPremium {
                        Label(L("Premium is active. Thank you!"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green).font(.headline)
                    } else {
                        Button {
                            guard let product = selected else { return }
                            buying = true
                            Task { await store.purchase(product); buying = false }
                        } label: {
                            HStack {
                                if buying { ProgressView().tint(.white) }
                                Text(buttonTitle).font(.headline)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(.white)
                        }
                        .disabled(selected == nil || buying)
                    }

                    if let message = store.message, !store.products.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }

                    Button(L("Restore purchases")) { Task { await store.restore() } }.font(.subheadline)

                    VStack(spacing: 6) {
                        Text(L("Monthly and yearly plans renew automatically unless cancelled at least 24 hours before the end of the current period. Payment is charged to your Apple ID account at confirmation of purchase. Manage or cancel in your Apple ID account settings. The lifetime unlock is a one-time purchase."))
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack(spacing: 16) {
                            Link(L("Terms of Use"), destination: AppLinks.terms)
                            Link(L("Privacy Policy"), destination: AppLinks.privacy)
                        }
                        .font(.caption)
                    }
                }
                .padding(16)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Close")) { dismiss() } } }
            .onAppear { if store.products.isEmpty { store.refresh() } }
            .onChange(of: premium.isPremium) { _, active in if active { dismiss() } }
        }
    }

    private var buttonTitle: String {
        guard let p = selected else { return L("Continue") }
        if p.id == PremiumProducts.lifetime { return String(format: L("Unlock for life, %@"), p.displayPrice) }
        return String(format: L("Subscribe, %@ %@"), p.displayPrice, StoreManager.period(for: p))
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Palette.indigo).frame(width: 24)
            Text(text).font(.subheadline)
            Spacer()
        }
    }

    private func plan(_ product: Product) -> some View {
        let isSelected = product.id == selectedID
        return Button { selectedID = product.id } label: {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Palette.indigo : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(StoreManager.title(for: product)).font(.headline).foregroundStyle(.primary)
                        if let badge = badge(for: product) {
                            Text(badge).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Palette.gold, in: Capsule()).foregroundStyle(.black)
                        }
                    }
                    Text(StoreManager.period(for: product)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice).font(.headline).foregroundStyle(.primary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.indigo : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func badge(for product: Product) -> String? {
        switch product.id {
        case PremiumProducts.yearly:
            if let monthly = store.products.first(where: { $0.id == PremiumProducts.monthly }) {
                let full = monthly.price * 12
                if full > 0 {
                    let save = Int((1 - NSDecimalNumber(decimal: product.price / full).doubleValue) * 100)
                    if save > 0 { return String(format: L("Save %d%%"), save) }
                }
            }
            return L("Best value")
        case PremiumProducts.lifetime: return L("Pay once")
        default: return nil
        }
    }
}
