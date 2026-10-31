// OLED Dark Mode: turn Facebook's whole UI true-black.
//
// When the toggle is on, every app window is forced to the dark interface style
// (so the user does not have to enable Facebook's own dark mode), and every dark
// surface in the view tree is repainted pure black. Because the app is forced
// dark, the repaint runs unconditionally while the toggle is on — there is no
// separate "is the app dark" check that could go stale and leave some surfaces
// grey while others turn black.
//
// Facebook paints backgrounds at many levels, and the two surfaces that used to
// stay grey — the top app header and the profile's "Add to story / Edit profile"
// panel — are painted by mechanisms a plain -setBackgroundColor: hook never sees.
// A radare2/r2pipe walk of FBSharedFramework showed why:
//
//   * FBMovableNavigationBarView (the app header) sets nothing on its own view.
//     Its grey lives on child views (_fakeNavigationBar, _replacementNavigationBar
//     which is a real UINavigationBar drawn through UINavigationBarAppearance /
//     a UIVisualEffectView blur), a fade CAGradientLayer (_extraGradientHeight),
//     and a raw CALayer (FBNavigationBar._statusBarBackground). None of these is
//     the view's own -backgroundColor, so a plain -backgroundColor hook caught it
//     only intermittently, which produced the flickering header.
//
//   * ComponentKit cards (the profile panel) paint their rounded background onto
//     a CAGradientLayer / CAShapeLayer / plain CALayer added as a *sublayer*, not
//     onto the view's -backgroundColor, so -setBackgroundColor: never fires.
//
// So in addition to the -backgroundColor path, the tweak (1) resolves dynamic
// colours against a forced-dark trait collection before judging darkness —
// removing the timing dependence — (2) sweeps each view's own sublayers
// (gradient/shape/plain) and blackens the dark ones, and (3) hooks
// FBMovableNavigationBarView directly to blacken its header sub-tree (blur,
// UINavigationBar, gradients) while leaving genuinely coloured accents and photos
// alone.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/// Cached toggle state, refreshed on the settings-changed notification so the hot
/// path never touches NSUserDefaults.
static BOOL gOLEDEnabled = NO;

static void FBPRefreshOLED(void) { gOLEDEnabled = FBPEnabled(FBPKeyOLED); }

#pragma mark - Colour judgement

/// A dark trait collection every dynamic colour is resolved against. Facebook's
/// backgrounds are dynamic UIColors; resolving them explicitly (instead of relying
/// on whatever the current trait environment happens to be) is what makes the
/// header deterministic rather than intermittently dark.
static UITraitCollection *FBPDarkTraits(void) {
    static UITraitCollection *traits = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            traits = [UITraitCollection
                traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
        }
    });
    return traits;
}

/// Resolves a (possibly dynamic) colour to its concrete dark-mode value.
static UIColor *FBPResolve(UIColor *color) {
    if (!color) return color;
    if (@available(iOS 13.0, *)) {
        UITraitCollection *traits = FBPDarkTraits();
        if (traits) {
            @try {
                UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
                if (resolved) return resolved;
            } @catch (__unused NSException *e) {}
        }
    }
    return color;
}

/// YES only for one of Facebook's own dark *background* greys — the surfaces that
/// should go true-black. Facebook's dark palette (FDSColor / FBColorPaletteConfig
/// -greyColorWithShade:) paints every surface from a small ladder of near-neutral
/// greys that tops out around #3A3B3C (base #18191A, card #242526, elevated
/// #3A3B3C). We match exactly that band — near-neutral and no lighter than
/// ~#3A3B3C — instead of a loose "is it darkish" luma test.
///
/// This is deliberately tight: the old test blackened anything up to a mid-grey
/// (luma < 0.48), which also caught dividers, pressed/hover states, elevated
/// chips and placeholders and painted them as solid black rectangles — the
/// "square box" artefacts. Lighter greys, tinted surfaces, accents and photos are
/// now left untouched, so only real backgrounds deepen to black.
static const CGFloat kFBPBgMaxLuma    = 0.26;   // just above #3A3B3C (luma ~0.231)
static const CGFloat kFBPBgMaxChroma  = 0.05;   // near-neutral only (FB greys are ~neutral)

static BOOL FBPColorIsDark(UIColor *color) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        if (a < 0.2) return NO;
        CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
        CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
        return (mx - mn) < kFBPBgMaxChroma && luma < kFBPBgMaxLuma;
    }
    CGFloat w = 0, wa = 0;
    if ([color getWhite:&w alpha:&wa]) {
        if (wa < 0.2) return NO;
        return w < kFBPBgMaxLuma;
    }
    return NO;
}

/// Darkness test for a CGColorRef (layer colours are always CGColor and already
/// concrete, so no dynamic resolution is needed).
static BOOL FBPCGColorIsDark(CGColorRef cg) {
    if (!cg) return NO;
    return FBPColorIsDark([UIColor colorWithCGColor:cg]);
}

/// The tweak's own UI keeps its own colours.
static BOOL FBPOLEDSkip(UIView *view) {
    return [NSStringFromClass([view class]) hasPrefix:@"FBP"];
}

#pragma mark - Layer sweeping

/// Black that keeps the source colour's alpha. A translucent scrim — an alert's
/// dimming view, a bottom-sheet backdrop — must stay translucent; forcing it to
/// opaque black would turn it into a solid curtain, hiding everything behind a
/// popup in OLED mode. Opaque surfaces (alpha 1) still become solid black, so the
/// rest of the app is unchanged.
static UIColor *FBPBlackKeepingAlpha(UIColor *color) {
    CGFloat alpha = color ? CGColorGetAlpha(color.CGColor) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha];
}
static CGColorRef FBPBlackCGKeepingAlpha(CGColorRef cg) {
    CGFloat alpha = cg ? CGColorGetAlpha(cg) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha].CGColor;
}

#pragma mark - Dividers

// Pure black merges Facebook's cards into their background, so the hairline
// separators between posts, list rows and sections vanish. Facebook draws them
// with FBLineComponentInternalView (and plain ~1–2pt hairline views); in OLED
// mode we paint those a faint white instead of black, so the structure the
// native dark theme has stays readable — a true-black look that still has lines.
static const CGFloat kFBPDividerAlpha = 0.22;   // faint white on black

static UIColor *FBPDividerColor(void) {
    static UIColor *color = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = [UIColor colorWithWhite:1.0 alpha:kFBPDividerAlpha]; });
    return color;
}

/// YES for a separator line we should lighten rather than blacken: Facebook's
/// FBLineComponentInternalView, or a thin (≤2pt) neutral/near-black hairline. A
/// *coloured* thin bar — a selected-tab underline, a progress bar — is not a
/// divider (its colour isn't dark), so it is left alone.
static BOOL FBPViewLooksLikeDivider(UIView *view) {
    if ([NSStringFromClass(view.class) containsString:@"LineComponent"]) return YES;
    CGSize size = view.bounds.size;
    BOOL thin = (size.height > 0 && size.height <= 2.0 && size.width  >= 40) ||
                (size.width  > 0 && size.width  <= 2.0 && size.height >= 40);
    if (!thin) return NO;
    UIColor *bg = view.backgroundColor;
    if (bg) return FBPColorIsDark(FBPResolve(bg));
    if (view.layer.backgroundColor) return FBPCGColorIsDark(view.layer.backgroundColor);
    return view.layer.sublayers.count > 0;   // line drawn on a sublayer
}

/// Paints a divider faint-white across the ways Facebook draws its line — the
/// view's background, its own layer, and any line-drawing sublayer.
static void FBPLightenDivider(UIView *view) {
    UIColor *light = FBPDividerColor();
    view.backgroundColor = light;
    view.layer.backgroundColor = light.CGColor;
    for (CALayer *sub in [view.layer.sublayers copy]) {
        if ([sub.delegate isKindOfClass:UIView.class]) continue;
        if ([sub isKindOfClass:CAShapeLayer.class]) {
            ((CAShapeLayer *)sub).fillColor = light.CGColor;
        }
        sub.backgroundColor = light.CGColor;
    }
}

#pragma mark - Profile avatars

// A profile avatar stacks an unmasked square image — a low-res placeholder /
// backing — behind the circular photo. On Facebook's grey cards its grey corners
// blend in, but on the OLED-black background they poke past the circle as a
// visible grey "box".
//
// Facebook builds avatars several different ways, but the box always comes from
// a square image that isn't being clipped to the avatar circle. Two shapes cover
// every case seen (feed headers, comments, video/AI posts):
//
//   A. A circular container (cornerRadius ~= half its square size) whose
//      masksToBounds is OFF, so the square image/placeholder inside bleeds out to
//      the corners. Turning masksToBounds on clips everything inside to the
//      circle. The online-status dot lives OUTSIDE this container, so it stays.
//   B. A container holding a *masked* MRCImageComponentView (the circular photo)
//      next to a bare, unmasked square UIImageView (a placeholder behind it).
//      Rounding that bare image to a circle removes its corners.
//
// Scoped to small, square-ish containers so rectangular post photos (which also
// use MRCImageComponentView) and larger media are never touched.
static void FBPFixAvatarBox(UIView *container) {
    CGSize size = container.bounds.size;
    if (size.width < 16.0 || size.width > 72.0) return;        // avatar-sized only
    CGFloat boxDiff = size.width > size.height ? size.width - size.height
                                               : size.height - size.width;
    if (boxDiff > 6.0) return;                                  // square-ish only

    UIView *maskedAvatar = nil;
    UIImageView *bareImages[8];
    NSUInteger bareCount = 0;
    BOOL hasImageContent = NO;

    for (UIView *sub in container.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"MRCImageComponent"]) {
            hasImageContent = YES;
            if (sub.layer.masksToBounds) maskedAvatar = sub;
            continue;
        }
        if (![sub isKindOfClass:UIImageView.class]) continue;
        hasImageContent = YES;
        if (sub.layer.cornerRadius > 0.5 || sub.layer.masksToBounds) continue;
        CGFloat w = sub.bounds.size.width, h = sub.bounds.size.height;
        CGFloat d = w > h ? w - h : h - w;
        if (w < 16.0 || d > 6.0) continue;                      // square-ish image
        if (bareCount < 8) bareImages[bareCount++] = (UIImageView *)sub;
    }

    // Case A: a circular container holding image content but not clipping it.
    CGFloat cr = container.layer.cornerRadius;
    CGFloat crDiff = cr > size.width / 2.0 ? cr - size.width / 2.0
                                           : size.width / 2.0 - cr;
    if (hasImageContent && crDiff < 3.0 && !container.layer.masksToBounds) {
        container.layer.masksToBounds = YES;
        container.clipsToBounds = YES;
    }

    // Case B: a masked avatar next to bare square placeholder image(s).
    if (maskedAvatar) {
        for (NSUInteger i = 0; i < bareCount; i++) {
            UIImageView *img = bareImages[i];
            img.layer.cornerRadius = img.bounds.size.width / 2.0;
            img.layer.masksToBounds = YES;
            img.clipsToBounds = YES;
        }
    }
}

/// Blackens the dark colours a view paints *directly onto its own layer's
/// sublayers* — the gradient/shape/plain CALayers ComponentKit uses for rounded
/// card backgrounds and Facebook uses for the header fade and status-bar strip.
/// Layers that merely back a subview are skipped: that subview repaints itself.
static void FBPBlackenSublayers(CALayer *layer) {
    NSArray<CALayer *> *sublayers = layer.sublayers;
    if (sublayers.count == 0) return;
    for (CALayer *sub in [sublayers copy]) {
        if ([sub.delegate isKindOfClass:UIView.class]) continue;   // subview's own layer

        if ([sub isKindOfClass:CAGradientLayer.class]) {
            CAGradientLayer *gradient = (CAGradientLayer *)sub;
            NSArray *colors = gradient.colors;
            BOOL anyDark = NO;
            for (id entry in colors) {
                if (FBPCGColorIsDark((__bridge CGColorRef)entry)) { anyDark = YES; break; }
            }
            if (anyDark && colors.count) {
                NSMutableArray *black = [NSMutableArray arrayWithCapacity:colors.count];
                for (id entry in colors) {
                    [black addObject:(__bridge id)FBPBlackCGKeepingAlpha(
                                         (__bridge CGColorRef)entry)];
                }
                gradient.colors = black;
            }
            continue;
        }
        if ([sub isKindOfClass:CAShapeLayer.class]) {
            CAShapeLayer *shape = (CAShapeLayer *)sub;
            if (FBPCGColorIsDark(shape.fillColor))
                shape.fillColor = FBPBlackCGKeepingAlpha(shape.fillColor);
            if (FBPCGColorIsDark(shape.backgroundColor))
                shape.backgroundColor = FBPBlackCGKeepingAlpha(shape.backgroundColor);
            continue;
        }
        if (FBPCGColorIsDark(sub.backgroundColor))
            sub.backgroundColor = FBPBlackCGKeepingAlpha(sub.backgroundColor);
    }
}

#pragma mark - Header (FBMovableNavigationBarView) helpers

/// Opaque black appearance for the real UINavigationBar the header hosts
/// (_replacementNavigationBar). Its background is drawn through
/// UINavigationBarAppearance / _UIBarBackground (a blur), not -backgroundColor,
/// so the appearance objects must be reconfigured and the blur flattened.
static void FBPBlackNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    bar.translucent = NO;
    bar.barTintColor = UIColor.blackColor;
    bar.backgroundColor = UIColor.blackColor;
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = UIColor.blackColor;
        appearance.backgroundEffect = nil;
        appearance.shadowColor = UIColor.clearColor;
        appearance.shadowImage = [[UIImage alloc] init];
        bar.standardAppearance = appearance;
        bar.compactAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        if (@available(iOS 15.0, *)) bar.compactScrollEdgeAppearance = appearance;
    }
    // Flatten the _UIBarBackground blur that sits behind the bar's content.
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"BarBackground"]) {
            sub.backgroundColor = UIColor.blackColor;
            for (UIView *inner in sub.subviews) {
                inner.backgroundColor = UIColor.blackColor;
                if ([inner isKindOfClass:UIVisualEffectView.class]) {
                    ((UIVisualEffectView *)inner).contentView.backgroundColor =
                        UIColor.blackColor;
                }
            }
        }
    }
}

/// Walks the header's sub-tree and blackens every grey surface it finds — dark
/// view backgrounds, dark layer/gradient/shape colours, the hosted UINavigationBar
/// and any blur — while leaving photos (nil/clear backgrounds) and coloured
/// accents untouched, so the profile cover and the blue "Add to story" button
/// keep their look.
static void FBPBlackenHeaderTree(UIView *view, int depth) {
    if (!view || depth > 12) return;
    for (UIView *sub in [view.subviews copy]) {
        if (FBPOLEDSkip(sub)) continue;

        if ([sub isKindOfClass:UINavigationBar.class]) {
            FBPBlackNavigationBar((UINavigationBar *)sub);
        } else if ([sub isKindOfClass:UIVisualEffectView.class]) {
            // A blur in the header reads as grey; cover it flat black.
            sub.backgroundColor = UIColor.blackColor;
            ((UIVisualEffectView *)sub).contentView.backgroundColor = UIColor.blackColor;
            FBPBlackenSublayers(sub.layer);
            continue;   // don't recurse into the effect view's content
        } else {
            if (FBPColorIsDark(FBPResolve(sub.backgroundColor))) {
                sub.backgroundColor = FBPBlackKeepingAlpha(sub.backgroundColor);
            }
            if (FBPCGColorIsDark(sub.layer.backgroundColor)) {
                sub.layer.backgroundColor =
                    FBPBlackCGKeepingAlpha(sub.layer.backgroundColor);
            }
        }
        FBPBlackenSublayers(sub.layer);
        FBPBlackenHeaderTree(sub, depth + 1);
    }
}

#pragma mark - Forced dark appearance

/// Forces every app window to the dark interface style while OLED is on.
/// When OLED is off, we only reset windows that we previously forced dark,
/// so we never override or destroy Facebook's own native dark mode.
/// Applied only on discrete events (never during layout) to avoid flicker.
static void FBPApplyForcedAppearance(void) {
    if (@available(iOS 13.0, *)) {
        static BOOL didForceDark = NO;
        if (gOLEDEnabled) {
            didForceDark = YES;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) continue;
                    if (window.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) {
                        window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                    }

                    UIViewController *root = window.rootViewController;
                    if (root) [root setNeedsStatusBarAppearanceUpdate];
                }
            }
        } else if (didForceDark) {
            // Only release the override if OLED was previously active in this session
            didForceDark = NO;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) continue;
                    if (window.overrideUserInterfaceStyle == UIUserInterfaceStyleDark) {
                        window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
                    }

                    UIViewController *root = window.rootViewController;
                    if (root) [root setNeedsStatusBarAppearanceUpdate];
                }
            }
        }
    }
}

#pragma mark - Hooks

%group FBPOLEDGlobal

// Force new/key windows dark while OLED is on.
%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    if (@available(iOS 13.0, *)) {
        if (gOLEDEnabled && ![NSStringFromClass(self.class) hasPrefix:@"FBP"] &&
            self.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) {
            self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
}
%end

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if (gOLEDEnabled && !FBPOLEDSkip(self)) {
        // A separator line keeps a faint white instead of vanishing into black.
        if ([NSStringFromClass(self.class) containsString:@"LineComponent"]) {
            %orig(FBPDividerColor());
            return;
        }
        if (FBPColorIsDark(FBPResolve(color))) {
            %orig(FBPBlackKeepingAlpha(color));
            return;
        }
    }
    %orig(color);
}

- (void)layoutSubviews {
    %orig;
    if (!gOLEDEnabled || FBPOLEDSkip(self)) return;

    // Dividers are lightened, not blackened, so posts/rows stay visually separated.
    if (FBPViewLooksLikeDivider(self)) {
        FBPLightenDivider(self);
        return;
    }

    // Round the square placeholder stacked behind a circular profile avatar, so
    // its grey corners don't show as a box against the OLED-black background.
    // Trigger both when the avatar container lays out and, more reliably, when
    // the masked image component itself mounts (then fix its siblings).
    FBPFixAvatarBox(self);
    if ([NSStringFromClass(self.class) containsString:@"MRCImageComponent"] &&
        self.layer.masksToBounds) {
        FBPFixAvatarBox(self.superview);
    }

    UIColor *bg = self.backgroundColor;
    if (bg) {
        // Views that paint through -backgroundColor (dynamic colours resolved).
        if (FBPColorIsDark(FBPResolve(bg))) self.backgroundColor = FBPBlackKeepingAlpha(bg);
    } else if (FBPCGColorIsDark(self.layer.backgroundColor)) {
        // ComponentKit cards that paint straight onto their own layer.
        self.layer.backgroundColor = FBPBlackCGKeepingAlpha(self.layer.backgroundColor);
    }

    // Cards / fades that paint onto a sublayer (gradient, shape or plain CALayer)
    // rather than the view or its own layer background — the profile panel and the
    // header fade. Cheap: most views have no sublayers.
    FBPBlackenSublayers(self.layer);
}

%end

%hook UITableView
- (void)setBackgroundColor:(UIColor *)color {
    if (gOLEDEnabled && !FBPOLEDSkip(self) && FBPColorIsDark(FBPResolve(color))) {
        %orig(FBPBlackKeepingAlpha(color));
        return;
    }
    %orig(color);
}
%end

%hook UITableViewCell
- (void)setBackgroundColor:(UIColor *)color {
    if (gOLEDEnabled && !FBPOLEDSkip(self) && FBPColorIsDark(FBPResolve(color))) {
        %orig(FBPBlackKeepingAlpha(color));
        return;
    }
    %orig(color);
}
%end

%hook UICollectionView
- (void)setBackgroundColor:(UIColor *)color {
    if (gOLEDEnabled && !FBPOLEDSkip(self) && FBPColorIsDark(FBPResolve(color))) {
        %orig(FBPBlackKeepingAlpha(color));
        return;
    }
    %orig(color);
}
%end

// The app header. It paints nothing on its own view; the grey lives on child
// views, a hosted UINavigationBar, a blur and gradients — so blacken the sub-tree
// on every layout pass while OLED is on. This is what stops the header flickering
// between grey and black.
%hook FBMovableNavigationBarView
- (void)layoutSubviews {
    %orig;
    if (!gOLEDEnabled) return;
    if (FBPColorIsDark(FBPResolve(self.backgroundColor))) {
        self.backgroundColor = FBPBlackKeepingAlpha(self.backgroundColor);
    }
    if (FBPCGColorIsDark(self.layer.backgroundColor)) {
        self.layer.backgroundColor = FBPBlackCGKeepingAlpha(self.layer.backgroundColor);
    }
    FBPBlackenSublayers(self.layer);
    FBPBlackenHeaderTree(self, 0);
}
%end

// The navigation-bar view controller drives the status bar, and it returns
// darkContent (black time / battery / signal) because Facebook's header is
// normally light. OLED paints that header black, so black status-bar glyphs
// vanish. Force light content (white glyphs) while OLED is on.
%hook FBMovableNavigationBarViewController
- (UIStatusBarStyle)preferredStatusBarStyle {
    if (gOLEDEnabled) return UIStatusBarStyleLightContent;
    return %orig;
}
%end

%end // FBPOLEDGlobal

void FBPInitOLEDHooks(void) {
    FBPRefreshOLED();

    // Toggling OLED in settings immediately forces (or releases) the dark
    // appearance; the layout hooks then repaint on the next pass.
    [NSNotificationCenter.defaultCenter
        addObserverForName:FBPSettingsDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        FBPRefreshOLED();
        FBPApplyForcedAppearance();
    }];

    // Re-assert the forced appearance on foreground and shortly after launch.
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { FBPApplyForcedAppearance(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FBPApplyForcedAppearance(); });

    FBP_ONCE(gOLED) { %init(FBPOLEDGlobal); }
}
