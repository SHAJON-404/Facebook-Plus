// Single constructor. Each hook group installs itself only after checking that
// its target class and selector actually exist in this build of Facebook, so a
// missing target degrades that one feature instead of taking the tweak down.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <mach-o/dyld.h>

extern void FBPInitFeedHooks(void);
extern void FBPInitStoryHooks(void);
extern void FBPInitConfirmHooks(void);
extern void FBPInitActionConfirm(void);
extern void FBPInitChromeHooks(void);
extern void FBPInitOLEDHooks(void);
extern void FBPInitReelsDownloader(void);
extern void FBPInitLinkHooks(void);
extern void FBPInitLinkBridge(void);
extern void FBPInitCallBlocker(void);

/// Runs every installer. Each group latches itself with FBP_ONCE, so calling
/// this repeatedly installs each hook exactly once.
static void FBPInstallHooks(void) {
    FBPInitFeedHooks();
    FBPInitStoryHooks();
    FBPInitConfirmHooks();
    FBPInitActionConfirm();
    FBPInitChromeHooks();
    FBPInitOLEDHooks();
    FBPInitReelsDownloader();
    FBPInitLinkHooks();
    FBPInitLinkBridge();
    FBPInitCallBlocker();
}

/// dyld calls this for every image already loaded, then again for each new one.
///
/// This is why the deferred-install pattern is needed at all: Facebook links only
/// FBSharedFramework at launch and dlopens the rest on demand, so a one-shot %ctor
/// observes only a fraction of the app's classes.
static void FBPImageDidLoad(const struct mach_header *header, intptr_t slide) {
    FBPInstallHooks();
}

%ctor {
    @autoreleasepool {
        // The tweak is bound to the app it ships in, not to a fixed bundle id:
        // the Filter plist scopes the substrate build to Facebook, and an
        // IPA-embedded build only ever loads inside the app cyan injected it into.
        // We therefore do not hardcode a bundle id here — that lets a re-signed
        // IPA use a custom identifier (to run alongside the stock app) and still
        // activate.

        // Registers defaults before any hook can read a preference.
        (void)FBPPrefs.shared;

        // Installs what is available now, and again as each framework arrives.
        FBPInstallHooks();
        _dyld_register_func_for_add_image(&FBPImageDidLoad);

        // Inlined (not a local) so the release build, where FBPLog is a no-op,
        // does not trip -Werror=unused-variable.
        FBPLog(@"loaded into %@", NSBundle.mainBundle.bundleIdentifier);
    }
}
