import SwiftUI
import WebKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case paper, sepia, night
    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: return L("Paper")
        case .sepia: return L("Sepia")
        case .night: return L("Night")
        }
    }

    var background: UInt32 {
        switch self { case .paper: return 0xFBFBFD; case .sepia: return 0xF4ECD8; case .night: return 0x101322 }
    }

    var text: UInt32 {
        switch self { case .paper: return 0x1A1A1A; case .sepia: return 0x5B4636; case .night: return 0xD6DAE8 }
    }

    var link: UInt32 {
        switch self { case .paper: return 0x4F46E5; case .sepia: return 0x8B4513; case .night: return 0x9A94FF }
    }

    var isDark: Bool { self == .night }

    var backgroundUIColor: UIColor { UIColor(Color(hex: background)) }
}

struct ReaderStyle: Equatable {
    var fontSize: Double = 20
    var theme: ReaderTheme = .paper
    var serif = true
    var lineHeight = 1.6
    var margin = 18.0

    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

    func css(rtl: Bool) -> String {
        let family = serif ? "Georgia, 'Times New Roman', serif" : "-apple-system, 'Helvetica Neue', Arial, sans-serif"
        var s = "html{-webkit-text-size-adjust:100%;background:\(Self.hex(theme.background)) !important;}"
        s += "body{background:\(Self.hex(theme.background)) !important;color:\(Self.hex(theme.text)) !important;"
        s += "font-family:\(family) !important;font-size:\(Int(fontSize))px !important;line-height:\(lineHeight) !important;"
        s += "margin:0 auto !important;max-width:40em;padding:16px \(Int(margin))px 40px \(Int(margin))px !important;"
        s += "word-wrap:break-word;overflow-wrap:break-word;"
        if rtl { s += "direction:rtl;" }
        s += "}"
        s += "body *{color:inherit !important;background-color:transparent !important;font-family:inherit !important;}"
        s += "a,a *{color:\(Self.hex(theme.link)) !important;}"
        s += "img,svg,video{max-width:100% !important;height:auto !important;}"
        s += "pre,code{white-space:pre-wrap !important;}"
        return s
    }
}

/// Serves the book's files to the web view from the ZIP, so nothing is unpacked to disk.
final class BookSchemeHandler: NSObject, WKURLSchemeHandler {
    var package: EpubPackage?
    var css = ""

    static let scheme = "epubbook"

    static func url(path: String, fragment: String? = nil) -> URL? {
        var s = "\(scheme)://book/" + EpubPath.encode(path)
        if let f = fragment, !f.isEmpty { s += "#" + (f.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? f) }
        return URL(string: s)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = String(url.path.dropFirst())
        guard let package, let data = try? package.archive.read(path) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
            if let response { urlSchemeTask.didReceive(response) }
            urlSchemeTask.didFinish()
            return
        }
        let mime = Mime.of(path)
        var body = data
        if mime == "text/html" { body = inject(data) }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: body.count,
                                   textEncodingName: mime == "text/html" || mime == "text/css" ? "utf-8" : nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static let selfClosing = try? NSRegularExpression(
        pattern: "<(a|span|div|p|b|i|em|strong|h[1-6]|section|td|th|li|ul|ol|u|sup|sub|small|font)(\\s[^<>]*?)?\\s*/>",
        options: [.caseInsensitive])

    private func inject(_ data: Data) -> Data {
        var html = Html.string(from: data)
        if let regex = Self.selfClosing {
            let range = NSRange(html.startIndex..., in: html)
            html = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "<$1$2></$1>")
        }
        let extra = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\"><style>\(css)</style>"
        if let r = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: extra, at: r.lowerBound)
        } else if let r = html.range(of: "<body", options: .caseInsensitive) {
            html.insert(contentsOf: "<head>" + extra + "</head>", at: r.lowerBound)
        } else {
            html = extra + html
        }
        return Data(html.utf8)
    }
}

struct BookWebView: UIViewRepresentable {
    let handler: BookSchemeHandler
    let path: String
    let fragment: String?
    let reloadToken: Int
    let restore: Double
    let background: UIColor
    var onProgress: (Double) -> Void
    var onLink: (String, String?) -> Void
    var onNext: () -> Void
    var onPrev: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: BookSchemeHandler.scheme)
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.scrollView.delegate = context.coordinator
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        let key = "\(path)#\(fragment ?? "")|\(reloadToken)"
        guard c.loadedKey != key else { return }
        c.loadedKey = key
        c.restore = restore
        c.ready = false
        if let url = BookSchemeHandler.url(path: path, fragment: fragment) { web.load(URLRequest(url: url)) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: BookWebView
        var loadedKey = ""
        var restore = 0.0
        var ready = false

        init(_ parent: BookWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let target = restore
            let hasFragment = webView.url?.fragment != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak webView] in
                guard let self, let sv = webView?.scrollView else { return }
                let maxY = max(0, sv.contentSize.height - sv.bounds.height)
                if target > 0, !hasFragment, maxY > 1 {
                    sv.setContentOffset(CGPoint(x: 0, y: target * maxY), animated: false)
                }
                self.ready = true
                self.report(sv)
            }
        }

        private func report(_ sv: UIScrollView) {
            let maxY = sv.contentSize.height - sv.bounds.height
            let frac = maxY > 1 ? min(1, max(0, Double(sv.contentOffset.y / maxY))) : 0
            parent.onProgress(frac)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard ready else { return }
            report(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard ready else { return }
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            if scrollView.contentOffset.y - maxY > 90 { parent.onNext() }
            else if scrollView.contentOffset.y < -90 { parent.onPrev() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.scheme == BookSchemeHandler.scheme {
                if navigationAction.navigationType == .linkActivated {
                    let target = String(url.path.dropFirst())
                    if target == parent.path { decisionHandler(.allow); return }
                    parent.onLink(target, url.fragment)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            } else if navigationAction.navigationType == .linkActivated {
                if url.scheme == "http" || url.scheme == "https" { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
