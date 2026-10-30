APP     := EyeBreak
BUILD   := build
BUNDLE  := $(BUILD)/$(APP).app
DEST    := /Applications
ARCH    := $(shell uname -m)
SOURCES := $(wildcard Sources/*.swift)

.PHONY: all app run install uninstall clean

all: app

app: $(BUNDLE)

$(BUNDLE): $(SOURCES) Resources/Info.plist $(BUILD)/AppIcon.icns
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	swiftc -O -swift-version 5 -target $(ARCH)-apple-macos13.0 $(SOURCES) -o $@/Contents/MacOS/$(APP)
	cp Resources/Info.plist $@/Contents/Info.plist
	cp $(BUILD)/AppIcon.icns $@/Contents/Resources/AppIcon.icns
	codesign --force --sign - $@
	touch $@

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

install: app
	-pkill -x $(APP)
	rm -rf $(DEST)/$(APP).app
	cp -R $(BUNDLE) $(DEST)/
	open $(DEST)/$(APP).app

uninstall:
	-pkill -x $(APP)
	rm -rf $(DEST)/$(APP).app

clean:
	rm -rf $(BUILD)
