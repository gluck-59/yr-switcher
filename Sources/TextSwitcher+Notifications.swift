import AppKit

extension TextSwitcher {

    func showSingleLayoutNotification() {
        let alert = NSAlert()
        alert.messageText = "Требуются две раскладки клавиатуры"
        alert.informativeText = """
            Добавьте вторую раскладку клавиатуры в Системных настройках → Клавиатура → \
            Источники ввода, чтобы включить конвертацию текста.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Title of the shared accessibility-permission alert. Exposed so a unit
    /// test can assert the wording without running a modal.
    static let accessibilityAlertTitle = "Требуется разрешение на доступность"

    /// Body of the shared accessibility-permission alert (System Settings →
    /// Privacy & Security → Accessibility).
    static let accessibilityAlertBody = """
        Предоставьте доступ в Системных настройках \u{2192} Конфиденциальность и безопасность \u{2192} Доступность, \
        затем перезапустите приложение.
        """

    /// Presents the shared accessibility-permission alert. Static so both the
    /// conversion flow here and `HotkeyManager`'s modifier-only registration
    /// surface the *same* message when the Accessibility grant is missing —
    /// the modifier-only global monitor never reaches this flow's own
    /// `AXIsProcessTrusted()` guard, so it must invoke this directly.
    ///
    /// Opens System Settings at the Accessibility pane automatically so the
    /// user can grant the permission without hunting for it.
    static func showAccessibilityNotification() {
        openAccessibilitySettings()
        let alert = NSAlert()
        alert.messageText = accessibilityAlertTitle
        alert.informativeText = accessibilityAlertBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Opens System Settings at the Accessibility permission pane. The URL
    /// scheme differs between macOS 13+ (Ventura, "extension" schema) and
    /// macOS 12 and earlier (Monterey, legacy "preference" schema).
    static func openAccessibilitySettings() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let urlString = major >= 13
            ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    static func showAutomationNotification() {
        openAutomationSettings()
        let alert = NSAlert()
        alert.messageText = "Требуется разрешение на автоматизацию"
        alert.informativeText = """
            Предоставьте доступ в Системных настройках \u{2192} Конфиденциальность и безопасность \u{2192} Автоматизация, \
            затем повторите попытку.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func openAutomationSettings() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let urlString = major >= 13
            ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
