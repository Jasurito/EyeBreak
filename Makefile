APP     := EyeBreak
VERSION ?= 0.0.0-dev
ARCHS   ?= $(shell uname -m)
BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
ZIP     := $(BUILD)/$(APP)-$(VERSION).zip
SOURCES := $(wildcard Sources/*.swift)

.PHONY: all app run zip clean

all: app

app: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist $(BUILD)/AppIcon.icns
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	for arch in $(ARCHS); do \
		swiftc -O -swift-version 5 -target $$arch-apple-macos13.0 $(SOURCES) -o $(BUILD)/$(APP)-$$arch || exit 1; \
	done
	lipo -create $(foreach arch,$(ARCHS),$(BUILD)/$(APP)-$(arch)) -output $@/Contents/MacOS/$(APP)
	cp Resources/Info.plist $@/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION)" $@/Contents/Info.plist
	cp $(BUILD)/AppIcon.icns $@/Contents/Resources/AppIcon.icns
	codesign --force --sign - $@

$(BUILD)/AppIcon.icns: scripts/make_icon.swift
	mkdir -p $(BUILD)/AppIcon.iconset
	swiftc -O scripts/make_icon.swift -o $(BUILD)/make_icon
	$(BUILD)/make_icon $(BUILD)/icon_1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(BUILD)/icon_1024.png --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) $(BUILD)/icon_1024.png --out $(BUILD)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD)/AppIcon.iconset -o $@

# Run the dev build (never registers itself as a login item).
run: app
	-pkill -x $(APP)
	open $(BUNDLE)

# Release archive: universal (Apple Silicon + Intel) build stamped with VERSION.
zip:
	rm -rf $(BUNDLE)
	$(MAKE) app ARCHS="arm64 x86_64" VERSION=$(VERSION)
	cd $(BUILD) && ditto -c -k --norsrc --noextattr --noacl --keepParent $(APP).app $(APP)-$(VERSION).zip
	shasum -a 256 $(ZIP)

clean:
	rm -rf $(BUILD)
