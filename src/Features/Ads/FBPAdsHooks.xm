// Specialised ad blocking for surfaces that do not flow through the News Feed
// model path (FBPFeedHooks handles that one).
//
//  * Watch / video feed ads come from FBVideoFeedAdsPool, which hands the player
//    an array of ad items to interleave. Returning an empty array leaves the
//    organic videos untouched and simply inserts nothing.
//  * Story ("Snacks") ads are loaded by FBSnacksAdsPaginatingFetcher ahead of
//    time; no-oping its fetch entry points means an ad is never requested, so no
//    gap is left between stories.
//  * Marketplace is React Native / Relay: its ads never reach a native model, so
//    they are dropped at the GraphQL layer instead (see the Marketplace section).
//
// Each hook installs only when its target class and selector are present, so a
// build that renames one degrades just that surface. Everything here is gated on
// the single "Remove Ads" preference (FBPKeyNoAds) — there is no separate toggle.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <objc/runtime.h>

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

#pragma mark - Marketplace ads (React Native / Relay)
//
// Marketplace is a React Native surface: Relay fetches its data with GraphQL over
// React Native's RCTNetworking, and every request carries an "X-FB-Friendly-Name"
// header (and/or an fb_api_req_friendly_name body param) naming the query. We hook
// -[RCTNetworking handlerForRequest:] and do two things while Remove Ads is on:
//
//   1. Dedicated ads queries (MarketplaceHomeFeedAdsQueryRendererQuery,
//      MarketplacePDPPersonalizedAdsQuery, …) are handed a handler that fails the
//      request immediately, so their QueryRenderers get a network error and render
//      nothing. Real listings come from separate queries and are untouched.
//   2. Feed / search queries blend ad stories into the normal listing edges, so we
//      wrap the real handler, buffer the response, and drop any item whose
//      __typename is an ad type (MarketplaceAdStory, …CarouselAdStory, Sponsored…).
//
// The idea and the core GraphQL-layer logic are adapted from adamsardo's
// MarketplaceAdBlock (see ROADMAP_AND_CREDITS.md); this is a restyled, toggle-gated
// port in the tweak's own conventions.

// The friendly names of the dedicated Marketplace ads queries. The explicit set
// documents the common ones; the regular expression then catches any other
// "…Ads…Query" sibling (Themed, Pagination, PDP, TopPicks, InstantIntent, …).
// "Ads" must be followed by an uppercase letter so Address/Adsomething never
// match, and only queries are touched — mutations are left alone.
static BOOL FBPMarketplaceIsAdQuery(NSString *name) {
    if (name.length == 0) return NO;

    static NSSet<NSString *> *names;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"MarketplaceHomeFeedAdsQueryRendererQuery",
            @"MarketplaceHomeFeedAdsPaginationQuery",
            @"MarketplaceHomeFeedBoostedListingAdsQuery",
            @"MarketplaceHomeFeedBoostedListingAdsPaginationQuery",
        ]];
        re = [NSRegularExpression
            regularExpressionWithPattern:@"^Marketplace\\w*Ads(?:[A-Z]\\w*)?Query$"
                                 options:0
                                   error:nil];
    });

    if ([names containsObject:name]) return YES;
    return [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

// Marketplace feed / search queries whose responses may carry blended ad stories.
static BOOL FBPMarketplaceIsFeedQuery(NSString *name) {
    return [name hasPrefix:@"Marketplace"] && [name containsString:@"Feed"];
}

// An ad __typename: MarketplaceAdStory, MarketplaceSearchAdStory, …AdsBlended…,
// SponsoredX. Requires an uppercase letter after "Ad"/"Ads" so Additional/Address
// never match.
static BOOL FBPMarketplaceIsAdTypename(NSString *typeName) {
    if (typeName.length == 0) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"Ads?[A-Z]|Sponsored"
                                                      options:0
                                                        error:nil];
    });
    return [re firstMatchInString:typeName options:0 range:NSMakeRange(0, typeName.length)] != nil;
}

// The friendly name of a request: the header first, else the body's
// fb_api_req_friendly_name param.
static NSString *FBPMarketplaceFriendlyName(NSURLRequest *request) {
    NSString *name = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
    if (name.length) return name;

    NSData *body = request.HTTPBody;
    if (body.length == 0 || body.length > 512 * 1024) return nil;
    NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSRange r = [str rangeOfString:@"fb_api_req_friendly_name="];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [str rangeOfString:@"&" options:0 range:NSMakeRange(start, str.length - start)];
    NSString *value = [str substringWithRange:
        NSMakeRange(start, (end.location == NSNotFound ? str.length : end.location) - start)];
    return value.stringByRemovingPercentEncoding ?: value;
}

// An edge is an ad if it, its node, or the node's story is an ad type.
static NSString *FBPMarketplaceAdTypenameOfItem(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:item];
    for (NSString *key in @[@"node", @"story"]) {
        id v = item[key];
        if ([v isKindOfClass:[NSDictionary class]]) {
            [candidates addObject:v];
            id story = v[@"story"];
            if ([story isKindOfClass:[NSDictionary class]]) [candidates addObject:story];
        }
    }
    for (NSDictionary *c in candidates) {
        id t = c[@"__typename"];
        if ([t isKindOfClass:[NSString class]] && FBPMarketplaceIsAdTypename(t)) return t;
    }
    return nil;
}

// Recursively removes ad items from any array reached in the parsed response.
static NSUInteger FBPMarketplaceStripAds(id obj) {
    NSUInteger removed = 0;
    if ([obj isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *arr = obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[i];
            if (FBPMarketplaceAdTypenameOfItem(item)) {
                [arr removeObjectAtIndex:i];
                removed++;
            } else {
                removed += FBPMarketplaceStripAds(item);
            }
        }
    } else if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        for (id value in [obj allValues]) removed += FBPMarketplaceStripAds(value);
    }
    return removed;
}

// Returns a filtered copy of the response, or the original if nothing changed or
// it is not JSON. Handles single JSON documents and newline-separated streamed
// payloads; anything unexpected (multipart, etc.) is left untouched.
static NSData *FBPMarketplaceFilterResponse(NSData *data, NSString *name) {
    if (data.length == 0) return data;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;

    NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:parts.count];
    NSUInteger removed = 0;

    for (NSString *part in parts) {
        NSString *trimmed =
            [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length == 0) { [out addObject:part]; continue; }
        id json = [NSJSONSerialization
            JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                       options:NSJSONReadingMutableContainers
                         error:nil];
        if (!json) return data; // not JSON (multipart / unexpected): leave untouched
        NSUInteger n = FBPMarketplaceStripAds(json);
        if (n == 0) { [out addObject:part]; continue; }
        NSData *re = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        if (!re) return data;
        [out addObject:[[NSString alloc] initWithData:re encoding:NSUTF8StringEncoding]];
        removed += n;
    }

    if (removed == 0) return data;
    FBPLog(@"marketplace: stripped %lu ad item(s) from %@", (unsigned long)removed, name);
    return [[out componentsJoinedByString:sep] dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark Marketplace — request handlers

// The subset of RCTURLRequestDelegate we call on the task RCTNetworking passes to
// a handler. Declared locally so the calls are typed; resolved at runtime.
@protocol FBPMarketplaceRequestDelegate <NSObject>
- (void)URLRequest:(id)token didReceiveData:(NSData *)data;
- (void)URLRequest:(id)token didCompleteWithError:(NSError *)error;
@end

// Stands in for a real RCTURLRequestHandler and fails the ad query immediately, so
// its QueryRenderer renders nothing.
@interface FBPMarketplaceBlockingHandler : NSObject
+ (instancetype)shared;
@end

@implementation FBPMarketplaceBlockingHandler

+ (instancetype)shared {
    static FBPMarketplaceBlockingHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; });
    return h;
}

+ (NSString *)moduleName { return @"FBPMarketplaceBlockingHandler"; }
- (BOOL)canHandleRequest:(NSURLRequest *)request { return YES; }
- (float)handlerPriority { return 0; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<FBPMarketplaceRequestDelegate>)delegate {
    id token = [NSUUID UUID];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Blocked by Facebook Plus"}];
    // Complete asynchronously so RCTNetworkTask has stored the token first.
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate URLRequest:token didCompleteWithError:error];
    });
    return token;
}

- (void)cancelRequest:(id)requestToken {}

@end

// Stands in for RCTNetworkTask as the inner handler's delegate: buffers the body
// and hands the filtered result to the real delegate on completion. Everything
// else the handler calls is forwarded untouched.
@interface FBPMarketplaceFilteringDelegate : NSObject <FBPMarketplaceRequestDelegate>
@property (nonatomic, strong) id realDelegate;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableData *buffer;
@end

// Keeps in-flight proxies alive in case the inner handler holds its delegate weakly.
static NSMutableSet *FBPMarketplaceLiveDelegates(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation FBPMarketplaceFilteringDelegate

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.realDelegate; }

- (void)URLRequest:(id)token didReceiveData:(NSData *)data {
    @synchronized (self) { [self.buffer appendData:data]; }
}

- (void)URLRequest:(id)token didCompleteWithError:(NSError *)error {
    if (!error) {
        NSData *body;
        @synchronized (self) { body = [self.buffer copy]; }
        body = FBPMarketplaceFilterResponse(body, self.name);
        if (body.length) [self.realDelegate URLRequest:token didReceiveData:body];
    }
    [self.realDelegate URLRequest:token didCompleteWithError:error];
    @synchronized (FBPMarketplaceLiveDelegates()) {
        [FBPMarketplaceLiveDelegates() removeObject:self];
    }
}

@end

// Per-request wrapper around the handler RCTNetworking picked, so the response can
// be buffered and filtered before it reaches Relay.
@interface FBPMarketplaceFilteringHandler : NSObject
@property (nonatomic, strong) id inner;
@property (nonatomic, copy) NSString *name;
@end

@implementation FBPMarketplaceFilteringHandler

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.inner respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.inner; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate {
    FBPMarketplaceFilteringDelegate *proxy = [FBPMarketplaceFilteringDelegate new];
    proxy.realDelegate = delegate;
    proxy.name = self.name;
    proxy.buffer = [NSMutableData data];
    @synchronized (FBPMarketplaceLiveDelegates()) {
        [FBPMarketplaceLiveDelegates() addObject:proxy];
    }
    return [self.inner sendRequest:request withDelegate:proxy];
}

@end

#pragma mark Marketplace — hook

%group FBPMarketplaceAds

%hook RCTNetworking

- (id)handlerForRequest:(NSURLRequest *)request {
    // Zero overhead and full fidelity when Remove Ads is off.
    if (!FBPEnabled(FBPKeyNoAds)) return %orig;

    NSString *name = FBPMarketplaceFriendlyName(request);

    if (FBPMarketplaceIsAdQuery(name)) {
        FBPLog(@"marketplace: blocked %@", name);
        return [FBPMarketplaceBlockingHandler shared];
    }

    id handler = %orig;
    if (handler && FBPMarketplaceIsFeedQuery(name)) {
        FBPMarketplaceFilteringHandler *wrapper = [FBPMarketplaceFilteringHandler new];
        wrapper.inner = handler;
        wrapper.name = name;
        return wrapper;
    }
    return handler;
}

%end

%end // FBPMarketplaceAds

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

    // RCTNetworking lives in FBReactNativeProductsFramework, which Facebook dlopens
    // on demand — so this installer is re-run from the dyld image-load callback and
    // latches once the class finally arrives.
    Class networking = objc_getClass("RCTNetworking");
    if (networking && [networking instancesRespondToSelector:@selector(handlerForRequest:)]) {
        FBP_ONCE(gMarketplaceAds) { %init(FBPMarketplaceAds); }
    }
}
