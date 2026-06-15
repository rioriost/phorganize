# Phorganize macOS GUI implementation plan

## phorganize_old analysis

`phorganize_old` is a Python CLI that targets Apple Silicon macOS only. It accepts an input file or directory, optionally walks recursively, extracts MIME type with `python-magic`, extracts camera model and creation date by spawning `mdls`, then copies or moves matching media files to generated destinations.

Important old options and behavior:

- `--move/-m`: move instead of copy. The current implementation uses `shutil.move`; for the GUI this should become "copy, verify, then delete original" for safer media-card workflows.
- `--rename/-r`: replace the original base name with metadata date/time.
- `--recursive`: include files in nested source folders.
- `--camera/-c`: append a camera-model directory. Movies commonly resolve to `(null)`.
- `--output/-o`: destination directory. Without this, the CLI writes under the input directory.
- `--lower/-l` and `--upper/-u`: normalize extension case.
- `--dryrun/-d`: print intended operations only.
- `--tzdelta`: interpret/convert metadata times in a fixed timezone offset.

The old path generation is option-dependent. Date directories are created only when `move` is enabled, camera directories only when `camera` is enabled, and duplicate renamed files get numeric suffixes. The new GUI should instead make the primary workflow explicit: source folder -> rules -> destination folder -> copy/move, using the requested archive layout:

```text
yyyy/mm/dd/camera_model/yyyymmdd-hhiiss_seq.ext
```

The old performance bottlenecks are:

- one `mdls` subprocess per file;
- MIME detection through a Python extension;
- unbounded logical task creation but still limited by blocking subprocess and copy behavior;
- no optimized same-volume clone/copy path.

## New app goals

1. Build a native macOS SwiftUI app with four main vertical areas:
   1. source folder drag/drop and picker;
   2. organization rules mapped from old CLI options;
   3. destination folder drag/drop and picker;
   4. copy/move action, progress, and result summary.
2. Persist source alias/bookmark and path in `UserDefaults`, but allow it to point to a currently missing path.
3. Persist rule options and destination alias/bookmark/path in `UserDefaults`.
4. Replace subprocess metadata extraction with native frameworks:
   - ImageIO for JPEG/HEIC/PNG/TIFF/RAW metadata;
   - AVFoundation for MP4/MOV creation-date and camera-model metadata when available;
   - file attributes as a last-resort creation date only for otherwise supported media files.
5. Process metadata and copies concurrently with configurable bounded concurrency, defaulting to a hardware-aware value.
6. Prefer same-volume shallow copies via APFS clone (`clonefile`) when possible, then fall back to regular copy.
7. Implement move mode as copy to a temporary destination, verify size, atomically promote, then delete source.

## Architecture

The native app is built by `Phorganize.xcodeproj` as a standard macOS `.app` bundle. The project has a shared `Phorganize` scheme and a macOS application target that compiles the SwiftUI app and core organizer sources into one app module. The Swift Package is kept for core unit tests and command-line development builds.

```text
Phorganize.xcodeproj/
  xcshareddata/xcschemes/Phorganize.xcscheme
Package.swift
Sources/
  PhorganizeCore/
    Models.swift
    MediaMetadataExtractor.swift
    FileOrganizer.swift
  PhorganizeApp/
    Info.plist
    Localization.swift
    PhorganizeApp.swift
    Resources/
      en.lproj/Localizable.strings
      ja.lproj/Localizable.strings
Tests/
  PhorganizeCoreTests/
    TargetPlannerTests.swift
```

`PhorganizeCore` contains deterministic, testable logic:

- supported media extension filtering;
- native metadata extraction;
- target path generation and duplicate suffix assignment;
- bounded concurrent planning and execution;
- copy/clone/move file operations.

`PhorganizeApp` contains SwiftUI state, drag/drop, open panels, `UserDefaults` persistence, progress display, and standard macOS app localization through `Bundle.main` and `.lproj/Localizable.strings` resources in the `.app` bundle.

## Data model

- `OrganizationOptions`
  - `recursive`
  - `includeCameraFolder`
  - `renameByDate`
  - `extensionCase` (`preserve`, `lower`, `upper`)
  - `operationMode` (`copy`, `move`)
  - `timezoneOffsetHours`
  - `metadataConcurrency`
  - `copyConcurrency`
- `MediaMetadata`
  - `creationDate`
  - `cameraModel`
  - `sourceKind`
- `PlannedFile`
  - source URL
  - target URL
  - metadata
  - operation mode
- `OrganizationSummary`
  - counts for planned, skipped, copied, cloned, moved, failed.

## Target path rules

For each valid media file:

1. Convert metadata creation date to the selected timezone.
2. Create `yyyy/mm/dd`.
3. Append sanitized camera model when enabled; missing or empty model becomes `(null)`.
4. File base name:
   - if `renameByDate`: `yyyyMMdd-HHmmss`;
   - otherwise: original base name.
5. Extension:
   - preserve/lower/upper according to options.
6. Avoid collisions across the new batch and existing destination files.
   - Single unique files use no suffix when possible.
   - Duplicate or colliding renamed files use `_1`, `_2`, ... before the extension.

## Concurrency and I/O plan

- Enumerate source files once, filtering unsupported extensions before metadata reads.
- Use `withTaskGroup` plus an async semaphore to bound metadata extraction. The default is based on CPU count, capped to avoid overwhelming Spotlight/ImageIO/AVFoundation.
- Use a second bounded task group for copy/move. The default is lower than metadata concurrency because large media files are I/O-bound.
- Each copy writes to a hidden temporary file in the target directory, verifies file size, then moves the temporary file into the final path.
- On same-volume APFS destinations, try `clonefile` first to create a shallow copy. If it fails, fall back to `FileManager.copyItem`.
- Move mode deletes the source only after the final target exists and size verification succeeds.

## Initial implementation scope

The first implementation will provide:

- a buildable SwiftUI macOS app executable;
- folder drag/drop and picker for source/destination;
- persisted bookmarks and settings;
- old-option-compatible rule controls;
- native metadata extraction for images and movies;
- bounded parallel planning and execution;
- shallow-copy fallback logic;
- basic unit tests for deterministic target planning.

Future refinements can add sandbox entitlements/Xcode project packaging, richer preview tables, cancellation, per-file retry, and optional hashing verification.
