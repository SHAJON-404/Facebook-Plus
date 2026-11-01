// Definitions of the shared constants declared in FBPlus.h: notification
// names, preference keys, and Facebook accessibility identifiers.

#import "FBPlus.h"

// Shared latch: a confirmation is on screen. Both confirmation paths read and
// set this so a second prompt never stacks on the first.
static BOOL gFBPConfirmPromptVisible = NO;
BOOL FBPConfirmPromptVisible(void) { return gFBPConfirmPromptVisible; }
void FBPSetConfirmPromptVisible(BOOL visible) { gFBPConfirmPromptVisible = visible; }

NSNotificationName const FBPSettingsDidChangeNotification =
    @"FBPlusSettingsDidChangeNotification";
NSNotificationName const FBPTabBarVisibilityDidChangeNotification =
    @"FBPlusTabBarVisibilityDidChangeNotification";
NSString *const FBPTabBarFractionKey = @"fraction";
NSString *const FBPKeyNoAds            = @"noAds";
NSString *const FBPKeyNoRecs           = @"noRecs";
NSString *const FBPKeyNoPYMK           = @"noPYMK";
NSString *const FBPKeyNoReels          = @"noReels";
NSString *const FBPKeyNoStories        = @"noStories";
NSString *const FBPKeyNoStoryPYMK      = @"noStoryPYMK";
NSString *const FBPKeyNoThreads        = @"noThreads";
NSString *const FBPKeyNoGroupSuggestions = @"noGroupSuggestions";
NSString *const FBPKeyNoSuggestedPages = @"noSuggestedPages";
NSString *const FBPKeyConfirmComment   = @"confirmComment";
NSString *const FBPKeyConfirmFriend    = @"confirmFriend";
NSString *const FBPKeyConfirmShare     = @"confirmShare";
NSString *const FBPKeyConfirmFollow    = @"confirmFollow";
NSString *const FBPKeyConfirmPost      = @"confirmPost";
NSString *const FBPKeyReelsDownloaderEnabled = @"reelsDownloaderEnabled";
NSString *const FBPKeyStoryDownloaderEnabled = @"storyDownloaderEnabled";
NSString *const FBPKeyReelsHideOverlay = @"reelsHideOverlay";
NSString *const FBPKeyAnonymousStories = @"anonymousStories";
NSString *const FBPKeyNoAutoNext       = @"noAutoNext";
NSString *const FBPKeyFeedLike         = @"feedLike";
NSString *const FBPKeyOLED             = @"oledMode";
NSString *const FBPKeyLinksInSafari    = @"linksInSafari";
NSString *const FBPKeyNotifyUpdates    = @"notifyUpdates";
NSString *const FBPKeyAutoClearCache   = @"autoClearCache";
NSString *const FBPKeyLanguage         = @"uiLanguage";
NSString *const FBPKeyIntroduced       = @"introduced";
NSString *const FBPKeyLastNotifiedVersion = @"lastNotifiedVersion";
NSString *const FBPAXFeedLikeButton    = @"cell-ufi-like-button";
NSString *const FBPAXReelsLikeButton   = @"shorts-like-top-button";
NSString *const FBPAXNavSettingsButton = @"nav-settings-button";
NSString *const FBPAXStoryHeaderView   = @"story-header-view";
