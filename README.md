<p align="center">
  <img src="docs/icon.png" width="160" alt="Diski icon">
</p>

<h1 align="center">Diski</h1>

<p align="center"><b>The cleanest, fastest Finder alternative for Mac.</b><br>
Everything Finder does — and the things it should have done all along — with Liquid Glass, instant folders and copies that finish before you blink.</p>

<p align="center">
  <img src="docs/screenshots/list.jpg" alt="Diski list view" width="900">
</p>

## Why it is fast

| What | How Diski does it | Finder |
| --- | --- | --- |
| Opening a folder | `getattrlistbulk(2)` reads names, sizes, dates, flags and Finder info for a whole batch of files in **one system call**. No `NSURL` per file, no per-file `stat`. | Per-item resource lookups |
| Sorting 50 000 files | Names are pre-folded into compact natural-sort keys once; sorting is byte comparisons, not `localizedStandardCompare` per comparison. | Visible delay in large folders |
| Going back | Listings are cached and kept current with FSEvents, so Back/Forward and tabs are instant. Refreshes merge into the existing listing, so selection and expanded folders never jump. | Re-reads |
| Copying on the same drive | **APFS clones** (`clonefile`): whole folder trees copied copy-on-write in a single call. A 20 GB folder "copies" in milliseconds and uses no extra space. | Clones files, but walks and prepares first |
| Moving on the same drive | One `rename(2)` per item. | — |
| Copying between drives | No "Preparing…" phase: folders are scanned while copying starts, files stream through **parallel workers**, big files bypass the page cache, sparse files stay sparse, metadata is applied last. | One file at a time |
| Folder sizes | Calculated in the background with a parallel, allocation-free scanner and shown right in the list. | `--` |

Settings › Speed has a built-in speed test that compares Diski's folder reading with the system's.

## Everything Finder does

- **Four views** — Icons, List (with inline folder disclosure), Columns, Gallery with a live Quick Look preview and filmstrip.
- **Liquid Glass toolbar** — back/forward, AirDrop, view switcher, sort & view options, share, tags, actions and search, exactly where you expect them.
- **Sidebar** — Favorites (drag folders in, reorder, remove), iCloud Drive, Home, volumes with eject buttons and free-space tooltips, AirDrop, Network, Trash and Tags.
- **Preview pane** — big preview, kind & size, created / modified / last opened, dimensions, duration, editable tags, and a "More…" section with permissions, version, where-from and exact sizes.
- **Path bar and item info** — clickable path, item count, selection size and free space.
- **Tabs and windows** — ⌘T / ⌘N, tab bar, merge windows; your windows, tabs and folders come back when you relaunch.
- **All the file actions** — open, open with, Quick Look, rename (Return, like Finder), duplicate, aliases, compress, tags, share, move to Trash, put back, delete immediately, empty Trash, eject, undo/redo for everything.
- **Drag and drop** everywhere — between views, panes, tabs, the sidebar, the path bar and other apps (including file promises from Mail and Photos). ⌥ copies, ⌘ moves, ⌥⌘ makes an alias. Drag to the Dock's Trash to delete.

## Everything Finder is missing

- **Cut & paste** that actually moves files (⌘X, ⌘V).
- **Instant filter** — start typing in the search field and the folder filters as you type; switch to *Subfolders* (a parallel scan, no index needed) or *This Mac* (Spotlight).
- **Dual pane** (⌘\\) with **F5** copy and **F6** move to the other pane, and **Tab** to switch panes.
- **Go to Folder** with live path completion and fuzzy matching on recent folders (⇧⌘G).
- **New Text File** (⌥⌘N), **Copy Path** (⌥⌘C), **Open in Terminal** (Terminal, iTerm, Ghostty or Warp), **Make Symbolic Link**.
- **Paste images and text as files** — copy a screenshot, press ⌘V in a folder, get `Pasted Image.png`.
- **Smarter conflicts** — Keep Both, Replace, Merge, Skip or Stop with a side-by-side comparison ("Newer", "Larger"). Replaced items go to the Trash, so nothing is ever lost.
- **Progress you can trust** — live speed, time remaining, pause/resume and stop in a toolbar progress ring, plus a small glass confirmation when an operation finishes ("Copied 3 items in 0.04 s · instant APFS clone").
- **Folder sizes** in the list, hidden files with one shortcut (⇧⌘.), keep folders on top, row density, full path in the title.

## Keyboard

| | |
| --- | --- |
| ⌘[ ⌘] ⌘↑ ⌘↓ | Back, forward, enclosing folder, open |
| Return · Space | Rename · Quick Look |
| ⌘C ⌘X ⌘V ⌥⌘V | Copy, cut, paste, move here |
| ⌘D ⌘⌫ ⌥⌘⌫ ⌘Z | Duplicate, Trash, delete immediately, undo |
| ⇧⌘N ⌥⌘N ⌃⌘N | New folder, new text file, new folder with selection |
| ⌘1–⌘4 | Icons, List, Columns, Gallery |
| ⌘F ⇧⌘G ⌥⌘C | Filter/search, go to folder, copy path |
| ⌘\\ · F5 · F6 · Tab | Dual pane, copy/move to other pane, switch pane |
| ⇧⌘. ⇧⌘P ⌥⌘P ⌥⌘S | Hidden files, preview, path bar, sidebar |

Help › Diski Keyboard Shortcuts (⇧⌘/) shows the full list.

## The icon

`Diski/AppIcon.icon` is an Icon Composer document: a warm amber-to-pink face with a frosted Liquid Glass half and a lightning-bolt nose, with dark, tinted and clear variants. Open it in Icon Composer to tweak it.

<p align="center"><img src="docs/icon-variants.png" width="720" alt="Icon variants"></p>

## Build

Requirements: macOS 26 or later, Xcode 26 or later.

```sh
git clone https://github.com/jordylegrand-cpu/Diski.git
open Diski/Diski.xcodeproj   # then ⌘R
```

Diski is not sandboxed (a file manager needs to see your files). The first time it opens Desktop, Documents or Downloads macOS asks for permission; for the Trash and other protected folders, turn on **Full Disk Access** for Diski in System Settings › Privacy & Security.

Every push is built, tested and screenshotted on a macOS 26 runner by GitHub Actions (`.github/workflows/build.yml`).

## Architecture

```
Diski/
  Engine/       DirectoryReader (getattrlistbulk), DirectoryStore (cache + FSEvents), FileItem,
                NaturalSort, FileKinds, IconCache, ThumbnailCache, FolderSizer, SearchEngine, Volumes
  Operations/   CopyEngine (clone / rename / parallel copy), FileOperationManager (undo, trash,
                put back, rename, compress), progress & conflict UI
  Browser/      BrowserWindowController (toolbar, tabs, dual pane, Quick Look), PaneViewController
                (navigation, actions, drag & drop), List / Icon / Column / Gallery view controllers
  Sidebar/      Favorites, locations, volumes, tags
  Inspector/    Preview pane (SwiftUI)
  Dialogs/      Go to Folder, Connect to Server
  Settings/     Settings window and speed test
DiskiTests/     Engine tests: listings vs FileManager, natural sort, copy correctness, conflicts, sizes
```

## License

MIT — see [LICENSE](LICENSE).
