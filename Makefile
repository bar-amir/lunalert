APP := build/Build/Products/Release/Lunalert.app

.PHONY: project build run install icon clean

project:
	xcodegen generate

build: project
	xcodebuild -project Lunalert.xcodeproj -scheme Lunalert -configuration Release -derivedDataPath build build

run: build
	open $(APP)

install: build
	rm -rf /Applications/Lunalert.app && cp -R $(APP) /Applications/

icon:
	swift scripts/make-icon.swift Lunalert/Resources/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build Lunalert.xcodeproj
