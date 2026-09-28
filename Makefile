APP := build/Agent HUD Open.app
BIN := $(APP)/Contents/MacOS/Agent HUD Open
SNAPSHOT_DIR ?= build/snapshots
# CommandLineTools lacks the SwiftUI macro plugin (SwiftUIMacros) that newer SDKs need,
# so builds pin the 26.x SDK where @State is still a plain property wrapper.
# Drop this once a full Xcode is installed: make build SDKROOT=$$(xcrun --show-sdk-path)
SDKROOT ?= /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
DMG := build/Agent-HUD-Open.dmg

.PHONY: build test check run demo snapshot dmg clean

build:
	@SDKROOT=$(SDKROOT) scripts/build-app.sh debug

check:
	python3 scripts/check-source-boundaries.py

test:
	swift test

run: build
	open "$(APP)"

demo: build
	open "$(APP)" --args --demo --show-settings

snapshot: build
	@"$(BIN)" --snapshot "$(SNAPSHOT_DIR)"

dmg: build
	hdiutil create -volname "Agent HUD Open" -srcfolder "$(APP)" -ov -format UDZO "$(DMG)"
	@echo "$(DMG)"

clean:
	rm -rf .build build
