import Foundation
import StoreKit

/// Product IDs. Create these exactly in App Store Connect:
/// a subscription group "EPUBSwift Premium" with the monthly and yearly auto-renewing subscriptions,
/// plus one non-consumable in-app purchase for the lifetime unlock.
enum PremiumProducts {
    static let monthly = "epubswift_premium_monthly"
    static let yearly = "epubswift_premium_yearly"
    static let lifetime = "epubswift_premium_lifetime"
    static let all = [lifetime, yearly, monthly]
}

/// Premium unlocks the Tools tab and removes ads. The library and reader are always free.
@MainActor
final class Premium: ObservableObject {
    static let shared = Premium()
    @Published private(set) var isPremium = false
    private let cacheKey = "epubswift_premium_cached"

    private init() {
        // Cached so the right experience shows before StoreKit answers on launch.
        isPremium = UserDefaults.standard.bool(forKey: cacheKey)
    }

    func set(_ active: Bool) {
        isPremium = active
        UserDefaults.standard.set(active, forKey: cacheKey)
    }
}

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var loading = true
    @Published var message: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result { await transaction.finish() }
                await self.refreshEntitlements()
            }
        }
        refresh()
    }

    func refresh() {
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func loadProducts() async {
        loading = true
        do {
            let fetched = try await Product.products(for: PremiumProducts.all)
            products = PremiumProducts.all.compactMap { id in fetched.first { $0.id == id } }
            if products.isEmpty { message = L("Premium is not available yet. Please try again later.") }
        } catch {
            message = L("The App Store is not available right now.")
        }
        loading = false
    }

    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, PremiumProducts.all.contains(t.productID), t.revocationDate == nil {
                active = true
            }
        }
        Premium.shared.set(active)
    }

    func purchase(_ product: Product) async {
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                case .unverified:
                    message = L("The purchase could not be verified. You were not charged.")
                }
            case .pending:
                message = L("Your payment is pending approval. Premium unlocks as soon as it is confirmed.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = L("The purchase could not be completed. You were not charged.")
        }
    }

    func restore() async {
        message = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = Premium.shared.isPremium ? L("Premium restored.") : L("No previous purchases were found.")
        } catch {
            message = L("Could not restore purchases right now.")
        }
    }

    // MARK: Display

    static func title(for product: Product) -> String {
        switch product.id {
        case PremiumProducts.lifetime: return L("Lifetime")
        case PremiumProducts.yearly: return L("Yearly")
        default: return L("Monthly")
        }
    }

    static func period(for product: Product) -> String {
        if product.id == PremiumProducts.lifetime { return L("one time") }
        guard let sub = product.subscription else { return "" }
        switch sub.subscriptionPeriod.unit {
        case .year: return L("per year")
        case .month: return L("per month")
        case .week: return L("per week")
        default: return L("per day")
        }
    }
}
