# DevSweep

A developer-focused disk cleaner for macOS. General cleaners (DaisyDisk,
CleanMyMac) don't know that 100GB of your disk is old simulator runtimes and
DeviceSupport symbols; DevSweep does.

## What it scans

| Category | Preselected? | Why |
|---|---|---|
| Xcode DerivedData | yes | rebuilt on next build |
| iOS DeviceSupport | all but newest per device | regenerated when a device reconnects |
| Simulator caches (user + system) | yes | rebuilt on simulator boot |
| Unavailable simulators (`simctl delete unavailable`) | yes | devices with no runtime |
| Simulator runtimes (`simctl runtime delete`) | **no** | ~16GB each, re-downloadable from Xcode |
| Xcode Archives | **no** | needed to symbolicate shipped builds |
| npm / SwiftPM / pip / CocoaPods / Gradle / Playwright / Homebrew | yes | re-downloaded on demand |
| Hugging Face / Ollama models | **no** | slow to re-download |

## Install

Download the latest `DevSweep-x.y.dmg` from
[Releases](https://github.com/jbaker00/DevSweep-macOS/releases), open it, and
drag DevSweep to Applications. The app is signed and notarized. Free, MIT
licensed. Requires macOS 14+.

## Build & run

```sh
xcodegen generate
open DevSweep.xcodeproj   # or:
xcodebuild -project DevSweep.xcodeproj -scheme DevSweep build
```

The project is generated — edit `project.yml`, then `xcodegen generate`.
Do not hand-edit `DevSweep.xcodeproj`.

Not sandboxed (it needs `~/Library/Developer`, dotfile caches, and
`xcrun`/`brew`), so this can't ship on the Mac App Store as-is — Developer ID
+ notarization is the distribution path. Some paths (e.g.
`/Library/Developer/CoreSimulator/Caches`) may require granting the app Full
Disk Access in System Settings → Privacy & Security.

Deletions are permanent (`FileManager.removeItem`), guarded by a confirmation
dialog.

## Releasing

`scripts/release.sh` archives a Release build, notarizes the app, packages a
signed + notarized DMG into `build/`, and with `--publish` creates a GitHub
release. Needs a "Developer ID Application" certificate and an App Store
Connect API key.

## Roadmap

- Per-simulator-device listing with sizes and last-boot date.
- watchOS/tvOS/macOS DeviceSupport, Xcode DocumentationCache.
- Move-to-Trash option instead of permanent delete.
- Menu-bar mode with a "you could free X GB" badge.
- Scheduled scans + notification.
