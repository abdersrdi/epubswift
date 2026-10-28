# EPUBSwift for iOS

Native SwiftUI port of the Android EPUB reader and toolbox.

- **Library and reader are free**: import EPUB books, read with themes, fonts, contents, in-book search, and reading
  progress. Arabic and right-to-left books are supported. Works offline.
- **Tools need Premium** (all run on the device): EPUB to PDF, PDF to EPUB, EPUB to TXT, EPUB to Markdown,
  Extract text, Metadata editor, Cover editor, Validator, Repair, Merge.
- **Premium** removes every ad and unlocks the tools. Plans: monthly (0.99), yearly (9.99) and lifetime (14.99),
  StoreKit 2. Prices are set in App Store Connect, the app shows what the store returns.
- **Ads** (free users): banner under the library, reader, tools and settings, a native card at the top of the library,
  and an interstitial after every third book is closed (at most once every 3 minutes). Google Mobile Ads via Swift
  Package Manager. Debug builds use Google's sample units; Release builds use the production units in
  `EPUBSwift/Ads/Ads.swift` (app id in `project.yml`).
- The settings tab uses the SF Symbol `gearshape` (modern outline gear).
- No third-party code besides Google Mobile Ads: the ZIP reader/writer, XML DOM and HTML tokenizer are in `Core/`.
- The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  on a Mac `brew install xcodegen && cd ios && xcodegen generate`, then open `EPUBSwift.xcodeproj`.
- Minimum iOS 17. Languages: English and Arabic.

## Before the first App Store submission

1. **Bundle id** `cc.epubswift.app`: register it in the Apple Developer portal and create the app in App Store Connect.
2. **In-app purchases** (App Store Connect), IDs must match `EPUBSwift/Premium/StoreManager.swift`:
   - subscription group "EPUBSwift Premium": `epubswift_premium_monthly` (1 month, 0.99) and
     `epubswift_premium_yearly` (1 year, 9.99)
   - non-consumable: `epubswift_premium_lifetime` (14.99)
3. **Privacy**: declare third-party advertising data (AdMob) and tracking, matching `PrivacyInfo.xcprivacy`.
   The app asks for App Tracking Transparency at first launch. Set the Privacy Policy URL in `Premium/PaywallView.swift`
   (`AppLinks.privacy`) to your real page.
4. **Codemagic**: see the comments at the top of `../codemagic.yaml` (set `APP_STORE_APPLE_ID`).

## Differences from Android

- No rewarded video: on iOS the tools are a Premium feature instead of an ad-gated action.
- Tools do not need an internet connection.
- Fonts embedded with the IDPF obfuscation are skipped when merging books.
