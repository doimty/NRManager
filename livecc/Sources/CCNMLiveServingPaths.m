#import <Foundation/Foundation.h>

#import "CCNMN78PolicyController.h"

static NSString *const CCNMLiveBundleMarker =
    @"/Library/ControlCenter/Bundles/NetworkManagerLive.bundle";

static NSString *CCNMLiveResolvedPath(NSString *suffix) {
    Class moduleClass = NSClassFromString(@"NetworkManagerLiveModule");
    NSString *bundlePath = moduleClass
        ? [NSBundle bundleForClass:moduleClass].bundlePath : nil;
    NSRange markerRange = [bundlePath rangeOfString:CCNMLiveBundleMarker
        options:NSBackwardsSearch];
    if (!bundlePath || markerRange.location == NSNotFound ||
        NSMaxRange(markerRange) != bundlePath.length || ![suffix hasPrefix:@"/"]) {
        return [@"/nonexistent/networkmanager-live" stringByAppendingString:suffix ?: @""];
    }
    NSString *prefix = [bundlePath substringToIndex:markerRange.location];
    return [prefix stringByAppendingString:suffix];
}

CCNMServingState const CCNMServingStateNRN78 = @"nrN78";
CCNMServingState const CCNMServingStateNROther = @"nrOther";
CCNMServingState const CCNMServingStateLTE = @"lteBand";
CCNMServingState const CCNMServingStateOther = @"other";
CCNMServingState const CCNMServingStateUnknown = @"unknown";

NSString *CCNMN78PolicyStatePath(void) {
    return CCNMLiveResolvedPath(
        @"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.state.plist");
}

NSString *CCNMN78PolicyLockPath(void) {
    return CCNMLiveResolvedPath(
        @"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.lock");
}
