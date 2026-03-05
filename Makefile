APP_NAME=MacPriceTicker
BIN=$(APP_NAME)
APP_DIR=$(APP_NAME).app
APP_VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.1.0)
DIST_DIR=dist
DMG=$(DIST_DIR)/$(APP_NAME)-$(APP_VERSION).dmg
SIGN_IDENTITY ?= -

SWIFTC=xcrun swiftc
MACOS_MIN=12.0
SWIFT_FLAGS=-O -target arm64-apple-macos$(MACOS_MIN) -framework Cocoa -framework UserNotifications

SRC=Sources/main.swift \
    Sources/PriceService.swift \
    Sources/Alerts.swift

.PHONY: build app run dmg release clean

build:
	$(SWIFTC) $(SWIFT_FLAGS) -o $(BIN) $(SRC)

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BIN) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/AppIcon.icns; fi
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "Signing app with ad-hoc identity"; \
		codesign --force --deep --sign - "$(APP_DIR)"; \
	else \
		echo "Signing app with Developer ID: $(SIGN_IDENTITY)"; \
		codesign --force --deep --options runtime --timestamp --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"; \
	fi
	codesign --verify --deep --strict --verbose=2 "$(APP_DIR)"

run: app
	open "./$(APP_DIR)"

dmg: app
	@command -v create-dmg >/dev/null || (echo "create-dmg not found. Install it with: brew install create-dmg"; exit 1)
	mkdir -p $(DIST_DIR)
	rm -f $(DMG)
	create-dmg \
		--volname "$(APP_NAME) Installer" \
		--volicon "Resources/AppIcon.icns" \
		--background "Resources/dmg-bg.png" \
		--window-pos 200 120 \
		--window-size 960 600 \
		--icon-size 132 \
		--icon "$(APP_DIR)" 240 300 \
		--hide-extension "$(APP_DIR)" \
		--app-drop-link 720 300 \
		"$(DMG)" \
		"$(APP_DIR)"
	@echo "Created $(DMG)"

release: dmg

clean:
	rm -rf $(BIN) $(APP_DIR) $(DIST_DIR)
