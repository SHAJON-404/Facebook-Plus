// Feed cleanup.
//
// Every News Feed unit is materialised through FBMemModelObject. Returning nil
// from the initialiser drops the unit before it reaches the data source, so no
// blank cell is left behind — which is why this is done at the model layer
// rather than by hiding views.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <objc/message.h>

/// Feed category token -> the preference that suppresses it.
///
/// Built once. -initWithFBPandoTree: is on the hot path for every item in the
/// feed, so per-call string work would show up as scroll jank.
static NSDictionary<NSString *, NSString *> *FBPCategoryMap(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Ads are handled separately by FBPModelIsBlockedAd (FBPAdsHooks.xm), so
        // "SPONSORED" is deliberately not mapped here.
        map = @{
            @"ENGAGEMENT"    : FBPKeyNoRecs,
            @"ENGAGEMENT_QP" : FBPKeyNoRecs,
            @"FB_SHORTS"     : FBPKeyNoReels,
            @"MULTI_FB_STORIES_TRAY" : FBPKeyNoStories,
            @"PYMK_STORY"    : FBPKeyNoStoryPYMK,
            @"PYMK"          : FBPKeyNoPYMK,
        };
    });
    return map;
}

/// The Threads cross-app promotion unit ("<name>, discover new threads").
///
/// Deliberately only Threads. The binary has a whole `*_IN_FEED_UNIT` family
/// (Notes, Highlights, "creators you may follow", follow-back, MEMU…) and
/// blocking all of them emptied the feed — Facebook stopped serving pages and
/// fell back to "feed not available at this moment". Those units evidently
/// carry pagination the feed depends on, so they stay.
static NSSet<NSString *> *FBPThreadsUnits(void) {
    static NSSet *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        units = [NSSet setWithArray:@[
            @"THREADS_IN_FEED_UNIT",
            @"THREADS_IN_STORY_UNIT_MID_CARD",
        ]];
    });
    return units;
}

/// Field keys that might carry the unit's type.
///
/// FBMemModelObject resolves its fields dynamically off the Pando tree — the
/// concrete model classes declare no ObjC methods or properties at all, so the
/// real accessor name cannot be read out of the binary. In v578 the app serves
/// the Threads card ("<name>, discover new threads") through a generic Pando
/// feed unit whose type lives in `feed_unit_type` (== "THREADS_IN_FEED_UNIT").
///
/// Both camelCase and the raw snake_case Pando key are tried, because KVC (see
/// FBPIsThreadsUnit) resolves either shape.
static NSArray<NSString *> *FBPUnitTypeKeys(void) {
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Grounded in the strings actually present in FBSharedFramework v578:
        // `unitType`, `feed_unit_type` and `FeedUnitType`. camelCase covers a
        // materialised accessor; the raw snake key covers KVC lookups that hit
        // the Pando tree directly.
        keys = @[@"feedUnitType", @"feed_unit_type", @"unitType", @"inlineUnitType"];
    });
    return keys;
}

static BOOL FBPValueIsThreadsToken(id value) {
    return [value isKindOfClass:NSString.class] &&
           [FBPThreadsUnits() containsObject:value];
}

static BOOL FBPIsThreadsUnit(id model) {
    for (NSString *key in FBPUnitTypeKeys()) {
        // 1) Typed selector send — only when the model genuinely declares an
        //    object-returning accessor. The return-type guard avoids the scalar
        //    case (-[FBShortsViewerRichMediaModel storyUnitType] is 'Q', an
        //    NSUInteger); messaging its result as an id is undefined behaviour
        //    and previously destabilised the feed.
        SEL selector = NSSelectorFromString(key);
        if ([model respondsToSelector:selector]) {
            NSMethodSignature *signature = [model methodSignatureForSelector:selector];
            const char *returnType = signature.methodReturnType;
            if (returnType && returnType[0] == _C_ID) {
                @try {
                    id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
                    if (FBPValueIsThreadsToken(value)) return YES;
                } @catch (__unused NSException *exception) {}
            }
        }

        // 2) KVC. Pando fields are reachable through -valueForKey: even when the
        //    matching accessor has not been lazily materialised yet, so
        //    -respondsToSelector: for it is NO at -initWithFBPandoTree: time.
        //    That gap is why the selector-only check missed the Threads card.
        //    -valueForKey: on an absent key throws NSUndefinedKeyException, which
        //    the @try absorbs; a scalar-backed field returns an NSNumber that
        //    FBPValueIsThreadsToken rejects.
        @try {
            id value = [model valueForKey:key];
            if (FBPValueIsThreadsToken(value)) return YES;
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

/// YES when this model should be dropped.
static BOOL FBPShouldFilterModel(id model) {
    if (!model) return NO;

    // Ads (sponsored units and sponsoredData-backed units) are detected in one
    // place — FBPModelIsBlockedAd in FBPAdsHooks.xm — so every ad rule lives
    // beside the other ad hooks. This single model hook stays the only thing that
    // touches FBMemModelObject.
    if (FBPModelIsBlockedAd(model)) return YES;

    // Most models have no category at all; bail out before doing any work.
    if ([model respondsToSelector:@selector(category)]) {
        NSString *category = [model category];
        if ([category isKindOfClass:NSString.class]) {
            NSString *key = FBPCategoryMap()[category];
            if (key && FBPEnabled(key)) return YES;
        }
    }

    if (FBPEnabled(FBPKeyNoThreads) && FBPIsThreadsUnit(model)) {
        return YES;
    }

    // "Groups you should join" / "Suggested for you" group units. These arrive as
    // their own FBMem* model class rather than under a shared category token, so
    // they are matched by class name. The generated model does not override
    // -initWithFBPandoTree:, so the instance still reaches this base hook.
    if (FBPEnabled(FBPKeyNoGroupSuggestions)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"GroupsYouShouldJoin"]) return YES;
    }

    // "Suggested Pages for you" — the pages-you-may-like unit. Like the group
    // suggestions above it arrives as its own FBMem* model class (the plain,
    // Paginated and Creative variants all share the "PagesYouMayLike" infix) and
    // does not override -initWithFBPandoTree:, so it reaches this base hook.
    if (FBPEnabled(FBPKeyNoSuggestedPages)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"PagesYouMayLike"]) return YES;
    }

    // A single ephemeral story shown inline in the feed (its own card, distinct
    // from the horizontal tray). It arrives as FBMemStoriesSingleBucketInline
    // ViewerFeedUnit under an ORGANIC edge, so it is matched by class name rather
    // than category. Gated by the same Stories toggle as the tray.
    if (FBPEnabled(FBPKeyNoStories)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"SingleBucketInlineViewer"]) return YES;
    }

    // The story-tray PYMK bucket is distinct from the feed-level one.
    if (FBPEnabled(FBPKeyNoStoryPYMK) &&
        [model respondsToSelector:@selector(storyBucketType)]) {
        NSString *bucket = [model storyBucketType];
        if ([bucket isKindOfClass:NSString.class] &&
            [bucket isEqualToString:@"PYMK_STORY"]) {
            return YES;
        }
    }

    return NO;
}

%group FBPFeed

%hook FBMemModelObject

// The current path in FB v570/v574.
- (id)initWithFBPandoTree:(void *)tree {
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeed

// Legacy GraphQL tree path. Absent from v570 and v574, so it is
// installed only when the selector actually exists — hooking a missing selector
// would fail silently and mask a real problem later.
%group FBPFeedLegacy

%hook FBMemModelObject

- (id)initWithFBTree:(void *)tree {
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeedLegacy

void FBPInitFeedHooks(void) {
    Class model = objc_getClass("FBMemModelObject");
    if (!model) {
        FBPLog(@"FBMemModelObject not found — feed filtering disabled");
        return;
    }

    if ([model instancesRespondToSelector:@selector(initWithFBPandoTree:)]) {
        FBP_ONCE(gFeed) { %init(FBPFeed); }
    }
    if ([model instancesRespondToSelector:@selector(initWithFBTree:)]) {
        FBP_ONCE(gFeedLegacy) { %init(FBPFeedLegacy); }
    }
}
