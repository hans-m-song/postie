.DEFAULT_GOAL := app

ROOT_DIR := $(CURDIR)
SWIFT ?= /usr/bin/swift
BUILD_DIR ?= .build
APP_DIR ?= dist/Postie.app
CONFIGURATION ?= release

INFO_PLIST := $(ROOT_DIR)/packaging/Info.plist
APP_ICON := $(ROOT_DIR)/packaging/Postie.icns

SWIFTPM_OPTIONS := \
	--package-path "$(ROOT_DIR)" \
	--scratch-path "$(BUILD_DIR)/swiftpm" \
	--cache-path "$(BUILD_DIR)/swiftpm-cache" \
	--config-path "$(BUILD_DIR)/swiftpm-config" \
	--security-path "$(BUILD_DIR)/swiftpm-security" \
	--manifest-cache local \
	--disable-dependency-cache \
	--disable-prefetching \
	--disable-netrc \
	--disable-keychain \
	--disable-sandbox

.PHONY: app test fixture

app:
	@set -eu; \
	cd "$(ROOT_DIR)"; \
	app_dir="$(APP_DIR)"; \
	while [ "$${app_dir%/}" != "$$app_dir" ]; do app_dir=$${app_dir%/}; done; \
	if [ "$${app_dir##*/}" != "Postie.app" ]; then printf '%s\n' 'APP_DIR must name Postie.app' >&2; exit 2; fi; \
	case "$$app_dir" in /*) ;; *) app_dir="$(ROOT_DIR)/$$app_dir" ;; esac; \
	if [ ! -f "$(APP_ICON)" ]; then printf '%s\n' 'missing app icon: $(APP_ICON)' >&2; exit 1; fi; \
	"$(SWIFT)" build $(SWIFTPM_OPTIONS) --configuration "$(CONFIGURATION)" --product Postie; \
	bin_dir="$$("$(SWIFT)" build $(SWIFTPM_OPTIONS) --configuration "$(CONFIGURATION)" --show-bin-path)"; \
	mkdir -p "$$app_dir/Contents/MacOS" "$$app_dir/Contents/Resources"; \
	cp -p "$$bin_dir/Postie" "$$app_dir/Contents/MacOS/Postie"; \
	cp -p "$(APP_ICON)" "$$app_dir/Contents/Resources/Postie.icns"; \
	cp -p "$(INFO_PLIST)" "$$app_dir/Contents/Info.plist"; \
	"/usr/bin/codesign" --force --sign - --timestamp=none "$$app_dir"; \
	printf '%s\n' "$$app_dir"

test:
	@cd "$(ROOT_DIR)" && "$(SWIFT)" test $(SWIFTPM_OPTIONS)

fixture:
	@cd "$(ROOT_DIR)" && "$(SWIFT)" run $(SWIFTPM_OPTIONS) PostieHTTPFixture --port 0
