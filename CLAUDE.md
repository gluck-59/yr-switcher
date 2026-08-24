# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

macOS menu bar app that converts selected text between any two installed keyboard layouts (e.g., English↔Russian) via a global hotkey. Uses `UCKeyTranslate` to dynamically read layout data from the OS — no hardcoded mappings.

## Working Rules

- Do only what the user explicitly asked. No proactive commits, pushes, or other actions without an explicit request.
- Always verify what was actually done by reading from disk (`defaults read`, TCC db, files) — never rely on memory, caches, or assumed state. Only reading.
- The Accessibility (TCC) grant is keyed to the designated requirement `identifier "com.gluck59.bilingual-switcher" and certificate leaf = H"b902cbab..."`. Never regenerate/replace the signing certificate (the p12 is the single source of truth) and never change the bundle id — either silently revokes the grant and forces a re-grant.

## Build Commands

```bash
make setup    # Download Sparkle framework (required before first build)
make          # Build universal binary (arm64 + x86_64) → build/YRSwitcher.app
make test     # Compile and run XCTest suite (159 tests)
make lint     # SwiftLint in --strict mode (CI enforces this)
make run      # Build + launch the app
make install  # Copy to /Applications
make clean    # Remove build/
```

No SPM or Xcode project — just `swiftc` via Makefile. The test target compiles all `Sources/*.swift` (excluding `main.swift`) + `Tests/*.swift` into an `.xctest` bundle.

## Architecture

**Data flow on hotkey press:**
```
HotkeyManager (Carbon hotkey or NSEvent modifier monitor) → TextSwitcher.switchSelectedText()
  → Cmd+C (copy selected text); nothing copied → retryWithLastWordSelection()
     → Terminal apps: TerminalWordConverter.convertLastWord() { Cmd+A + Cmd+C → parse last word → convert → Ctrl+W → inject }
     → Regular apps: ⌥⇧← selects the previous word and retries
  → LayoutConverter.convertWithTarget(text) {
      KeyboardLayoutMap.buildReverseMap(source)  // char → physical key
      KeyboardLayoutMap.buildCharacterMap(target) // physical key → char
    }
  → Unicode injection replaces the still-active selection; terminal bundle IDs get Right Arrow + N×Backspace first
  → InputSourceSwitcher.switchTo(target) (optional: activate target layout)
  → Restore original clipboard
```

**Key components:**
- `KeyboardLayoutMap` — UCKeyTranslate wrapper. Enumerates installed layouts via TIS APIs, builds character maps per layout, caches them with NSLock thread safety. Reads the physical keyboard type (ANSI/ISO/JIS) from `com.apple.keyboardtype.plist` (`LMGetKbdType()` is unreliable in GUI apps). Observes TIS notifications to invalidate caches and track the two most recently used layouts.
- `LayoutConverter` — Detects source layout by scoring text against each layout's character set (unique chars weighted higher). For 3+ layouts, converts within the two most recently used layouts; score ties break to the currently active layout as source. `convertWithTarget` resolves and returns the target layout so callers can activate it.
- `TextSwitcher` — Orchestrates the flow using `CGEvent` keyboard simulation. With nothing selected, retries on the previous word (⌥⇧←). Delivers converted text via Unicode injection (20-unit UTF-16 chunks) that replaces the still-active selection; terminal bundle IDs use the Right Arrow + N×Backspace flood instead. Missing Accessibility grant auto-opens System Settings.
- `TerminalWordConverter` — Converts the last word before cursor in terminal/iTerm2/TUI apps. Uses Cmd+A + Cmd+C (terminal-level shortcuts) to get the actual screen text, bypassing AX APIs which return Latin in iTerm2. Parses the last non-empty line, extracts the last word, converts it via `LayoutConverter`, deletes the word with Ctrl+W, and injects the converted text.
- `InputSourceSwitcher` — Activates the resolved target layout after conversion via `TISSelectInputSource`.
- `HotkeyManager` — Global hotkey registration with a dual path, chosen by a sentinel key code (`modifierOnlyKeyCode = 0xFFFF`). Keyed shortcuts (e.g. ⌥⌘S) use Carbon `RegisterEventHotKey`; modifier-only combos (e.g. ⌥⌘) use a passive global `NSEvent` monitor (`ModifierOnlyHotkeyMonitor`). Both routes share `register()`/`unregister()`/`registrationFailed`. Settings in UserDefaults (`hotkeyKeyCode`/`hotkeyModifiers`, backward compatible). `HotkeyModifierHelper` converts Carbon masks ↔ normalized `NSEvent.ModifierFlags` and validates combos (≥2 modifiers). Needs only Accessibility (already required for CGEvent injection) — no Input Monitoring grant.
- `ModifierTapDetector` — Pure fire-on-full-release state machine (no AppKit), the correctness core, heavily unit-tested. Arms when held modifiers exactly equal the target set; contaminates on any intervening key/mouse-down or extra modifier; fires only when all modifiers release cleanly. Firing on empty guarantees no modifier is held when the synthesized Cmd+C is posted.
- `ModifierOnlyHotkeyMonitor` — Thin AppKit glue: one global `NSEvent` monitor (`.flagsChanged` + key/mouse-down) feeds a `ModifierTapDetector` and invokes the callback on fire.

## SwiftLint Rules

CI runs `swiftlint --strict`. Key limits: line length 200 (error), identifier min 2 chars (exceptions: `id`, `x`, `y`), function body 100 lines, file 1000 lines. Only `Sources/` is linted (not Tests).

## Testing Notes

- Tests require keyboard layouts to be installed on the machine. Missing layouts cause `XCTSkip`, not failures.
- `LayoutConverter.convertText(_:from:to:)` is internal access specifically so tests can call it directly without duplicating conversion logic.
- The dev machine runs under Rosetta (x86_64) — the Makefile test target auto-detects host architecture via `uname -m`.
