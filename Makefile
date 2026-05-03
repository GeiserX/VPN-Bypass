.PHONY: build build-helper bundle clean run install install-helper release dmg

APP_NAME = VPN Bypass
BUNDLE_ID = com.geiserx.vpn-bypass
HELPER_ID = com.geiserx.vpnbypass.helper
BUILD_DIR = .build/apple/Products/Release
APP_BUNDLE = $(APP_NAME).app
HELPER_BUILD_DIR = .build/helper
VERSION = $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0")

# Main app build (universal binary)
build:
	swift build -c release --arch arm64 --arch x86_64

# Helper tool build (universal binary)
build-helper:
	@echo "Building privileged helper..."
	@mkdir -p $(HELPER_BUILD_DIR)
	@swiftc -O \
		-target arm64-apple-macos13.0 \
		-o $(HELPER_BUILD_DIR)/$(HELPER_ID)-arm64 \
		Sources/VPNBypassCore/HelperProtocol.swift \
		Helper/HelperTool.swift \
		Helper/main.swift
	@swiftc -O \
		-target x86_64-apple-macos13.0 \
		-o $(HELPER_BUILD_DIR)/$(HELPER_ID)-x86_64 \
		Sources/VPNBypassCore/HelperProtocol.swift \
		Helper/HelperTool.swift \
		Helper/main.swift
	@lipo -create \
		$(HELPER_BUILD_DIR)/$(HELPER_ID)-arm64 \
		$(HELPER_BUILD_DIR)/$(HELPER_ID)-x86_64 \
		-output $(HELPER_BUILD_DIR)/$(HELPER_ID)
	@rm $(HELPER_BUILD_DIR)/$(HELPER_ID)-arm64 $(HELPER_BUILD_DIR)/$(HELPER_ID)-x86_64
	@echo "Helper built (universal): $(HELPER_BUILD_DIR)/$(HELPER_ID)"

# Create app bundle with helper embedded
bundle: build build-helper
	@echo "Creating app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	@cp $(BUILD_DIR)/VPNBypass "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Info.plist "$(APP_BUNDLE)/Contents/"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "Version stamped: $(VERSION)"
	@cp $(HELPER_BUILD_DIR)/$(HELPER_ID) "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Helper/Launchd.plist "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/$(HELPER_ID).plist"
	@echo "APPL????" > "$(APP_BUNDLE)/Contents/PkgInfo"
	@# Copy assets
	@cp assets/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/VPNBypass.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/author-avatar.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon@2x.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon-active.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon-active@2x.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon-error.png "$(APP_BUNDLE)/Contents/Resources/"
	@cp assets/menubar-icon-error@2x.png "$(APP_BUNDLE)/Contents/Resources/"
	@# Copy localizations
	@cp -R Resources/*.lproj "$(APP_BUNDLE)/Contents/Resources/"
	@echo "App bundle created: $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
	rm -rf $(HELPER_BUILD_DIR)

run: bundle
	@open "$(APP_BUNDLE)"

# Install app to /Applications
install: bundle
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# Install helper (requires admin)
# This copies the helper to /Library/PrivilegedHelperTools and loads the launchd plist
install-helper: build-helper
	@echo "Installing privileged helper (requires admin)..."
	@sudo mkdir -p /Library/PrivilegedHelperTools
	@sudo cp $(HELPER_BUILD_DIR)/$(HELPER_ID) /Library/PrivilegedHelperTools/
	@sudo chmod 544 /Library/PrivilegedHelperTools/$(HELPER_ID)
	@sudo chown root:wheel /Library/PrivilegedHelperTools/$(HELPER_ID)
	@sudo cp Helper/Launchd.plist /Library/LaunchDaemons/$(HELPER_ID).plist
	@sudo chmod 644 /Library/LaunchDaemons/$(HELPER_ID).plist
	@sudo chown root:wheel /Library/LaunchDaemons/$(HELPER_ID).plist
	@sudo launchctl bootout system/$(HELPER_ID) 2>/dev/null || true
	@sudo launchctl bootstrap system /Library/LaunchDaemons/$(HELPER_ID).plist
	@echo "Helper installed and loaded"

# Uninstall helper
uninstall-helper:
	@echo "Uninstalling privileged helper..."
	@sudo launchctl bootout system/$(HELPER_ID) 2>/dev/null || true
	@sudo rm -f /Library/PrivilegedHelperTools/$(HELPER_ID)
	@sudo rm -f /Library/LaunchDaemons/$(HELPER_ID).plist
	@echo "Helper uninstalled"

# Create signed release DMG for distribution
release: bundle
	@echo "Creating release v$(VERSION)..."
	@codesign --force --deep --sign - "$(APP_BUNDLE)"
	@mkdir -p dist
	@$(MAKE) dmg
	@echo ""
	@echo "✅ Release created!"
	@echo "   DMG: dist/VPN-Bypass-$(VERSION).dmg"
	@echo "   SHA256: $$(shasum -a 256 dist/VPN-Bypass-$(VERSION).dmg | awk '{print $$1}')"

# Create DMG
dmg:
	@echo "Creating DMG..."
	@mkdir -p dist
	@rm -f dist/VPN-Bypass-$(VERSION).dmg
	@DMG_DIR=$$(mktemp -d) && \
		cp -R "$(APP_BUNDLE)" "$$DMG_DIR/" && \
		ln -s /Applications "$$DMG_DIR/Applications" && \
		hdiutil create -volname "VPN Bypass" -srcfolder "$$DMG_DIR" -ov -format UDZO "dist/VPN-Bypass-$(VERSION).dmg" && \
		rm -rf "$$DMG_DIR"
	@echo "DMG created: dist/VPN-Bypass-$(VERSION).dmg"

# Update Homebrew cask SHA
update-cask:
	@SHA256=$$(shasum -a 256 dist/VPN-Bypass-$(VERSION).dmg | awk '{print $$1}') && \
		sed -i '' "s/sha256 \".*\"/sha256 \"$$SHA256\"/" Casks/vpn-bypass.rb && \
		sed -i '' "s/version \".*\"/version \"$(VERSION)\"/" Casks/vpn-bypass.rb
	@echo "Updated Casks/vpn-bypass.rb with SHA256 and version"

# Install via local cask (for testing)
brew-install: release
	@brew install --cask --no-quarantine ./Casks/vpn-bypass.rb

# Full release workflow
full-release: release update-cask
	@echo ""
	@echo "🎉 Full release complete!"
	@echo "Next steps:"
	@echo "  1. Upload dist/VPN-Bypass-$(VERSION).dmg to GitHub releases"
	@echo "  2. Create git tag: git tag v$(VERSION)"
	@echo "  3. Push to GitHub: git push origin v$(VERSION)"
