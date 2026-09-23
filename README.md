# Foolscap

A skeuomorphic macOS notebook and task manager. Daily notes are markdown files
in a folder you choose (iCloud Drive works), tasks written in those notes are
collected into a Tasks tab, and the whole thing looks like a leather notebook
with paper index tabs.

Named for foolscap paper, the old ruled sheet whose watermark was a jester's cap.

## Layout

```
Daily/2026-09-23.md               one file per day
Attachments/2026-09-23/*.png      pasted screenshots and images
Tasks.md                          tasks added from the Tasks tab or quick-task panel
```

Tasks are ordinary markdown checkboxes, with the Obsidian convention for
"in progress". Indented lines under a task are its notes (links welcome):

```
- [ ] Not started #category
  Notes for the task, see https://example.com
- [/] In progress
- [x] Completed
```

## Features

- Daily Notes: one markdown page per day. Markdown syntax is shown only on the
  line the caret is on (Bear-style). Paste or drop screenshots and images: they
  are saved to `Attachments/` and shown inline; drag the corner handle to resize
  (stored as `![alt|width](path)`). Bare URLs get link-preview cards.
  ⌘[ / ⌘] flip days, ⌘T is today.
- Tasks: every `- [ ]` line from every note, grouped by status. Drag a task
  between sections or click its checkbox; double-click (or the pencil) opens an
  editor for its one-line text and its notes; the tag button or the context menu
  adds `#tags`. Every change is written back into the note. `+` adds a task to
  today's note.
- Tags: `#tag` anywhere in a note is highlighted and indexed, but shown nowhere
  else. In search, type `#` for a list of tags; `#tag` in a query is a strict
  filter (a tag being typed filters by prefix).
- Search: ⌘⇧F searches all notes and tasks (SQLite FTS5); ⌘F finds in the page.
- Quick task: ⌃⌥Space from any app (configurable in Settings) opens a small
  panel; Return adds the task to the Tasks tab. Tasks added this way, or with
  the tab's `+`, live in `Tasks.md` at the notebook root rather than in a day.
- Text size: ⌘+ / ⌘− / ⌘0, or the slider in Settings. Ruling and line height
  scale with the text.
- Tabs: ⌘D Daily Notes, ⌘T Tasks. ⌘⇧T is today, ⌘[ / ⌘] flip days.
- On launch the closed cover, embossed with the jester, swings open (Settings can
  turn this off; Reduce Motion skips it).
- Full screen (green button or ⌃⌘F): the notebook fills the display with square
  corners; the menu bar hides and comes back when the pointer touches the top.
- Export: File ▸ Export Notes… (⌘⇧E) writes a day, a range or everything as
  Markdown (with attachments), TextBundle (one package per note, images inside),
  HTML or PDF.
- Themes: Classic Black, Oxblood, Kraft and Midnight (Foolscap ▸ Settings…).
  Midnight is the dark one: pale leather around true-black paper with white ink.
  Pages carry paper texture only, no ruling.
- iCloud Drive: the notebook folder can live in iCloud Drive; placeholder files
  are downloaded on demand and conflicting copies get a Keep mine / Take theirs /
  Keep both banner.

## Building

The app is a plain Swift package; the Makefile assembles `Foolscap.app`.

```
make app        # release build → Foolscap.app
make run        # debug build and launch
make test
make install    # copies to ~/Applications
```

Requirements: macOS 26+ and Xcode 26+ with its licence accepted. (If the licence
is not accepted the Makefile falls back to the Command Line Tools and borrows
Xcode's SwiftUI macro plugins.) `swift` on PATH may be
python-swiftclient on this machine, so the Makefile always uses `xcrun swift`.

## Package targets

| Target | Purpose |
|---|---|
| `FoolscapCore` | Models, section/task/search protocols, markdown line parsing |
| `FoolscapStore` | Notes folder, iCloud coordination, SQLite FTS5 index |
| `FoolscapEditor` | TextKit 2 hybrid markdown editor |
| `FoolscapUI` | Notebook chrome, themes, textures |
| `FoolscapSections` | Daily Notes, Tasks, search, preferences, export |
| `FoolscapScribe` | Kindle Scribe tab: Amazon sync, handwriting OCR, transcripts, `#scribe` tasks |
| `FoolscapScribeOCR` | The `scribe-ocr` helper bundled next to the app binary (Vision runs out of process) |
| `FoolscapApp` | The executable |

New sections (for example a Kindle Scribe tab) conform to `NotebookSection`
in `FoolscapCore` and are registered in `AppModel.sections`. A section can
contribute a tab, a `TaskProvider` (its tasks appear in the Tasks tab, read-only
if it says so), a `SearchProvider`, and a settings pane.

## Launch flags (for scripting and screenshots)

```
Foolscap --day 2026-09-22      open on a given day
Foolscap --search dave         open the search palette with a query
Foolscap --export              open the export sheet
Foolscap --prefs               open Settings
Foolscap --scribe              show the Scribe tab whatever Settings says
```

`Tools/window-shot.sh Foolscap out.png [all]` captures the app's window(s).
