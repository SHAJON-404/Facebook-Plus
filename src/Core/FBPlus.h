// Shared declarations for the tweak: preference and notification keys, the
// FBPLog macro, accessibility identifiers, view tags, and the FBP_ONCE
// deferred-install helper.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

#ifdef DEBUG
#define FBPLog(fmt, ...) NSLog(@"[Facebook Plus] " fmt, ##__VA_ARGS__)
#else
#define FBPLog(fmt, ...) do {} while (0)
#endif

#pragma mark - Deferred hook installation

/// Guards a hook group so it installs exactly once.
///
/// Facebook's main binary links only FBSharedFramework at launch;
/// FBFeedAttachmentsFramework, FBSharedDynamicFramework, FBCameraFramework and
/// FBRarelyUsedFramework are dlopen'd later, the first time the user visits
/// something that needs them. A %ctor therefore runs long before most of the
/// app's classes exist, and any group gated on `objc_getClass` for those
/// frameworks silently never installs.
///
/// The installers are re-run on every dyld image load (see FBPEntry.xm), so
/// each group needs its own latch:
///
///     if (objc_getClass("CKComponentActionControlForwarder")) {
///         FBP_ONCE(gConfirmInstalled) { %init(FBPConfirm); }
///     }
#define FBP_ONCE(name) static BOOL name = NO; if (!name && (name = YES))

#pragma mark - Notifications

/// Posted whenever any preference changes, so live views can re-read state
/// without an app relaunch.
extern NSNotificationName const FBPSettingsDidChangeNotification;

/// Posted as Facebook slides its tab bar in or out. userInfo carries
/// @c FBPTabBarFractionKey as an NSNumber<double>, 0 = fully visible.
extern NSNotificationName const FBPTabBarVisibilityDidChangeNotification;
extern NSString *const FBPTabBarFractionKey;

#pragma mark - Preference keys

// Feed
extern NSString *const FBPKeyNoAds;             // Remove sponsored units
extern NSString *const FBPKeyNoRecs;            // Remove ENGAGEMENT recommendations
extern NSString *const FBPKeyNoPYMK;            // Remove "People you may know"
extern NSString *const FBPKeyNoReels;           // Remove the reels carousel
extern NSString *const FBPKeyNoStories;         // Remove the stories tray
extern NSString *const FBPKeyNoStoryPYMK;       // Remove PYMK from the story tray
extern NSString *const FBPKeyNoThreads;         // Remove the Threads promo unit
extern NSString *const FBPKeyNoGroupSuggestions;// Remove "groups you should join"
extern NSString *const FBPKeyNoSuggestedPages;  // Remove "suggested pages for you"

// Confirmations (opt-in: guard an action behind a prompt)
extern NSString *const FBPKeyConfirmComment;    // Confirm before posting a comment
extern NSString *const FBPKeyConfirmFriend;     // Confirm before a friend-request action
extern NSString *const FBPKeyConfirmShare;      // Confirm before sharing
extern NSString *const FBPKeyConfirmFollow;     // Confirm before following / joining
extern NSString *const FBPKeyConfirmPost;       // Confirm before publishing a post

// Downloads
extern NSString *const FBPKeyReelsDownloaderEnabled;
extern NSString *const FBPKeyStoryDownloaderEnabled;

// Reels
extern NSString *const FBPKeyReelsHideOverlay;  // Strip the Reels overlay (always on; no toggle)

// Stories
extern NSString *const FBPKeyAnonymousStories;
extern NSString *const FBPKeyNoAutoNext;

// Feed interaction
extern NSString *const FBPKeyFeedLike;          // Confirm every like (feed + Reels)

// Appearance
extern NSString *const FBPKeyOLED;              // True-black background in dark mode

// Links
extern NSString *const FBPKeyLinksInSafari;     // Open external links in the default browser

// Other
extern NSString *const FBPKeyNotifyUpdates;
extern NSString *const FBPKeyAutoClearCache;
extern NSString *const FBPKeyLanguage;          // In-tweak UI language ("" = English/Base, "fr", …)

// Internal
extern NSString *const FBPKeyIntroduced;        // Onboarding has been shown
extern NSString *const FBPKeyLastNotifiedVersion; // Latest release the user was told about

#pragma mark - Confirmations

/// One shared "a confirmation is on screen" latch, so the two confirmation
/// paths (the ComponentKit forwarder and the method-swizzle commit hooks) never
/// stack a second prompt on top of the first — which is what made tapping a post
/// raise the prompt over and over.
#ifdef __cplusplus
extern "C" {
#endif
BOOL FBPConfirmPromptVisible(void);
void FBPSetConfirmPromptVisible(BOOL visible);
#ifdef __cplusplus
}
#endif

#pragma mark - Ads

/// Ad detection for News Feed unit models. Defined in FBPAdsHooks.xm (so every
/// ad rule lives in one place) and called by the single FBMemModelObject filter
/// in FBPFeedHooks, which keeps that model hooked exactly once.
#ifdef __cplusplus
extern "C" BOOL FBPModelIsBlockedAd(id model);
#else
extern BOOL FBPModelIsBlockedAd(id model);
#endif

#pragma mark - Accessibility identifiers used to locate Facebook views
//
// These are stable across app versions because Facebook's own UI tests depend
// on them, which makes them a far better anchor than ComponentKit's generated
// view class names. Verified present in FB v570.0.0 and v574.0.0.

extern NSString *const FBPAXFeedLikeButton;     // cell-ufi-like-button
extern NSString *const FBPAXReelsLikeButton;    // shorts-like-top-button
extern NSString *const FBPAXNavSettingsButton;  // nav-settings-button
extern NSString *const FBPAXStoryHeaderView;    // story-header-view

#pragma mark - View tags
//
// Injected container views are located again on subsequent layout passes with
// -viewWithTag: rather than being re-created, which is what keeps repeated
// -layoutSubviews calls from stacking duplicate buttons.

typedef NS_ENUM(NSInteger, FBPViewTag) {
    FBPViewTagStoryButton  = 0x7B902,
};

NS_ASSUME_NONNULL_END
