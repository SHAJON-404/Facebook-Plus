#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
#import "FBPResources.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdint.h>
#import <string.h>
#import <math.h>

#pragma mark - Globals

static void (*gOriginalDidStartPlayback)(
    id, SEL, id, int64_t, id, id
) = NULL;

static void (*gOriginalSidebarDidMoveToWindow)(
    id, SEL
) = NULL;

static void (*gOriginalPlayerViewWillAppear)(
    id, SEL, BOOL
) = NULL;

static void (*gOriginalPlayerViewDidDisappear)(
    id, SEL, BOOL
) = NULL;

static NSURL *gCurrentDownloadURL = nil;
static NSString *gCurrentVideoID = nil;

static void (*gOriginalHitTestLayoutSubviews)(
    id, SEL
) = NULL;

static BOOL gPlayerHookInstalled = NO;
static BOOL gSidebarHookInstalled = NO;
static BOOL gLifecycleHooksInstalled = NO;
static BOOL gHitTestHookInstalled = NO;

static __weak id gMediaOwnerPlayerVC = nil;

static const NSInteger kFBPDownloadButtonTag =
    0x46425044;

static const NSInteger kFBPHideOverlayButtonTag =
    0x46425048;

// Vertical gap between the download button and the hide-overlay toggle stacked
// above it.
static const CGFloat kFBPButtonGap = 10.0;

static NSHashTable<UIView *> *gSidebars = nil;

#pragma mark - Hide-overlay state

// Session-only "cinema mode": while YES, every Reel's chrome (gradients,
// caption, author, and the whole like/comment/share/save/more sidebar) is
// hidden, leaving only the video plus our own download + toggle buttons. The
// user turns it on/off with the eye toggle; it persists across reel swipes
// until they untoggle, and resets to shown on relaunch.
static BOOL gOverlayHidden = NO;

// The overlay container views we have hidden, held weakly so recycled
// ComponentKit views don't keep us alive. Used to restore them on untoggle.
static NSHashTable<UIView *> *gHiddenOverlays = nil;

// Marks a view as hidden by us (not by Facebook) so the sidebar-visibility
// check can tell "the reel left the screen" apart from "we stripped its chrome".
static const void *kFBPHiddenByUsKey = &kFBPHiddenByUsKey;

static BOOL FBPViewHiddenByUs(UIView *view) {
    return [objc_getAssociatedObject(view, kFBPHiddenByUsKey) boolValue];
}

static void FBPSetViewHiddenByUs(UIView *view, BOOL hidden) {
    objc_setAssociatedObject(
        view,
        kFBPHiddenByUsKey,
        hidden ? @YES : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

// Walk up from a sidebar to the Shorts overlay container that holds every chrome
// element. Matched by class-name substring because it is a Swift class whose
// mangled ObjC name is not stable to hardcode. The video is rendered by an
// ancestor OUTSIDE this view, so hiding it never touches the video.
static UIView *FBPOverlayForSidebar(UIView *sidebar) {
    UIView *view = sidebar;
    while (view) {
        if ([NSStringFromClass([view class])
                containsString:@"ShortsViewerOverlay"]) {
            return view;
        }
        view = view.superview;
    }
    return nil;
}

// Hide the overlay container of every Reel currently laid out in this window.
// Re-run each frame so a reel swiped in while hide-mode is on is stripped too.
static void FBPHideOverlaysForWindow(UIWindow *window) {
    if (!window || !gSidebars)
        return;

    if (!gHiddenOverlays)
        gHiddenOverlays = [NSHashTable weakObjectsHashTable];

    for (UIView *sidebar in gSidebars.allObjects) {
        if (sidebar.window != window)
            continue;

        UIView *overlay = FBPOverlayForSidebar(sidebar);
        if (!overlay)
            continue;

        if (!overlay.hidden)
            overlay.hidden = YES;

        FBPSetViewHiddenByUs(overlay, YES);
        [gHiddenOverlays addObject:overlay];
    }
}

// Hide the Shorts overlay component(s) parented by a given container (the
// hit-test view). Used from the synchronous layout hook so a reel swiped in is
// stripped in the same layout pass Facebook re-shows it — no one-frame flash.
static void FBPHideOverlayChildrenOf(UIView *container) {
    if (!container)
        return;

    if (!gHiddenOverlays)
        gHiddenOverlays = [NSHashTable weakObjectsHashTable];

    for (UIView *sub in container.subviews) {
        if (![NSStringFromClass([sub class])
                containsString:@"ShortsViewerOverlay"])
            continue;

        if (!sub.hidden)
            sub.hidden = YES;

        FBPSetViewHiddenByUs(sub, YES);
        [gHiddenOverlays addObject:sub];
    }
}

// Restore every overlay we hid and forget them.
static void FBPUnhideAllOverlays(void) {
    if (!gHiddenOverlays)
        return;

    for (UIView *overlay in gHiddenOverlays.allObjects) {
        if (!overlay)
            continue;
        FBPSetViewHiddenByUs(overlay, NO);
        overlay.hidden = NO;
    }

    [gHiddenOverlays removeAllObjects];
}

#pragma mark - Tab bar (cinema mode)

// While cinema mode is on, the bottom tab bar is faded out along with the rest of
// the Reels chrome, then restored on untoggle or on leaving Reels. Held strongly
// only while hidden so we can always restore their alpha; cleared on restore.
static NSMutableSet<UIView *> *gHiddenTabBars = nil;

// Every view that makes up the bottom tab bar's chrome — the icon rows AND the
// separate background/material/safe-area fills behind them — matched by exact
// class so content is never touched. Hiding only the icon row left the glass
// background (FBFloatingTabBarContainerMaterial) as a visible placeholder, so the
// whole set is listed. "…AndContentView" is deliberately absent: it wraps the
// entire screen, not just the bar. Covers the classic bar and the iOS 26
// liquid-glass bars (floating / native).
static BOOL FBPIsTabBarContainer(UIView *view) {
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"FBTabBarContainerView", @"FBTabBarFloatableContainerView",
            @"FBTabBarSafeAreaProtectionView", @"FBTabBarVideoSamplingView",
            @"FBTabBarVideoSamplingBlurView", @"FBTabBarTransitionView", @"FBTabBar",
            @"FBFloatingTabBar", @"FBFloatingTabBarContainerMaterial",
            @"FBFloatingTabBarItemView", @"FBNativeTabBar",
        ]];
    });
    return [names containsObject:NSStringFromClass(view.class)];
}

// Walk the whole window tree, collecting every tab-bar chrome view (icons and
// backgrounds may be siblings, so we don't stop at the first match).
static void FBPCollectTabBars(UIView *root, NSMutableArray<UIView *> *out, NSInteger depth) {
    if (!root || depth > 80) return;
    if (FBPIsTabBarContainer(root)) [out addObject:root];
    for (UIView *sub in root.subviews) FBPCollectTabBars(sub, out, depth + 1);
}

// Fade the window's tab bar(s) out and remember them.
static void FBPHideTabBars(UIWindow *window) {
    if (!window) return;
    if (!gHiddenTabBars) gHiddenTabBars = [NSMutableSet set];
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    FBPCollectTabBars(window, bars, 0);
    for (UIView *bar in bars) {
        [gHiddenTabBars addObject:bar];
        bar.userInteractionEnabled = NO;
        bar.alpha = 0.0;
    }
}

// Cheap per-frame top-up: keep already-found bars faded without re-walking the
// tree (Facebook's own scroll-driven offset animations don't touch alpha, so one
// search per enter is enough, but this guards against a stray reset).
static void FBPReassertHiddenTabBars(void) {
    if (!gHiddenTabBars) return;
    for (UIView *bar in gHiddenTabBars) {
        if (bar.window && bar.alpha > 0.01) bar.alpha = 0.0;
    }
}

// Restore every tab bar we faded and forget them.
static void FBPShowTabBars(void) {
    if (!gHiddenTabBars || gHiddenTabBars.count == 0) return;
    for (UIView *bar in gHiddenTabBars) {
        bar.alpha = 1.0;
        bar.userInteractionEnabled = YES;
    }
    [gHiddenTabBars removeAllObjects];
}

#pragma mark - Runtime helpers

static id FBPSafeObjectGetter(
    id object,
    NSString *getterName
) {
    if (!object || !getterName)
        return nil;

    SEL selector =
        NSSelectorFromString(getterName);

    Method method =
        class_getInstanceMethod(
            [object class],
            selector
        );

    if (!method)
        return nil;

    if (method_getNumberOfArguments(method) != 2)
        return nil;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == '@';

    if (returnType)
        free(returnType);

    if (!valid)
        return nil;

    @try {

        id (*sendObject)(id, SEL) =
            (id (*)(id, SEL))objc_msgSend;

        return sendObject(
            object,
            selector
        );

    } @catch (__unused NSException *e) {

        return nil;
    }
}

static NSURL *FBPURLFromObject(id object) {

    if (!object)
        return nil;

    if ([object
        isKindOfClass:
            [NSURL class]]) {

        return object;
    }

    if ([object
        isKindOfClass:
            [NSString class]]) {

        return [NSURL
            URLWithString:object];
    }

    return nil;
}

static NSURL *FBPPlaybackURLFromItem(id item, NSString **videoIDOut) {
    if (!item) return nil;

    NSURL *hdURL = FBPURLFromObject(FBPSafeObjectGetter(item, @"HDPlaybackURL"));
    NSURL *sdURL = FBPURLFromObject(FBPSafeObjectGetter(item, @"SDPlaybackURL"));
    NSURL *chosen = hdURL ?: sdURL;

    if (videoIDOut) {
        id rawID = FBPSafeObjectGetter(item, @"videoID");
        if ([rawID isKindOfClass:[NSString class]]) {
            *videoIDOut = [(NSString *)rawID copy];
        } else if (rawID) {
            *videoIDOut = [[rawID description] copy];
        } else {
            *videoIDOut = nil;
        }
    }

    return chosen;
}

static UIViewController *FBPFindControllerOfClass(UIViewController *vc, Class targetClass) {
    if (!vc || !targetClass) return nil;
    if ([vc isKindOfClass:targetClass]) return vc;

    UIViewController *found = FBPFindControllerOfClass(vc.presentedViewController, targetClass);
    if (found) return found;

    for (UIViewController *child in vc.childViewControllers) {
        found = FBPFindControllerOfClass(child, targetClass);
        if (found) return found;
    }

    return nil;
}

#pragma mark - Top VC

static UIViewController *
FBPTopViewController(void) {

    UIWindow *keyWindow = nil;

    for (UIScene *scene in
         [UIApplication sharedApplication]
             .connectedScenes) {

        if (scene.activationState !=
            UISceneActivationStateForegroundActive)
            continue;

        if (![scene
            isKindOfClass:
                [UIWindowScene class]])
            continue;

        UIWindowScene *windowScene =
            (UIWindowScene *)scene;

        for (UIWindow *window
             in windowScene.windows) {

            if (window.isKeyWindow) {

                keyWindow = window;
                break;
            }
        }

        if (keyWindow)
            break;
    }

    if (!keyWindow)
        return nil;

    UIViewController *vc =
        keyWindow.rootViewController;

    while (YES) {

        if (vc.presentedViewController) {

            vc =
                vc.presentedViewController;

            continue;
        }

        if ([vc
            isKindOfClass:
                [UINavigationController class]]) {

            UIViewController *next =
                [(UINavigationController *)vc
                    visibleViewController];

            if (next) {

                vc = next;
                continue;
            }
        }

        if ([vc
            isKindOfClass:
                [UITabBarController class]]) {

            UIViewController *next =
                [(UITabBarController *)vc
                    selectedViewController];

            if (next) {

                vc = next;
                continue;
            }
        }

        break;
    }

    return vc;
}

#pragma mark - Alert

static void FBPShowMessage(
    NSString *title,
    NSString *message
) {
    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *vc =
            FBPTopViewController();

        if (!vc)
            return;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:title
                message:message
                preferredStyle:
                    UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:FBPL(@"common.ok")
                style:
                    UIAlertActionStyleDefault
                handler:nil]];

        [vc
            presentViewController:alert
                         animated:YES
                       completion:nil];
    });
}

#pragma mark - Progress UI

@interface FBPDownloadProgressController :
    UIViewController

@property(nonatomic, strong)
    UIActivityIndicatorView *spinner;

@property(nonatomic, strong)
    UIProgressView *progressView;

@property(nonatomic, strong)
    UILabel *percentLabel;

@property(nonatomic, strong)
    UILabel *titleLabel;

@property(nonatomic, strong)
    UIImageView *checkmarkView;

- (void)setProgressValue:(float)value;
- (void)showSuccessWithTitle:(NSString *)title;

@end

@implementation FBPDownloadProgressController

- (void)viewDidLoad {

    [super viewDidLoad];

    // Clear background so the hosting alert's vibrant blur shows through instead
    // of a flat fill — the "premium" material look.
    self.view.backgroundColor = UIColor.clearColor;

    self.preferredContentSize = CGSizeMake(272.0, 172.0);

    // Spinner — large for presence, tinted to the label colour.
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = UIColor.labelColor;
    [self.spinner startAnimating];

    // Success checkmark, shown only once the save completes.
    UIImageSymbolConfiguration *checkCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:40.0
                                                        weight:UIImageSymbolWeightSemibold];
    self.checkmarkView = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"
                              withConfiguration:checkCfg]];
    self.checkmarkView.translatesAutoresizingMaskIntoConstraints = NO;
    self.checkmarkView.tintColor = UIColor.systemGreenColor;
    self.checkmarkView.contentMode = UIViewContentModeScaleAspectFit;
    self.checkmarkView.hidden = YES;

    // Title — rounded, wraps to two lines so longer strings never truncate.
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = FBPL(@"download.reel.progress");
    self.titleLabel.font = FBPFont(16.0, UIFontWeightSemibold);
    self.titleLabel.textColor = UIColor.labelColor;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.85;

    // Progress bar — accent-tinted, thicker and rounded.
    self.progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0.0f;
    self.progressView.progressTintColor = UIColor.systemBlueColor;
    self.progressView.trackTintColor =
        [UIColor.labelColor colorWithAlphaComponent:0.12];
    self.progressView.transform = CGAffineTransformMakeScale(1.0, 1.6);
    self.progressView.clipsToBounds = YES;
    self.progressView.layer.cornerRadius = 3.0;

    // Percent — rounded, monospaced digits so it doesn't jitter as it counts.
    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.text = @"0%";
    self.percentLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.percentLabel.textColor = UIColor.secondaryLabelColor;
    self.percentLabel.textAlignment = NSTextAlignmentCenter;

    [self.view addSubview:self.spinner];
    [self.view addSubview:self.checkmarkView];
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.progressView];
    [self.view addSubview:self.percentLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.topAnchor
            constraintEqualToAnchor:self.view.topAnchor constant:24.0],
        [self.spinner.centerXAnchor
            constraintEqualToAnchor:self.view.centerXAnchor],

        [self.checkmarkView.centerXAnchor
            constraintEqualToAnchor:self.spinner.centerXAnchor],
        [self.checkmarkView.centerYAnchor
            constraintEqualToAnchor:self.spinner.centerYAnchor],

        [self.titleLabel.topAnchor
            constraintEqualToAnchor:self.spinner.bottomAnchor constant:14.0],
        [self.titleLabel.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [self.titleLabel.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],

        [self.progressView.topAnchor
            constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:18.0],
        [self.progressView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor constant:28.0],
        [self.progressView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor constant:-28.0],

        [self.percentLabel.topAnchor
            constraintEqualToAnchor:self.progressView.bottomAnchor constant:12.0],
        [self.percentLabel.centerXAnchor
            constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (void)setProgressValue:(float)value {

    value =
        MAX(
            0.0f,
            MIN(1.0f, value)
        );

    dispatch_async(
        dispatch_get_main_queue(), ^{

        [self.progressView
            setProgress:value
               animated:YES];

        NSInteger percent =
            (NSInteger)lrintf(
                value * 100.0f);

        self.percentLabel.text =
            [NSString
                stringWithFormat:
                    @"%ld%%",
                    (long)percent];

        if (percent >= 100) {

            self.titleLabel.text =
                FBPL(@"download.reel.saving");
        }
    });
}

// Morphs the card into a success state: the spinner and percent give way to a
// green checkmark, the bar fills green. Used in place of a separate confirmation
// alert so the whole flow reads as one premium HUD.
- (void)showSuccessWithTitle:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        self.spinner.hidden = YES;
        self.percentLabel.hidden = YES;

        self.progressView.progressTintColor = UIColor.systemGreenColor;
        [self.progressView setProgress:1.0f animated:YES];

        self.titleLabel.text = title;

        self.checkmarkView.hidden = NO;
        self.checkmarkView.transform = CGAffineTransformMakeScale(0.6, 0.6);
        self.checkmarkView.alpha = 0.0;
        [UIView animateWithDuration:0.28
                              delay:0.0
             usingSpringWithDamping:0.6
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.checkmarkView.transform = CGAffineTransformIdentity;
            self.checkmarkView.alpha = 1.0;
        } completion:nil];
    });
}

@end

#pragma mark - Download manager

@interface FBPReelDownloadManager :
    NSObject
    <NSURLSessionDownloadDelegate>

@property(nonatomic, strong)
    NSURLSession *session;

@property(nonatomic, strong)
    NSURLSessionDownloadTask *task;

@property(nonatomic, strong)
    FBPDownloadProgressController
        *progressController;

@property(nonatomic, strong)
    UIViewController *progressContainer;

@property(nonatomic, copy)
    NSString *videoID;

@property(nonatomic, assign)
    BOOL downloading;

+ (instancetype)shared;

- (void)startDownloadWithURL:
    (NSURL *)url
    videoID:
    (NSString *)videoID;

@end

@implementation FBPReelDownloadManager

+ (instancetype)shared {

    static FBPReelDownloadManager *manager =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        manager =
            [[FBPReelDownloadManager alloc]
                init];
    });

    return manager;
}

- (void)showProgress {

    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *presenter =
            FBPTopViewController();

        if (!presenter)
            return;

        FBPDownloadProgressController
            *progress =
                [[FBPDownloadProgressController
                    alloc] init];

        UIAlertController *container =
            [UIAlertController
                alertControllerWithTitle:nil
                message:nil
                preferredStyle:
                    UIAlertControllerStyleAlert];

        @try {

            [container
                setValue:progress
                forKey:
                    @"contentViewController"];

        } @catch (__unused NSException *e) {

        }

        self.progressController =
            progress;

        self.progressContainer =
            container;

        [presenter
            presentViewController:container
                         animated:YES
                       completion:nil];
    });
}

- (void)dismissProgressWithCompletion:
    (void (^)(void))completion {

    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *container =
            self.progressContainer;

        self.progressController =
            nil;

        self.progressContainer =
            nil;

        if (container &&
            container
                .presentingViewController) {

            [container
                dismissViewControllerAnimated:YES
                                   completion:
                    completion];

        } else if (completion) {

            completion();
        }
    });
}

- (void)finishWithError:
    (NSString *)message {

    self.downloading =
        NO;

    [self.session
        invalidateAndCancel];

    self.session =
        nil;

    self.task =
        nil;

    [self
        dismissProgressWithCompletion:^{

        FBPShowMessage(
            FBPL(@"download.appName"),
            message ?:
                FBPL(@"download.reel.failed")
        );
    }];
}

- (void)saveVideo:
    (NSURL *)fileURL {


    [[PHPhotoLibrary
        sharedPhotoLibrary]
        performChanges:^{

        [PHAssetChangeRequest
            creationRequestForAssetFromVideoAtFileURL:
                fileURL];

    } completionHandler:^(
        BOOL success,
        NSError *error
    ) {

        [[NSFileManager
            defaultManager]
            removeItemAtURL:fileURL
                     error:nil];

        self.downloading =
            NO;

        [self.session
            finishTasksAndInvalidate];

        self.session =
            nil;

        self.task =
            nil;

        if (success) {

            // Morph the progress card into a success checkmark, hold briefly so
            // it registers, then dismiss — no separate confirmation alert.
            [self.progressController
                showSuccessWithTitle:FBPL(@"download.reel.saved")];

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                [self dismissProgressWithCompletion:nil];
            });

        } else {


            [self
                dismissProgressWithCompletion:^{

                FBPShowMessage(
                    FBPL(@"download.appName"),
                    [NSString
                        stringWithFormat:
                            FBPL(@"download.reel.saveFailed"),
                        error.localizedDescription
                            ?: FBPL(@"download.error.unknown")]
                );
            }];
        }
    }];
}

- (void)startDownloadWithURL:
    (NSURL *)url
    videoID:
    (NSString *)videoID {

    if (!url)
        return;

    if (self.downloading) {

        FBPShowMessage(
            FBPL(@"download.appName"),
            FBPL(@"download.reel.inProgress")
        );

        return;
    }

    self.downloading =
        YES;

    self.videoID =
        videoID ?: @"unknown";




    [self showProgress];

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration
            defaultSessionConfiguration];

    config.requestCachePolicy =
        NSURLRequestReloadIgnoringLocalCacheData;

    config.timeoutIntervalForRequest =
        60.0;

    config.timeoutIntervalForResource =
        180.0;

    NSOperationQueue *queue =
        [[NSOperationQueue alloc]
            init];

    queue.maxConcurrentOperationCount =
        1;

    self.session =
        [NSURLSession
            sessionWithConfiguration:config
            delegate:self
            delegateQueue:queue];

    NSMutableURLRequest *request =
        [NSMutableURLRequest
            requestWithURL:url
            cachePolicy:
                NSURLRequestReloadIgnoringLocalCacheData
            timeoutInterval:60.0];

    request.HTTPMethod =
        @"GET";

    self.task =
        [self.session
            downloadTaskWithRequest:
                request];

    [self.task resume];
}

- (void)URLSession:
    (NSURLSession *)session
    downloadTask:
    (NSURLSessionDownloadTask *)downloadTask
    didWriteData:
    (int64_t)bytesWritten
    totalBytesWritten:
    (int64_t)totalBytesWritten
    totalBytesExpectedToWrite:
    (int64_t)totalBytesExpectedToWrite {

    if (totalBytesExpectedToWrite <= 0)
        return;

    float progress =
        (float)totalBytesWritten /
        (float)totalBytesExpectedToWrite;

    [self.progressController
        setProgressValue:progress];
}

- (void)URLSession:
    (NSURLSession *)session
    downloadTask:
    (NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:
    (NSURL *)location {

    NSHTTPURLResponse *response =
        [downloadTask.response
            isKindOfClass:
                [NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)
            downloadTask.response
        : nil;

    NSInteger status =
        response
        ? response.statusCode
        : 0;


    if (status < 200 ||
        status >= 300) {

        [self
            finishWithError:
                [NSString
                    stringWithFormat:
                        FBPL(@"download.reel.httpError"),
                        (long)status]];

        return;
    }

    NSString *filename =
        [NSString
            stringWithFormat:
                @"FBP-Reel-%@.mp4",
                self.videoID
                    ?: @"unknown"];

    NSString *path =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                filename];

    NSURL *destination =
        [NSURL
            fileURLWithPath:path];

    NSFileManager *fm =
        [NSFileManager
            defaultManager];

    [fm
        removeItemAtURL:destination
                 error:nil];

    NSError *moveError =
        nil;

    BOOL moved =
        [fm moveItemAtURL:location
                    toURL:destination
                    error:&moveError];

    if (!moved) {


        [self
            finishWithError:
                FBPL(@"download.reel.tmpFailed")];

        return;
    }



    [self.progressController
        setProgressValue:1.0f];

    [self saveVideo:destination];
}

- (void)URLSession:
    (NSURLSession *)session
    task:
    (NSURLSessionTask *)task
    didCompleteWithError:
    (NSError *)error {

    if (!error)
        return;


    [self
        finishWithError:
            [NSString
                stringWithFormat:
                    FBPL(@"download.reel.failedDetail"),
                error.localizedDescription
                    ?: FBPL(@"download.error.unknown")]];
}

@end


#pragma mark - Active playback fallback

static id FBPObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;

    for (Class cls = object_getClass(object);
         cls;
         cls = class_getSuperclass(cls)) {

        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;

        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *e) {
            return nil;
        }
    }

    return nil;
}

static BOOL FBPCaptureActivePlaybackController(UIButton *sender) {
    UIWindow *window = sender.window;
    if (!window) return NO;

    Class playerClass =
        NSClassFromString(@"FBVideoHomeUnifiedPlayerViewController");
    if (!playerClass) return NO;

    UIViewController *playerVC =
        FBPFindControllerOfClass(
            window.rootViewController,
            playerClass
        );
    if (!playerVC) return NO;

    id feedVC =
        FBPObjectIvar(playerVC, "_feedViewController");

    id autoAdvance =
        FBPObjectIvar(feedVC, "_feedAutoAdvanceController");

    id monitor =
        FBPObjectIvar(autoAdvance, "_currentVideoMonitor");

    id playbackController =
        FBPSafeObjectGetter(
            monitor,
            @"activePlaybackController"
        );
    if (!playbackController) return NO;

    id item =
        FBPSafeObjectGetter(
            playbackController,
            @"currentVideoPlaybackItem"
        );
    if (!item) return NO;

    NSString *videoID = nil;
    NSURL *url =
        FBPPlaybackURLFromItem(
            item,
            &videoID
        );
    if (!url) return NO;

    @synchronized([NSFileManager class]) {
        gCurrentDownloadURL = url;
        gCurrentVideoID = [videoID copy];
        gMediaOwnerPlayerVC = playerVC;
    }

    return YES;
}

#pragma mark - Button handler

@interface FBPReelDownloadHandler :
    NSObject

+ (instancetype)shared;

- (void)downloadTouchDown:
    (UIButton *)sender;

- (void)downloadTouchFinished:
    (UIButton *)sender;

- (void)downloadButtonPressed:
    (UIButton *)sender;

- (void)hideOverlayButtonPressed:
    (UIButton *)sender;

@end

// Forward declaration — defined with the window-button helpers below.
static void FBPUpdateHideOverlayButtonIcon(UIButton *button);

@implementation FBPReelDownloadHandler

+ (instancetype)shared {

    static FBPReelDownloadHandler *handler =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        handler =
            [[FBPReelDownloadHandler alloc]
                init];
    });

    return handler;
}

- (void)downloadTouchDown:
    (UIButton *)sender {

    sender.alpha =
        0.45;
}

- (void)downloadTouchFinished:
    (UIButton *)sender {

    sender.alpha =
        1.0;
}

- (void)downloadButtonPressed:
    (UIButton *)sender {

    sender.alpha = 1.0;

    NSURL *url = nil;
    NSString *videoID = nil;

    @synchronized([NSFileManager class]) {
        url = gCurrentDownloadURL;
        videoID = [gCurrentVideoID copy];
    }

    /*
     * Reels/swipe normally arrive through didStartPlayback.
     * The first video opened from Home can already be playing before that
     * callback reaches this controller, so resolve Facebook's active playback
     * controller on demand when the user actually taps Download.
     */
    if (!url &&
        FBPCaptureActivePlaybackController(sender)) {

        @synchronized([NSFileManager class]) {
            url = gCurrentDownloadURL;
            videoID = [gCurrentVideoID copy];
        }
    }

    if (!url) {
        FBPShowMessage(
            FBPL(@"download.appName"),
            FBPL(@"download.reel.noLink")
        );
        return;
    }

    [[FBPReelDownloadManager shared]
        startDownloadWithURL:url
        videoID:videoID];
}

- (void)hideOverlayButtonPressed:
    (UIButton *)sender {

    sender.alpha = 1.0;

    gOverlayHidden = !gOverlayHidden;

    UIWindow *window = sender.window;
    if (gOverlayHidden) {
        // Strip the current reel immediately so the tap feels instant; the
        // display-link tracker keeps newly-swiped reels stripped from here on.
        FBPHideOverlaysForWindow(window);
        // The bottom tab bar is chrome too, so it fades away with the rest.
        [UIView animateWithDuration:0.2 animations:^{ FBPHideTabBars(window); }];
    } else {
        FBPUnhideAllOverlays();
        [UIView animateWithDuration:0.2 animations:^{ FBPShowTabBars(); }];
    }

    FBPUpdateHideOverlayButtonIcon(sender);
}

@end

#pragma mark - Sidebar geometry

static NSArray<UIView *> *
FBPExistingSidebarControls(
    UIView *sidebar
) {
    NSMutableArray *result =
        [NSMutableArray array];

    for (UIView *view
         in sidebar.subviews) {

        if (view.hidden ||
            view.alpha < 0.05)
            continue;

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        if (CGRectIsEmpty(frame))
            continue;

        if (frame.size.width < 20.0 ||
            frame.size.height < 20.0)
            continue;

        if (frame.size.width > 100.0 ||
            frame.size.height > 120.0)
            continue;

        [result addObject:view];
    }

    return result;
}

static CGFloat
FBPDetectedSpacing(
    UIView *sidebar,
    NSArray<UIView *> *controls
) {
    if (controls.count < 2)
        return 12.0;

    NSMutableArray<NSNumber *> *centers =
        [NSMutableArray array];

    for (UIView *view in controls) {

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        [centers
            addObject:
                @(CGRectGetMidY(frame))];
    }

    [centers
        sortUsingSelector:
            @selector(compare:)];

    CGFloat best =
        CGFLOAT_MAX;

    for (NSUInteger i = 1;
         i < centers.count;
         i++) {

        CGFloat gap =
            centers[i].doubleValue -
            centers[i - 1].doubleValue;

        if (gap >= 35.0 &&
            gap <= 100.0 &&
            gap < best) {

            best =
                gap;
        }
    }

    if (best ==
        CGFLOAT_MAX)
        return 12.0;

    return MAX(
        8.0,
        MIN(
            best - 46.0,
            30.0
        )
    );
}

static BOOL
FBPFrameForSidebar(
    UIView *sidebar,
    UIWindow *window,
    CGRect *outputFrame
) {
    if (!sidebar ||
        !window ||
        sidebar.window != window ||
        sidebar.hidden ||
        sidebar.alpha < 0.05)
        return NO;

    NSArray<UIView *> *controls =
        FBPExistingSidebarControls(
            sidebar
        );

    UIView *topControl =
        nil;

    CGFloat topY =
        CGFLOAT_MAX;

    CGRect topFrame =
        CGRectZero;

    for (UIView *view
         in controls) {

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        if (CGRectGetMinY(frame)
            < topY) {

            topY =
                CGRectGetMinY(frame);

            topControl =
                view;

            topFrame =
                frame;
        }
    }

    if (!topControl)
        return NO;

    CGFloat spacing =
        FBPDetectedSpacing(
            sidebar,
            controls
        );

    CGRect desired =
        CGRectMake(
            CGRectGetMidX(
                sidebar.bounds) - 24.0,

            CGRectGetMinY(topFrame)
                - spacing
                - 48.0,

            48.0,
            48.0
        );

    CGRect frame =
        [sidebar
            convertRect:desired
            toView:window];

    if (outputFrame)
        *outputFrame =
            frame;

    return YES;
}

#pragma mark - Window button

static UIButton *
FBPGetOrCreateWindowButton(
    UIWindow *window
) {
    if (!window)
        return nil;

    UIButton *button =
        (UIButton *)
            [window
                viewWithTag:
                    kFBPDownloadButtonTag];

    if (button) {
        return button;
    }

    button =
        [UIButton
            buttonWithType:
                UIButtonTypeCustom];

    button.tag =
        kFBPDownloadButtonTag;

    button.userInteractionEnabled =
        YES;

    button.exclusiveTouch =
        YES;

    button.backgroundColor =
        [UIColor clearColor];

    UIImage *image =
        [UIImage fbp_imageNamed:@"download"];

    [button
        setImage:image
        forState:UIControlStateNormal];

    button.imageView.contentMode =
        UIViewContentModeScaleAspectFit;

    button.contentEdgeInsets =
        UIEdgeInsetsMake(9, 9, 9, 9);

    button.tintColor =
        [UIColor whiteColor];

    button.accessibilityLabel =
        FBPL(@"download.reel.a11y");

    FBPReelDownloadHandler *handler =
        [FBPReelDownloadHandler shared];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchDown:)
        forControlEvents:
            UIControlEventTouchDown];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchFinished:)
        forControlEvents:
            UIControlEventTouchCancel |
            UIControlEventTouchDragExit |
            UIControlEventTouchUpOutside];

    [button
        addTarget:handler
        action:
            @selector(downloadButtonPressed:)
        forControlEvents:
            UIControlEventTouchUpInside];

    [window addSubview:button];

    return button;
}

#pragma mark - Hide-overlay toggle button

// The glyph reflects the action the tap performs: an open eye while chrome is
// visible (tap to hide), a slashed eye while it is hidden (tap to reveal).
static void FBPUpdateHideOverlayButtonIcon(UIButton *button) {
    if (!button)
        return;

    NSString *symbol =
        gOverlayHidden ? @"eye.slash.fill" : @"eye.fill";

    UIImage *image =
        [UIImage fbp_symbolNamed:symbol
                            size:21.0
                          weight:UIImageSymbolWeightSemibold];

    [button setImage:image forState:UIControlStateNormal];
}

static UIButton *
FBPGetOrCreateHideOverlayButton(
    UIWindow *window
) {
    if (!window)
        return nil;

    UIButton *button =
        (UIButton *)
            [window
                viewWithTag:
                    kFBPHideOverlayButtonTag];

    if (button) {
        return button;
    }

    button =
        [UIButton
            buttonWithType:
                UIButtonTypeCustom];

    button.tag =
        kFBPHideOverlayButtonTag;

    button.userInteractionEnabled =
        YES;

    button.exclusiveTouch =
        YES;

    button.backgroundColor =
        [UIColor clearColor];

    // Set the image BEFORE touching -imageView so the image view is realized on
    // the main thread with its content already in place. Otherwise an
    // accessibility query of -accessibilityLabel (which internally calls
    // -imageView) can lazily build the image view on a background thread and
    // trip UIKit's main-queue assertion. This mirrors the download button.
    FBPUpdateHideOverlayButtonIcon(button);

    button.imageView.contentMode =
        UIViewContentModeScaleAspectFit;

    button.contentEdgeInsets =
        UIEdgeInsetsMake(10, 10, 10, 10);

    button.tintColor =
        [UIColor whiteColor];

    button.accessibilityLabel =
        FBPL(@"reels.hideOverlay.a11y");

    FBPReelDownloadHandler *handler =
        [FBPReelDownloadHandler shared];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchDown:)
        forControlEvents:
            UIControlEventTouchDown];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchFinished:)
        forControlEvents:
            UIControlEventTouchCancel |
            UIControlEventTouchDragExit |
            UIControlEventTouchUpOutside];

    [button
        addTarget:handler
        action:
            @selector(hideOverlayButtonPressed:)
        forControlEvents:
            UIControlEventTouchUpInside];

    [window addSubview:button];

    return button;
}

#pragma mark - Display-link tracker

@interface FBPReelButtonTracker : NSObject
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, weak) UIView *lastSidebar;
@property(nonatomic, assign) CGRect lastCandidateFrame;
@property(nonatomic, assign) BOOL hasLastCandidateFrame;
@property(nonatomic, assign) NSInteger stableFrames;
+ (instancetype)shared;
- (void)start;
- (void)registerSidebar:(UIView *)sidebar;
- (void)tick:(CADisplayLink *)link;
@end

@implementation FBPReelButtonTracker

+ (instancetype)shared {
    static FBPReelButtonTracker *tracker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracker = [[FBPReelButtonTracker alloc] init];
    });
    return tracker;
}

- (void)start {
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)registerSidebar:(UIView *)sidebar {
    if (!sidebar) return;
    if (!gSidebars) gSidebars = [NSHashTable weakObjectsHashTable];
    [gSidebars addObject:sidebar];
    [self start];
}

// Per-button show/hide. Dedupe is read off the button's own state rather than a
// shared flag, so the download button and the hide-overlay toggle can be driven
// independently.
- (void)setButton:(UIButton *)button visible:(BOOL)visible {
    if (!button) return;

    if (visible) {
        if (!button.hidden && button.alpha > 0.99 &&
            button.userInteractionEnabled) return;
        button.hidden = NO;
        button.userInteractionEnabled = YES;
        [UIView animateWithDuration:0.10
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ button.alpha = 1.0; }
                         completion:nil];
    } else {
        if (button.hidden || button.alpha < 0.01) return;
        button.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.05
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ button.alpha = 0.0; }
                         completion:^(BOOL finished) {
            if (finished && button.alpha < 0.01) button.hidden = YES;
        }];
    }
}

// Hide both overlay buttons at once (used on every "not on a reel" path).
- (void)hideButton:(UIButton *)download andToggle:(UIButton *)toggle {
    if (download) [self setButton:download visible:NO];
    if (toggle)   [self setButton:toggle   visible:NO];
}

/*
 * Find the UIScrollView that contains the sidebar. Facebook may wrap the sidebar
 * in several containers, so walk the entire superview chain rather than guessing
 * a specific class.
 */
- (UIScrollView *)scrollViewForSidebar:(UIView *)sidebar {
    UIView *view = sidebar;
    while (view) {
        if ([view isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)view;
        view = view.superview;
    }
    return nil;
}

- (BOOL)userIsDraggingSidebar:(UIView *)sidebar {
    UIScrollView *scrollView = [self scrollViewForSidebar:sidebar];
    if (!scrollView) return NO;

    UIGestureRecognizerState state = scrollView.panGestureRecognizer.state;

    return scrollView.dragging ||
           state == UIGestureRecognizerStateBegan ||
           state == UIGestureRecognizerStateChanged;
}

/*
 * The sidebar can still have a window after the user has switched to another
 * tab, so sidebar.window != nil is NOT enough to conclude that Reels is on
 * screen. Check the full ancestor chain up to the UIWindow: if any one of them
 * is hidden or has a low alpha, the sidebar is no longer the active UI.
 */
- (BOOL)sidebarHierarchyIsVisible:(UIView *)sidebar inWindow:(UIWindow *)window {
    if (!sidebar || !window || sidebar.window != window) return NO;

    UIView *view = sidebar;
    while (view && view != window) {
        if (view.hidden || view.alpha < 0.05) {
            // In hide-overlay mode we deliberately hide the Shorts overlay
            // container (an ancestor of the sidebar). That must NOT read as the
            // reel having left the screen — the reel is still there, just
            // stripped — otherwise our own buttons would vanish with it.
            if (FBPViewHiddenByUs(view)) {
                view = view.superview;
                continue;
            }
            return NO;
        }
        view = view.superview;
    }
    if (view != window) return NO;

    // A modal presented over the Reel (comment sheet, share sheet, the "..." menu,
    // or Facebook Plus settings) does not hide the sidebar in the view tree — it
    // just sits on top of it. Facebook hides its own like/comment/share controls
    // in that state, so the download button should hide too. Detect it: if the
    // window's top-most presented controller is a modal that does not contain the
    // sidebar, the Reel is covered.
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && top != window.rootViewController &&
        ![sidebar isDescendantOfView:top.view]) {
        return NO;
    }

    return YES;
}

static BOOL FBPViewControllerTreeContainsClass(UIViewController *vc, Class targetClass) {
    if (!vc || !targetClass) return NO;
    if ([vc isKindOfClass:targetClass]) return YES;
    if (vc.presentedViewController &&
        FBPViewControllerTreeContainsClass(vc.presentedViewController, targetClass)) return YES;
    if ([vc isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top && FBPViewControllerTreeContainsClass(top, targetClass)) return YES;
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
        if (selected && FBPViewControllerTreeContainsClass(selected, targetClass)) return YES;
    }
    return NO;
}

static BOOL FBPPlusSettingsIsPresented(UIWindow *window) {
    Class settingsClass = objc_getClass("FBPSettingsController");
    return settingsClass && window &&
           FBPViewControllerTreeContainsClass(window.rootViewController, settingsClass);
}

- (void)tick:(__unused CADisplayLink *)link {
    if (!gSidebars || gSidebars.count == 0) return;

    UIWindow *window = nil;
    for (UIView *sidebar in gSidebars.allObjects) {
        if (sidebar.window) { window = sidebar.window; break; }
    }
    if (!window) return;

    BOOL downloaderEnabled =
        [FBPPrefs.shared boolForKey:FBPKeyReelsDownloaderEnabled];
    BOOL hideEnabled =
        [FBPPrefs.shared boolForKey:FBPKeyReelsHideOverlay];

    UIButton *downloadButton =
        (UIButton *)[window viewWithTag:kFBPDownloadButtonTag];
    UIButton *toggleButton =
        (UIButton *)[window viewWithTag:kFBPHideOverlayButtonTag];

    // Toggle feature switched off in settings while chrome was hidden: restore
    // everything so the user is never stuck looking at a stripped reel.
    if (!hideEnabled && gOverlayHidden) {
        FBPUnhideAllOverlays();
        FBPShowTabBars();
        gOverlayHidden = NO;
        if (toggleButton) FBPUpdateHideOverlayButtonIcon(toggleButton);
    }

    // Production gate: both features OFF means no overlay at all. Also suppress
    // our floating buttons while Facebook Plus settings is presented over the
    // still-live Reels hierarchy (long-press tab case).
    if ((!downloaderEnabled && !hideEnabled) ||
        FBPPlusSettingsIsPresented(window)) {
        // Keep the tab bar faded while settings sits over an active cinema-mode
        // reel (so returning looks unchanged); otherwise restore it.
        if (gOverlayHidden && hideEnabled && FBPPlusSettingsIsPresented(window)) {
            FBPReassertHiddenTabBars();
        } else {
            FBPShowTabBars();
        }
        [self hideButton:downloadButton andToggle:toggleButton];
        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
    }

    // Keep every reel currently laid out stripped while hide-mode is on, so a
    // reel swiped in after the toggle was pressed comes up without chrome too.
    if (gOverlayHidden && hideEnabled) {
        FBPHideOverlaysForWindow(window);
    }

    CGFloat viewportMidY = CGRectGetMidY(window.bounds);
    UIView *bestSidebar = nil;
    CGRect bestButtonFrame = CGRectZero;
    CGFloat bestDistance = CGFLOAT_MAX;

    for (UIView *sidebar in gSidebars.allObjects) {
        if (![self sidebarHierarchyIsVisible:sidebar inWindow:window])
            continue;

        CGRect sidebarFrame = [sidebar convertRect:sidebar.bounds toView:window];

        /*
         * The candidate must ACTUALLY be on the current screen. An earlier
         * revision allowed a tracking area as wide as ±1 screen, so a Reels
         * sidebar that had already left the tab could still win and keep the
         * button alive like a ghost.
         */
        if (!CGRectIntersectsRect(window.bounds, sidebarFrame))
            continue;

        CGRect buttonFrame = CGRectZero;
        if (!FBPFrameForSidebar(sidebar, window, &buttonFrame)) continue;

        CGFloat distance = fabs(CGRectGetMidY(sidebarFrame) - viewportMidY);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestSidebar = sidebar;
            bestButtonFrame = buttonFrame;
        }
    }

    if (!bestSidebar) {
        // No Reel on screen (another tab, feed, etc.) — the tab bar belongs there.
        FBPShowTabBars();
        [self hideButton:downloadButton andToggle:toggleButton];
        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
    }

    // On a Reel: fade the tab bar in lock-step with cinema mode, restore it when
    // cinema mode is off.
    if (gOverlayHidden && hideEnabled) {
        if (!gHiddenTabBars || gHiddenTabBars.count == 0) FBPHideTabBars(window);
        else FBPReassertHiddenTabBars();
    } else {
        FBPShowTabBars();
    }

    // Create only the buttons whose feature is enabled; take down any button
    // whose feature was turned off in settings.
    UIButton *download =
        downloaderEnabled ? FBPGetOrCreateWindowButton(window) : nil;
    UIButton *toggle =
        hideEnabled ? FBPGetOrCreateHideOverlayButton(window) : nil;

    if (!downloaderEnabled && downloadButton)
        [self setButton:downloadButton visible:NO];
    if (!hideEnabled && toggleButton)
        [self setButton:toggleButton visible:NO];

    if (!download && !toggle) return;

    /*
     * Stop the buttons from chasing the Reel while it moves.
     *
     * - A finger dragging the UIScrollView => hide immediately, do NOT move the
     *   buttons' frames.
     * - After the finger lifts, Facebook still decelerates / snaps => the
     *   candidate keeps changing, so keep hiding.
     * - Candidate held still for 5 frames => the snap is done: set the frames
     *   ONCE and then show.
     *
     * This way the buttons never appear at an intermediate position mid-swipe.
     */
    BOOL dragging = [self userIsDraggingSidebar:bestSidebar];

    if (dragging) {
        self.stableFrames = 0;
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        [self hideButton:download andToggle:toggle];
        return;
    }

    if (!self.hasLastCandidateFrame || self.lastSidebar != bestSidebar) {
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        self.stableFrames = 0;
        [self hideButton:download andToggle:toggle];
        return;
    }

    CGFloat dx = fabs(CGRectGetMidX(bestButtonFrame) - CGRectGetMidX(self.lastCandidateFrame));
    CGFloat dy = fabs(CGRectGetMidY(bestButtonFrame) - CGRectGetMidY(self.lastCandidateFrame));

    self.lastCandidateFrame = bestButtonFrame;

    /* Deceleration / snap is still running. */
    if (dx > 0.35 || dy > 0.35) {
        self.stableFrames = 0;
        [self hideButton:download andToggle:toggle];
        return;
    }

    self.stableFrames += 1;

    /*
     * Wait for 5 genuinely still frames before showing. Do not animate the
     * position. The frames are only updated at the moment the buttons are still
     * hidden. The toggle sits one slot directly above the download button.
     */
    if (self.stableFrames >= 5) {
        CGRect base = CGRectIntegral(bestButtonFrame);

        if (download) {
            download.frame = base;
            [window bringSubviewToFront:download];
            [self setButton:download visible:YES];
        }

        if (toggle) {
            CGRect toggleFrame = base;
            toggleFrame.origin.y -= (base.size.height + kFBPButtonGap);
            toggle.frame = CGRectIntegral(toggleFrame);
            [window bringSubviewToFront:toggle];
            [self setButton:toggle visible:YES];
        }
    }
}

@end

#pragma mark - Anti-flash layout hook

// FBShortsCustomHitTestView is the container that parents the overlay component.
// It re-lays-out whenever a (recycled) cell is reconfigured for a newly-swiped
// reel — the same runloop pass in which Facebook re-shows the overlay. Re-hiding
// it here, synchronously, means the frame never renders with chrome, so there is
// no brief flash before the display-link tracker catches it next frame.
static void
FBPHitTestLayoutSubviews(
    id self,
    SEL _cmd
) {
    if (gOriginalHitTestLayoutSubviews) {
        gOriginalHitTestLayoutSubviews(self, _cmd);
    }

    if (!gOverlayHidden)
        return;

    if (![self isKindOfClass:[UIView class]])
        return;

    UIView *hitTest = (UIView *)self;
    if (!hitTest.window)
        return;

    FBPHideOverlayChildrenOf(hitTest);
}

#pragma mark - Sidebar hook

static void
FBPSidebarDidMoveToWindow(
    id self,
    SEL _cmd
) {
    if (gOriginalSidebarDidMoveToWindow) {

        gOriginalSidebarDidMoveToWindow(
            self,
            _cmd
        );
    }

    if (![self
        isKindOfClass:
            [UIView class]])
        return;

    UIView *sidebar =
        (UIView *)self;

    if (!sidebar.window)
        return;

    // If hide-mode is already on when a fresh reel's sidebar moves on screen,
    // strip it right away rather than waiting for the next display-link tick.
    if (gOverlayHidden) {
        UIView *overlay = FBPOverlayForSidebar(sidebar);
        if (overlay && !overlay.hidden) {
            overlay.hidden = YES;
            FBPSetViewHiddenByUs(overlay, YES);
            if (!gHiddenOverlays)
                gHiddenOverlays = [NSHashTable weakObjectsHashTable];
            [gHiddenOverlays addObject:overlay];
        }
    }

    dispatch_async(
        dispatch_get_main_queue(), ^{

        [[FBPReelButtonTracker shared]
            registerSidebar:sidebar];
    });
}

#pragma mark - Current video

static void
FBPDidStartPlayback(
    id self,
    SEL _cmd,
    id videoID,
    int64_t position,
    id analyticsContext,
    id playbackController
) {
    if (gOriginalDidStartPlayback) {
        gOriginalDidStartPlayback(
            self,
            _cmd,
            videoID,
            position,
            analyticsContext,
            playbackController
        );
    }

    id item =
        FBPSafeObjectGetter(
            playbackController,
            @"currentVideoPlaybackItem"
        );
    if (!item) return;

    NSString *itemVideoID = nil;
    NSURL *url =
        FBPPlaybackURLFromItem(
            item,
            &itemVideoID
        );
    if (!url) return;

    NSString *newID = nil;
    if ([videoID isKindOfClass:[NSString class]]) {
        newID = [(NSString *)videoID copy];
    } else if (videoID) {
        newID = [[videoID description] copy];
    } else {
        newID = itemVideoID;
    }

    @synchronized([NSFileManager class]) {
        gCurrentDownloadURL = url;
        gCurrentVideoID = [newID copy];
        gMediaOwnerPlayerVC = self;
    }
}

#pragma mark - Player lifecycle

static void
FBPPlayerViewWillAppear(
    id self,
    SEL _cmd,
    BOOL animated
) {
    /*
     * A newly-created fullscreen player must never inherit the previous
     * viewer's CDN URL.
     */
    @synchronized([NSFileManager class]) {
        if (gMediaOwnerPlayerVC &&
            gMediaOwnerPlayerVC != self) {

            gCurrentDownloadURL = nil;
            gCurrentVideoID = nil;
            gMediaOwnerPlayerVC = nil;
        }
    }

    if (gOriginalPlayerViewWillAppear) {
        gOriginalPlayerViewWillAppear(
            self,
            _cmd,
            animated
        );
    }
}

static void
FBPPlayerViewDidDisappear(
    id self,
    SEL _cmd,
    BOOL animated
) {
    if (gOriginalPlayerViewDidDisappear) {
        gOriginalPlayerViewDidDisappear(
            self,
            _cmd,
            animated
        );
    }

    @synchronized([NSFileManager class]) {
        if (!gMediaOwnerPlayerVC ||
            gMediaOwnerPlayerVC == self) {

            gCurrentDownloadURL = nil;
            gCurrentVideoID = nil;
            gMediaOwnerPlayerVC = nil;
        }
    }

    dispatch_async(
        dispatch_get_main_queue(), ^{

        // Leaving the player: restore any chrome we stripped so recycled Shorts
        // views never leak a hidden state elsewhere. gOverlayHidden is kept, so
        // returning to Reels re-strips automatically.
        FBPUnhideAllOverlays();
        FBPShowTabBars();

        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

            if (![scene
                isKindOfClass:[UIWindowScene class]])
                continue;

            for (UIWindow *window in
                 ((UIWindowScene *)scene).windows) {

                NSInteger tags[] = { kFBPDownloadButtonTag,
                                     kFBPHideOverlayButtonTag };

                for (size_t i = 0; i < sizeof(tags) / sizeof(tags[0]); i++) {

                    UIButton *button =
                        (UIButton *)[window viewWithTag:tags[i]];

                    if (button) {
                        button.hidden = YES;
                        button.alpha = 0.0;
                    }
                }
            }
        }
    });
}

static BOOL
FBPInstallOneLifecycleHook(
    Class cls,
    SEL sel,
    IMP replacement,
    IMP *originalOut
) {
    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method ||
        method_getNumberOfArguments(method) != 3)
        return NO;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return NO;

    MSHookMessageEx(
        cls,
        sel,
        replacement,
        originalOut
    );

    return YES;
}

static void
FBPInstallLifecycleHooks(void) {
    if (gLifecycleHooksInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBVideoHomeUnifiedPlayerViewController"
        );
    if (!cls)
        return;

    BOOL willAppearOK =
        FBPInstallOneLifecycleHook(
            cls,
            @selector(viewWillAppear:),
            (IMP)FBPPlayerViewWillAppear,
            (IMP *)&gOriginalPlayerViewWillAppear
        );

    BOOL didDisappearOK =
        FBPInstallOneLifecycleHook(
            cls,
            @selector(viewDidDisappear:),
            (IMP)FBPPlayerViewDidDisappear,
            (IMP *)&gOriginalPlayerViewDidDisappear
        );

    gLifecycleHooksInstalled =
        willAppearOK &&
        didDisappearOK;
}

#pragma mark - Hook installers

static void
FBPInstallPlayerHook(void) {

    if (gPlayerHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBVideoHomeUnifiedPlayerViewController"
        );

    if (!cls)
        return;

    SEL sel =
        NSSelectorFromString(
            @"didStartPlaybackForVideo:"
            @"position:"
            @"analyticsContext:"
            @"playbackController:"
        );

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method)
        return;

    const char *encoding =
        method_getTypeEncoding(method);

    if (!encoding ||
        strcmp(
            encoding,
            "v48@0:8@16q24@32@40"
        ) != 0) {


        return;
    }

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPDidStartPlayback,
        (IMP *)
            &gOriginalDidStartPlayback
    );

    gPlayerHookInstalled =
        YES;

}

static void
FBPInstallSidebarHook(void) {

    if (gSidebarHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBShortsSideBarView"
        );

    if (!cls)
        return;

    SEL sel =
        @selector(didMoveToWindow);

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method)
        return;

    if (method_getNumberOfArguments(
        method) != 2)
        return;

    char *returnType =
        method_copyReturnType(
            method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return;

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPSidebarDidMoveToWindow,
        (IMP *)
            &gOriginalSidebarDidMoveToWindow
    );

    gSidebarHookInstalled =
        YES;

}

static void
FBPInstallHitTestHook(void) {

    if (gHitTestHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBShortsCustomHitTestView"
        );

    if (!cls)
        return;

    SEL sel =
        @selector(layoutSubviews);

    // Only hook if this class defines -layoutSubviews itself. If it merely
    // inherited UIView's, hooking here would swizzle UIView globally.
    Class superCls =
        class_getSuperclass(cls);

    if (superCls &&
        class_getMethodImplementation(cls, sel) ==
            class_getMethodImplementation(superCls, sel))
        return;

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method ||
        method_getNumberOfArguments(method) != 2)
        return;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return;

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPHitTestLayoutSubviews,
        (IMP *)
            &gOriginalHitTestLayoutSubviews
    );

    gHitTestHookInstalled =
        YES;

}

void FBPInitReelsDownloader(void) {
    FBPInstallPlayerHook();
    FBPInstallSidebarHook();
    FBPInstallLifecycleHooks();
    FBPInstallHitTestHook();
}
