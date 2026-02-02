APP_NAME=MacPriceTicker
BIN=$(APP_NAME)
APP_DIR=$(APP_NAME).app

SWIFTC=xcrun swiftc
SWIFT_FLAGS=-O -framework Cocoa -framework UserNotifications

SRC=Sources/main.swift \
    Sources/PriceService.swift \
    Sources/Alerts.swift

.PHONY: build app run clean

build:
	$(SWIFTC) $(SWIFT_FLAGS) -o $(BIN) $(SRC)

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BIN) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist

run: app
	open "./$(APP_DIR)"

clean:
	rm -rf $(BIN) $(APP_DIR)
