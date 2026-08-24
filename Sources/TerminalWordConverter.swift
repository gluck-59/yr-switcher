import AppKit

/// Converts the last word before cursor in terminal/iTerm2 apps.
/// Uses AppleScript (`osascript`) to read the terminal screen content directly,
/// bypassing Cmd+A which causes a visual flash of the entire buffer.
enum TerminalWordConverter {

    static func convertLastWord(bundleID: String?) -> Bool {
        guard let screenText = readScreenViaAppleScript(bundleID: bundleID) else {
            return false
        }
        TextSwitcher.diag("terminal word: got \(screenText.count) chars via AppleScript")

        guard let lastLine = parseLastLine(from: screenText) else { return false }
        guard let (_, originalWord) = extractLastWord(from: lastLine) else { return false }

        TextSwitcher.diag("terminal word: copiedWord=`\(originalWord)`")

        waitUntilModifiersReleased(timeout: 0.3)

        simulateKeystroke(keyCode: 0x0D, flags: .maskControl) // Ctrl+W — delete word before cursor
        usleep(30_000)

        let converted = LayoutConverter.convertWithTarget(originalWord).converted
        guard !converted.isEmpty else { return false }

        TextSwitcher.injectUnicode(converted)
        return true
    }

    // MARK: - AppleScript screen reading

    private static func readScreenViaAppleScript(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let script: String
        switch bundleID {
        case "com.googlecode.iterm2":
            script = """
                tell application "iTerm"
                    tell current session of current tab of current window
                        get contents
                    end tell
                end tell
                """
        case "com.apple.Terminal":
            script = """
                tell application "Terminal"
                    get contents of front tab of front window
                end tell
                """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorMessage = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "?"
            let errorCode = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            TextSwitcher.diag("terminal word: AppleScript error \(errorCode): \(errorMessage)")

            // errAEEventNotPermitted = -1743
            if errorCode == -1743
                || errorMessage.localizedCaseInsensitiveContains("not authorized")
                || errorMessage.localizedCaseInsensitiveContains("not allowed") {
                DispatchQueue.main.async {
                    TextSwitcher.showAutomationNotification()
                }
            }
            return nil
        }
        return result?.stringValue
    }

    // MARK: - Parsing

    static func parseLastLine(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines.reversed() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return line
        }
        return nil
    }

    static func extractLastWord(from line: String) -> (Range<Int>, String)? {
        let trimmed = line.trimmingTrailingWhitespace()
        guard !trimmed.isEmpty else { return nil }
        let end = trimmed.count
        var start = trimmed.count
        let chars = Array(trimmed)
        while start > 0 && !chars[start - 1].isWhitespace {
            start -= 1
        }
        guard start < end else { return nil }
        return (start..<end, String(chars[start..<end]))
    }

    // MARK: - Helpers

    private static let eventSource: CGEventSource? = CGEventSource(stateID: .combinedSessionState)

    private static func simulateKeystroke(keyCode: UInt16, flags: CGEventFlags = []) {
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func waitUntilModifiersReleased(timeout: TimeInterval) {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CGEventSource.keyState(.hidSystemState, key: 0x37) ||
              CGEventSource.keyState(.hidSystemState, key: 0x38) ||
              CGEventSource.keyState(.hidSystemState, key: 0x3A) ||
              CGEventSource.keyState(.hidSystemState, key: 0x3F) ||
              CGEventSource.keyState(.hidSystemState, key: 0x3D) ||
              CGEventSource.keyState(.hidSystemState, key: 0x3E) {
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            usleep(3_000)
        }
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var chars = Array(self)
        while let last = chars.last, last.isWhitespace {
            chars.removeLast()
        }
        return String(chars)
    }
}
