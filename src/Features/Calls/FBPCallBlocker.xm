// Call blocker: stop the sideloaded Facebook app from ringing for Messenger
// calls, so an incoming call reaches only the real Messenger app.
//
// When Facebook and Messenger are both installed, each registers for VoIP and
// both ring at once, and the call cannot be answered cleanly. We silence calls
// in Facebook ONLY, at the two points that are specific to calling and nowhere
// near ordinary notifications:
//
//   1. PushKit — strip PKPushTypeVoIP from -setDesiredPushTypes:. Facebook never
//      registers for VoIP pushes, so Apple stops delivering call pushes to it
//      and routes them to Messenger instead. This is the real fix, at the source.
//
//   2. CallKit — no-op -[CXProvider reportNewIncomingCallWithUUID:update:
//      completion:]. A belt-and-suspenders guard: if a VoIP push still slips
//      through (e.g. Facebook registered before this hook installed), no incoming
//      call UI is presented. The completion is still invoked so the caller does
//      not stall.
//
// This touches PushKit and CallKit only. It never touches UNUserNotificationCenter,
// -application:didReceiveRemoteNotification:…, or APNs registration, so every
// non-call notification (messages, reactions, reminders, …) keeps working.
//
// Always on — there is no preference gate. PKPushRegistry and CXProvider are
// system classes that always exist, so the installer latches once on first run.

#import "FBPlus.h"

#import <PushKit/PushKit.h>
#import <CallKit/CallKit.h>
#import <objc/runtime.h>

%group FBPCallBlocker

%hook PKPushRegistry

- (void)setDesiredPushTypes:(NSSet<PKPushType> *)desiredPushTypes {
    if ([desiredPushTypes containsObject:PKPushTypeVoIP]) {
        NSMutableSet *stripped = [desiredPushTypes mutableCopy];
        [stripped removeObject:PKPushTypeVoIP];
        desiredPushTypes = stripped;
    }
    %orig(desiredPushTypes);
}

%end

%hook CXProvider

- (void)reportNewIncomingCallWithUUID:(NSUUID *)UUID
                               update:(CXCallUpdate *)update
                           completion:(void (^)(NSError *error))completion {
    // Swallow the call: do not present any call UI. Still invoke the completion
    // (with no error) so Facebook's call-setup code does not hang waiting on it.
    if (completion) completion(nil);
}

%end

%end // FBPCallBlocker

void FBPInitCallBlocker(void) {
    FBP_ONCE(gCallBlocker) { %init(FBPCallBlocker); }
}
