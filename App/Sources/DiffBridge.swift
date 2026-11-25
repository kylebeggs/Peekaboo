import Foundation

/// The script injected into a review window's page. The markdown view keeps page
/// JavaScript to a minimum; the diff page is the deliberate exception, because what it
/// does cannot be done from Swift without throwing the page away:
///
/// - **Per-file patching.** A refresh replaces only the `<details>` elements whose
///   content changed. Swapping the whole body (what the markdown view does) would
///   reset every file's collapsed state and the reader's selection each time an agent
///   saves a file.
/// - **Viewed / Load diff**, reported to Swift, which owns the state.
/// - **Comment targets**: a click in the line-number gutter, or a text selection
///   resolved to the lines it covers on one side.
/// - **Markers** on commented lines, re-applied after every patch.
///
/// Page → Swift messages go to the `pkbDiff` handler: `viewed`, `load`, `comment`, `select`.
enum DiffBridge {
    static let handlerName = "pkbDiff"

    static let script = #"""
    (function() {
      if (window.__pkbDiff) { return; }

      var markers = [];

      function post(message) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pkbDiff) {
          window.webkit.messageHandlers.pkbDiff.postMessage(message);
        }
      }
      function filesRoot() { return document.getElementById('pkb-files'); }
      function fileOf(node) { return node && node.closest ? node.closest('details.file') : null; }
      function sideOf(cell) { return cell.classList.contains('l') ? 'old' : 'new'; }

      // ---- Patching ---------------------------------------------------------------

      // The first file still (partly) on screen and where its top edge is: after a
      // patch the page is scrolled so that edge is back where it was.
      function topAnchor() {
        var files = filesRoot().children;
        for (var i = 0; i < files.length; i++) {
          var rect = files[i].getBoundingClientRect();
          if (rect.bottom > 0) { return { id: files[i].id, top: rect.top }; }
        }
        return null;
      }

      function patch(update) {
        var root = filesRoot();
        var anchor = window.scrollY > 0 ? topAnchor() : null;
        if (update.summary != null) { document.getElementById('pkb-summary').innerHTML = update.summary; }

        var template = document.createElement('template');
        Object.keys(update.files).forEach(function(id) {
          template.innerHTML = update.files[id];
          var fresh = template.content.firstElementChild;
          var old = document.getElementById(id);
          if (!old) { root.appendChild(fresh); return; }
          // Keep a manual collapse/expand unless the Viewed state itself changed.
          var was = old.querySelector('input[data-pkb-viewed]');
          var now = fresh.querySelector('input[data-pkb-viewed]');
          if (was && now && was.checked === now.checked) { fresh.open = old.open; }
          old.replaceWith(fresh);
        });

        var keep = {};
        update.order.forEach(function(id) { keep[id] = true; });
        Array.prototype.slice.call(root.children).forEach(function(el) {
          if (!keep[el.id]) { el.remove(); }
        });
        var current = Array.prototype.map.call(root.children, function(el) { return el.id; });
        if (current.join('\n') !== update.order.join('\n')) {
          update.order.forEach(function(id) {
            var el = document.getElementById(id);
            if (el) { root.appendChild(el); }
          });
        }

        if (anchor) {
          var el = document.getElementById(anchor.id);
          if (el) { window.scrollBy(0, el.getBoundingClientRect().top - anchor.top); }
        }
        applyMarkers();
      }

      // ---- Viewed and Load diff -----------------------------------------------------

      document.addEventListener('change', function(event) {
        var input = event.target;
        if (!input.matches || !input.matches('input[data-pkb-viewed]')) { return; }
        var file = fileOf(input);
        if (!file) { return; }
        var viewed = input.checked;
        // Deferred: the click that changed the checkbox may also be toggling the
        // <details> through its <summary>, and this has to have the last word.
        setTimeout(function() {
          file.open = !viewed;
          // Collapsing a file whose top has scrolled off would leave the reader
          // somewhere arbitrary further down; bring the collapsed header to the top.
          if (viewed && file.getBoundingClientRect().top < 0) { file.scrollIntoView(); }
        }, 0);
        post({ type: 'viewed', id: file.id, viewed: viewed });
      });

      // ---- Comments -----------------------------------------------------------------

      function comment(first, last) {
        var file = fileOf(first);
        if (!file) { return; }
        var a = +first.getAttribute('data-l'), b = +last.getAttribute('data-l');
        post({ type: 'comment', id: file.id, side: sideOf(first), start: Math.min(a, b), end: Math.max(a, b) });
      }

      // The part of a range that lies inside one cell.
      function clipTo(range, cell) {
        var probe = document.createRange();
        probe.selectNodeContents(cell);
        var clipped = range.cloneRange();
        if (clipped.compareBoundaryPoints(Range.START_TO_START, probe) < 0) {
          clipped.setStart(probe.startContainer, probe.startOffset);
        }
        if (clipped.compareBoundaryPoints(Range.END_TO_END, probe) > 0) {
          clipped.setEnd(probe.endContainer, probe.endOffset);
        }
        return clipped;
      }

      // The code cells a selection covers, on the side it was started on, within one file.
      function selectedCells() {
        var selection = window.getSelection();
        if (!selection || selection.isCollapsed || selection.rangeCount === 0) { return null; }
        var range = selection.getRangeAt(0);
        var root = range.commonAncestorContainer;
        if (root.nodeType !== 1) { root = root.parentElement; }
        if (!root || !filesRoot().contains(root)) { return null; }
        var side = document.body.classList.contains('sel-l') ? 'l' : 'r';
        var own = root.closest('td.c');
        var candidates = own ? [own] : root.querySelectorAll('td.c.' + side + ':not(.nil)');
        var cells = [];
        for (var i = 0; i < candidates.length; i++) {
          if (own) { cells.push(candidates[i]); break; }
          if (!range.intersectsNode(candidates[i])) { continue; }
          // A cell counts only if some of its text is selected: a selection that
          // merely ends at the start of the next line (triple-click does this) must
          // not claim that line. Clip the selection to the cell and look at what is left.
          if (clipTo(range, candidates[i]).toString().length > 0) { cells.push(candidates[i]); }
        }
        if (!cells.length) { return null; }
        var file = fileOf(cells[0]);
        cells = cells.filter(function(cell) { return fileOf(cell) === file; });
        return { first: cells[0], last: cells[cells.length - 1] };
      }

      function fab() {
        var el = document.getElementById('pkb-fab');
        if (el) { return el; }
        el = document.createElement('button');
        el.id = 'pkb-fab';
        el.type = 'button';
        el.textContent = '💬 Comment';
        el.addEventListener('mousedown', function(event) { event.preventDefault(); });
        el.addEventListener('click', function(event) {
          event.preventDefault();
          var cells = selectedCells();
          hideFab();
          var selection = window.getSelection();
          if (selection) { selection.removeAllRanges(); }
          if (cells) { comment(cells.first, cells.last); }
        });
        document.documentElement.appendChild(el);
        return el;
      }
      function hideFab() {
        var el = document.getElementById('pkb-fab');
        if (el) { el.style.display = 'none'; }
      }
      function showFab() {
        var cells = selectedCells();
        if (!cells) { hideFab(); return; }
        // Anchor to the selected text on the first line only. The whole range's box
        // spans every row it crosses, gutters and the other side included, so its
        // left edge is the table's.
        var rect = clipTo(window.getSelection().getRangeAt(0), cells.first).getBoundingClientRect();
        if (!rect || (rect.width === 0 && rect.height === 0)) { rect = cells.first.getBoundingClientRect(); }
        var el = fab();
        el.style.display = 'block';
        el.style.top = Math.max(0, window.scrollY + rect.top - 34) + 'px';
        el.style.left = Math.max(0, window.scrollX + rect.left) + 'px';
      }

      // A split diff is two documents side by side, but the DOM runs across rows, so a
      // plain drag would select old and new lines alternately. Whichever side the drag
      // starts on becomes the only selectable one until the next mouse-down.
      document.addEventListener('mousedown', function(event) {
        var cell = event.target.closest ? event.target.closest('td.c') : null;
        if (!cell || cell.classList.contains('nil')) { return; }
        document.body.classList.toggle('sel-l', cell.classList.contains('l'));
        document.body.classList.toggle('sel-r', cell.classList.contains('r'));
      });
      document.addEventListener('mouseup', function() { setTimeout(showFab, 0); });
      document.addEventListener('selectionchange', function() {
        var selection = window.getSelection();
        if (!selection || selection.isCollapsed) { hideFab(); }
      });

      document.addEventListener('click', function(event) {
        var target = event.target;
        if (!target.closest) { return; }
        var load = target.closest('button[data-pkb-load]');
        if (load) {
          var file = fileOf(load);
          if (file) { post({ type: 'load', id: file.id }); }
          return;
        }
        var gutter = target.closest('td.n[data-n]');
        if (gutter) {
          comment(gutter.nextElementSibling, gutter.nextElementSibling);
          return;
        }
        var marked = target.closest('td.c.cm');
        if (marked && window.getSelection().isCollapsed) {
          post({ type: 'select', thread: marked.getAttribute('data-thread') });
        }
      });

      // ---- Markers ------------------------------------------------------------------

      function cellFor(marker, line) {
        var file = document.getElementById(marker.file);
        if (!file) { return null; }
        return file.querySelector('td.c.' + (marker.side === 'old' ? 'l' : 'r') + '[data-l="' + line + '"]');
      }

      function applyMarkers() {
        document.querySelectorAll('td.c.cm').forEach(function(cell) {
          cell.classList.remove('cm', 'done');
          cell.removeAttribute('data-thread');
        });
        // Resolved first, so an open thread on the same line wins the styling.
        markers.slice().sort(function(a, b) { return (b.resolved ? 1 : 0) - (a.resolved ? 1 : 0); })
          .forEach(function(marker) {
            for (var line = marker.start; line <= marker.end; line++) {
              var cell = cellFor(marker, line);
              if (!cell) { continue; }
              cell.classList.add('cm');
              cell.classList.toggle('done', !!marker.resolved);
              cell.setAttribute('data-thread', marker.thread);
            }
          });
      }

      function injectStyle() {
        var style = document.createElement('style');
        style.textContent =
          '#pkb-fab{position:absolute;z-index:99999;display:none;font:12px -apple-system,system-ui,sans-serif;' +
          'padding:4px 9px;border-radius:6px;border:1px solid rgba(0,0,0,0.15);background:#fff;color:#111;' +
          'box-shadow:0 2px 8px rgba(0,0,0,0.25);cursor:pointer;}' +
          '@media (prefers-color-scheme:dark){#pkb-fab{background:#2c2c2e;color:#fff;border-color:rgba(255,255,255,0.2);}}';
        document.head.appendChild(style);
      }

      window.__pkbDiff = {
        patch: patch,
        setMarkers: function(list) {
          markers = list || [];
          applyMarkers();
        },
        scrollTo: function(thread) {
          var marker = null;
          for (var i = 0; i < markers.length; i++) {
            if (markers[i].thread === thread) { marker = markers[i]; break; }
          }
          if (!marker) { return; }
          var file = document.getElementById(marker.file);
          if (file) { file.open = true; }
          var cell = cellFor(marker, marker.start);
          if (!cell) { return; }
          cell.scrollIntoView({ behavior: 'smooth', block: 'center' });
          for (var line = marker.start; line <= marker.end; line++) {
            var target = cellFor(marker, line);
            if (!target) { continue; }
            target.classList.remove('flash');
            void target.offsetWidth;
            target.classList.add('flash');
          }
        }
      };

      injectStyle();
    })();
    """#
}
