APP_NAME     = YRSwitcher
BUNDLE_ID    = com.gluck59.bilingual-switcher
VERSION      ?= 2.1
BUILD_DIR    = build
APP_BUNDLE   = $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME     = $(APP_NAME).dmg
ZIP_NAME     = $(APP_NAME).zip
SOURCES      = $(wildcard Sources/*.swift)
SPARKLE_DIR  = Vendor/Sparkle.framework
COMMON_FLAGS = -module-name YRSwitcher \
               -O \
               -framework Cocoa \
               -framework Carbon \
               -framework ServiceManagement \
               -F Vendor \
               -framework Sparkle \
               -Xlinker -rpath -Xlinker @executable_path/../Frameworks
INSTALL_DIR  = /Applications

# Code-signing identity. A stable self-signed "Code Signing" certificate keeps
# the macOS Accessibility (TCC) grant valid across rebuilds — ad-hoc signing
# changes the cdhash every build and silently revokes the grant. The build
# FAILS when the certificate is absent: silently falling back to ad-hoc would
# silently break the grant for users who already granted Accessibility.
SIGN_IDENTITY ?= BilingualSwitcher Dev
# Leaf SHA-1 of $(SIGN_IDENTITY). The Accessibility TCC grant is keyed to the
# designated requirement "identifier <bundle-id> and certificate leaf = H<hash>";
# any rebuild or release signed with a different cert silently revokes the grant.
CERT_LEAF_HASH = b902cbab321847bd2493104dd0f1b102038d2d1f

TESTS          = $(filter-out Tests/ASanRunner.swift,$(wildcard Tests/*.swift))
SOURCES_NO_MAIN = $(filter-out Sources/main.swift,$(SOURCES))
XCTEST_PLAT    = $(shell xcode-select -p)/Platforms/MacOSX.platform/Developer
XCTEST_FW      = $(XCTEST_PLAT)/Library/Frameworks
XCTEST_LIB     = $(XCTEST_PLAT)/usr/lib
TEST_BUNDLE    = $(BUILD_DIR)/Tests.xctest
HOST_TARGET    = $(shell uname -m)-apple-macos14

SPARKLE_VERSION = 2.9.1
SPARKLE_URL     = https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
SPARKLE_SHA256  = c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7

.PHONY: all clean install uninstall run dmg zip icons lint setup test test-asan

all: $(APP_BUNDLE)

# --- Build (universal binary) ---

$(APP_BUNDLE): $(SOURCES) Info.plist Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/PreferencesWindow.xib $(SPARKLE_DIR)
	@rm -f /tmp/bilingual-switcher.log
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	@mkdir -p $(BUILD_DIR)/arch
	swiftc $(COMMON_FLAGS) -target arm64-apple-macos10.15 $(SOURCES) -o $(BUILD_DIR)/arch/$(APP_NAME)-arm64
	swiftc $(COMMON_FLAGS) -target x86_64-apple-macos10.15 $(SOURCES) -o $(BUILD_DIR)/arch/$(APP_NAME)-x86_64
	lipo -create $(BUILD_DIR)/arch/$(APP_NAME)-arm64 $(BUILD_DIR)/arch/$(APP_NAME)-x86_64 \
		-output $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@rm -rf $(BUILD_DIR)/arch
	@cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@plutil -replace CFBundleVersion -string "$(VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@cp Resources/MenuBarIcon.png $(APP_BUNDLE)/Contents/Resources/MenuBarIcon.png
	@cp Resources/MenuBarIcon@2x.png $(APP_BUNDLE)/Contents/Resources/MenuBarIcon@2x.png 2>/dev/null || true
	@ibtool --compile $(APP_BUNDLE)/Contents/Resources/PreferencesWindow.nib Resources/PreferencesWindow.xib
	@rsync -a --delete $(SPARKLE_DIR) $(APP_BUNDLE)/Contents/Frameworks/
	@xattr -cr $(APP_BUNDLE) 2>/dev/null || true; find "$(APP_BUNDLE)" -name '._*' -delete 2>/dev/null || true
	@if security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE) || { echo "ERROR: codesign failed with $(SIGN_IDENTITY)"; exit 1; }; \
		echo "✓ Signed with $(SIGN_IDENTITY)"; \
	else \
		echo "ERROR: $(SIGN_IDENTITY) not found — refusing ad-hoc (would silently revoke the Accessibility grant). Import the cert first."; \
		exit 1; \
	fi
	@echo "✓ Built $(APP_BUNDLE) (universal)"

# --- Icons ---

icons: Resources/AppIcon.icns

Resources/AppIcon.icns: scripts/generate_icon.swift
	swift scripts/generate_icon.swift

# --- Install ---

install: $(APP_BUNDLE)
	@rm -f /tmp/bilingual-switcher.log
	@echo "Installing to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/"
	@DR="$$(codesign -dr - "$(INSTALL_DIR)/$(APP_NAME).app" 2>&1)"; \
	if echo "$$DR" | grep -q 'certificate leaf = H"$(CERT_LEAF_HASH)"' && echo "$$DR" | grep -q '"$(BUNDLE_ID)"'; then \
		echo "✓ Grant identity verified: $(BUNDLE_ID) + cert $(CERT_LEAF_HASH)"; \
	else \
		echo "ERROR: installed app DR does not match the Accessibility grant identity (would prompt on launch). DR: $$DR"; \
		exit 1; \
	fi
	@echo "✓ Installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "  Run: open '$(INSTALL_DIR)/$(APP_NAME).app'"

uninstall:
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "✓ Removed from $(INSTALL_DIR)"

# --- Run ---

run: $(APP_BUNDLE)
	@open $(APP_BUNDLE)

# --- DMG ---

dmg: $(APP_BUNDLE)
	@rm -f $(BUILD_DIR)/$(DMG_NAME)
	@mkdir -p $(BUILD_DIR)/dmg-staging
	@cp -R $(APP_BUNDLE) $(BUILD_DIR)/dmg-staging/
	@ln -sf /Applications $(BUILD_DIR)/dmg-staging/Applications
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(BUILD_DIR)/dmg-staging \
		-ov -format UDZO \
		$(BUILD_DIR)/$(DMG_NAME)
	@rm -rf $(BUILD_DIR)/dmg-staging
	@echo "✓ Created $(BUILD_DIR)/$(DMG_NAME)"

# --- ZIP (for Sparkle updates) ---

zip: $(APP_BUNDLE)
	@rm -f $(BUILD_DIR)/$(ZIP_NAME)
	cd $(BUILD_DIR) && ditto -c -k --keepParent $(APP_NAME).app $(ZIP_NAME)
	@echo "✓ Created $(BUILD_DIR)/$(ZIP_NAME)"

# --- Test ---

test: $(SPARKLE_DIR)
	@mkdir -p $(TEST_BUNDLE)/Contents/MacOS
	swiftc \
		$(TEST_FLAGS) \
		-F $(XCTEST_FW) -I $(XCTEST_LIB) -L $(XCTEST_LIB) \
		-framework XCTest -lXCTestSwiftSupport \
		-framework Cocoa -framework Carbon -framework ServiceManagement \
		-F Vendor -framework Sparkle \
		-Xlinker -rpath -Xlinker $(XCTEST_FW) \
		-Xlinker -rpath -Xlinker $(XCTEST_LIB) \
		-Xlinker -rpath -Xlinker $(CURDIR)/Vendor \
		-Xlinker -bundle \
		-target $(HOST_TARGET) \
		$(SOURCES_NO_MAIN) $(TESTS) \
		-o $(TEST_BUNDLE)/Contents/MacOS/Tests
	xcrun xctest $(TEST_BUNDLE)

test-asan: $(SPARKLE_DIR)
	@mkdir -p $(BUILD_DIR)
	swiftc \
		-sanitize=address \
		-F $(XCTEST_FW) -I $(XCTEST_LIB) -L $(XCTEST_LIB) \
		-framework XCTest -lXCTestSwiftSupport \
		-framework Cocoa -framework Carbon -framework ServiceManagement \
		-F Vendor -framework Sparkle \
		-Xlinker -rpath -Xlinker $(XCTEST_FW) \
		-Xlinker -rpath -Xlinker $(XCTEST_LIB) \
		-Xlinker -rpath -Xlinker $(CURDIR)/Vendor \
		-target $(HOST_TARGET) \
		$(SOURCES_NO_MAIN) $(TESTS) Tests/ASanRunner.swift \
		-o $(BUILD_DIR)/TestRunner-asan
	$(BUILD_DIR)/TestRunner-asan

# --- Lint ---

lint:
	swiftlint lint --strict

# --- Setup (download dependencies) ---

setup: $(SPARKLE_DIR)

$(SPARKLE_DIR):
	@echo "Downloading Sparkle $(SPARKLE_VERSION)..."
	@mkdir -p Vendor
	@curl -sfL "$(SPARKLE_URL)" -o Vendor/Sparkle.tar.xz
	@echo "$(SPARKLE_SHA256)  Vendor/Sparkle.tar.xz" | shasum -a 256 -c - || \
		(rm -f Vendor/Sparkle.tar.xz && echo "ERROR: Sparkle checksum mismatch" && exit 1)
	@tar xf Vendor/Sparkle.tar.xz -C Vendor
	@rm Vendor/Sparkle.tar.xz
	@echo "✓ Sparkle framework ready"

# --- Clean ---

clean:
	rm -rf $(BUILD_DIR)
