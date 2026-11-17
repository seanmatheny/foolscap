# Markdown editing review, 2026-11-18

Sean's brief: the markdown and navigation in Daily Notes felt clunky and inconsistent. Some
constructs formatted at once and hid their syntax (bullets, code blocks), others kept their
markers in view on the caret's line (headings, quotes), one did not format until the caret left
(`---`), emphasis kept its asterisks after the closing pair was typed, and a line could not be
added after or between two link cards. The yardstick was Bear: hide the markdown as soon as it
can be hidden, and do what most markdown editors do on Return, Tab and ⌫.

This is the evaluation, construct by construct, and what changed in 0.23.0. The editor is one
code path for both apps (`MarkdownStyler`, `MarkdownCommands.swift`), so every change is on
the phone too; the Mac is what was built and tested here.

## One rule for syntax

Before, the rule was "syntax shows, dimmed, on every line under the selection; it is hidden
elsewhere". That is why a heading kept its hashes until Return, a quote its `>`, and
`**bold**` its asterisks while the caret stayed on the line, and why a rule only drew once the
caret had left.

Now the rule is "syntax is hidden the moment its construct is complete; it shows, dimmed, only
while the selection touches the marker itself". Touching means:

| Marker | Shown while |
|---|---|
| `#`s of a heading, `>` of a quote | the caret is anywhere from the line's start to just after the marker (so Home on a heading shows its level; typing the title hides it) |
| `-`/`*`/`+` of a bullet | the caret is on either side of the dash (unchanged from 0.20.0) |
| `**`, `*`, `` ` ``, `~~`, `==`, `[`…`](url)` | the caret is strictly inside the span, or a selection crosses it; at either edge, hidden, so the closing keystroke folds the span up |
| the dashes of a `---` rule | the caret is strictly inside them; otherwise the rule is drawn, caret on the line or not |
| ``` fences | the caret is on the line (the language is typed after the marks; unchanged) |
| `- [ ]` task marks, `1.` numbers | always (they are controls, not syntax) |

The styler keeps the touched set per line (`revealedSyntax`) and restyles a line only when
its set changes, so a caret moving through plain text costs nothing.

## Construct by construct

| Construct | Before | Now |
|---|---|---|
| Heading `## Title` | heading font at once, hashes visible until the caret left the line | hashes go as the first letter of the title is typed; back with the caret at the line's start |
| Bullet `- ` | dot as soon as the space is typed | unchanged |
| Numbered `1. ` | number shown, renumbers | unchanged |
| Task `- [ ] `, `[] ` shorthand | mark shown, click cycles | unchanged |
| Quote `> ` | quote style at once, `>` visible on the caret's line | `>` hidden once text follows it; the bar and indent say it is a quote |
| Rule `---` | plain dashes until the caret left the line | drawn as a rule on the third dash; the dashes show only with the caret inside them |
| `**bold**`, `*italic*`, `~~gone~~`, `` `code` `` | styled when the closing pair was typed, delimiters dimmed until the caret left the line | delimiters hidden on the closing keystroke; back when the caret steps into the span |
| `[text](url)` | as above | as above |
| `==highlight==` | not recognised (`MarkdownEscaping` already escaped it) | a marker-yellow stroke; Format ▸ Highlight, ⇧⌘H, and a button on the phone's bar |
| Code block | fences shown on the caret's line; typing ``` swept the rest of the note into the block until a closing fence was typed | Return on a fresh opening fence writes the closing one under a blank line and puts the caret between (Bear, Obsidian, Typora, VS Code do this); leaving a block by typing the close is as in 0.22.1 |
| Pictures and link cards | the caret skipped the line whole, so there was no caret position after a card or between two; ⌫ beside one removed it | the card is a block the caret rests on (see below) |
| Tags, bare URLs | styled, no syntax | unchanged |

## Return, Tab and ⌫

| Key | Before | Now |
|---|---|---|
| Return on an empty top-level item | ends the list, the `- ` goes | unchanged |
| Return on an empty nested item | steps out a level, keeping an empty bullet at the outer level (Bear, Notes, Notion do this; another Return ends the list) | unchanged; tests now cover a nested task, a tab-indented item and a nested numbered item. Sean reported the list ending instead: it could not be reproduced on the Mac, so the exact steps (and whether on the phone) are wanted |
| Return before a space in an item (`- one‸ two`) | `- one` / `-  two` | `- one` / `- two` |
| ⌫ just after `- `, `1. `, `- [ ] `, `> `, `## ` | deleted the space, leaving `-item` as plain text | takes the marker off: the line is plain text; a nested item steps out a level first |
| Tab / ⇧Tab on items | indent by a level | unchanged |
| Return on a fresh ``` | plain newline, the block ran to the end of the note | closes the block (above) |

## Pictures and cards as blocks

A collapsed image or URL line now holds the caret at its end, and only there. The picture or
card shows selected (outlined in the accent colour) while the caret is on it, on both
platforms (`SelectableOverlayView`). From there:

- ↓ and ↑ stop on every block, so two cards in a row are two stops.
- Return opens a line under the block; text typed, or pasted, goes on a new line under it.
  Nothing is ever typed into the block's own markdown.
- ⌫ or ⌦ removes the block (and lands on the next one when another has moved up).
- ← from the block goes to the end of the line above; → to the start of the line below.
- A click on a picture puts the caret there (a tap on the phone too, without raising the
  keyboard). The badges and menus (Show Markdown, Copy, Show as Text) are unchanged.
- ⌫ at the start of the line under a block and ⌦ at the end of the line above one still remove
  it whole, as since 2026-10-26.

The one-line reason the old model broke: the caret could never rest on a collapsed line, so
between two cards there was no position at all, and after the last card only the next line's
start.

## Left as they are, deliberately

- Fence lines show whole while the caret is on them: the language is typed after the marks.
- `*word*s` is not italic (CommonMark would make it so): the tokenizer forbids intraword
  emphasis for both `*` and `_`, which keeps `snake_case` and `2 * 3 * 4` plain.
- No auto-pairing of `**`, `` ` `` or `[]`: Bear does not either.
- A bare URL line in the Secrets editor (no link cards there) still collapses to a hairline;
  URLs there are normally `- site: …` lines, which are not URL lines.
- The Today panel's room under a daily note's date is reserved on the heading line, which is
  unaffected by the hash hiding.

## Files

`Sources/FoolscapCore/InlineTokenizer.swift` (highlight), `Sources/FoolscapEditor/MarkdownStyler.swift`
(touched-syntax reveal), `MarkdownCommands.swift` (`restingCaret`, `blockUnderCaret`,
`typedOnBlock`, `backspaceOnMarker`, the fence close, the Return space), `MarkdownTextView.swift`
and `MarkdownTextView+iOS.swift` (the selection hook, paste, ⌫/⌦), `OverlayController.swift`
and `OverlayViews+iOS.swift` (`select(line:)`, the card outline), `EditorDecorations.swift`
(rules draw unless the dashes show), `EditorPalette.swift` (`marker`), the Format menu and the
phone's bar. Tests: `Tests/FoolscapTests/SyntaxRevealTests.swift`.
