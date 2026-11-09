import WebKit
import XCTest

/// Runs the real page script inside a real WebKit view with the same settings the reader uses (page JavaScript off), so the
/// parts that cannot be checked without a browser are checked here.
@MainActor
final class HighlightScriptTests: XCTestCase {
    private static let world = WKContentWorld.world(name: "mw-test")

    private final class Handler: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        var onMessage: (([String: Any]) -> Void)?
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String, let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            messages.append(obj)
            onMessage?(obj)
        }
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private let html = "<html><head><title>t</title></head><body><p>Hello <b>big</b> world</p><p>Second paragraph here</p></body></html>"

    private func makeWeb(handler: Handler) async -> (WKWebView, Loader) {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false                          // as in the reader
        config.defaultWebpagePreferences = prefs
        config.userContentController.addUserScript(WKUserScript(source: AnnotationScripts.source, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: Self.world))
        config.userContentController.add(handler, contentWorld: Self.world, name: AnnotationScripts.handlerName)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { cont in
            loader.done = cont
            web.loadHTMLString(html, baseURL: nil)
        }
        return (web, loader)
    }

    private func js(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await web.evaluateJavaScript(source, in: nil, contentWorld: Self.world)
    }

    private func item(_ id: String, _ start: Int, _ end: Int, color: String = "yellow", note: Bool = false) -> String {
        "{\"id\":\"\(id)\",\"start\":\(start),\"end\":\(end),\"color\":\"\(color)\",\"note\":\(note)}"
    }

    func testScriptRunsEvenThoughPageJavaScriptIsOff() async throws {
        let (web, _) = await makeWeb(handler: Handler())
        XCTAssertEqual(try await js(web, "typeof window.__mw") as? String, "object")
    }

    func testHighlightWrapsTextAcrossElementsWithoutChangingTheText() async throws {
        let (web, _) = await makeWeb(handler: Handler())
        let before = try await js(web, "document.body.innerHTML") as? String
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        let start = (text as NSString).range(of: "lo big wor").location
        XCTAssertNotEqual(start, NSNotFound)
        let count = try await js(web, "window.__mw.applyAll([\(item("a1", start, start + 10))])") as? Int
        XCTAssertEqual(count, 3, "one mark per text node: 'lo ', 'big', ' wor'")
        let marked = try await js(web, "Array.from(document.querySelectorAll('mark.mw')).map(function(m){return m.textContent}).join('')") as? String
        XCTAssertEqual(marked, "lo big wor")
        XCTAssertEqual(try await js(web, "window.__mw.bodyText()") as? String, text, "the text and its offsets do not move")

        _ = try await js(web, "window.__mw.applyAll([])")             // clearing restores the page exactly
        XCTAssertEqual(try await js(web, "document.body.innerHTML") as? String, before)
    }

    func testTwoHighlightsAndTheirColoursAndNoteMarker() async throws {
        let (web, _) = await makeWeb(handler: Handler())
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        let a = (text as NSString).range(of: "Hello")
        let b = (text as NSString).range(of: "paragraph")
        let list = "[\(item("a", a.location, a.location + a.length, color: "green")),\(item("b", b.location, b.location + b.length, color: "pink", note: true))]"
        XCTAssertEqual(try await js(web, "window.__mw.applyAll(\(list))") as? Int, 2)
        XCTAssertEqual(try await js(web, "document.querySelector('mark.mw-green').textContent") as? String, "Hello")
        XCTAssertEqual(try await js(web, "document.querySelector('mark.mw-pink.mw-note').textContent") as? String, "paragraph")
    }

    func testApplyingTheSameListTwiceDoesNotNestMarks() async throws {
        let (web, _) = await makeWeb(handler: Handler())
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        let s = (text as NSString).range(of: "world").location
        let list = "[\(item("a", s, s + 5))]"
        _ = try await js(web, "window.__mw.applyAll(\(list))")
        _ = try await js(web, "window.__mw.applyAll(\(list))")
        XCTAssertEqual(try await js(web, "document.querySelectorAll('mark.mw').length") as? Int, 1)
        XCTAssertEqual(try await js(web, "document.querySelectorAll('mark.mw mark.mw').length") as? Int, 0)
    }

    func testSelectionIsReportedWithOffsetsThatMatchTheText() async throws {
        let handler = Handler()
        let (web, _) = await makeWeb(handler: handler)
        let got = expectation(description: "selection message")
        handler.onMessage = { m in if m["type"] as? String == "selection", m["empty"] == nil { got.fulfill() } }
        _ = try await js(web, """
            (function(){
              var p = document.querySelectorAll('p')[1].firstChild;
              var r = document.createRange(); r.setStart(p, 7); r.setEnd(p, 16);
              var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
            })()
            """)
        await fulfillment(of: [got], timeout: 5)
        let m = try XCTUnwrap(handler.messages.last { $0["empty"] == nil && $0["type"] as? String == "selection" })
        let start = try XCTUnwrap(m["start"] as? Int), end = try XCTUnwrap(m["end"] as? Int)
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        XCTAssertEqual(m["text"] as? String, "paragraph")
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: end - start)), "paragraph")
    }

    func testTappingAHighlightIsReported() async throws {
        let handler = Handler()
        let (web, _) = await makeWeb(handler: handler)
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        let s = (text as NSString).range(of: "Second").location
        _ = try await js(web, "window.__mw.applyAll([\(item("tap-1", s, s + 6))])")
        let got = expectation(description: "tap message")
        handler.onMessage = { m in if m["type"] as? String == "tap" { got.fulfill() } }
        _ = try await js(web, "document.querySelector('mark.mw').click()")
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(handler.messages.last { $0["type"] as? String == "tap" }?["id"] as? String, "tap-1")
    }

    func testScrollToFindsAHighlight() async throws {
        let (web, _) = await makeWeb(handler: Handler())
        let text = try await js(web, "window.__mw.bodyText()") as? String ?? ""
        let s = (text as NSString).range(of: "Hello").location
        _ = try await js(web, "window.__mw.applyAll([\(item("x", s, s + 5))])")
        XCTAssertEqual(try await js(web, "window.__mw.scrollTo('x')") as? Bool, true)
        XCTAssertEqual(try await js(web, "window.__mw.scrollTo('missing')") as? Bool, false)
    }
}
