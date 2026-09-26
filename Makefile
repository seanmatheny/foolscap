# Foolscap — macOS application build
#
#   make app         release build → Foolscap.app in the repo root
#   make app-debug   debug build
#   make run         build (debug) and launch
#   make test        run the test suite
#   make install     release build, installed to /Applications (the copy in daily use)
#   make icon        regenerate Icon/Foolscap.icns from Tools/make-icon.swift
#   make textures    regenerate the texture tiles from Tools/make-textures.swift
#   make xcode       open the package in Xcode
#   make clean
#
# NOTE: `swift` on this machine's PATH is python-swiftclient, so every
# invocation goes through `xcrun swift`. If Xcode is installed and its
# licence accepted, it is preferred; otherwise the Command Line Tools are used.

XCODE_DEV := /Applications/Xcode.app/Contents/Developer
XCODE_OK  := $(shell [ -d "$(XCODE_DEV)" ] && DEVELOPER_DIR=$(XCODE_DEV) xcrun swift --version >/dev/null 2>&1 && echo yes)
ifeq ($(XCODE_OK),yes)
  export DEVELOPER_DIR := $(XCODE_DEV)
endif
# The macOS 26 SDK implements SwiftUI's @State etc. as compiler macros whose
# plugin ships only inside Xcode. When building with the Command Line Tools we
# point the compiler at Xcode's copy.
XCODE_PLUGINS := $(XCODE_DEV)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
ifeq ($(XCODE_OK),yes)
  SWIFT_FLAGS :=
else ifneq ($(wildcard $(XCODE_PLUGINS)),)
  # An explicit -plugin-path replaces the default search, so add the CLT's
  # own plugin directories back (Swift Testing lives under plugins/testing).
  CLT_PLUGINS := $(shell xcrun --find swift | sed 's|/bin/swift$$||')/lib/swift/host/plugins
  SWIFT_FLAGS := -Xswiftc -plugin-path -Xswiftc $(XCODE_PLUGINS) \
                 -Xswiftc -plugin-path -Xswiftc $(CLT_PLUGINS) \
                 -Xswiftc -plugin-path -Xswiftc $(CLT_PLUGINS)/testing
endif
SWIFT := xcrun swift

# macOS ties an app's privacy grants (Files & Folders ▸ Kindle, Full Disk Access) to
# its code signature. An ad-hoc signature is a hash of the build, so every rebuild
# would reset them. A self-signed code-signing certificate named "Foolscap Dev" in
# the login keychain (Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…,
# type Code Signing) keeps the grants across builds; any other valid identity is used
# next, and the ad-hoc signature is the fallback.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | \
  awk -F'"' '/"/ { n[++c] = $$2; if ($$2 ~ /Foolscap Dev/) p = $$2 } END { if (p) print p; else if (c) print n[1] }')
ifeq ($(strip $(CODESIGN_IDENTITY)),)
  CODESIGN_IDENTITY := -
endif

BINARY_NAME   := Foolscap
BUNDLE_NAME   := $(BINARY_NAME).app
CONTENTS      := $(BUNDLE_NAME)/Contents
MACOS_DIR     := $(CONTENTS)/MacOS
RESOURCES_DIR := $(CONTENTS)/Resources
PLIST_SRC     := Sources/FoolscapApp/Info.plist
ICNS          := Icon/Foolscap.icns

.PHONY: app app-debug run test install icon textures xcode clean sign

app:
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	$(MAKE) _bundle BUILD_DIR=.build/release

app-debug:
	$(SWIFT) build $(SWIFT_FLAGS)
	$(MAKE) _bundle BUILD_DIR=.build/debug

_bundle:
	rm -rf "$(BUNDLE_NAME)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(BUILD_DIR)/$(BINARY_NAME)" "$(MACOS_DIR)/$(BINARY_NAME)"
	cp "$(BUILD_DIR)/FoolscapScribeOCR" "$(MACOS_DIR)/scribe-ocr"
	cp "$(PLIST_SRC)" "$(CONTENTS)/Info.plist"
	@for b in $(BUILD_DIR)/*.bundle; do [ -d "$$b" ] && cp -R "$$b" "$(RESOURCES_DIR)/"; done; true
	@[ -f "$(ICNS)" ] && cp "$(ICNS)" "$(RESOURCES_DIR)/Foolscap.icns" || echo "(no icon yet: run make icon)"
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" "$(BUNDLE_NAME)" >/dev/null 2>&1 || true
	@echo "✅  $(BUNDLE_NAME) is ready (signed: $(CODESIGN_IDENTITY))."

run: app-debug
	open "$(BUNDLE_NAME)"

test:
	$(SWIFT) test $(SWIFT_FLAGS)

install: app
	rm -rf /Applications/$(BUNDLE_NAME)
	cp -R $(BUNDLE_NAME) /Applications/
	@echo "✅  Installed to /Applications/$(BUNDLE_NAME)"

icon:
	$(SWIFT) Tools/make-icon.swift Icon/Foolscap.iconset
	iconutil -c icns Icon/Foolscap.iconset -o $(ICNS)
	@echo "✅  $(ICNS)"

textures:
	$(SWIFT) Tools/make-textures.swift Sources/FoolscapUI/Textures

xcode:
	open Package.swift

clean:
	$(SWIFT) package clean
	rm -rf "$(BUNDLE_NAME)"
