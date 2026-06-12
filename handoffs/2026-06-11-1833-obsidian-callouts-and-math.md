---
slug: obsidian-callouts-and-math
created: 2026-06-11-1833
status: done
closed: 2026-06-12
---

# Handoff: Obsidian callout + blockquote math support — follow-ups

## Goal / why this matters

Kyle's Obsidian vault (`~/Documents/second-brain/`) is a primary use case for
Peekaboo. This session added Obsidian callout and blockquote-math rendering;
the changes are implemented, verified against the real vault docs, and
installed, but the test suite has not been run and a few Obsidian features
remain unsupported.

## Background & current state

Three rendering bugs were fixed (uncommitted on `main` as of this writing):

1. **Obsidian callouts** — `AlertsPass.swift` rewritten. It now accepts all
   Obsidian callout kinds (`info`, `question`, `danger`, `example`, …) mapped
   onto the 5 existing GitHub alert style classes, case-insensitive markers,
   custom titles on the marker line (including inline math/formatting), fold
   markers (`[!info]-`, rendered expanded), and `>[!info]` without a space.
2. **Display math in blockquotes** — `MathExtractor.swift` now strips `> `
   prefixes when detecting `$$` blocks and re-emits tokens with the prefix
   preserved, so math inside callouts stays inside the blockquote.
3. **Glued opener** (`…such as$$` at end of a text line) — previously the
   unpaired `$$` mispaired every later block and swallowed headings into math.

Verified by rendering every doc in
`~/Documents/second-brain/Theory/Automatic Differentiation/` with
`markdown-render-cli`: zero leaked `[!kind]` markers, zero leaked `$$`, zero
KaTeX errors, kitchen-sink fixture needles all pass. App rebuilt and installed
to /Applications with the QL extension re-registered.

## Key files / locations

- `Packages/MarkdownRenderer/Sources/MarkdownRenderer/AlertsPass.swift` — kind
  map, marker/title parsing, title rendered via detached cmark document
- `Packages/MarkdownRenderer/Sources/MarkdownRenderer/MathExtractor.swift` —
  `splitQuotePrefix`, `collectBlock`, glued-opener branch
- `Packages/MarkdownRenderer/Sources/MarkdownRenderer/CMarkPipeline.swift` —
  now passes the parser's syntax-extension list into AlertsPass
- `Packages/MarkdownRenderer/Tests/MarkdownRendererTests/MarkdownRendererTests.swift`
  — 16 new tests (Obsidian callouts + quoted/glued math). **Written and
  compiled but never run** (user policy: don't run tests unless told).

## Decisions & conclusions

- Obsidian-only kinds reuse the closest GitHub style class instead of adding
  new CSS/icons (e.g. `question`→`warning`, `example`→`important`); the
  default title still shows the real kind name ("Question"). `quote`/`cite`
  intentionally fall through to the base gray `.markdown-alert` styling.
- Callout titles are rendered by moving the title inline nodes into a detached
  cmark document and rendering that, then embedding the HTML in the raw
  `<p class="markdown-alert-title">` block. **A detached paragraph cannot be
  rendered directly**: cmark-gfm's `html.c:304` dereferences `parent->type`
  unconditionally on paragraph exit → SIGSEGV. The document wrapper is the
  fix; this is an upstream cmark-gfm bug worth knowing about.
- Title HTML is wrapped in an inner `<span>` so the flex `gap: 8px` on
  `.markdown-alert-title` doesn't split rich titles into spaced-out fragments.

## What's left / next steps

1. Run the test suite when Kyle says to: `cd Packages/MarkdownRenderer &&
   swift test` (16 new tests have never executed).
2. Commit the changes (Kyle hasn't asked yet; working tree is dirty).
3. Optional, vault-visible gaps spotted while verifying (not requested, ask
   first): Obsidian wikilinks `[[Note]]` / `[[Note#Heading]]` render as
   literal text in every vault doc; nested callouts and fold/collapse behavior
   are unsupported (fold markers are ignored, always expanded).

## Gotchas / constraints

- The repo lives in iCloud Drive — keep build products outside it
  (`swift build --scratch-path /tmp/peekaboo-spm`, app builds in
  `/tmp/peekaboo-dd` via `Scripts/build.sh`).
- `MathExtractor` quote-stripping is deliberately conditional: candidate/inner
  lines are only stripped when the opener line was quoted, so TeX lines that
  legitimately start with `>` in unquoted blocks survive.
- A truly blank line ends a blockquote, so `findBlockClose` aborts a quoted
  block search at blank lines; `>`-only lines are fine.
- Quick verification loop without tests:
  `/tmp/peekaboo-spm/debug/markdown-render-cli <file.md>` and grep the output
  for leaked `[!`, `$$`, or `math-error`.

## Outcome (2026-06-12)

All items addressed. Suite ran green (68 tests; one pre-existing
testImageInlining bug fixed — temp dir URL lacked the directory flag). Work
landed as atomic commits: math fixes, callout support, foldable callouts via
details/summary (works in QL, no JS), and wikilinks ([[Note]], aliases,
headings, ![[image]] embeds) with in-app navigation (vault discovery via
.obsidian, NSDocumentController open). Nested callouts already worked —
regression test added. Vault sweep of all 473 notes found and fixed two more
MathExtractor bugs: glued closers ($$prose) and stray $ inside wikilinks
swallowing the closing ]]. Final sweep: zero leaks. Known cuts: cross-note
heading anchors unused on open, no vault search cache, [[Note|alias]] breaks
inside GFM tables (use \|), `- [!]` alternative checkboxes render literally
(out of scope).
