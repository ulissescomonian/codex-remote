APP_NAME := CodexRemote
APP_BUNDLE := .build/$(APP_NAME).app

.PHONY: build test bundle dmg run clean

build:
	swift build

test:
	swift test

bundle:
	Scripts/package_app.sh

dmg:
	Scripts/package_dmg.sh

run: bundle
	open $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf dist
