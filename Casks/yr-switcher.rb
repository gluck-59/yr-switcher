cask "yr-switcher" do
  version "2.1"
  sha256 "4cff37a95d3fdb20ce00e43ff0d17071869e886e2e741f360926a57f0d8a3927"

  url "https://github.com/gluck-59/yr-switcher/releases/download/v2.1/YRSwitcher.zip"
  name "ЯR Switcher"
  desc "Convert selected text between keyboard layouts with a hotkey"
  homepage "https://github.com/gluck-59/yr-switcher"

  app "YRSwitcher.app"

  zap trash: [
    "~/Library/Preferences/com.gluck59.bilingual-switcher.plist",
  ]
end
