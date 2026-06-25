import Foundation
import MarkdownRenderer

/// The web-view side of commenting. All comment UI is native SwiftUI; this script
/// does only the three things that must live in the page: serialize a selection,
/// show a floating "Comment" affordance, and re-apply highlights by text-quote
/// matching. State (`window.__pkb`) and listeners hang off `document`, so they
/// survive the live-reload body swap; highlights re-apply through the existing
/// `window.__peekabooRender` hook (the same one Mermaid uses).
enum CommentBridge {
    static func anchorsJSON(_ threads: [CommentThread]) -> String {
        struct Payload: Encodable { let id, quote, prefix, suffix: String; let resolved: Bool }
        let payload = threads.compactMap { thread -> Payload? in
            guard let anchor = thread.anchor else { return nil }
            return Payload(id: thread.id, quote: anchor.quote, prefix: anchor.prefix, suffix: anchor.suffix,
                           resolved: thread.status == .resolved)
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static let script = """
    (function() {
      if (window.__pkb) { return; }

      function post(msg) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pkbComment) {
          window.webkit.messageHandlers.pkbComment.postMessage(msg);
        }
      }

      function buildIndex() {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: function(node) {
            var p = node.parentNode;
            while (p && p !== document.body) {
              var tag = p.nodeName;
              if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return NodeFilter.FILTER_REJECT;
              if (p.hasAttribute && p.hasAttribute('data-pkb-skip')) return NodeFilter.FILTER_REJECT;
              p = p.parentNode;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var segs = [], text = '', node;
        while ((node = walker.nextNode())) {
          segs.push({ node: node, start: text.length, len: node.nodeValue.length });
          text += node.nodeValue;
        }
        return { text: text, segs: segs };
      }

      function globalOffset(index, container, offset) {
        if (container.nodeType === Node.TEXT_NODE) {
          for (var i = 0; i < index.segs.length; i++) {
            if (index.segs[i].node === container) return index.segs[i].start + Math.min(offset, index.segs[i].len);
          }
          return -1;
        }
        var child = container.childNodes[offset];
        if (child) {
          for (var j = 0; j < index.segs.length; j++) {
            var n = index.segs[j].node;
            if (n === child || (child.contains && child.contains(n))) return index.segs[j].start;
            if (child.compareDocumentPosition(n) & Node.DOCUMENT_POSITION_FOLLOWING) return index.segs[j].start;
          }
          return index.text.length;
        }
        var last = -1;
        for (var k = 0; k < index.segs.length; k++) {
          if (container.contains(index.segs[k].node)) last = k;
        }
        if (last >= 0) return index.segs[last].start + index.segs[last].len;
        return index.text.length;
      }

      function selectionAnchor() {
        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
        var range = sel.getRangeAt(0);
        if (!document.body.contains(range.commonAncestorContainer)) return null;
        var index = buildIndex();
        var start = globalOffset(index, range.startContainer, range.startOffset);
        var end = globalOffset(index, range.endContainer, range.endOffset);
        if (start < 0 || end < 0 || end <= start) return null;
        var CTX = 40;
        return {
          quote: index.text.slice(start, end),
          prefix: index.text.slice(Math.max(0, start - CTX), start),
          suffix: index.text.slice(end, end + CTX)
        };
      }

      function commonSuffixLen(a, b) {
        var i = 0;
        while (i < a.length && i < b.length && a[a.length - 1 - i] === b[b.length - 1 - i]) i++;
        return i;
      }
      function commonPrefixLen(a, b) {
        var i = 0;
        while (i < a.length && i < b.length && a[i] === b[i]) i++;
        return i;
      }

      function findMatch(text, a) {
        if (!a.quote) return -1;
        var idx = -1, best = -1, bestScore = -1;
        while ((idx = text.indexOf(a.quote, idx + 1)) !== -1) {
          var before = text.slice(Math.max(0, idx - (a.prefix ? a.prefix.length : 0)), idx);
          var after = text.slice(idx + a.quote.length, idx + a.quote.length + (a.suffix ? a.suffix.length : 0));
          var score = commonSuffixLen(before, a.prefix || '') + commonPrefixLen(after, a.suffix || '');
          if (score > bestScore) { bestScore = score; best = idx; }
        }
        return best;
      }

      function clearHighlights() {
        var spans = document.querySelectorAll('span.pkb-hl');
        for (var i = 0; i < spans.length; i++) {
          var s = spans[i], parent = s.parentNode;
          if (!parent) continue;
          while (s.firstChild) parent.insertBefore(s.firstChild, s);
          parent.removeChild(s);
          parent.normalize();
        }
      }

      function wrap(index, gStart, gEnd, id, resolved) {
        var parts = [];
        for (var i = 0; i < index.segs.length; i++) {
          var seg = index.segs[i];
          var from = Math.max(gStart, seg.start) - seg.start;
          var to = Math.min(gEnd, seg.start + seg.len) - seg.start;
          if (to > from) parts.push({ node: seg.node, from: from, to: to });
        }
        var wrapped = false;
        for (var j = parts.length - 1; j >= 0; j--) {
          var p = parts[j];
          try {
            var r = document.createRange();
            r.setStart(p.node, p.from);
            r.setEnd(p.node, p.to);
            var span = document.createElement('span');
            span.className = resolved ? 'pkb-hl pkb-hl-resolved' : 'pkb-hl';
            span.setAttribute('data-pkb-id', id);
            r.surroundContents(span);
            wrapped = true;
          } catch (e) { /* segment not wrappable in isolation; skip it */ }
        }
        return wrapped;
      }

      function injectStyle() {
        if (document.getElementById('pkb-style')) return;
        var st = document.createElement('style');
        st.id = 'pkb-style';
        st.textContent =
          'span.pkb-hl{background:rgba(255,212,0,0.35);border-radius:2px;cursor:pointer;}' +
          'span.pkb-hl.pkb-hl-resolved{background:transparent;cursor:auto;}' +
          'span.pkb-hl.pkb-flash{animation:pkbflash 1.2s ease-out;}' +
          '@keyframes pkbflash{from{background:rgba(255,212,0,0.95);}to{background:rgba(255,212,0,0.35);}}' +
          '#pkb-fab{position:absolute;z-index:99999;display:none;font:12px -apple-system,system-ui,sans-serif;' +
          'padding:4px 9px;border-radius:6px;border:1px solid rgba(0,0,0,0.15);background:#fff;color:#111;' +
          'box-shadow:0 2px 8px rgba(0,0,0,0.25);cursor:pointer;}' +
          '@media (prefers-color-scheme:dark){#pkb-fab{background:#2c2c2e;color:#fff;border-color:rgba(255,255,255,0.2);}' +
          'span.pkb-hl{background:rgba(255,212,0,0.30);}}';
        document.head.appendChild(st);
      }

      function fab() {
        var el = document.getElementById('pkb-fab');
        if (el) return el;
        el = document.createElement('button');
        el.id = 'pkb-fab';
        el.type = 'button';
        el.textContent = '💬 Comment';
        el.setAttribute('data-pkb-skip', '');
        el.addEventListener('mousedown', function(ev) { ev.preventDefault(); });
        el.addEventListener('click', function(ev) {
          ev.preventDefault();
          var a = selectionAnchor();
          hideFab();
          var s = window.getSelection();
          if (s) s.removeAllRanges();
          if (a) post({ type: 'add', anchor: a });
        });
        document.documentElement.appendChild(el);
        return el;
      }

      function hideFab() {
        var el = document.getElementById('pkb-fab');
        if (el) el.style.display = 'none';
      }

      function showFab() {
        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) { hideFab(); return; }
        var range = sel.getRangeAt(0);
        if (!document.body.contains(range.commonAncestorContainer)) { hideFab(); return; }
        var rect = range.getBoundingClientRect();
        if (!rect || (rect.width === 0 && rect.height === 0)) { hideFab(); return; }
        var el = fab();
        el.style.display = 'block';
        el.style.top = Math.max(0, window.scrollY + rect.top - 34) + 'px';
        el.style.left = Math.max(0, window.scrollX + rect.left) + 'px';
      }

      window.__pkb = {
        lastAnchors: [],
        selectionAnchor: selectionAnchor,
        apply: function(anchors) {
          if (anchors) this.lastAnchors = anchors;
          clearHighlights();
          var outdated = [], resolved = [];
          var list = this.lastAnchors || [];
          for (var i = 0; i < list.length; i++) {
            var a = list[i];
            var index = buildIndex();
            var pos = findMatch(index.text, a);
            if (pos < 0 || !wrap(index, pos, pos + a.quote.length, a.id, a.resolved)) {
              outdated.push(a.id);
            } else {
              resolved.push({ id: a.id, pos: pos });
            }
          }
          resolved.sort(function(x, y) { return x.pos - y.pos; });
          post({ type: 'outdated', ids: outdated, order: resolved.map(function(r) { return r.id; }) });
        },
        scrollTo: function(id) {
          var el = document.querySelector('span.pkb-hl[data-pkb-id="' + id + '"]');
          if (!el) return;
          el.scrollIntoView({ behavior: 'smooth', block: 'center' });
          el.classList.remove('pkb-flash');
          void el.offsetWidth;
          el.classList.add('pkb-flash');
        }
      };

      injectStyle();
      document.addEventListener('mouseup', function() { setTimeout(showFab, 0); });
      document.addEventListener('selectionchange', function() { showFab(); });
      document.addEventListener('click', function(ev) {
        var hl = ev.target.closest ? ev.target.closest('span.pkb-hl') : null;
        if (hl) post({ type: 'select', id: hl.getAttribute('data-pkb-id') });
      });

      var prevRender = window.__peekabooRender;
      window.__peekabooRender = function() {
        if (typeof prevRender === 'function') prevRender();
        injectStyle();
        try { window.__pkb.apply(); } catch (e) {}
      };
    })();
    """
}
