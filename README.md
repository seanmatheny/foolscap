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
```

Tasks are ordinary markdown checkboxes, with the Obsidian convention for
"in progress":

```
- [ ] Not started #category
- [/] In progress
- [x] Completed
```

## Features

- Daily Notes: one markdown page per day with inline styling, code blocks, pasted
  screenshots (saved to `Attachments/`), and link-preview cards for bare URLs.
  ⌘[ / ⌘] flip days, ⌘T is today.
- Tasks: every `- [ ]` line from every note, grouped by status. Drag a task
  between sections or click its checkbox; the change is written back into the
  note. `+` adds a task to today's note. Categories come from `#tags`.
- Search: ⌘⇧F searches all notes and tasks (SQLite FTS5); ⌘F finds in the page.
- Export: File ▸ Export Notes… (⌘⇧E) writes a day, a range or everything as
  Markdown (with attachments), HTML or PDF.
- Themes: Classic Black, Oxblood, Kraft, Midnight (Foolscap ▸ Settings…).
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

Requirements: macOS 26+, Xcode 26+ (or the Command Line Tools with Xcode
installed alongside, for the SwiftUI macro plugin). `swift` on PATH may be
python-swiftclient on this machine, so the Makefile always uses `xcrun swift`.

## Package targets

| Target | Purpose |
|---|---|
| `FoolscapCore` | Models, section/task/search protocols, markdown line parsing |
| `FoolscapStore` | Notes folder, iCloud coordination, SQLite FTS5 index |
| `FoolscapEditor` | TextKit 2 hybrid markdown editor |
| `FoolscapUI` | Notebook chrome, themes, textures |
| `FoolscapSections` | Daily Notes, Tasks, search, preferences, export |
| `FoolscapApp` | The executable |

| `FoolscapScribe` | Stub for the future Kindle Scribe tab (enable with `--scribe-stub`) |

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
Foolscap --scribe-stub         show the Scribe placeholder tab
```

`Tools/window-shot.sh Foolscap out.png [all]` captures the app's window(s).
