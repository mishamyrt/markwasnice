# Environment paths
XCODE_DIR := /Applications/Xcode-beta.app
XCODE_CONTENTS_DIR := $(XCODE_DIR)/Contents

# Repository paths
ASSETS_DIR := Assets
ASSETS_ICON_PATH := $(ASSETS_DIR)/AppIcon.icon
ASSETS_MANIFEST_PATH := $(ASSETS_DIR)/Info.plist
CLI_SCRIPT_PATH := scripts/markwasnice

# Distribution paths
RELEASE_DIR := .build/release
RESOURCES_DIR := $(RELEASE_DIR)/Resources
# SwiftPM emits the target's declared resources here, beside the executable
# rather than inside RESOURCES_DIR, so it needs copying in explicitly.
SPM_BUNDLE := $(RELEASE_DIR)/Markwasnice_Markwasnice.bundle
APP_ICON_PNG_PATH := $(RESOURCES_DIR)/AppIcon.png
ICONSET_DIR := $(RESOURCES_DIR)/AppIcon.iconset
APP_NAME := Markwasnice
APP_DIST := $(RELEASE_DIR)/$(APP_NAME).app
APP_CONTENTS_DIR := $(APP_DIST)/Contents
FRAMEWORKS_DIR := $(APP_CONTENTS_DIR)/Frameworks

# Release
VERSION := 1.0.0
VERSION_BUNDLE := 1

# Installation paths
APP_INSTALL_DIR := /Applications/$(APP_NAME).app
CLI_NAME := markwasnice

# Build tools
ICTOOL := $(XCODE_CONTENTS_DIR)/Applications/Icon\ Composer.app/Contents/Executables/ictool
ACTOOL := $(XCODE_CONTENTS_DIR)/Developer/usr/bin/actool

# Source lists
ICON_FILES := \
	$(ASSETS_ICON_PATH)/icon.json \
	$(shell find $(ASSETS_ICON_PATH)/Assets -type f | sed 's/ /\\ /g')
SWIFT_FILES = $(shell find Sources/ -type f -name '*.swift')
LPROJ_FILES = $(shell find Assets/ -type f \( -name '*.strings' -o -name '*.stringsdict' \))

SIGNATURE_NAME := "Markwasnice Signing"

all: $(APP_DIST)

.PHONY: run
run: ## build and run the app
	@swift run $(APP_NAME)

.PHONY: clean
clean: ## clean the build directory
	@rm -rf .build

.PHONY: lint
lint: ## lint and fix the code
	@swiftlint lint --quiet

.PHONY: fmt
fmt: ## format the code
	@swiftformat Sources/

install: $(APP_DIST) ## build and install the app
	@rm -rf "$(APP_INSTALL_DIR)"
	@ditto "$(APP_DIST)" "$(APP_INSTALL_DIR)"
	@echo "$(APP_NAME).app is installed successfully"

$(APP_DIST): \
	$(RESOURCES_DIR)/AppIcon.icns \
	$(RESOURCES_DIR)/Assets.car \
	$(LPROJ_FILES) \
	$(CLI_SCRIPT_PATH) \
	$(RELEASE_DIR)/$(APP_NAME)

	@echo "Packaging $(APP_NAME).app"

	@rm -rf "$(RELEASE_DIR)/$(APP_NAME).app"
	@mkdir -p "$(APP_CONTENTS_DIR)"
	@echo "APPL????" > "$(APP_CONTENTS_DIR)/PkgInfo"

	@mkdir -p "$(APP_CONTENTS_DIR)/MacOS"
	@cp "$(RELEASE_DIR)/$(APP_NAME)" "$(APP_CONTENTS_DIR)/MacOS/$(APP_NAME)"

	@cp -r "$(RESOURCES_DIR)" "$(APP_CONTENTS_DIR)/Resources"
	@cp -r "$(SPM_BUNDLE)" "$(APP_CONTENTS_DIR)/Resources/"
	@cp -r $(ASSETS_MANIFEST_PATH) "$(APP_CONTENTS_DIR)/Info.plist"

	@install -m 755 "$(CLI_SCRIPT_PATH)" "$(APP_CONTENTS_DIR)/Resources/$(CLI_NAME)"

	@install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_CONTENTS_DIR)/MacOS/$(APP_NAME)" 2>/dev/null || true

	@codesign \
	     --force \
	     --sign $(SIGNATURE_NAME) \
	     "$(APP_DIST)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_DIST)"
	@codesign -d -r- "$(APP_DIST)"


$(RELEASE_DIR)/$(APP_NAME): $(SWIFT_FILES)
	@echo "Building binary"
	@swift build -c release --product $(APP_NAME)

define convert_iconset
    @sips -z $1 $1 "$(APP_ICON_PNG_PATH)" --out "$(ICONSET_DIR)/icon_$1x$1.png" > /dev/null
endef

# SwiftPM initializes the release symlink before we can safely generate resources there.
$(RESOURCES_DIR)/AppIcon.icns: $(ICON_FILES) | $(RELEASE_DIR)/$(APP_NAME)
	@echo "Building AppIcon.icns"
	@rm -rf "$(ICONSET_DIR)" && mkdir -p "$(ICONSET_DIR)"

	@echo "  Generating iconset"
	@$(ICTOOL) "$(ASSETS_ICON_PATH)" \
		--export-image \
		--output-file "$(APP_ICON_PNG_PATH)" \
		--platform macOS \
		--rendition Default \
		--width 1024 \
		--height 1024 \
		--scale 1 > /dev/null
	$(call convert_iconset,16)
	$(call convert_iconset,32)
	$(call convert_iconset,64)
	$(call convert_iconset,128)
	$(call convert_iconset,256)
	$(call convert_iconset,512)
	@cp "$(ICONSET_DIR)/icon_32x32.png" "$(ICONSET_DIR)/icon_16x16@2x.png"
	@cp "$(ICONSET_DIR)/icon_64x64.png" "$(ICONSET_DIR)/icon_32x32@2x.png"
	@cp "$(ICONSET_DIR)/icon_128x128.png" "$(ICONSET_DIR)/icon_64x64@2x.png"
	@cp "$(ICONSET_DIR)/icon_256x256.png" "$(ICONSET_DIR)/icon_128x128@2x.png"
	@cp "$(ICONSET_DIR)/icon_512x512.png" "$(ICONSET_DIR)/icon_256x256@2x.png"
	@cp "$(APP_ICON_PNG_PATH)" "$(ICONSET_DIR)/icon_512x512@2x.png"
	@cp "$(APP_ICON_PNG_PATH)" "$(ICONSET_DIR)/icon_1024x1024.png"

	@echo "  Converting iconset"
	@iconutil -c icns "$(ICONSET_DIR)" -o "$(RESOURCES_DIR)/AppIcon.icns"

# Clean up
	@rm -rf "$(ICONSET_DIR)"
	@rm -f "$(APP_ICON_PNG_PATH)"

$(RESOURCES_DIR)/Assets.car: $(ICON_FILES) | $(RELEASE_DIR)/$(APP_NAME)
	@echo "Building Assets.car"
	@mkdir -p $(RESOURCES_DIR)
	@$(ACTOOL) "$(ASSETS_ICON_PATH)" \
		--compile "$(RESOURCES_DIR)" \
		--app-icon AppIcon \
		--enable-on-demand-resources NO \
		--development-region en \
		--target-device mac \
		--platform macosx \
		--minimum-deployment-target 26.0 \
		--include-all-app-icons \
		--enable-icon-stack-fallback-generation=disabled \
		--output-partial-info-plist /dev/null > /dev/null

.PHONY: help
help: ## print this message
	@echo "Usage: make <command>"
	@echo "Available commands:"
	@awk \
		'BEGIN {FS = ":.*?## "} \
		/^[a-zA-Z_-]+:.*?## / \
		{printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST)
