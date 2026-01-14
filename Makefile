.PHONY: build bundle clean run install

APP_NAME = VPN Bypass
BUNDLE_ID = com.geiserx.vpn-bypass
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app

build:
	swift build -c release

bundle: build
	@echo "Creating app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(BUILD_DIR)/VPNBypass "$(APP_BUNDLE)/Contents/MacOS/"
	@cp Info.plist "$(APP_BUNDLE)/Contents/"
	@echo "APPL????" > "$(APP_BUNDLE)/Contents/PkgInfo"
	@echo "App bundle created: $(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"

run: bundle
	@open "$(APP_BUNDLE)"

install: bundle
	@echo "Installing to /Applications..."
	@rm -rf "/Applications/$(APP_BUNDLE)"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"
