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

New sections (for example a Kindle Scribe tab) conform to `NotebookSection`
in `FoolscapCore` and are registered in `AppModel.sections`.
