import Cocoa
import Carbon

class TextSwitcher {

    /// Invoked on the main thread after every successfully typed conversion;
    /// failure paths never reach it, so their feedback is unchanged.
    var onConversionSucceeded: (() -> Void)?

    // MARK: - Tunables

    /// Maximum time to wait for the focused app to fill the pasteboard after
    /// Cmd+C. Polling stops as soon as `changeCount` ticks. Chromium apps copy
    /// in ~10–50 ms normally, up to ~150 ms under renderer load; 150 ms keeps
    /// the no-selection path snappy while retaining that margin.
    static let copyTimeout: TimeInterval = 0.15

    /// Interval between `changeCount` reads while waiting on Cmd+C. Reads are
    /// cheap, but each requeues `asyncAfter`, which has its own overhead.
    static let copyPollInterval: TimeInterval = 0.005

    /// `CGEventKeyboardSetUnicodeString` writes into a fixed UniChar buffer in
    /// the event payload. The documented & widely cited size is 20 UTF-16
    /// code units per event; longer strings are silently truncated. See
    /// `<CoreGraphics/CGEvent.h>` and isamert.net "Typing (unicode) characters
    /// programmatically on Linux and macOS".
    static let unicodeChunkLimit = 20

    /// Tiny pause between Unicode chunks. Some apps drop chunks posted
    /// back-to-back at HID rate; Espanso and similar tools default to a
    /// 1–4 ms delay. Conservative middle ground.
    private static let interChunkDelay: useconds_t = 2_000

    /// Maximum time to block waiting for hotkey modifiers to release before
    /// posting keystrokes. Real release latency is typically 50–200 ms;
    /// 500 ms covers users who hold the hotkey longer.
    private static let modifierReleaseTimeout: TimeInterval = 0.5
    /// Longer timeout for terminals: a terminal user often holds the hotkey
    /// while scanning the converted output, so a short timeout would abort
    /// legitimate conversions. We still refuse to post while modifiers are
    /// held — held Cmd hijacks every synthetic keystroke.
    private static let terminalModifierReleaseTimeout: TimeInterval = 1.5
    private static let modifierReleasePollInterval: TimeInterval = 0.005

    /// Small settle pause between backspace flood and Unicode injection in
    /// the terminal-fallback path. 150 ms lets the terminal finish draining
    /// and echoing the backspaces before the injection starts; 50 ms was
    /// occasionally too short and interleaved the injection with the echo.
    private static let terminalSettleDelay: TimeInterval = 0.15

    /// Bundle IDs that need the backspace-flood path because their visible
    /// text "selection" is a screen overlay rather than a real selection in
    /// the input buffer — typing does not replace what looks selected.
    /// Anything not in this set uses the selection-replace path, which
    /// works in every app that respects standard "typing replaces
    /// selection" semantics (all Cocoa, Chromium contenteditable, Swing).
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal",                  // Terminal.app
        "com.googlecode.iterm2",               // iTerm2
        "co.zeit.hyper",                       // Hyper
        "com.github.wez.wezterm",              // WezTerm
        "com.mitchellh.ghostty",               // Ghostty
        "net.kovidgoyal.kitty",                // kitty
        "io.alacritty",                        // Alacritty
        "dev.warp.Warp-Stable",                // Warp
        "dev.warp.Warp-Preview"
    ]

    /// How we deliver the converted text to the focused application.
    enum InjectionStrategy: String {
        /// Default. After Cmd+C the selection is still active in the host
        /// app; we just type the converted text via Unicode injection and
        /// the standard "typing replaces selection" behavior of every
        /// modern text widget (Cocoa, Chromium contenteditable, Java Swing)
        /// does the deletion for us. One injected keystroke per Unicode
        /// chunk — no backspace flood, no race with renderer-queue drain.
        case selectionReplace

        /// Terminal fallback. Shell input buffers don't track visual
        /// selection, so typing appends rather than replaces. We deselect
        /// (Right Arrow) and erase character-by-character (N × Backspace)
        /// before injecting the converted text.
        case backspaceFlood
    }

    /// UserDefaults key for forcing a strategy. Hidden — not exposed in
    /// preferences UI; used for triage via `defaults write`.
    private static let backendOverrideKey = "BILINGUAL_BACKEND"

    /// Decide how to deliver converted text to the focused app. A user
    /// override via UserDefaults wins; otherwise terminal bundle IDs route
    /// to the flood path and everything else to selection-replace.
    static func pickStrategy(bundleID: String?) -> InjectionStrategy {
        if let raw = UserDefaults.standard.string(forKey: backendOverrideKey),
           let forced = InjectionStrategy(rawValue: raw) {
            return forced
        }
        if let id = bundleID, terminalBundles.contains(id) {
            return .backspaceFlood
        }
        return .selectionReplace
    }

    /// Modifiers that hijack our synthesized keystrokes when held:
    /// - Cmd+Backspace = "delete to start of line" in most text fields
    /// - Cmd+letter = menu/keyboard shortcut, eats Unicode injection
    /// - Opt+Backspace = "delete word"
    /// Shift is omitted: it has no shortcut role for our keys and doesn't
    /// affect `keyboardSetUnicodeString` (the unicode string is what types,
    /// not the virtual key).
    private static let hijackingModifiers: CGEventFlags =
        [.maskCommand, .maskAlternate, .maskControl]

    /// One CGEventSource reused for every posted event. Constructing this
    /// object per event was a measurable cost in the old code — for a 50-char
    /// selection we'd build it ~100 times per hotkey press.
    private static let eventSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState)

    // MARK: - Main flow

    func switchSelectedText() {
        guard AXIsProcessTrusted() else {
            Self.showAccessibilityNotification()
            return
        }

        Self.diag("--- switchSelectedText start ---")

        // Capture the focused-app bundle ID up front; we'll need it later
        // to pick the settle delay. Doing it before Cmd+C makes it robust
        // against any focus transitions during polling.
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Self.diag("front app: \(frontBundleID ?? "<unknown>")")

        let pasteboard = NSPasteboard.general
        let savedItems = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        let baselineChangeCount = pasteboard.changeCount

        Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        Self.diag("posted Cmd+C, baselineChangeCount=\(baselineChangeCount)")

        // Capture self strongly: if a `[weak self]` early-returned mid-poll
        // the cleared clipboard would stay cleared. TextSwitcher lives for
        // the app's lifetime, so the extra retention is ~500 ms — no cycle,
        // since this closure is not stored on self.
        Self.pollForClipboardChange(
            initialChangeCount: baselineChangeCount,
            timeout: Self.copyTimeout,
            pollInterval: Self.copyPollInterval,
            pasteboard: pasteboard
        ) { didChange in
            let copiedText = pasteboard.string(forType: .string)
            guard Self.firstCopyProducedText(didChange: didChange, copiedText: copiedText) else {
                // No convertible text (nothing copied, or non-string data, e.g. Telegram) — retry.
                self.retryWithLastWordSelection(
                    savedItems: savedItems,
                    pasteboard: pasteboard,
                    frontBundleID: frontBundleID
                )
                return
            }
            self.completeConversion(
                copied: true,
                copiedText: copiedText,
                savedItems: savedItems,
                pasteboard: pasteboard,
                frontBundleID: frontBundleID
            )
        }
    }

    /// No text was selected, so Cmd+C copied nothing. In regular apps,
    /// select the word before the cursor and retry the copy. In terminals,
    /// keyboard-based selection is not possible — beep and bail out.
    private func retryWithLastWordSelection(
        savedItems: [[NSPasteboard.PasteboardType: Data]],
        pasteboard: NSPasteboard,
        frontBundleID: String?
    ) {
        // The first Cmd+C may have copied just after the poll window timed
        // out. If the clipboard has text, use it directly instead of
        // disturbing the selection.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            Self.diag("first copy landed late — converting directly")
            self.completeConversion(
                copied: true,
                copiedText: text,
                savedItems: savedItems,
                pasteboard: pasteboard,
                frontBundleID: frontBundleID
            )
            return
        }

        // Option+Shift+Left Arrow selects the word before the cursor in
        // every Cocoa text view and most editors — but not in terminals,
        // where keyboard-based selection doesn't exist. In terminals the
        // user must select text with the mouse; skip the fallback and
        // let completeConversion beep + restore the clipboard.
        let strategy = Self.pickStrategy(bundleID: frontBundleID)
        if strategy == .backspaceFlood {
            Self.diag("terminal — reading screen via AppleScript")
            let ok = TerminalWordConverter.convertLastWord(bundleID: frontBundleID)
            Self.restoreClipboard(savedItems, to: pasteboard)
            if !ok { NSSound.beep() }
            return
        }

        // Prefer a precise Accessibility selection: the whitespace-delimited
        // word before the caret. ⌥⇧← (fallback below) splits on punctuation,
        // which mis-detects words like `dcz;jgf`.
        if let axWord = WholeWordSelection.selectWordBeforeCaret() {
            Self.diag("AX selected word: \(axWord.prefix(80))")
            Thread.sleep(forTimeInterval: 0.05)
            self.copySelectionAndCompleteConversion(
                label: "AX-select",
                savedItems: savedItems,
                pasteboard: pasteboard,
                frontBundleID: frontBundleID
            )
            return
        }

        Self.diag("no selection — greedy word expansion")

        // ⌥⇧← selects the word before the cursor but splits on punctuation
        // (e.g. `hf,jnftn` → `jnftn`). Extend the selection across punctuation
        // until the added prefix contains whitespace or the selection stops
        // growing, so the whole whitespace-delimited word is selected.
        self.greedyWordExpansionAndConvert(
            savedItems: savedItems,
            pasteboard: pasteboard,
            frontBundleID: frontBundleID
        )
    }

    /// Post Cmd+C, wait for the focused app to fill the pasteboard, then run
    /// the conversion on whatever the active selection produced.
    private func copySelectionAndCompleteConversion(
        label: String,
        savedItems: [[NSPasteboard.PasteboardType: Data]],
        pasteboard: NSPasteboard,
        frontBundleID: String?
    ) {
        let baselineChangeCount = pasteboard.changeCount
        Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        Self.diag("posted \(label) + Cmd+C, baselineChangeCount=\(baselineChangeCount)")

        Self.pollForClipboardChange(
            initialChangeCount: baselineChangeCount,
            timeout: Self.copyTimeout,
            pollInterval: Self.copyPollInterval,
            pasteboard: pasteboard
        ) { didChange in
            self.completeConversion(
                copied: didChange,
                copiedText: pasteboard.string(forType: .string),
                savedItems: savedItems,
                pasteboard: pasteboard,
                frontBundleID: frontBundleID
            )
        }
    }

    func completeConversion(
        copied: Bool,
        copiedText: String?,
        savedItems: [[NSPasteboard.PasteboardType: Data]],
        pasteboard: NSPasteboard,
        frontBundleID: String?
    ) {
        Self.diag("poll completion copied=\(copied) textLen=\(copiedText?.count ?? -1)")

        // A slow copy can land just after the poll window closed, leaving the
        // poll reporting no change while the clipboard actually holds text.
        // Fall back to a final read before concluding there is nothing.
        let text: String?
        if copied, let copiedText = copiedText, !copiedText.isEmpty {
            text = copiedText
        } else {
            text = pasteboard.string(forType: .string)
        }

        guard let text, !text.isEmpty else {
            Self.diag("bail — no text from clipboard")
            // Cmd+C put nothing on the clipboard — almost always because no
            // text was selected, or the focused app grabbed the mouse so the
            // terminal never made a selection (full-screen TUIs like Claude
            // Code, vim, htop; in kitty hold Shift while dragging, in iTerm2
            // hold Option). Without feedback this is an invisible no-op that
            // reads as "the hotkey is broken." A beep makes "fired but found
            // nothing to convert" audible so the cause is obvious.
            NSSound.beep()
            Self.restoreClipboard(savedItems, to: pasteboard)
            return
        }

        guard KeyboardLayoutMap.installedLayouts().count >= 2 else {
            showSingleLayoutNotification()
            Self.restoreClipboard(savedItems, to: pasteboard)
            return
        }

        let result = LayoutConverter.convertWithTarget(text)
        let converted = result.converted
        let targetLayout = result.target
        let chunkCount = Self.chunkUTF16(converted, maxCodeUnits: Self.unicodeChunkLimit).count
        Self.diag("text=\(text.prefix(120))")
        Self.diag("converted=\(converted.prefix(120)) chunks=\(chunkCount)")

        // Unicode injection never touches the pasteboard, so we can restore
        // the user's clipboard right now — before posting any keystrokes.
        // No race between paste and restore is possible.
        Self.restoreClipboard(savedItems, to: pasteboard)

        // Polling Cmd+C completes in ~30–80 ms — often before the user has
        // physically released the hotkey. With Cmd still held, our
        // synthesized events get hijacked: Cmd+letter becomes a menu
        // shortcut, Cmd+Backspace deletes the whole field. Wait it out.
        //
        // A modifier-only hotkey (e.g. ⌃⌥) fires on full release — the user
        // already let go, so no wait is needed. The wait reads .hidSystemState,
        // which our synthesized Cmd+C leaves reporting Cmd as held (no separate
        // Cmd keyUp is posted), so it would spuriously time out and abort.
        let strategy = Self.pickStrategy(bundleID: frontBundleID)
        Self.diag("strategy: \(strategy.rawValue) (bundle=\(frontBundleID ?? "?"))")

        if UserDefaults.standard.hotkeyKeyCode != HotkeyManager.modifierOnlyKeyCode {
            let flagsBefore = CGEventSource.flagsState(.hidSystemState)
            Self.diag("flags before modifier wait: 0x\(String(flagsBefore.rawValue, radix: 16))")
            let timeout = strategy == .backspaceFlood
                ? Self.terminalModifierReleaseTimeout
                : Self.modifierReleaseTimeout
            let cleared = Self.waitForModifierRelease(timeout: timeout)
            let flagsAfter = CGEventSource.flagsState(.hidSystemState)
            Self.diag("flags after wait: 0x\(String(flagsAfter.rawValue, radix: 16)) cleared=\(cleared)")

            // If the user is still holding the hotkey, every keystroke we post
            // would be hijacked (Cmd+Backspace deletes the line, Cmd+letter is
            // a menu shortcut). Posting anyway corrupts the text. Bail out
            // instead: the clipboard is already restored and no events have
            // been posted, so aborting is safe — the user just hears a beep
            // and retries.
            guard cleared else {
                Self.diag("modifier wait timed out — aborting to avoid hijacked keystrokes")
                NSSound.beep()
                return
            }
        }

        switch strategy {
        case .selectionReplace:
            // The Cmd+C left the user's selection intact. Typing into a
            // live selection replaces it in every text widget that
            // respects standard editing semantics — Cocoa NSText*, Chromium
            // contenteditable (Slack/Discord/VS Code), JTextComponent
            // (JetBrains IDEs). No deletion events needed.
            Self.injectUnicode(converted)

        case .backspaceFlood:
            // Terminals don't see the visual selection at the shell-input
            // level, so typing appends rather than replaces. Move the cursor
            // to the end of the line first: a mouse click that starts a
            // selection can leave the TUI's internal cursor at the start of
            // the text, so Backspaces would delete nothing. End is
            // layout-independent and idempotent (never overshoots past the
            // end); a couple of Right Arrows cover terminals that intercept
            // End for scrolling. Then erase character-by-character.
            Self.diag("backspaceFlood: textLen=\(text.count) settle=\(Self.terminalSettleDelay)")
            Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_End), flags: [])
            Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_RightArrow), flags: [])
            Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_RightArrow), flags: [])
            // One extra backspace: terminals strip a trailing space when copying.
            for _ in 0..<(text.count + 1) {
                Self.simulateKeyStroke(keyCode: CGKeyCode(kVK_Delete), flags: [])
            }
            Thread.sleep(forTimeInterval: Self.terminalSettleDelay)
            Self.injectUnicode(converted)
        }
        Self.diag("injection done")
        finishConversion(targetLayout: targetLayout)
    }

    /// Post-injection success tail: report success + optional layout switch.
    private func finishConversion(targetLayout: LayoutInfo?) {
        onConversionSucceeded?()
        if UserDefaults.standard.switchLayoutAfterConversion, let targetLayout {
            InputSourceSwitcher.switchTo(target: targetLayout)
        }
    }

    // MARK: - Modifier-release wait

    /// Block until none of `mask` is currently held on the hardware keyboard,
    /// or `timeout` elapses. Synchronous so we can sequence cleanly with the
    /// subsequent keystroke posts. Reads via `.hidSystemState` because that
    /// reflects only physical keys, regardless of any synthesized events we
    /// or others have injected.
    @discardableResult
    static func waitForModifierRelease(
        mask: CGEventFlags = hijackingModifiers,
        timeout: TimeInterval = modifierReleaseTimeout,
        pollInterval: TimeInterval = modifierReleasePollInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.hidSystemState).isDisjoint(with: mask) {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    // MARK: - Unicode keyboard injection

    /// Post the converted text as a sequence of synthetic Unicode keyboard
    /// events. This is the modern macOS substitute for clipboard-based paste:
    /// no Cmd+V, no clipboard state, no race.
    static func injectUnicode(_ string: String) {
        let chunks = chunkUTF16(string, maxCodeUnits: unicodeChunkLimit)
        for (offset, chunk) in chunks.enumerated() {
            chunk.withUnsafeBufferPointer { buffer in
                postUnicodeEvent(buffer: buffer, keyDown: true)
                postUnicodeEvent(buffer: buffer, keyDown: false)
            }
            if offset < chunks.count - 1 {
                usleep(interChunkDelay)
            }
        }
    }

    private static func postUnicodeEvent(buffer: UnsafeBufferPointer<UniChar>, keyDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: keyDown)
        else { return }
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        event.post(tap: .cghidEventTap)
    }

    /// Split `string` into UTF-16 segments of at most `maxCodeUnits` units,
    /// packed scalar by scalar so a non-BMP Unicode scalar (e.g. emoji) — which
    /// occupies a surrogate pair of two UTF-16 code units — is never split
    /// across chunks. Splitting a surrogate pair would send malformed UTF-16
    /// to `CGEventKeyboardSetUnicodeString`, producing replacement characters
    /// or dropped input. Empty input yields `[]`. `maxCodeUnits` must be at
    /// least 2 to accommodate any non-BMP scalar.
    static func chunkUTF16(_ string: String, maxCodeUnits: Int) -> [[UniChar]] {
        precondition(maxCodeUnits > 0, "maxCodeUnits must be positive")
        guard !string.isEmpty else { return [] }

        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxCodeUnits)

        for scalar in string.unicodeScalars {
            let value = scalar.value
            let needed = value <= 0xFFFF ? 1 : 2
            precondition(needed <= maxCodeUnits,
                         "maxCodeUnits too small to fit a single non-BMP scalar")

            if current.count + needed > maxCodeUnits {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }

            if value <= 0xFFFF {
                current.append(UniChar(value))
            } else {
                // Encode supplementary scalar as UTF-16 surrogate pair.
                // Reference: Unicode Standard §3.9, RFC 2781 §2.1.
                let shifted = value - 0x10000
                current.append(UniChar(0xD800 + (shifted >> 10)))
                current.append(UniChar(0xDC00 + (shifted & 0x3FF)))
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    // MARK: - Keyboard simulation

    static func simulateKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
