# Phorganize

Phorganize is a native macOS app for safely importing camera media into a Lightroom Classic-oriented archive structure.

It reads metadata from photos, RAW files, and videos, then copies or moves files into a consistent date-based folder layout:

```text
yyyy/mm/dd/camera_model/lens_model/yyyyMMdd-HHmmss_seq.ext
```

The lens-model folder is optional. When camera or lens metadata is missing, Phorganize uses `(null)` for that folder.

## Features

- Native SwiftUI macOS app.
- Drag-and-drop or picker-based source and destination folder selection.
- Persistent source, destination, and rule settings with security-scoped bookmarks.
- Metadata extraction with native Apple frameworks instead of per-file subprocesses.
- Supported media includes common image, RAW, and video extensions such as JPEG, HEIC, TIFF, PNG, DNG, CR2, CR3, RAF, ORF, MP4, and MOV.
- Date-based archive layout with optional camera-model and lens-model folders.
- Copy mode and move mode. Move is implemented as copy, verify, then delete source.
- APFS clone/shallow copy is attempted for same-volume copies.
- Parallel metadata extraction and copy execution.
- SHA-256 comparison for existing destination files:
  - identical existing file: skip;
  - different existing file: add a sequence suffix.
- Warnings for recursive imports where the destination is inside the source folder.
- Localized UI resources for English and Japanese.
- Sandboxed and hardened-runtime Xcode app target.

## Build

Requirements:

- macOS 13 or later
- Xcode 26 or compatible Swift/Xcode toolchain

Build the macOS app:

```bash
xcodebuild -project Phorganize.xcodeproj \
  -scheme Phorganize \
  -configuration Release \
  -derivedDataPath .xcode-derived \
  build
```

The built app is created at:

```text
.xcode-derived/Build/Products/Release/Phorganize.app
```

## Test

Run unit tests:

```bash
swift test
```

Run the coverage gate. The target is 80% line coverage for the core package code:

```bash
scripts/check_coverage.sh 80
```

## Project layout

```text
Phorganize.xcodeproj/          Xcode macOS app target
Sources/PhorganizeApp/         SwiftUI app, resources, entitlements
Sources/PhorganizeCore/        Metadata, planning, copy/move logic
Tests/PhorganizeCoreTests/     Unit tests
scripts/check_coverage.sh      Coverage threshold script
docs/implementation_plan.md    Design and migration notes
design/icon-candidates/        App icon design candidates
```

## Privacy and security

Phorganize processes files locally. It does not use accounts, cloud services, analytics, or tracking.

The app is sandboxed and uses user-selected read/write access plus app-scoped security-scoped bookmarks. Its privacy manifest declares local use of UserDefaults and file timestamp APIs for app functionality.

## License

MIT License. See [LICENSE](LICENSE).
