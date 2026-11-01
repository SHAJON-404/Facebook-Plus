// Custom app font.
//
// Facebook renders its text through UIKit, so every visible label ultimately
// asks UIFont for a face — either a system font (systemFontOfSize:, …) or a
// named one (fontWithName:/fontWithDescriptor:, e.g. the bundled "Optimistic"
// family). Those factory methods are the single chokepoint, so they are hooked
// and, when the user has picked a custom font, re-pointed at it at the same size
// and nearest weight.
//
// Only *text* is swapped. Facebook draws its tab-bar and button glyphs from a
// private icon font ("Facebook-Icons"); replacing that would turn every icon
// into garbage, so icon, emoji and symbol faces are deliberately left untouched —
// the hooks replace a face only when its name is a known Facebook text family or
// a system font. Unknown third-party faces are passed through unchanged too.
//
// The tweak's own UI (FBPFont) and the replacement-building below both create
// UIFont objects; a thread-local scope latch (FBPFontScopeActive) makes those
// requests fall through to the original so the tweak UI keeps its own look and
// the hooks never recurse.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"

#import <CoreText/CoreText.h>
#import <objc/runtime.h>

#pragma mark - Registered custom fonts

// Family names of every available font, in load order. Built at launch and
// rebuilt when the user imports or deletes one; read by the Fonts picker.
static NSArray<NSString *> *gFamilies = nil;

// Which families came from the user-imported folder (so only those are
// deletable), and the file(s) backing each — a family can span several files.
static NSMutableArray<NSString *> *gUserFamilies = nil;
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *gUserFiles = nil;

/// A writable folder the tweak owns, where fonts the user imports from Files are
/// kept so they survive relaunches and sit beside the bundled ones.
extern "C" NSString *FBPUserFontsDirectoryPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"FacebookPlusFonts"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

/// Registers every .ttf/.otf/.ttc under a directory with Core Text and appends
/// their family names (de-duplicated). Re-registering an already-registered file
/// is harmless — Core Text just reports it and we ignore the result. When
/// @c isUser is set, the family and its file are also recorded as deletable.
static void FBPRegisterFontsIn(NSString *path, BOOL isUser,
                              NSMutableArray<NSString *> *families) {
    NSArray<NSString *> *names =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"] ||
              [ext isEqualToString:@"ttc"])) continue;

        NSString *filePath = [path stringByAppendingPathComponent:name];
        NSURL *url = [NSURL fileURLWithPath:filePath];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                         kCTFontManagerScopeProcess, NULL);

        // Read the family name from the file, not the filename, so e.g.
        // "Stay With Me.otf" lists under its real family name.
        NSArray *descriptors = (__bridge_transfer NSArray *)
            CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
        for (id d in descriptors) {
            NSString *family = (__bridge_transfer NSString *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)d, kCTFontFamilyNameAttribute);
            if (family.length == 0) continue;
            if (![families containsObject:family]) [families addObject:family];
            if (isUser) {
                if (![gUserFamilies containsObject:family]) [gUserFamilies addObject:family];
                NSMutableArray *paths = gUserFiles[family] ?: [NSMutableArray array];
                if (![paths containsObject:filePath]) [paths addObject:filePath];
                gUserFiles[family] = paths;
            }
        }
    }
}

/// (Re)scans the bundled fonts and the user-imported ones into gFamilies.
extern "C" void FBPReloadFonts(void) {
    gUserFamilies = [NSMutableArray array];
    gUserFiles = [NSMutableDictionary dictionary];

    NSMutableArray<NSString *> *families = [NSMutableArray array];
    NSBundle *bundle = NSBundle.fbp_resourceBundle;
    if (bundle) FBPRegisterFontsIn(bundle.bundlePath, NO, families);
    FBPRegisterFontsIn(FBPUserFontsDirectoryPath(), YES, families);
    gFamilies = [families copy];
}

// Exposed to the Fonts picker (plain C linkage so the ObjC controller links).
extern "C" NSArray<NSString *> *FBPRegisteredFontFamilies(void) {
    return gFamilies ?: @[];
}

/// The subset of families the user imported — the only ones that may be deleted.
extern "C" NSArray<NSString *> *FBPUserFontFamilies(void) {
    return gUserFamilies ?: @[];
}

/// Removes an imported family: unregisters and deletes every file backing it,
/// then rebuilds the registry. Bundled families are ignored (nothing matches).
extern "C" void FBPDeleteUserFont(NSString *family) {
    NSArray<NSString *> *paths = gUserFiles[family];
    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path];
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url,
                                           kCTFontManagerScopeProcess, NULL);
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
    FBPReloadFonts();
}

#pragma mark - Selection

/// The chosen family, or nil when the user is on the original font.
static NSString *FBPSelectedFontFamily(void) {
    NSString *family = [FBPPrefs.shared stringForKey:FBPKeyFont];
    return family.length ? family : nil;
}

/// Custom-font size multiplier. Custom faces often render smaller than the app's
/// own font at the same point size, so the Fonts page lets the user scale them.
/// 1.0 (unset) leaves sizes exactly as the app asked; clamped to a sane range.
static CGFloat FBPFontScale(void) {
    NSString *raw = [FBPPrefs.shared stringForKey:FBPKeyFontScale];
    if (raw.length == 0) return 1.0;
    CGFloat scale = raw.doubleValue;
    if (scale < 1.0) return 1.0;
    if (scale > 3.0) return 3.0;
    return scale;
}

/// Builds the replacement face at the requested size and weight. Guarded by the
/// scope latch so the UIFont calls here are not themselves replaced.
static UIFont *FBPReplacementFont(CGFloat size, UIFontWeight weight) {
    NSString *family = FBPSelectedFontFamily();
    if (!family || size <= 0) return nil;

    size *= FBPFontScale();

    FBPSetFontScopeActive(YES);
    UIFontDescriptor *descriptor =
        [UIFontDescriptor fontDescriptorWithFontAttributes:@{
            UIFontDescriptorFamilyAttribute : family,
            UIFontDescriptorTraitsAttribute : @{ UIFontWeightTrait : @(weight) },
        }];
    UIFont *font = [UIFont fontWithDescriptor:descriptor size:size];
    FBPSetFontScopeActive(NO);
    return font;
}

#pragma mark - Which faces to replace

/// A weight parsed out of a font name ("…-Semibold", "…Bold…"), or regular.
static UIFontWeight FBPWeightFromName(NSString *lower) {
    if ([lower containsString:@"black"] || [lower containsString:@"heavy"]) return UIFontWeightHeavy;
    if ([lower containsString:@"semibold"])  return UIFontWeightSemibold;  // before "bold"
    if ([lower containsString:@"bold"])      return UIFontWeightBold;
    if ([lower containsString:@"medium"])    return UIFontWeightMedium;
    if ([lower containsString:@"light"])     return UIFontWeightLight;
    if ([lower containsString:@"thin"])      return UIFontWeightThin;
    return UIFontWeightRegular;
}

/// YES when a face named @c name is Facebook body/UI text that may be swapped.
/// Icon, emoji and symbol faces return NO so they are never touched; so do
/// unknown third-party faces, which are left exactly as the app asked for them.
static BOOL FBPShouldReplaceName(NSString *name) {
    if (name.length == 0) return NO;
    NSString *lower = name.lowercaseString;

    // Never the icon / emoji / symbol faces.
    if ([lower containsString:@"icon"])   return NO;   // Facebook-Icons
    if ([lower containsString:@"emoji"])  return NO;
    if ([lower containsString:@"symbol"]) return NO;

    // The system font is often created by its private dotted name.
    if ([name hasPrefix:@"."]) return YES;

    // Facebook's own text families.
    return [lower containsString:@"optimistic"] ||
           [lower containsString:@"facebooksans"] || [lower containsString:@"facebook sans"] ||
           [lower containsString:@"facebooknarrow"] || [lower containsString:@"facebook narrow"] ||
           [lower containsString:@"aveny"];
}

#pragma mark - Hooks

%group FBPFonts

%hook UIFont

+ (UIFont *)systemFontOfSize:(CGFloat)fontSize {
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightRegular) ?: %orig;
}

+ (UIFont *)boldSystemFontOfSize:(CGFloat)fontSize {
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightBold) ?: %orig;
}

+ (UIFont *)italicSystemFontOfSize:(CGFloat)fontSize {
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightRegular) ?: %orig;
}

+ (UIFont *)systemFontOfSize:(CGFloat)fontSize weight:(UIFontWeight)weight {
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, weight) ?: %orig;
}

+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    UIFont *original = %orig;
    if (FBPFontScopeActive()) return original;
    return FBPReplacementFont(original.pointSize, UIFontWeightRegular) ?: original;
}

+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)fontSize {
    if (FBPFontScopeActive() || !FBPShouldReplaceName(name)) return %orig;
    return FBPReplacementFont(fontSize, FBPWeightFromName(name.lowercaseString)) ?: %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)fontSize {
    if (FBPFontScopeActive()) return %orig;

    NSString *family = descriptor.fontAttributes[UIFontDescriptorFamilyAttribute]
        ?: descriptor.fontAttributes[UIFontDescriptorNameAttribute];
    if (!FBPShouldReplaceName(family)) return %orig;

    CGFloat size = fontSize > 0 ? fontSize : descriptor.pointSize;
    NSDictionary *traits = descriptor.fontAttributes[UIFontDescriptorTraitsAttribute];
    UIFontWeight weight = UIFontWeightRegular;
    NSNumber *w = traits[UIFontWeightTrait];
    if ([w isKindOfClass:NSNumber.class]) weight = w.doubleValue;

    return FBPReplacementFont(size, weight) ?: %orig;
}

%end

%end // FBPFonts

void FBPInitFontHooks(void) {
    FBP_ONCE(gFontsInstalled) {
        FBPReloadFonts();
        %init(FBPFonts);
    }
}
