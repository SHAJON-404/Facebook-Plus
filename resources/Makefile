include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FacebookPlus

FacebookPlus_INSTALL_PATH = /Library/Application Support

# Info.plist plus every PNG in bundle/ (logo, feature glyphs, footer icons at
# @1x/@2x/@3x). A wildcard so a newly rasterised icon ships without editing here.
FacebookPlus_RESOURCE_FILES = bundle/Info.plist $(wildcard bundle/*.png)

# RESOURCE_DIRS copies each folder's *contents* into the bundle root.
#   ../Localizations -> Base.lproj/ fr.lproj/ … (loaded by FBPLocalizedString)
#   ../resources/logo -> fbplus_* custom app-icon logos. These ship inside
#     FacebookPlus.bundle so they travel with the tweak; build.sh's cyan step then
#     drops them at the app root and registers them in the app's Info.plist.
#   ../resources/fonts -> custom .ttf/.otf the Fonts picker offers. Copied via cp
#     (space-safe), registered with Core Text at launch and listed by family name.
FacebookPlus_RESOURCE_DIRS = ../Localizations ../resources/logo ../resources/fonts

include $(THEOS_MAKE_PATH)/bundle.mk
