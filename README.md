<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/app-icon-512.png" alt="Peekaboo" width="128">
</p>

# Peekaboo

A fast macOS Markdown viewer with native Quick Look previews.

macOS doesn't render Markdown well out of the box: opening a `.md` file in an editor is heavy,
and Finder's Quick Look just shows the raw text. Peekaboo fixes that. It renders Markdown the
way you'd see it on GitHub — both as a real app window and as a Finder **Quick Look** preview
(select a file and press space). Everything renders **fully offline**: the CSS, web fonts, math
typesetting, and syntax-highlighting assets are all inlined into the generated HTML, so a
preview never touches the network — which is what lets the sandboxed Quick Look extension work
at all.

## Install

Requires macOS 13+, [Xcode](https://developer.apple.com/xcode/), and
[`xcodegen`](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen   # one-time
git clone https://github.com/kylebeggs/Peekaboo.git
cd Peekaboo && ./Scripts/build.sh && ./Scripts/install.sh
```

`build.sh` generates the Xcode project and builds a Release app (DerivedData → `/tmp/peekaboo-dd`).
`install.sh` copies it to `/Applications`, registers the Quick Look extension (and flushes its
cache), and installs the `peekaboo` command-line wrapper. Re-run both after pulling updates —
`install.sh` is what makes new builds show up in the app and in Quick Look.

## Features

- **GitHub-Flavored Markdown** — tables, task lists, strikethrough, autolinks, footnotes
- **Math** via KaTeX — `$inline$`, `$$display$$`, and ` ```math ` fences, with a MathJax fallback
- **GitHub alerts** (`> [!NOTE]`) and **Obsidian callouts** (including foldable ones)
- **Syntax highlighting** for fenced code blocks; also renders whole source files (`.jl`, `.py`, …)
- **Obsidian-style wikilinks** — `[[Note]]`, `[[Note#Heading|alias]]`, `![[image]]`
- **Emoji shortcodes**, **YAML front matter** rendered as a table, and **heading anchor links**
- **Mermaid diagrams** (app only — see [Under the hood](#under-the-hood))
- **Live reload** — edit in any editor and the preview updates in ~150 ms, preserving scroll position
- **Source view** — toolbar toggle between the rendered page and the raw Markdown, plus one-click
  copy of the source and a Show in Finder button
- **Light / dark mode** following the system appearance
- **Review-comment sidebar** for annotating documents
- **Local diff review** — `peekaboo diff` shows a git repo's changes as a GitHub-style side-by-side
  diff with per-file Viewed toggles and line comments (see [Reviewing a diff](#reviewing-a-diff))
- **Self-contained output** — local images are inlined as data URIs

## Usage

- **Open in the app** — double-click a Markdown file, or run `peekaboo file.md`
  (a thin `open -a Peekaboo` wrapper).
- **Quick Look** — select a Markdown file in Finder and press space.
- **Live reload** — keep the Peekaboo window open while you edit in your editor of choice; the
  preview refreshes on save.
- **Supported extensions** — `md`, `markdown`, `mdown`, `mkd`, `mkdn`, plus source files like `.jl`.

## Reviewing a diff

Run `peekaboo diff` inside a git repository (or use **File > Review Repository…**) to review its
changes the way you would a pull request, without pushing anything:

- **What it compares** — the point where your branch left the default branch, against the working
  tree. Uncommitted edits and brand-new untracked files are included: it is what the PR would
  contain if you committed right now. Pass a ref to compare against something else:
  `peekaboo diff HEAD~3`.
- **Side by side** — old on the left, new on the right, removed lines red and added lines green,
  syntax-highlighted, with the changed part of each edited line marked.
- **Viewed** — tick a file's Viewed box to collapse it. If that file's changes later differ, it
  un-views itself, as on GitHub.
- **Comments** — click a line number, or select some code and press **Comment**. Threads appear in
  the same sidebar documents use, grouped by file.
- **Live** — the window follows the working tree, so edits made while it is open show up as they
  are saved, without losing your place or your collapsed files.

Comments are stored in `<repo>/.peekaboo/review.md`, a readable Markdown file meant to be handed to
a coding agent: it reads the threads, changes the code, and replies in the same file, which the
window picks up live. A comment stays attached to its lines as the code moves; if the commented
line itself is rewritten, the thread is marked *outdated*. The `.peekaboo/` folder ignores itself,
so it never shows up in `git status`.

## Under the hood

Peekaboo is three layers, with the dependency flowing downward:

- **`App/`** — the SwiftUI app: `DocumentGroup` opens files, a `WKWebView` displays the rendered
  HTML, and a `FileWatcher` drives live reload. A second document scene hosts diff reviews, which
  shell out to `git` for the diff itself.
- **`QuickLook/`** — the sandboxed, read-only Quick Look extension. It runs **without JavaScript**.
- **`Packages/MarkdownRenderer/`** — the shared rendering engine both layers call into. It's a
  UI-free, fully testable Swift package that turns Markdown into a single self-contained HTML
  document. It also builds a `markdown-render-cli` executable for rendering from the command line.

Two consequences worth knowing:

- JavaScript-only features (Mermaid) render in the app but not in Quick Look, since the extension
  has no JS engine.
- Documents over 2 MB skip math and syntax highlighting to stay within Quick Look's memory budget.

> **Note:** `Peekaboo.xcodeproj` is generated by XcodeGen from `project.yml` — don't edit the
> `.xcodeproj` by hand. Change `project.yml` and re-run `xcodegen generate` (`build.sh` does this).

## Development

Tests live in the Swift package, not an Xcode test target:

```bash
cd Packages/MarkdownRenderer
swift test                                          # all tests
swift test --filter MarkdownRendererTests/testTable # a single test
```

Render a file straight to HTML from the command line:

```bash
markdown-render-cli file.md > out.html
```

Regenerating the app icons (`Scripts/make-icons.sh`) additionally needs `rsvg-convert`
(`brew install librsvg`).

## Project layout

```
App/                      SwiftUI app
QuickLook/                Quick Look extension
Packages/MarkdownRenderer/  shared rendering engine + markdown-render-cli
Scripts/                  build.sh, install.sh, the peekaboo CLI, make-icons.sh
Design/                   source SVG art for the icons
project.yml               XcodeGen project spec (source of truth for the Xcode project)
```
