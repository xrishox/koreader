IOS_DIR = $(PLATFORM_DIR)/ios
IOS_NAME ?= $(VERSION)
IOS_BUNDLE_ID ?= rocks.koreader.koreader
IOS_APP = $(INSTALL_DIR)/KOReader.app
IOS_IPA = koreader-ios-$(IOS_ARCH)$(KODEDUG_SUFFIX)-$(IOS_NAME).ipa
IOS_NATIVE_BUILD = $(INSTALL_DIR)/ios-native
IOS_ARCH ?= arm64
IOS_SDK ?= $(if $(filter sim-% sim_% simulator-% simulator_% sim%,$(IOS_ARCH)),iphonesimulator,iphoneos)
IOS_ARCH_NAME ?= $(patsubst sim-%,%,$(patsubst sim_%,%,$(patsubst simulator-%,%,$(patsubst simulator_%,%,$(IOS_ARCH)))))
IOS_MIN_VERSION ?= 15.0
IOS_CC = $(shell xcrun -sdk $(IOS_SDK) -find clang)
IOS_CXX = $(shell xcrun -sdk $(IOS_SDK) -find clang++)
IOS_XCODE_DIR = $(CURDIR)/koreader-ios-xcode/$(IOS_SDK)

define UPDATE_PATH_EXCLUDES +=
plugins/SSH.koplugin
plugins/autofrontlight.koplugin
plugins/externalkeyboard.koplugin
plugins/hello.koplugin
plugins/httpinspector.koplugin
plugins/terminal.koplugin
plugins/timesync.koplugin
tools
endef

update: all
	rm -rf $(IOS_APP) $(INSTALL_DIR)/Payload
	cmake -S $(IOS_DIR)/native -B $(IOS_NATIVE_BUILD) -G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT=$(IOS_SDK) \
		-DCMAKE_OSX_ARCHITECTURES=$(IOS_ARCH_NAME) \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(IOS_MIN_VERSION) \
		-DCMAKE_BUILD_TYPE=$(if $(KODEBUG),Debug,Release) \
		-DCMAKE_C_COMPILER=$(IOS_CC) \
		-DCMAKE_OBJC_COMPILER=$(IOS_CC) \
		-DKOREADER_STAGING_DIR=$(abspath $(STAGING_DIR))
	cmake --build $(IOS_NATIVE_BUILD)
	cp -R $(IOS_NATIVE_BUILD)/KOReader.app $(IOS_APP)
	install -d $(IOS_APP)/reader
	cd $(INSTALL_DIR)/koreader && '$(abspath tools/mkrelease.sh)' $(abspath $(IOS_APP))/reader/ . $(release_excludes)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(IOS_BUNDLE_ID)" $(IOS_APP)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(IOS_NAME)" $(IOS_APP)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(shell git rev-list --count HEAD)" $(IOS_APP)/Info.plist
	install -d $(INSTALL_DIR)/Payload
	cp -R $(IOS_APP) $(INSTALL_DIR)/Payload/
	cd $(INSTALL_DIR) && zip -qry $(abspath $(IOS_IPA)) Payload

xcodeproj:
	command -v xcodegen >/dev/null || { echo "xcodegen not found. Install it with: brew install xcodegen" >&2; exit 1; }
	xcodegen generate \
		--spec $(IOS_DIR)/project.yml \
		--project $(CURDIR) \
		--project-root $(CURDIR)
	@echo "Generated $(CURDIR)/KOReader.xcodeproj"

ios-xcode-stage: all
	rm -rf $(IOS_XCODE_DIR)
	install -d $(IOS_XCODE_DIR)
	ln -s $(abspath $(STAGING_DIR)) $(IOS_XCODE_DIR)/staging
	ln -s $(abspath $(INSTALL_DIR)) $(IOS_XCODE_DIR)/install

ios-xcode-embed: ios-xcode-stage ios-xcode-embed-only

ios-xcode-embed-only:
	test -n '$(IOS_XCODE_APP)' || { echo "IOS_XCODE_APP is required" >&2; exit 2; }
	rm -rf '$(IOS_XCODE_APP)/reader'
	install -d '$(IOS_XCODE_APP)/reader'
	cd $(INSTALL_DIR)/koreader && '$(abspath tools/mkrelease.sh)' '$(IOS_XCODE_APP)/reader/' . $(release_excludes)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(IOS_BUNDLE_ID)" '$(IOS_XCODE_APP)/Info.plist'
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(IOS_NAME)" '$(IOS_XCODE_APP)/Info.plist'
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(shell git rev-list --count HEAD)" '$(IOS_XCODE_APP)/Info.plist'
	if [ "$${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && [ -n "$${EXPANDED_PROVISIONING_PROFILE:-}" ]; then \
		exit 0; \
	fi; \
	sign_identity="$${EXPANDED_CODE_SIGN_IDENTITY:-$${CODE_SIGN_IDENTITY:-}}"; \
	if [ "$${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] \
		|| [ -z "$${sign_identity}" ] \
		|| [ "$${sign_identity}" = "iPhone Developer" ] \
		|| [ "$${sign_identity}" = "Apple Development" ] \
		|| [ "$${sign_identity}" = "-" ]; then \
		sign_identity="-"; \
		keychain_flags=""; \
	else \
		keychain_flags="$${OTHER_CODE_SIGN_FLAGS:-}"; \
	fi; \
	while IFS= read -r -d '' lib; do \
		/usr/bin/codesign --force --sign "$${sign_identity}" --timestamp=none $${keychain_flags} "$${lib}" >/dev/null; \
	done < <(find '$(IOS_XCODE_APP)/reader' -type f \( -name '*.dylib' -o -name '*.so' \) -print0)

PHONY += xcodeproj ios-xcode-stage ios-xcode-embed ios-xcode-embed-only

# vim: foldmethod=marker foldlevel=0
