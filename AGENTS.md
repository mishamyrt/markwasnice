# AGENTS.md

## Toolchain
- This is a SwiftPM AppKit app, not an Xcode project; `Package.swift` requires Swift 6.2+ and macOS v26.
- The executable target is `Markwasnice`; SwiftPM only copies `Assets/Fonts`, while `Assets/Info.plist` and the app icon are packaged by `make`.
- Tests use Swift Testing (`import Testing`), not XCTest test-case classes.

## Commands
- Run the app from source with `make run`; it expands to `swift run -Xswiftc -swift-version -Xswiftc 6 Markwasnice`.
- Compile without launching with `swift build`.
- Run all tests with `swift test`; run one test with `swift test --filter SourceMapTests/asciiSingleLine`.
- Format source with `make fmt`, which runs `swiftformat Sources/` only.
- Lint with `make lint`, which runs `swiftlint lint --quiet`.
- Build the signed `.app` bundle with `make`; this requires `/Applications/Xcode.app`, Icon Composer `ictool`, `actool`, and a signing identity named `Markwasnice Signing`.
- Install the packaged app into `/Applications` with `make install`.

## App Wiring
- Startup is `Sources/Markwasnice/main.swift` -> `AppDelegate`; the app is AppKit-only with manual menus and document/window setup.
- `AppDelegate` owns settings and autosave, creates `MarkdownDocument`, and persists autosaved sessions at `~/Library/Application Support/Markwasnice/AutosavedDraft.json`.
- `MarkdownDocumentWindowController` owns the window, `MarkdownEditorView`, `EditorChromeView`, and `MarkdownStylingController` for each document.
- Markdown styling parses on a detached task in `MarkdownParseService`, then `MarkdownStylingController` maps parse ranges and discards stale results by checking source length.
- `SourceMap` converts `swift-markdown` UTF-8 byte columns into NSText `NSRange` UTF-16 offsets; keep the Cyrillic/emoji/combining-mark tests when changing parsing.

## Repo Conventions
- SwiftFormat is intentionally configured with `--swiftversion 5.7` even though the package uses Swift 6.2+.
- SwiftLint has a custom `final_class` rule; make classes `final` unless subclassing is required and disable the rule locally.
- `MarkdownEditorView` preserves undo, selection, scroll position, and IME marked text while applying attributes; avoid wholesale text replacement in styling changes.
