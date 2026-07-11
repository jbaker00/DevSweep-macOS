# CLAUDE.md

DevSweep — developer-focused disk cleaner for macOS. SwiftUI, macOS 14+,
not sandboxed (needs ~/Library/Developer, dot-dir caches, xcrun/brew).

## Project generation

Generated project: edit `project.yml`, run `xcodegen generate`. Do NOT
hand-edit DevSweep.xcodeproj.

## Architecture

- `Models/CacheModels.swift` — `CacheItem` (a deletable path OR an external
  command like `brew cleanup`), `CacheCategory`, `Risk` (.safe = regenerable,
  .caution = review first, never preselected).
- `Scanner/CacheScanner.swift` — read-only discovery. One `@Sendable` builder
  per category, run concurrently in a task group; sizes via
  `totalFileAllocatedSize` enumeration. DeviceSupport keeps the newest version
  per device model deselected (numeric compare of the version token in
  "iPhone18,2 26.5.2 (23F84)"). `simulatorRuntimes` parses
  `simctl runtime list -j` (skipping non-"Ready" states) — nothing in that
  category is EVER preselected (~16GB re-downloads); newest per platform is
  .caution, older ones .safe.
- `ViewModels/SweepModel.swift` — @MainActor @Observable; owns selection,
  performs deletions (permanent) and command runs, rescans after cleaning.
- `Views/ContentView.swift` — sectioned list, per-item toggles, footer with
  selected total + confirm dialog.

Invariant: scanning never mutates the disk; only `cleanSelected()` deletes,
and only what is in `selection`.

## Build

`xcodegen generate && xcodebuild -project DevSweep.xcodeproj -scheme DevSweep build`
