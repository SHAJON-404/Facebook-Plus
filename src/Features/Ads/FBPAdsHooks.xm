// Specialised ad blocking for surfaces that do not flow through the News Feed
// model path (FBPFeedHooks handles that one).
//
//  * Watch / video feed ads come from FBVideoFeedAdsPool, which hands the player
//    an array of ad items to interleave. Returning an empty array leaves the
//    organic videos untouched and simply inserts nothing.
//  * Story ("Snacks") ads are loaded by FBSnacksAdsPaginatingFetcher ahead of
//    time; no-oping its fetch entry points means an ad is never requested, so no
//    gap is left between stories.
//
// Each hook installs only when its target class and selector are present, so a
// build that renames one degrades just that surface.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#pragma mark - Feed-model ad detection
//
// The News Feed ad units flow through the single FBMemModelObject filter in
// FBPFeedHooks. Rather than hook that model class a second time here — which
// would mean two installers racing on one method — the ad-specific test lives in
// this function and the feed filter calls it. So every ad rule stays in this
// file, and the model is still hooked exactly once.

/// YES when a feed-unit model is a paid/ad unit the user has chosen to block.
BOOL FBPModelIsBlockedAd(id model) {
    if (!model) return NO;

    // "SPONSORED" category token, and any unit carrying sponsoredData (a paid
    // unit even when its category token says otherwise).
    if (FBPEnabled(FBPKeyNoAds)) {
        if ([model respondsToSelector:@selector(category)]) {
            NSString *category = [model category];
            if ([category isKindOfClass:NSString.class] &&
                [category isEqualToString:@"SPONSORED"]) {
                return YES;
            }
        }
        if ([model respondsToSelector:@selector(sponsoredData)] &&
            [model sponsoredData] != nil) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Watch / video feed ads

%group FBPVideoAds

%hook FBVideoFeedAdsPool

- (NSArray *)insertedItems {
    if (FBPEnabled(FBPKeyNoAds)) return @[];
    return %orig;
}

%end

%end // FBPVideoAds

#pragma mark - Story ("Snacks") ads

%group FBPStoryAds

%hook FBSnacksAdsPaginatingFetcher

- (void)startFetch:(id)arg1 organicConsumption:(id)arg2 {
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

- (void)fetchAdsForStoryWithRequestPayload:(id)payload {
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

- (void)fetchAdsForStoryWithRequestPayloadAsync:(id)payload {
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

%end

%end // FBPStoryAds

// Note: Marketplace ads are deliberately not handled here. They are server-side,
// per-account "Sponsored" listings rendered by React Native (Fabric); there is
// no reliable client-side hook — any native view change is overwritten on the
// next Fabric render pass, and the items never reach a native model to filter.

#pragma mark - Init

void FBPInitAdsHooks(void) {
    Class videoPool = objc_getClass("FBVideoFeedAdsPool");
    if (videoPool && [videoPool instancesRespondToSelector:@selector(insertedItems)]) {
        FBP_ONCE(gVideoAds) { %init(FBPVideoAds); }
    } else {
        FBPLog(@"FBVideoFeedAdsPool not found — video ad blocking disabled");
    }

    Class storyFetcher = objc_getClass("FBSnacksAdsPaginatingFetcher");
    if (storyFetcher) {
        FBP_ONCE(gStoryAds) { %init(FBPStoryAds); }
    } else {
        FBPLog(@"FBSnacksAdsPaginatingFetcher not found — story ad blocking disabled");
    }
}
