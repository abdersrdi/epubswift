import Foundation

/// The small script that runs inside the reader's page to show highlights and report what the reader selects.
///
/// It runs in its own content world, so the book's own scripts (which are switched off anyway) can never see or change it, and
/// it talks to the app through the `mw` message handler. Positions are character offsets inside `document.body`, measured with
/// `Range.toString()`, so wrapping text in `<mark>` elements never moves them.
enum AnnotationScripts {
    static let handlerName = "mw"

    static let source = #"""
    (function () {
      if (window.__mw) return;
      var post = function (o) {
        try { window.webkit.messageHandlers.mw.postMessage(JSON.stringify(o)); } catch (e) {}
      };
      var textNodes = function () {
        var out = [], w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n;
        while ((n = w.nextNode())) out.push(n);
        return out;
      };
      var offsetOf = function (node, off) {
        var r = document.createRange();
        r.setStart(document.body, 0);
        r.setEnd(node, off);
        return r.toString().length;
      };
      var unwrapAll = function () {
        var marks = document.querySelectorAll('mark.mw');
        for (var i = 0; i < marks.length; i++) {
          var m = marks[i], p = m.parentNode;
          while (m.firstChild) p.insertBefore(m.firstChild, m);
          p.removeChild(m);
          p.normalize();
        }
      };
      var wrap = function (a) {
        var nodes = textNodes(), pos = 0, todo = [];
        for (var i = 0; i < nodes.length; i++) {
          var len = nodes[i].data.length, s = pos, e = pos + len;
          pos = e;
          if (e <= a.start) continue;
          if (s >= a.end) break;
          todo.push({ n: nodes[i], from: Math.max(a.start, s) - s, to: Math.min(a.end, e) - s });
        }
        todo.forEach(function (t) {
          var mid = t.from > 0 ? t.n.splitText(t.from) : t.n;
          if (t.to - t.from < mid.data.length) mid.splitText(t.to - t.from);
          var m = document.createElement('mark');
          m.className = 'mw mw-' + a.color + (a.note ? ' mw-note' : '');
          m.setAttribute('data-mw', a.id);
          mid.parentNode.insertBefore(m, mid);
          m.appendChild(mid);
        });
      };
      var style = document.createElement('style');
      style.textContent =
        'body mark.mw{color:inherit !important;border-radius:3px;padding:0;}' +
        'body mark.mw-yellow{background-color:rgba(255,214,10,0.45) !important;}' +
        'body mark.mw-green{background-color:rgba(52,199,89,0.40) !important;}' +
        'body mark.mw-blue{background-color:rgba(10,132,255,0.35) !important;}' +
        'body mark.mw-pink{background-color:rgba(255,55,95,0.35) !important;}' +
        'body mark.mw-note{border-bottom:2px solid rgba(120,120,120,0.8);}';
      document.head.appendChild(style);

      var timer = null;
      document.addEventListener('selectionchange', function () {
        clearTimeout(timer);
        timer = setTimeout(function () {
          var sel = window.getSelection();
          if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { post({ type: 'selection', empty: true }); return; }
          var r = sel.getRangeAt(0);
          if (!document.body.contains(r.startContainer) || !document.body.contains(r.endContainer)) return;
          post({ type: 'selection', start: offsetOf(r.startContainer, r.startOffset), end: offsetOf(r.endContainer, r.endOffset), text: sel.toString() });
        }, 150);
      });
      document.addEventListener('click', function (e) {
        var t = e.target, m = t && t.closest ? t.closest('mark.mw') : null;
        if (m) { post({ type: 'tap', id: m.getAttribute('data-mw') }); e.preventDefault(); }
      }, true);

      window.__mw = {
        applyAll: function (list) {
          unwrapAll();
          list.sort(function (a, b) { return a.start - b.start; });
          list.forEach(wrap);
          return document.querySelectorAll('mark.mw').length;
        },
        clearSelection: function () { var s = window.getSelection(); if (s) s.removeAllRanges(); },
        scrollTo: function (id) {
          var el = document.querySelector('mark[data-mw="' + id + '"]');
          if (el) el.scrollIntoView({ block: 'center' });
          return !!el;
        },
        bodyText: function () { return document.body.textContent; }
      };
    })();
    """#

    /// The call that shows a chapter's highlights. `json` is a list of `{id,start,end,color,note}`.
    static func apply(_ annotations: [Annotation]) -> String {
        struct Item: Encodable { var id: String; var start: Int; var end: Int; var color: String; var note: Bool }
        let items = annotations.map { Item(id: $0.id.uuidString, start: $0.start, end: $0.end, color: $0.color.rawValue, note: $0.hasNote) }
        let json = (try? String(data: JSONEncoder().encode(items), encoding: .utf8)) ?? "[]"
        return "window.__mw ? window.__mw.applyAll(\(json)) : -1"
    }
}
