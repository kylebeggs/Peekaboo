import Foundation

/// Stylesheet for the diff page. The page is self-contained and deliberately does not
/// load `github-markdown.css`: that sheet styles every `table` as a scrolling block with
/// zebra rows and padded, bordered cells, all of which a diff table would have to undo.
/// Colours follow GitHub's diff palette in both schemes.
enum DiffCSS {
    static let css: String = base + HTMLTemplate.highlightCSS

    private static let base = #"""
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --fg-muted: #59636e; --bg: #ffffff; --bg-muted: #f6f8fa; --border: #d1d9e0;
      --add-bg: #dafbe1; --add-num: #aceebb; --add-word: #aceebb;
      --del-bg: #ffebe9; --del-num: #ffcecb; --del-word: #ffcecb;
      --hunk-bg: #ddf4ff; --accent: #0969da; --plus: #1a7f37; --minus: #d1242f;
      --mark-bg: rgba(255, 212, 0, 0.22); --mark-edge: #d4a72c;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #f0f6fc; --fg-muted: #9198a1; --bg: #0d1117; --bg-muted: #151b23; --border: #3d444d;
        --add-bg: rgba(46, 160, 67, 0.15); --add-num: rgba(63, 185, 80, 0.3); --add-word: rgba(46, 160, 67, 0.4);
        --del-bg: rgba(248, 81, 73, 0.1); --del-num: rgba(248, 81, 73, 0.3); --del-word: rgba(248, 81, 73, 0.4);
        --hunk-bg: rgba(56, 139, 253, 0.1); --accent: #4493f8; --plus: #3fb950; --minus: #f85149;
        --mark-bg: rgba(210, 153, 34, 0.25); --mark-edge: #d29922;
      }
    }
    body.pkb-diff {
      margin: 0; background: var(--bg); color: var(--fg);
      font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    #pkb-summary { padding: 14px 16px 2px; }
    #pkb-summary .line { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; }
    #pkb-summary .count { font-weight: 600; }
    #pkb-summary .base { color: var(--fg-muted); }
    #pkb-summary .notice, #pkb-summary .empty { margin-top: 8px; color: var(--fg-muted); }
    #pkb-summary .empty { padding: 48px 0; text-align: center; font-size: 15px; }
    #pkb-files { padding: 10px 16px 40px; }
    .plus { color: var(--plus); font-weight: 600; }
    .minus { color: var(--minus); font-weight: 600; }
    code, .path, table.split { font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; }

    details.file { border: 1px solid var(--border); border-radius: 6px; margin-bottom: 16px; }
    details.file > summary {
      position: sticky; top: 0; z-index: 2;
      display: flex; align-items: center; gap: 8px;
      padding: 6px 12px; border-radius: 6px;
      background: var(--bg-muted); cursor: pointer; list-style: none; font-size: 12px;
    }
    details.file[open] > summary { border-bottom: 1px solid var(--border); border-radius: 6px 6px 0 0; }
    details.file > summary::-webkit-details-marker { display: none; }
    .chev {
      flex: none; width: 6px; height: 6px; margin: 0 4px 0 2px;
      border-right: 1.5px solid var(--fg-muted); border-bottom: 1.5px solid var(--fg-muted);
      transform: rotate(-45deg); transition: transform 0.12s ease;
    }
    details.file[open] > summary .chev { transform: rotate(45deg); }
    .path { min-width: 0; overflow-wrap: anywhere; font-weight: 600; }
    .badge {
      flex: none; padding: 0 6px; border: 1px solid var(--border); border-radius: 10px;
      color: var(--fg-muted); font-size: 11px;
    }
    .stat { flex: none; }
    .viewed {
      flex: none; margin-left: auto; display: flex; align-items: center; gap: 5px;
      padding: 2px 8px; border: 1px solid var(--border); border-radius: 6px;
      background: var(--bg); color: var(--fg-muted); cursor: pointer;
      user-select: none; -webkit-user-select: none;
    }
    .viewed input { margin: 0; }
    .body { border-radius: 0 0 6px 6px; overflow: hidden; }
    .note { padding: 18px 16px; color: var(--fg-muted); text-align: center; }
    .note button {
      margin-left: 8px; padding: 3px 10px; border: 1px solid var(--border); border-radius: 6px;
      background: var(--bg-muted); color: var(--accent); font: inherit; cursor: pointer;
    }

    table.split {
      width: 100%; table-layout: fixed; border-collapse: collapse;
      font-size: 12px; line-height: 20px; tab-size: 4;
    }
    table.split col.cn { width: 52px; }
    /* Low specificity on purpose: the per-cell rules below must be able to set padding. */
    .split td { padding: 0; vertical-align: top; }
    td.n {
      padding: 0 10px; text-align: right; color: var(--fg-muted); position: relative;
      user-select: none; -webkit-user-select: none;
    }
    td.n::before { content: attr(data-n); }
    td.n:nth-child(3) { border-left: 1px solid var(--border); }
    td.c { position: relative; padding: 0 10px 0 22px; white-space: pre-wrap; overflow-wrap: anywhere; }
    td.c.add::before, td.c.del::before {
      position: absolute; left: 8px; user-select: none; -webkit-user-select: none;
    }
    td.c.add::before { content: "+"; }
    td.c.del::before { content: "-"; }
    td.c.add { background: var(--add-bg); }
    td.n.add { background: var(--add-num); color: var(--fg); }
    td.c.del { background: var(--del-bg); }
    td.n.del { background: var(--del-num); color: var(--fg); }
    td.nil { background: var(--bg-muted); }
    td.add .x { background: var(--add-word); border-radius: 2px; }
    td.del .x { background: var(--del-word); border-radius: 2px; }
    .t:empty::before { content: "\200b"; }
    td.nonl .t::after { content: " \29B8"; color: var(--minus); }
    tr.hunk td { background: var(--hunk-bg); color: var(--fg-muted); user-select: none; -webkit-user-select: none; }
    tr.hunk td.hh { padding: 2px 10px; white-space: pre-wrap; overflow-wrap: anywhere; }

    /* Review comments. The line-number gutter is the "add a comment" target. */
    td.n[data-n]:hover { cursor: pointer; }
    td.n[data-n]:hover::after {
      content: "+"; position: absolute; left: 3px; top: 2px; width: 16px; height: 16px;
      border-radius: 4px; background: var(--accent); color: #ffffff;
      font: 600 13px/16px -apple-system, sans-serif; text-align: center;
    }
    td.c.cm { background-image: linear-gradient(var(--mark-bg), var(--mark-bg)); box-shadow: inset 3px 0 0 var(--mark-edge); cursor: pointer; }
    td.c.cm.done { background-image: none; box-shadow: inset 3px 0 0 var(--border); }
    @keyframes pkb-flash { from { outline-color: var(--accent); } to { outline-color: transparent; } }
    td.c.flash { outline: 2px solid transparent; outline-offset: -2px; animation: pkb-flash 1.4s ease-out; }
    /* While a selection is being dragged, only the side it started on is selectable. */
    body.sel-l td.c.r, body.sel-r td.c.l { user-select: none; -webkit-user-select: none; }

    """#
}
