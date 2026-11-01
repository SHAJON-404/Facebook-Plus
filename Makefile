TARGET := iphone:clang:latest:15.1
# arm64 only. This targets iPhone 11 → latest, all sideloaded / re-signed: those
# apps run in the arm64 slice even on A12+ (arm64e) devices — the arm64e slice is
# reserved for Apple-signed platform binaries — so an injected arm64e slice would
# never load. Dropping it also removes the "incompatible arm64e ABI" linker warning.
ARCHS  := arm64
INSTALL_TARGET_PROCESSES = Facebook

# Set to 1 (or export in your environment) when building for a roothide
# jailbreak, which needs the .jbroot loader-path indirection.
THEOS_PACKAGE_SCHEME ?= rootless
THEOS ?= $(HOME)/theos

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FacebookPlus

FacebookPlus_FILES = \
	src/Core/FBPlus.m \
	src/Core/FBPPrefs.m \
	src/Core/FBPResources.m \
	src/Core/FBPEntry.xm \
	src/UI/Toast/FBPToastWindow.m \
	src/UI/Toast/FBPToastView.m \
	src/UI/Toast/FBPToastManager.m \
	src/UI/Sheet/FBPSheetPresenter.m \
	src/UI/Sheet/FBPSheetController.m \
	src/UI/Sheet/FBPDetentPresentationController.m \
	src/Settings/FBPSettingsController.m \
	src/Features/Onboarding/FBPWelcomeController.m \
	src/Features/AppIcons/FBPAppIconController.m \
	src/Features/Language/FBPLanguageController.m \
	src/Features/Feed/FBPFeedHooks.xm \
	src/Features/Stories/FBPStoryHooks.xm \
	src/Features/LikeConfirmation/FBPConfirmHooks.xm \
	src/Features/Confirmations/FBPActionConfirm.mm \
	src/Features/AppChrome/FBPChromeHooks.xm \
	src/Features/OLED/FBPOLEDHooks.xm \
	src/Features/Downloads/FBPReelsDownloader.xm \
	src/Features/Downloads/FBPStoryDownloader.xm \
	src/Features/Links/FBPLinkHooks.xm \
	src/Features/Links/FBPLinkBridge.xm \
	src/Features/Calls/FBPCallBlocker.xm \
	src/Features/Update/FBPUpdateController.m \
	src/Features/Update/FBPUpdateChecker.m \
	src/PluginsInject/PluginsInject.mm \
	src/PluginsInject/Paths.mm \
	src/PluginsInject/SecRebinds.xm \
	src/PluginsInject/SideloadFix.xm \
	fishhook/fishhook.c

# The tweak's own version, read from control, exposed to the code as FBP_VERSION
# (an NSString literal) so the update checker can compare against GitHub releases.
FBP_VERSION := $(shell awk -F': ' '/^Version:/{print $$2; exit}' control)

FacebookPlus_CFLAGS  = -fobjc-arc -Wno-deprecated-declarations \
	-DFBP_VERSION='@"$(FBP_VERSION)"' \
	-Isrc/Core -Isrc/UI -Isrc/UI/Toast -Isrc/UI/Sheet -Isrc/Settings \
	-Isrc/Features -Isrc/Features/AppChrome -Isrc/Features/AppIcons \
	-Isrc/Features/Calls -Isrc/Features/Downloads -Isrc/Features/Feed \
	-Isrc/Features/Language -Isrc/Features/LikeConfirmation \
	-Isrc/Features/Links -Isrc/Features/OLED -Isrc/Features/Onboarding \
	-Isrc/Features/Stories -Isrc/Features/Update -Isrc/PluginsInject
FacebookPlus_FRAMEWORKS = UIKit Foundation Photos QuartzCore CoreGraphics AVFoundation CoreMedia Security PushKit CallKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += resources
include $(THEOS_MAKE_PATH)/aggregate.mk

# Editor support. Without a compilation database, clangd and the VS Code C/C++
# extension cannot find the iOS SDK and every Foundation type reads as
# "Unknown type name".
#
# We cannot let bear *intercept* the build: theos compiles with the Xcode
# toolchain's Apple-signed clang, and macOS strips DYLD_INSERT_LIBRARIES (bear's
# interception mechanism) from hardened-runtime Apple binaries, so `bear -- make`
# only ever records an empty "[]". Instead we use bear's `parse-sh`, which reads
# theos's own dry-run (`make -n`) and turns each compile into a database entry
# with the real flags — no interception, works on any macOS. theos wraps every
# compile in a `( … )` subshell that parse-sh would skip, so the sed first
# unwraps it to a bare command. Logos .xm files appear as their preprocessed
# .theos/obj/…/<name>.xm.mm; editing the original .xm is covered by .clangd above.
.PHONY: compile-commands
compile-commands:
	@command -v bear >/dev/null 2>&1 || { \
		echo "error: bear is not installed."; \
		echo "       Debian/Ubuntu: sudo apt install bear"; \
		echo "       macOS:         brew install bear"; \
		exit 1; \
	}
	@echo "==> Generating .clangd…"
	@sdk=$$(ls -d "$(THEOS)"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1); \
	if [ -z "$$sdk" ]; then \
		echo "error: no iPhoneOS SDK found under $(THEOS)/sdks"; exit 1; \
	fi; \
	sdkver=$$(basename "$$sdk" .sdk | sed 's/^iPhoneOS//'); \
	{ \
		echo "CompileFlags:"; \
		echo "  Add:"; \
		echo "    - -target"; \
		echo "    - arm64-apple-ios$$sdkver"; \
		echo "    - -isysroot"; \
		echo "    - $$sdk"; \
		echo "    - -I$(THEOS)/include"; \
		echo "    - -I$(THEOS)/include/iphone"; \
		echo "    - -I$(THEOS)/vendor/include"; \
		echo "    - -I$(THEOS)/include/_fallback"; \
		echo "    - -F$$sdk/System/Library/Frameworks"; \
		echo "    - -F$$sdk/System/Library/PrivateFrameworks"; \
		echo "    - -Isrc/Core"; \
		echo "    - -Isrc/UI"; \
		echo "    - -Isrc/UI/Toast"; \
		echo "    - -Isrc/UI/Sheet"; \
		echo "    - -Isrc/Settings"; \
		echo "    - -Isrc/Features"; \
		echo "    - -Isrc/Features/AppChrome"; \
		echo "    - -Isrc/Features/AppIcons"; \
		echo "    - -Isrc/Features/Calls"; \
		echo "    - -Isrc/Features/Downloads"; \
		echo "    - -Isrc/Features/Feed"; \
		echo "    - -Isrc/Features/Language"; \
		echo "    - -Isrc/Features/LikeConfirmation"; \
		echo "    - -Isrc/Features/Links"; \
		echo "    - -Isrc/Features/OLED"; \
		echo "    - -Isrc/Features/Onboarding"; \
		echo "    - -Isrc/Features/Stories"; \
		echo "    - -Isrc/Features/Update"; \
		echo "    - -Isrc/PluginsInject"; \
		echo "    - -DTARGET_IPHONE=1"; \
		echo "    - -DDEBUG"; \
		echo "    - -fobjc-arc"; \
		echo "    - -Wno-deprecated-declarations"; \
		echo ""; \
		echo "Diagnostics:"; \
		echo "  Suppress:"; \
		echo "    - unknown_type_name"; \
		echo "    - undeclared_var_use"; \
		echo "    - duplicate_decl_context"; \
		echo "    - expected_unqualified_id"; \
		echo "    - err_expected_unqualified"; \
		echo "    - missing_method_context"; \
	} > .clangd
	@echo "==> Recording compile commands with bear…"
	@$(MAKE) clean >/dev/null
	@$(MAKE) -n | sed -E 's/.*set -o pipefail; \(//; s/\)[[:space:]]*$$//' \
		| bear parse-sh -o compile_commands.json 2>/dev/null
	@echo "==> Wrote compile_commands.json"
