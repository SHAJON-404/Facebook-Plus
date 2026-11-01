// Commit-level confirmations — an opt-in guard for publishing a post and posting
// a comment.
//
// Likes, shares, follows/joins and friend-request buttons are ComponentKit
// controls and are guarded in the ComponentKit forwarder hook. Publishing a post
// and posting a comment are not ComponentKit buttons: the app commits each
// through its own concrete method, and there are several of them (one composer
// has two post entry points, renamed between app versions), so guarding any
// single class would cover one entry point and silently miss the rest.
//
// The table below lists the one method that actually commits each action, and
// each is swizzled with method_setImplementation onto a shared replacement. The
// replacement looks up which action "kind" the method belongs to and, only when
// the user has switched that kind on, raises a prompt — running the real method
// just once, on confirm.
//
// A static %hook on a class missing in a given build fails silently; an entry
// here is installed only when its class exists and genuinely declares the
// selector with the expected argument shape and a void return, so a build that
// renames or drops one loses just that single entry while the rest keep working.
//
// A composer can route a single tap through more than one of its post methods,
// which is what raised the prompt repeatedly. The shared "a prompt is on screen"
// latch (FBPConfirmPromptVisible) collapses those into one: the first method
// prompts, the siblings fired by the same tap are dropped, and the confirmed
// replay commits the post exactly once.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPResources.h"
#import "FBPSheet.h"

#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Kinds

typedef NS_ENUM(NSInteger, FBPConfirmKind) {
    FBPConfirmKindPost = 0,
    FBPConfirmKindComment,
};

static NSString *FBPConfirmPrefKey(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindPost:    return FBPKeyConfirmPost;
        case FBPConfirmKindComment: return FBPKeyConfirmComment;
    }
    return nil;
}

// Each prompt pulls three pieces of text from the string table by key. Universal
// words (e.g. "Confirm") resolve to a shared common.* key rather than a
// per-kind duplicate, so the same string is defined once.

static NSString *FBPConfirmTitleKey(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindPost:    return @"confirm.post.title";
        case FBPConfirmKindComment: return @"confirm.comment.title";
    }
    return @"common.confirm";
}

static NSString *FBPConfirmMessageKey(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindPost:    return @"confirm.post.message";
        case FBPConfirmKindComment: return @"confirm.comment.message";
    }
    return nil;
}

static NSString *FBPConfirmVerbKey(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindPost:    return @"confirm.post.verb";
        case FBPConfirmKindComment: return @"confirm.comment.verb";
    }
    return @"common.confirm";
}

#pragma mark - The table

typedef struct {
    const char *className;
    const char *selector;
    int argCount;            // argument count the method must have for the shape to match
    FBPConfirmKind kind;
} FBPConfirmEntry;

// Each row is the single method that commits one action on one Facebook class.
static const FBPConfirmEntry kTable[] = {
    // Publish a post
    {"FBComposerAdminCrossProfilePostingViewController","_didTapPostItem",                2, FBPConfirmKindPost},
    {"FBComposerViewController",                     "_didTapPostButton",                 2, FBPConfirmKindPost},
    {"FBComposerViewController",                     "postButtonTapped",                  2, FBPConfirmKindPost},
    {"FBCreatorComposerViewController",              "_didTapPostItem",                   2, FBPConfirmKindPost},
    {"FBEventsSideFeedRemindersView",                "postButtonPressed:",                3, FBPConfirmKindPost},
    {"FBGroupRulesReviewViewController",             "didTapPublish",                     2, FBPConfirmKindPost},
    {"FBInspirationShortFormVideoShareSheetViewController","_handlePostAction",           2, FBPConfirmKindPost},
    {"FBInspirationShortFormVideoShareSheetViewController","didTapPostButton",            2, FBPConfirmKindPost},
    {"FBProfileMLEEditorViewController",             "didTapNavigationBarPost",           2, FBPConfirmKindPost},

    // Comment
    {"FBCommentCreateMutator",                       "publishWithSession:",               3, FBPConfirmKindComment},
};

#pragma mark - Saved originals

// key "<ClassName> <selector>" -> boxed original IMP, and -> boxed kind.
static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableDictionary<NSString *, NSNumber *> *gKinds;

// Set while replaying a confirmed action so the replacement falls straight
// through to the original on the second pass.
static BOOL gPassthrough = NO;

static NSString *FBPEntryKey(const char *className, const char *selName) {
    return [NSString stringWithFormat:@"%s %s", className, selName];
}

/// Walks the receiver's class chain to find the registered original IMP and kind
/// for this selector — so an instance of a subclass that inherits the swizzled
/// method still resolves to the entry installed on the defining class.
static IMP FBPResolve(__unsafe_unretained id object, SEL cmd, FBPConfirmKind *outKind) {
    const char *selName = sel_getName(cmd);
    for (Class c = object_getClass(object); c; c = class_getSuperclass(c)) {
        NSString *key = [NSString stringWithFormat:@"%s %s", class_getName(c), selName];
        NSValue *boxed = gOriginals[key];
        if (boxed) {
            if (outKind) *outKind = (FBPConfirmKind)gKinds[key].integerValue;
            return (IMP)boxed.pointerValue;
        }
    }
    return NULL;
}

#pragma mark - Prompt

static void FBPPresentConfirm(FBPConfirmKind kind, dispatch_block_t onConfirm) {
    dispatch_block_t show = ^{
        UIViewController *host = [FBPSheetPresenter topViewController];
        while (host.presentedViewController) host = host.presentedViewController;
        if (!host) { if (onConfirm) onConfirm(); return; }   // nowhere to ask — fail open

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:FBPL(FBPConfirmTitleKey(kind))
                                                message:FBPL(FBPConfirmMessageKey(kind))
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *a) {
            FBPSetConfirmPromptVisible(NO);
        }]];
        UIAlertAction *go = [UIAlertAction actionWithTitle:FBPL(FBPConfirmVerbKey(kind))
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
            FBPSetConfirmPromptVisible(NO);
            if (onConfirm) onConfirm();
        }];
        [alert addAction:go];
        alert.preferredAction = go;
        alert.view.tintColor = FBPTintColor();
        FBPSetConfirmPromptVisible(YES);
        [host presentViewController:alert animated:YES completion:nil];
    };
    if (NSThread.isMainThread) show(); else dispatch_async(dispatch_get_main_queue(), show);
}

#pragma mark - Replacements

// self is __unsafe_unretained: an IMP receiver is not owned by the callee, so
// letting ARC retain/release it would over-release. The original is replayed
// through a strong capture that keeps the receiver (and argument) alive while the
// prompt is on screen.

static void FBPReplace2(__unsafe_unretained id self, SEL _cmd) {
    FBPConfirmKind kind = FBPConfirmKindPost;
    IMP orig = FBPResolve(self, _cmd, &kind);
    if (!orig) return;
    void (*call)(id, SEL) = (void (*)(id, SEL))orig;

    // Replay, or the kind is switched off — perform the real method untouched.
    if (gPassthrough || !FBPEnabled(FBPConfirmPrefKey(kind))) { call(self, _cmd); return; }

    // A prompt is already on screen (a sibling commit method from the same tap,
    // or the ComponentKit path). Drop this one so prompts never stack — the
    // action still fires through the prompt that is up.
    if (FBPConfirmPromptVisible()) return;

    id keepSelf = self;
    FBPPresentConfirm(kind, ^{
        gPassthrough = YES;
        call(keepSelf, _cmd);
        gPassthrough = NO;
    });
}

static void FBPReplace3(__unsafe_unretained id self, SEL _cmd, id arg) {
    FBPConfirmKind kind = FBPConfirmKindPost;
    IMP orig = FBPResolve(self, _cmd, &kind);
    if (!orig) return;
    void (*call)(id, SEL, id) = (void (*)(id, SEL, id))orig;

    if (gPassthrough || !FBPEnabled(FBPConfirmPrefKey(kind))) { call(self, _cmd, arg); return; }

    if (FBPConfirmPromptVisible()) return;

    id keepSelf = self;
    id keepArg = arg;
    FBPPresentConfirm(kind, ^{
        gPassthrough = YES;
        call(keepSelf, _cmd, keepArg);
        gPassthrough = NO;
    });
}

#pragma mark - Install

/// YES when @c cls itself declares @c sel (not merely inherits it), so the
/// IMP we replace belongs to this class and not a shared ancestor.
static Method FBPOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    free(list);
    return found;
}

void FBPInitActionConfirm(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOriginals = [NSMutableDictionary dictionary];
        gKinds = [NSMutableDictionary dictionary];
    });

    for (size_t i = 0; i < sizeof(kTable) / sizeof(kTable[0]); i++) {
        const FBPConfirmEntry *e = &kTable[i];

        Class cls = objc_getClass(e->className);
        if (!cls) continue;                               // framework not loaded yet / renamed

        NSString *key = FBPEntryKey(e->className, e->selector);
        if (gOriginals[key]) continue;                    // already installed

        SEL sel = sel_registerName(e->selector);
        Method method = FBPOwnMethod(cls, sel);
        if (!method) continue;                            // not declared on this class

        if ((int)method_getNumberOfArguments(method) != e->argCount) continue;

        char ret[8] = {0};
        method_getReturnType(method, ret, sizeof(ret));
        if (ret[0] != 'v') continue;                      // only void commit methods

        IMP replacement = (e->argCount == 3) ? (IMP)FBPReplace3 : (IMP)FBPReplace2;
        IMP original = method_setImplementation(method, replacement);
        if (original && original != replacement) {
            gOriginals[key] = [NSValue valueWithPointer:(const void *)original];
            gKinds[key] = @(e->kind);
        }
    }
}
