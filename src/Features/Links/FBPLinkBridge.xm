// Link bridge: open inbound Facebook links at their exact destination instead of
// landing on Home.
//
// On a sideloaded / re-signed build, a Facebook web link reaching the app from
// the outside does not reliably resolve a Reel/post/photo/story and falls back
// to the News Feed. Three outside sources matter, and all three end up as one of
// two shapes the app mishandles on these builds:
//
//   1. Our "Open in Facebook" Safari extension, which hands us the clean HTTPS
//      URL through our own registered route:  fb://fbplusbridge?url=<https url>
//
//   2. Messenger (and other Meta apps), which resolve a shared link through an
//      app-link / FaceWeb step and open the app with either
//        * a FaceWeb deep link:  fb://faceweb…?href=<https url>  (or ?url=…), or
//        * a plain Facebook universal link:  https://m.facebook.com/…  etc.
//      Messenger also wraps shared links in LinkShim (l.facebook.com/l.php?u=…).
//
// This hook normalizes all of those to a canonical https://www.facebook.com URL
// and feeds it to the app's browsing-web NSUserActivity handler — the same path
// a real Universal Link takes — so Facebook resolves it to the intended screen.
//
// It deliberately does NOT touch structured native deep links (fb://story?…,
// fb://group?id=…, fb://profile, fb://notifications, tapped-notification
// routing): those already resolve correctly and are passed straight through.
//
// Installed from FBPEntry's repeated image-load pass: FBBaseAppDelegate may not
// exist yet when the tweak first loads, so the installer simply no-ops until the
// class is present and then latches with FBP_ONCE.

#import "FBPlus.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/// Our own bridge route. Reached as fb://fbplusbridge?url=… — the fb scheme is
/// already registered by the app, so no extra Info.plist entry is needed; we
/// only own the "fbplusbridge" host.
static NSString *const kFBPBridgeScheme = @"fb";
static NSString *const kFBPBridgeHost   = @"fbplusbridge";

static BOOL FBPIsFacebookHost(NSString *host) {
    if (!host.length) return NO;
    host = host.lowercaseString;
    return [host isEqualToString:@"facebook.com"] || [host hasSuffix:@".facebook.com"];
}

/// Pull the first query item named any of `names` out of a URL.
static NSString *FBPQueryValue(NSURL *url, NSArray<NSString *> *names) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                            resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
                return item.value;
            }
        }
    }
    return nil;
}

/// Unwrap Facebook's LinkShim redirector (…facebook.com/l.php?u=<real url>, also
/// seen as /l/?u= and ?url=). Returns the inner URL, or the input unchanged.
static NSURL *FBPUnwrapLinkShim(NSURL *url) {
    if (!FBPIsFacebookHost(url.host)) return url;
    NSString *path = url.path.lowercaseString ?: @"";
    if (![path isEqualToString:@"/l.php"] && ![path hasPrefix:@"/l/"]) return url;

    NSString *inner = FBPQueryValue(url, @[ @"u", @"url" ]);
    if (!inner.length) return url;
    NSURL *innerURL = [NSURL URLWithString:inner];
    return innerURL ?: url;
}

/// Canonicalize any Facebook web URL to https://www.facebook.com/… keeping
/// path/query/fragment so Reels, posts, story.php, permalink.php, groups,
/// watch/share URLs keep their identity. Returns nil for non-Facebook or
/// non-http(s) URLs (so the caller passes them through untouched).
static NSURL *FBPCanonicalFacebookURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return nil;

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;

    url = FBPUnwrapLinkShim(url);
    if (!FBPIsFacebookHost(url.host)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                            resolvingAgainstBaseURL:NO];
    components.scheme = @"https";
    components.host = @"www.facebook.com";
    return components.URL ?: url;
}

/// If this is a FaceWeb-style fb:// deep link carrying an embedded web URL
/// (fb://faceweb…?href=… or ?url=…), return that embedded URL; otherwise nil.
static NSURL *FBPHrefFromFaceWeb(NSURL *url) {
    if ([url.scheme.lowercaseString isEqualToString:@"fb"]) {
        NSString *host = url.host.lowercaseString ?: @"";
        if ([host isEqualToString:@"faceweb"] ||
            [host isEqualToString:@"facewebmodal"] ||
            [host isEqualToString:@"web"]) {
            NSString *embedded = FBPQueryValue(url, @[ @"href", @"url" ]);
            if (embedded.length) return [NSURL URLWithString:embedded];
        }
    }
    return nil;
}

/// Resolve an incoming URL to the canonical Facebook destination we should route,
/// or nil to leave the URL for the app's original handler.
static NSURL *FBPBridgeTargetURL(NSURL *incomingURL) {
    if (![incomingURL isKindOfClass:NSURL.class]) return nil;

    NSString *scheme = incomingURL.scheme.lowercaseString ?: @"";
    NSString *host = incomingURL.host.lowercaseString ?: @"";

    // 1. Our own Safari-extension route.
    if ([scheme isEqualToString:kFBPBridgeScheme] && [host isEqualToString:kFBPBridgeHost]) {
        NSString *target = FBPQueryValue(incomingURL, @[ @"url" ]);
        return target.length ? FBPCanonicalFacebookURL([NSURL URLWithString:target]) : nil;
    }

    // 2. A FaceWeb deep link wrapping a web URL (Messenger / other Meta apps).
    NSURL *href = FBPHrefFromFaceWeb(incomingURL);
    if (href) return FBPCanonicalFacebookURL(href);

    // 3. A plain Facebook web/universal link arriving through openURL.
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        return FBPCanonicalFacebookURL(incomingURL);
    }

    // Anything else (structured fb:// deep links, other schemes) is left alone.
    return nil;
}

/// Hand a canonical Facebook URL to the app's browsing-web Universal Link handler.
static BOOL FBPRouteThroughUniversalLink(id delegate, UIApplication *application, NSURL *targetURL) {
    SEL universalLinkSelector =
        NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
    if (![delegate respondsToSelector:universalLinkSelector]) return NO;

    NSUserActivity *activity =
        [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = targetURL;

    void (^restorationHandler)(NSArray *) = ^(NSArray *restorableObjects) {
        (void)restorableObjects;
    };

    BOOL (*sendUniversalLink)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) =
        (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))objc_msgSend;

    return sendUniversalLink(delegate, universalLinkSelector, application, activity,
                             restorationHandler);
}

%group FBPLinkBridge

%hook FBBaseAppDelegate

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary *)options {
    NSURL *targetURL = FBPBridgeTargetURL(url);
    if (!targetURL) return %orig;

    // `self` is typed as the forward-declared FBBaseAppDelegate here, so route
    // the dynamic call through an untyped id.
    id delegate = self;
    if (FBPRouteThroughUniversalLink(delegate, application, targetURL)) return YES;
    return %orig;
}

- (BOOL)application:(UIApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(id)restorationHandler {
    // A real Universal Link (e.g. Messenger opening m.facebook.com). Rewrite the
    // host to the canonical www form before the app routes it, so mobile/web
    // host variants do not degrade to Home. Non-Facebook activities untouched.
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        NSURL *canonical = FBPCanonicalFacebookURL(userActivity.webpageURL);
        if (canonical && ![canonical isEqual:userActivity.webpageURL]) {
            userActivity.webpageURL = canonical;
        }
    }
    return %orig;
}

%end

%end // FBPLinkBridge

void FBPInitLinkBridge(void) {
    if (objc_getClass("FBBaseAppDelegate")) {
        FBP_ONCE(gLinkBridge) { %init(FBPLinkBridge); }
    }
}
