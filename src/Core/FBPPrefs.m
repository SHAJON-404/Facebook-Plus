// Preference store implementation. Registers default values at launch and posts
// a change notification on commit.

#import "FBPPrefs.h"

static NSString *const kSuiteName = @"com.shajon.fbplus";

@implementation FBPPrefs {
    NSUserDefaults *_defaults;
}

+ (FBPPrefs *)shared {
    static FBPPrefs *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
        [_defaults registerDefaults:[self.class defaultValues]];
    }
    return self;
}

+ (NSDictionary<NSString *, id> *)defaultValues {
    // Every feature ships enabled, so the tweak works out of the box; the user
    // turns off whatever they do not want. Only onboarding state starts off.
    return @{
        FBPKeyNoAds            : @YES,
        FBPKeyNoRecs           : @YES,
        FBPKeyNoPYMK           : @YES,
        FBPKeyNoReels          : @YES,
        FBPKeyNoStories        : @YES,
        FBPKeyNoStoryPYMK      : @YES,
        FBPKeyNoThreads        : @YES,
        FBPKeyNoGroupSuggestions : @YES,
        FBPKeyNoSuggestedPages : @YES,
        FBPKeyConfirmComment   : @NO,
        FBPKeyConfirmFriend    : @NO,
        FBPKeyConfirmShare     : @NO,
        FBPKeyConfirmFollow    : @NO,
        FBPKeyConfirmPost      : @NO,
        FBPKeyReelsDownloaderEnabled : @YES,
        FBPKeyStoryDownloaderEnabled : @YES,
        FBPKeyReelsHideOverlay : @YES,
        FBPKeyAnonymousStories : @YES,
        FBPKeyNoAutoNext       : @YES,
        FBPKeyFeedLike         : @YES,
        FBPKeyOLED             : @YES,
        FBPKeyLinksInSafari    : @YES,
        FBPKeyNotifyUpdates    : @YES,
        FBPKeyAutoClearCache   : @YES,
        FBPKeyIntroduced       : @NO,
    };
}

- (BOOL)boolForKey:(NSString *)key {
    return [_defaults boolForKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [_defaults setBool:value forKey:key];
}

- (NSString *)stringForKey:(NSString *)key {
    id value = [_defaults objectForKey:key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)setString:(NSString *)value forKey:(NSString *)key {
    if (value) {
        [_defaults setObject:value forKey:key];
    } else {
        [_defaults removeObjectForKey:key];
    }
}

- (void)commit {
    [_defaults synchronize];
    [NSNotificationCenter.defaultCenter
        postNotificationName:FBPSettingsDidChangeNotification
                      object:nil];
}

- (void)resetToDefaults {
    BOOL introduced = [self boolForKey:FBPKeyIntroduced];
    [_defaults removePersistentDomainForName:kSuiteName];
    [_defaults registerDefaults:[self.class defaultValues]];
    [_defaults setBool:introduced forKey:FBPKeyIntroduced];
    [self commit];
}

@end
