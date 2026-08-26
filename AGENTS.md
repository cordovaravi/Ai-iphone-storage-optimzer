# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
OffloadPro is a **native iOS app** (Swift 5.10, SwiftUI, iOS 16+). The Xcode
project is generated from `project.yml` with [XcodeGen]; SwiftPM deps (GRDB,
RevenueCat, Sentry) are declared there. See `README.md` for the full Mac setup
and architecture.

### Hard platform limitation (read first)
The full app **cannot be built, run, or tested in the Cursor Cloud Linux VM**.
Building/running/testing requires **macOS + Xcode 16 + XcodeGen + an iOS
Simulator/device**, none of which exist on Linux. The sources import Apple-only
frameworks throughout (`SwiftUI`, `UIKit`, `Photos`/`PhotosUI`, `CryptoKit`,
`BackgroundTasks`, `AuthenticationServices`, `ImageIO`, `CoreGraphics`,
`RevenueCat`, `Sentry`). On a Mac the normal flow is:
```
brew install xcodegen && xcodegen generate && open OffloadPro.xcodeproj   # ⌘R to run, ⌘U for tests
```
There is intentionally **no `Package.swift`** and no `.xcodeproj` committed
(both are gitignored / generated), so `swift build`/`swift test` at the repo
root will not work.

### What the Linux VM *can* do
A Linux Swift toolchain (`swift`/`swiftc`, currently 6.3.3, installed via
`swiftly`) is available and can compile/run the **platform-agnostic logic
layer** — the pure `Foundation`-only files with no Apple-framework or GRDB
dependency. This is the only end-to-end thing runnable here. Example (a closed,
self-contained set):
```
swiftc -swift-version 5 \
  OffloadPro/Services/Scanner/AssetProviding.swift \
  OffloadPro/Services/Scanner/DHash.swift \
  OffloadPro/Services/Scanner/BlurScorer.swift \
  OffloadPro/Core/Extensions/ByteFormatting.swift \
  <your-main>.swift -o /tmp/demo && /tmp/demo
```
Files that pull in `GRDB` (e.g. `Core/Models/*`, `Core/Database/*`), Apple
frameworks, or `CryptoKit` (`Services/Offload/StreamingHasher.swift`) will not
compile on Linux without a Mac/Xcode. The XCTest suites in `OffloadProTests/`
depend on those types, so they run only on macOS.

### Toolchain gotchas
- `swift` is on `PATH` only in **login shells** (`swiftly` added the loader to
  `~/.profile`). If a command can't find `swift`, run it via `bash -lc '...'`
  or first `. "$HOME/.local/share/swiftly/env.sh"`.
- Use `-swift-version 5` when compiling (the project targets Swift 5.10; the
  installed compiler is 6.x and defaults to a newer language mode).
