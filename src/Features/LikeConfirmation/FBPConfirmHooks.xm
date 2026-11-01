// Action confirmations routed through ComponentKit.
//
// Facebook's UI is ComponentKit-generated, so the concrete button classes are
// mangled and change between builds. Every ComponentKit control event funnels
// through one forwarder, so that is intercepted instead and the sender is
// identified by its accessibility identifier — stable, because Facebook's own
// UI tests depend on it — with the label as a fallback for the few buttons that
// ship no identifier.
//
// Like, Share, Follow/Join and Friend-request buttons all dispatch through this
// same forwarder, so one hook guards every one of them; the commit-level hooks
// (comment and post) live separately because they are not ComponentKit buttons.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPResources.h"
#import "FBPSheet.h"

typedef NS_ENUM(NSInteger, FBPConfirmKind) {
    FBPConfirmKindNone = -1,
    FBPConfirmKindLike = 0,
    FBPConfirmKindShare,
    FBPConfirmKindFollow,   // following a page, or joining a group
    FBPConfirmKindFriend,   // confirming / responding to a friend request
};

/// Classifies a single view by its accessibility identifier and label, matching
/// the anchors Facebook puts on these controls. Identifiers are preferred; the
/// label is a fallback for buttons that carry no identifier ("Share now", the
/// group "Join" button). All comparisons are lower-cased so a label is matched
/// regardless of its exact casing.
static FBPConfirmKind FBPKindForView(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    NSString *label = view.accessibilityLabel;
    NSString *idl = identifier.lowercaseString;
    NSString *lbl = label.lowercaseString;

    // Like — feed posts and Reels share one guard.
    if ([identifier isEqualToString:FBPAXFeedLikeButton] ||
        [identifier isEqualToString:FBPAXReelsLikeButton]) {
        return FBPConfirmKindLike;
    }

    // Share — the feed share button carries an identifier; the share-sheet's
    // final "Share now" button carries only a label.
    if ([idl containsString:@"ufi-share-button"] ||
        [lbl isEqualToString:@"share now"]) {
        return FBPConfirmKindShare;
    }

    // Friend request — the confirm button on an incoming request. Checked before
    // Follow because some of these also carry follow-ish labels.
    if (([idl containsString:@"friend"] &&
         ([idl containsString:@"request"] ||
          [idl containsString:@"confirm"] ||
          [idl containsString:@"add"])) ||
        [lbl containsString:@"friend request"]) {
        return FBPConfirmKindFriend;
    }

    // Follow / Join — the profile follow control carries a "following_status"
    // identifier; the group join button carries only a "Join …" label.
    if ([idl containsString:@"following_status"] ||
        [idl containsString:@"follow-button"] ||
        [lbl isEqualToString:@"follow"] ||
        [lbl isEqualToString:@"following"] ||
        [lbl hasPrefix:@"join "]) {
        return FBPConfirmKindFollow;
    }

    return FBPConfirmKindNone;
}

/// The preference that guards a kind, or nil when the kind is disabled here.
static NSString *FBPKeyForKind(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindLike:   return FBPKeyFeedLike;
        case FBPConfirmKindShare:  return FBPKeyConfirmShare;
        case FBPConfirmKindFollow: return FBPKeyConfirmFollow;
        case FBPConfirmKindFriend: return FBPKeyConfirmFriend;
        default:                   return nil;
    }
}

/// Which confirmable action this sender is, or None when it is not one of them.
///
/// ComponentKit does not consistently put the accessibility identifier on the
/// view that ends up as the sender — depending on how the component tree was
/// built it can sit on a wrapper above it or on the tappable child below.
/// Checking only the sender itself is why confirmation fired on some controls
/// and not others, so a couple of levels are searched in each direction.
static FBPConfirmKind FBPConfirmKindForSender(id sender, UIView **outMatch) {
    if (outMatch) *outMatch = nil;
    if (![sender isKindOfClass:UIView.class]) return FBPConfirmKindNone;
    UIView *view = (UIView *)sender;

    FBPConfirmKind kind = FBPKindForView(view);
    if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = view; return kind; }

    // Upwards: a wrapper carrying the identifier for its subtree.
    UIView *node = view.superview;
    for (NSInteger level = 0; node && level < 3; level++, node = node.superview) {
        kind = FBPKindForView(node);
        if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = node; return kind; }
    }

    // Downwards: the identifier on the actual glyph inside a tappable wrapper.
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    NSInteger visited = 0;
    while (queue.count && visited < 24) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        kind = FBPKindForView(candidate);
        if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = candidate; return kind; }
        [queue addObjectsFromArray:candidate.subviews];
    }

    return FBPConfirmKindNone;
}

/// YES when an accessibility label names an "already liked" state — i.e. tapping
/// would *remove* the reaction. Facebook labels the control "Like" when it will
/// add a like and "Unlike" when it will take one away (both are literal strings
/// in FBSharedFramework), so the label is the reliable signal.
static BOOL FBPLabelMeansLiked(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = label.lowercaseString;
    return [lower hasPrefix:@"unlike"] ||
           [lower containsString:@"remove like"] ||
           [lower containsString:@"remove reaction"];
}

/// YES when the like control is currently in the liked state, so the pending tap
/// is an *unlike* and must not be confirmed — undoing a like needs no guard.
///
/// The state lives on the same component as the like identifier (its label flips
/// to "Unlike", and it carries the selected trait), but ComponentKit sometimes
/// splits the identifier and the label across a wrapper and its glyph child, so
/// a shallow subtree is checked for the label too.
static BOOL FBPSenderIsCurrentlyLiked(UIView *view) {
    if (!view) return NO;
    if (view.accessibilityTraits & UIAccessibilityTraitSelected) return YES;
    if (FBPLabelMeansLiked(view.accessibilityLabel)) return YES;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    NSInteger visited = 0;
    while (queue.count && visited < 24) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if (FBPLabelMeansLiked(candidate.accessibilityLabel)) return YES;
        [queue addObjectsFromArray:candidate.subviews];
    }
    return NO;
}

/// Title, message and confirm-verb for a kind, read from the strings table. Like
/// builds its message from the sender's reaction label (see the hook), so this
/// returns its generic fallback for that kind.
static void FBPStringsForKind(FBPConfirmKind kind,
                              NSString **title, NSString **message, NSString **verb) {
    switch (kind) {
        case FBPConfirmKindShare:
            *title   = FBPL(@"confirm.share.title");
            *message = FBPL(@"confirm.share.message");
            *verb    = FBPL(@"confirm.share.verb");
            break;
        case FBPConfirmKindFollow:
            *title   = FBPL(@"common.confirm");
            *message = FBPL(@"confirm.follow.message");
            *verb    = FBPL(@"confirm.follow.verb");
            break;
        case FBPConfirmKindFriend:
            *title   = FBPL(@"confirm.friend.title");
            *message = FBPL(@"confirm.friend.message");
            *verb    = FBPL(@"common.confirm");
            break;
        case FBPConfirmKindLike:
        default:
            *title   = FBPL(@"confirm.like.title");
            *message = FBPL(@"confirm.like.message");
            *verb    = FBPL(@"confirm.like.verb");
            break;
    }
}

// Set while replaying a confirmed event, so the second pass through the hook
// falls straight through to the original. Logos cannot expand an orig call
// from inside a block, so the event is re-sent instead of being forwarded.
static BOOL gConfirmedPassthrough = NO;

%group FBPConfirm

%hook CKComponentActionControlForwarder

- (void)handleControlEventFromSender:(id)sender withEvent:(UIEvent *)event {
    if (gConfirmedPassthrough) {
        %orig;
        return;
    }

    UIView *match = nil;
    FBPConfirmKind kind = FBPConfirmKindForSender(sender, &match);
    NSString *key = FBPKeyForKind(kind);
    if (!key || !FBPEnabled(key)) {
        %orig;
        return;
    }

    // Confirm a like, never an unlike: if the control is already liked this tap
    // just undoes it, which needs no guard — let it through untouched.
    if (kind == FBPConfirmKindLike &&
        FBPSenderIsCurrentlyLiked(match ?: (UIView *)sender)) {
        %orig;
        return;
    }

    // A prompt is already up (the other confirmation path, or a stray second
    // event from the same tap). Drop this one rather than stacking a prompt —
    // the action still fires through the first prompt's confirm.
    if (FBPConfirmPromptVisible()) {
        return;
    }

    UIView *view = (UIView *)sender;
    UIViewController *host = view._viewControllerForAncestor
        ?: [FBPSheetPresenter topViewController];
    if (!host) {
        %orig;
        return;
    }
    while (host.presentedViewController) host = host.presentedViewController;

    NSString *alertTitle = nil, *message = nil, *verb = nil;
    FBPStringsForKind(kind, &alertTitle, &message, &verb);

    // For a like the sender's accessibility label ("Like", "Love", …) names the
    // exact reaction, so the message is tailored to it and stays correct across
    // reaction types and languages without shipping a copy of each.
    if (kind == FBPConfirmKindLike && view.accessibilityLabel.length) {
        message = [NSString stringWithFormat:@"Send a “%@” reaction?",
                   view.accessibilityLabel];
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:alertTitle
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        FBPSetConfirmPromptVisible(NO);
    }]];

    // Held strongly on purpose: the forwarder must outlive the prompt, or the
    // replay below would message a deallocated object.
    __block id forwarder = self;
    UIAlertAction *confirm =
        [UIAlertAction actionWithTitle:verb
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
        FBPSetConfirmPromptVisible(NO);
        // Only now does the action actually fire.
        gConfirmedPassthrough = YES;
        [forwarder handleControlEventFromSender:sender withEvent:event];
        gConfirmedPassthrough = NO;
    }];
    [alert addAction:confirm];
    alert.preferredAction = confirm;

    alert.view.tintColor = FBPTintColor();
    FBPSetConfirmPromptVisible(YES);
    [host presentViewController:alert animated:YES completion:nil];
}

%end

%end // FBPConfirm

void FBPInitConfirmHooks(void) {
    if (objc_getClass("CKComponentActionControlForwarder")) {
        FBP_ONCE(gConfirm) { %init(FBPConfirm); }
    } else {
        FBPLog(@"CKComponentActionControlForwarder not found — confirmations disabled");
    }
}
