// Private interfaces of the Facebook iOS app and of UIKit that the hooks bind
// to, verified against Facebook v570 and v574.
//
// Declaring them does not create a link-time dependency; they are resolved
// through the Objective-C runtime at hook-install time.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Private UIKit

@interface UIResponder (FBPPrivate)
/// Nearest ancestor view controller. Private UIKit API, not Facebook's.
- (nullable UIViewController *)_viewControllerForAncestor;
@end

#pragma mark - Feed

/// FBSharedFramework. Subclass of GQLModel. Every feed unit passes through
/// -initWithFBPandoTree:.
@interface FBMemModelObject : NSObject
- (nullable NSString *)category;
- (nullable id)sponsoredData;
- (nullable NSString *)storyBucketType;
@end

#pragma mark - Ads (specialised ad sources, outside the feed-model path)

/// FBSharedFramework. Builds the array of ad items inserted into the Watch /
/// video feed; returning an empty -insertedItems suppresses them.
@interface FBVideoFeedAdsPool : NSObject
- (NSArray *)insertedItems;
@end

/// FBSharedFramework. Fetches the ads interleaved between stories; the fetch
/// entry points are no-oped to keep story ads from ever loading.
@interface FBSnacksAdsPaginatingFetcher : NSObject
@end

#pragma mark - Action-confirmation targets
//
// Each exposes the single method that commits the action, verified present in
// FBSharedFramework. The hooks guard that method behind an opt-in prompt.

@interface FBCommentCreateMutator : NSObject
- (void)publishWithSession:(id)session;
@end

@interface FBPersonFriendableTableViewCell : UITableViewCell
- (void)handleFriendButtonTapped:(id)sender;
@end

@interface FBPersonFriendable2TableViewCell : UITableViewCell
- (void)handleFriendButtonTapped:(id)sender;
@end

@interface FBSnacksFeedbackComposerShareButtonComponentController : NSObject
- (void)didTapShareButton;
@end

@interface FBSnacksFollowButtonComponentController : NSObject
- (void)didTapFollowButton;
@end

#pragma mark - Stories ("Snacks")

@interface FBSnacksBucketsSeenStateManager : NSObject
@end

@interface FBSnacksThreadSwitcherViewController : UIViewController
@end

@interface FBSnacksBucketViewController : UIViewController
@end

#pragma mark - Reels / Shorts

@interface FBShortsSideBarView : UIView
@end

@interface CKSurfaceViewControllerImpl : UIViewController
- (nullable id)viewManager;
@end

@interface CKSurfaceRootView : UIView
@end

@interface FBTransparentView : UIView
@end

#pragma mark - ComponentKit action routing

/// Every ComponentKit-built control event funnels through this one forwarder,
/// which is what makes it a viable interception point for like confirmation.
@interface CKComponentActionControlForwarder : NSObject
- (void)handleControlEventFromSender:(id)sender withEvent:(nullable UIEvent *)event;
@end

#pragma mark - Chrome

@interface FBTabBarContainerView : UIView
@end

@interface FBTabBarItemDefaultView : UIView
@end

// iOS 26+ "liquid glass" tab bars. FBFloatingTabBar is the floating pill bar and
// FBNativeTabBar wraps the system bar; both are METANoCodingView (a UIView
// subclass) and replace the classic FBTabBarContainerView on newer builds.
@interface FBFloatingTabBar : UIView
@end

@interface FBNativeTabBar : UIView
@end

@interface FBBaseAppDelegate : UIResponder <UIApplicationDelegate>
@end

// Facebook's in-app browser (IAB). Its initial-URL load is intercepted to hand
// external links to the default browser.
@interface FBWebViewController : UIViewController
@end

#pragma mark - OLED targets
//
// The chrome and feed container views whose background fills the screen. Forcing
// these to pure black in dark mode is what turns the app AMOLED-black. Each is
// hooked only when present, so a build that renames one loses only that surface.

@interface FBTabBar : UIView
@end

@interface FBTabBarAndContentView : UIView
@end

@interface FBTopBarAndContentView : UIView
@end

@interface FBMovableNavigationBarView : UIView
@end

@interface FBNewsFeedView : UIView
@end

@interface FBNewsFeedCollectionView : UICollectionView
@end

NS_ASSUME_NONNULL_END
