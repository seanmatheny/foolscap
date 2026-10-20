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
# point the compiler at Xcode's copy, or, with Xcode uninstalled, at a copy of
# that folder kept in SAVED_PLUGINS (it must match the Command Line Tools'
# compiler: copy it afresh from Xcode after a tools update).
SAVED_PLUGINS ?= $(HOME)/bin/Xcode/plugins
XCODE_PLUGINS := $(XCODE_DEV)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
ifeq ($(wildcard $(XCODE_PLUGINS)),)
  XCODE_PLUGINS := $(SAVED_PLUGINS)
endif
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

# The MLX handwriting helper (Helpers/scribe-vlm) is a package of its own, built by
# xcodebuild: only Xcode's build system compiles MLX's Metal kernels into
# mlx-swift_Cmlx.bundle, and that needs Xcode plus its Metal Toolchain component
# (`xcodebuild -downloadComponent MetalToolchain`). Without them the app still
# builds and Vision stays the engine. Products land in .build/xcode.
VLM_DIR      := Helpers/scribe-vlm
VLM_DERIVED  := .build/xcode
VLM_CONFIG   ?= Release
VLM_PRODUCTS := $(VLM_DERIVED)/Build/Products/$(VLM_CONFIG)
VLM_XCODEBUILD := xcodebuild build -scheme scribe-vlm -configuration $(VLM_CONFIG) \
  -destination 'platform=macOS' -derivedDataPath "$(CURDIR)/$(VLM_DERIVED)" -skipMacroValidation -quiet

.PHONY: app app-debug run test install icon textures xcode clean sign scribe-vlm \
        xcodegen ios-icon ios-project ios-team ios ios-check ios-install ios-refresh ios-agent-install

app:
	$(SWIFT) build -c release $(SWIFT_FLAGS)
	$(MAKE) scribe-vlm
	$(MAKE) _bundle BUILD_DIR=.build/release

app-debug:
	$(SWIFT) build $(SWIFT_FLAGS)
	$(MAKE) scribe-vlm
	$(MAKE) _bundle BUILD_DIR=.build/debug

# Builds the MLX helper when Xcode and its Metal Toolchain are present, else says why.
# Metal Toolchain 32023 (Xcode 27) has been seen to reject MLX's steel attention
# kernel in the default language mode; the retry asks for Metal 4.0.
scribe-vlm:
	@if [ "$(XCODE_OK)" != "yes" ]; then \
	  echo "(scribe-vlm skipped: Xcode not installed or licence not accepted; Vision stays the handwriting engine)"; \
	elif ! DEVELOPER_DIR=$(XCODE_DEV) xcrun -f metal >/dev/null 2>&1; then \
	  echo "(scribe-vlm skipped: no Metal Toolchain; run: xcodebuild -downloadComponent MetalToolchain)"; \
	else \
	  cd $(VLM_DIR) && ( $(VLM_XCODEBUILD) || $(VLM_XCODEBUILD) MTL_LANGUAGE_REVISION=Metal40 ) && \
	  echo "✅  scribe-vlm built ($(VLM_PRODUCTS))"; \
	fi

_bundle:
	rm -rf "$(BUNDLE_NAME)"
	mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	cp "$(BUILD_DIR)/$(BINARY_NAME)" "$(MACOS_DIR)/$(BINARY_NAME)"
	cp "$(BUILD_DIR)/FoolscapScribeOCR" "$(MACOS_DIR)/scribe-ocr"
	cp "$(PLIST_SRC)" "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(git rev-list --count HEAD 2>/dev/null || echo 1)" "$(CONTENTS)/Info.plist"
	@for b in $(BUILD_DIR)/*.bundle; do [ -d "$$b" ] && cp -R "$$b" "$(RESOURCES_DIR)/"; done; true
	@if [ -x "$(VLM_PRODUCTS)/FoolscapScribeVLM" ]; then \
	  cp "$(VLM_PRODUCTS)/FoolscapScribeVLM" "$(MACOS_DIR)/scribe-vlm"; \
	  for b in $(VLM_PRODUCTS)/*.bundle; do [ -d "$$b" ] && cp -R "$$b" "$(RESOURCES_DIR)/"; done; true; \
	fi
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
	rm -rf "$(BUNDLE_NAME)" "$(VLM_DERIVED)" "$(IOS_DERIVED)"

# ---- iPhone ------------------------------------------------------------------
# The iOS app is an Xcode target generated by XcodeGen from Mobile/project.yml (the
# .xcodeproj is gitignored) that links the same packages. It is signed with a free
# Apple ID Personal Team, whose signature lasts seven days: Tools/ios-refresh.sh, run by
# a LaunchAgent (`make ios-agent-install`), rebuilds and reinstalls it over Wi-Fi every
# five days. The team id lives in Mobile/team.xcconfig (gitignored); the version and
# build are the Mac app's, so both show the same "Version 0.3.0 (123)".
IOS_DIR       := Mobile
IOS_PROJECT   := $(IOS_DIR)/Foolscap.xcodeproj
IOS_SCHEME    := FoolscapMobile
IOS_CONFIG    ?= Release
IOS_DERIVED   ?= .build/ios
IOS_APP       := $(abspath $(IOS_DERIVED))/Build/Products/$(IOS_CONFIG)-iphoneos/Foolscap.app
IOS_UDID      ?= 00008140-000D05C63643401C
IOS_TEAM      ?= $(shell sed -n 's/^DEVELOPMENT_TEAM *= *//p' $(IOS_DIR)/team.xcconfig 2>/dev/null)
IOS_ICON_SRC  := Icon/Foolscap.iconset/icon_512x512@2x.png
IOS_ICON      := $(IOS_DIR)/Assets.xcassets/AppIcon.appiconset/icon-1024.png
APP_VERSION   := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST_SRC))
GIT_COUNT     := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
IOS_XCODEBUILD := xcodebuild build -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) -configuration $(IOS_CONFIG) \
  -destination 'generic/platform=iOS' -derivedDataPath "$(abspath $(IOS_DERIVED))" \
  MARKETING_VERSION=$(APP_VERSION) CURRENT_PROJECT_VERSION=$(GIT_COUNT) -quiet

xcodegen:
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen

# The 1024 px icon the asset catalogue wants is the iconset's largest tile.
ios-icon: $(IOS_ICON)
$(IOS_ICON): $(IOS_ICON_SRC)
	cp "$<" "$@"
$(IOS_ICON_SRC):
	$(MAKE) icon

ios-project: xcodegen ios-icon
	cd $(IOS_DIR) && xcodegen generate --quiet

# Prints the Personal Team id Xcode knows, for Mobile/team.xcconfig.
ios-team:
	@defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null \
	  || echo "No team yet: sign your Apple ID into Xcode ▸ Settings ▸ Accounts first."

ios: ios-project
	@if [ -z "$(IOS_TEAM)" ]; then \
	  echo "No DEVELOPMENT_TEAM: copy $(IOS_DIR)/team.xcconfig.example to $(IOS_DIR)/team.xcconfig and fill in the id (make ios-team)"; exit 1; fi
	$(IOS_XCODEBUILD) -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=$(IOS_TEAM)
	@echo "✅  $(IOS_APP) ($(APP_VERSION) ($(GIT_COUNT)))"

# Compiles for the phone without signing: proves the code builds before an Apple ID is set up.
ios-check: ios-project
	$(IOS_XCODEBUILD) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
	@echo "✅  builds for iOS (unsigned)"

ios-install:
	xcrun devicectl device install app --device $(IOS_UDID) "$(IOS_APP)"
	@echo "✅  installed on $(IOS_UDID)"

ios-refresh: ios ios-install

ios-agent-install:
	mkdir -p ~/Library/LaunchAgents
	sed -e 's|@REPO@|$(CURDIR)|g' -e 's|@HOME@|$(HOME)|g' Tools/com.seanmatheny.foolscap.ios-refresh.plist \
	  > ~/Library/LaunchAgents/com.seanmatheny.foolscap.ios-refresh.plist
	launchctl bootout gui/$$(id -u)/com.seanmatheny.foolscap.ios-refresh 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/com.seanmatheny.foolscap.ios-refresh.plist
	@echo "✅  LaunchAgent loaded; try it with: launchctl kickstart -k gui/$$(id -u)/com.seanmatheny.foolscap.ios-refresh"
