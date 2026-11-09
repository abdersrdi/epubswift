import SwiftUI
import UIKit
import AppTrackingTransparency
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

/// AdMob unit IDs. Debug builds use Google's SAMPLE units so development never produces real
/// impressions; Release builds use the production units for this app.
enum AdUnits {
    private static let testBanner = "ca-app-pub-3940256099942544/2435281174"
    private static let testInterstitial = "ca-app-pub-3940256099942544/4411468910"
    private static let testNative = "ca-app-pub-3940256099942544/3986624511"
    private static let testRewarded = "ca-app-pub-3940256099942544/1712485313"

    private static let prodBanner = "ca-app-pub-2683853184901962/6678275675"
    private static let prodInterstitial = "ca-app-pub-2683853184901962/6009685125"
    private static let prodNative = "ca-app-pub-2683853184901962/4187843708"
    private static let prodRewarded = "ca-app-pub-2683853184901962/9191219957"

    #if DEBUG
    static let banner = testBanner
    static let interstitial = testInterstitial
    static let native = testNative
    static let rewarded = testRewarded
    #else
    static let banner = prodBanner
    static let interstitial = prodInterstitial
    static let native = prodNative
    static let rewarded = prodRewarded
    #endif
}

extension UIApplication {
    static func topViewController() -> UIViewController? {
        let scene = shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

/// Decides how often a full-screen ad may appear: every third time a book is closed, and at most every 3 minutes.
enum AdPacing {
    private static let countKey = "epubswift_reader_closes"
    private static var lastShown = Date.distantPast

    static func shouldShowAfterReader() -> Bool {
        let d = UserDefaults.standard
        let n = d.integer(forKey: countKey) + 1
        d.set(n, forKey: countKey)
        guard n % 3 == 0, Date().timeIntervalSince(lastShown) > 180 else { return false }
        lastShown = Date()
        return true
    }
}

#if canImport(GoogleMobileAds)

@MainActor
final class AdManager: NSObject, FullScreenContentDelegate {
    static let shared = AdManager()

    private var started = false
    private var interstitial: InterstitialAd?

    /// Asks for tracking permission (required before personalised ads), then starts the SDK.
    func start() {
        guard !started else { return }
        started = true
        let begin = {
            MobileAds.shared.start(completionHandler: nil)
            Task { @MainActor in
                self.preloadInterstitial()
                RewardedAds.shared.preload()
            }
        }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            ATTrackingManager.requestTrackingAuthorization { _ in DispatchQueue.main.async { begin() } }
        } else {
            begin()
        }
    }

    func preloadInterstitial() {
        guard !Premium.shared.isPremium, interstitial == nil else { return }
        Task {
            do {
                let ad = try await InterstitialAd.load(with: AdUnits.interstitial, request: Request())
                ad.fullScreenContentDelegate = self
                self.interstitial = ad
            } catch {
                self.interstitial = nil
            }
        }
    }

    /// Interstitials only at natural breaks (after closing a book), never for Premium members.
    func afterReader() {
        guard !Premium.shared.isPremium, AdPacing.shouldShowAfterReader() else { return }
        guard let ad = interstitial, let vc = UIApplication.topViewController() else {
            preloadInterstitial()
            return
        }
        interstitial = nil
        ad.present(from: vc)
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.preloadInterstitial() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.preloadInterstitial() }
    }
}

/// The rewarded video used by the Book Maker: one video removes the "Made with EPUBSwift" note from one export, and three
/// videos earn one more export. It never plays unless the person taps the button.
@MainActor
final class RewardedAds: NSObject, ObservableObject, FullScreenContentDelegate {
    static let shared = RewardedAds()

    @Published private(set) var isReady = false
    private var ad: RewardedAd?
    private var loading = false
    private var earned = false
    private var finish: ((Bool) -> Void)?

    /// True where this build can show videos at all.
    var isAvailable: Bool { !Premium.shared.isPremium }

    func preload() {
        guard isAvailable, ad == nil, !loading else { return }
        loading = true
        Task {
            do {
                let loaded = try await RewardedAd.load(with: AdUnits.rewarded, request: Request())
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.isReady = true
            } catch {
                self.ad = nil
                self.isReady = false
            }
            self.loading = false
        }
    }

    /// Plays a video. The completion gets true only if it was watched to the end and the reward was earned.
    func show(_ completion: @escaping (Bool) -> Void) {
        guard let ad, let vc = UIApplication.topViewController() else {
            preload()
            completion(false)
            return
        }
        earned = false
        finish = completion
        self.ad = nil
        isReady = false
        ad.present(from: vc) { [weak self] in self?.earned = true }
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in
            let done = self.finish, got = self.earned
            self.finish = nil
            self.earned = false
            done?(got)
            self.preload()
        }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            let done = self.finish
            self.finish = nil
            done?(false)
            self.preload()
        }
    }
}

struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: AdSizeBanner)
        banner.adUnitID = AdUnits.banner
        banner.rootViewController = UIApplication.topViewController()
        banner.load(Request())
        return banner
    }

    func updateUIView(_ uiView: BannerView, context: Context) {}
}

/// A native ad styled as a compact card.
final class NativeAdLoaderModel: NSObject, ObservableObject, NativeAdLoaderDelegate {
    @Published var nativeAd: NativeAd?
    private var loader: AdLoader?

    func load() {
        guard loader == nil else { return }
        let l = AdLoader(adUnitID: AdUnits.native, rootViewController: UIApplication.topViewController(),
                         adTypes: [.native], options: nil)
        l.delegate = self
        loader = l
        l.load(Request())
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        DispatchQueue.main.async { self.nativeAd = nativeAd }
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        DispatchQueue.main.async { self.loader = nil }
    }
}

final class NativeCardView: NativeAdView {
    private let iconImage = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let adBadge = UILabel()
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.cornerRadius = 14
        clipsToBounds = true
        iconImage.layer.cornerRadius = 10
        iconImage.clipsToBounds = true
        iconImage.contentMode = .scaleAspectFill
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 1
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 2
        adBadge.text = "Ad"
        adBadge.font = .systemFont(ofSize: 10, weight: .bold)
        adBadge.textColor = .white
        adBadge.backgroundColor = UIColor.systemOrange
        adBadge.textAlignment = .center
        adBadge.layer.cornerRadius = 4
        adBadge.clipsToBounds = true
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.backgroundColor = UIColor(red: 0.39, green: 0.36, blue: 1, alpha: 1)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.isUserInteractionEnabled = false
        
        let texts = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [iconImage, texts, button])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        adBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(adBadge)
        NSLayoutConstraint.activate([
            iconImage.widthAnchor.constraint(equalToConstant: 48),
            iconImage.heightAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            adBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            adBadge.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            adBadge.widthAnchor.constraint(equalToConstant: 22),
            adBadge.heightAnchor.constraint(equalToConstant: 13)
        ])
        iconImage.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        headlineView = titleLabel
        bodyView = bodyLabel
        iconView = iconImage
        callToActionView = button
    }

    func populate(_ ad: NativeAd) {
        titleLabel.text = ad.headline
        bodyLabel.text = ad.body ?? ad.advertiser
        iconImage.image = ad.icon?.image
        iconImage.isHidden = ad.icon == nil
        button.setTitle(ad.callToAction ?? "Open", for: .normal)
        nativeAd = ad
    }
}

struct NativeAdCard: UIViewRepresentable {
    let ad: NativeAd

    func makeUIView(context: Context) -> NativeCardView {
        let v = NativeCardView()
        v.populate(ad)
        return v
    }

    func updateUIView(_ uiView: NativeCardView, context: Context) { uiView.populate(ad) }
}

/// Native ad shown as one card at the top of the library; hidden for Premium users.
struct NativeAdBar: View {
    @ObservedObject private var premium = Premium.shared
    @StateObject private var model = NativeAdLoaderModel()

    var body: some View {
        Group {
            if !premium.isPremium, let ad = model.nativeAd {
                NativeAdCard(ad: ad).frame(height: 82)
            }
        }
        .onAppear { if !premium.isPremium { model.load() } }
    }
}

#else

/// Fallback when the Google Mobile Ads package is not linked: ads are simply skipped.
@MainActor
final class AdManager {
    static let shared = AdManager()
    func start() {}
    func preloadInterstitial() {}
    func afterReader() {}
}

/// Without the ads package there are no videos.
@MainActor
final class RewardedAds: ObservableObject {
    static let shared = RewardedAds()
    @Published private(set) var isReady = false
    var isAvailable: Bool { false }
    func preload() {}
    func show(_ completion: @escaping (Bool) -> Void) { completion(false) }
}

struct BannerAdView: View {
    var body: some View { EmptyView() }
}

struct NativeAdBar: View {
    var body: some View { EmptyView() }
}

#endif

/// Banner pinned under a screen; hidden for Premium users.
struct BannerBar: View {
    @ObservedObject private var premium = Premium.shared

    var body: some View {
        if !premium.isPremium && !ScreenshotMode.isActive {
            BannerAdView()
                .frame(width: 320, height: 50)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
        }
    }
}
