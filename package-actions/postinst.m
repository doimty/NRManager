#import <Foundation/Foundation.h>
#import <unistd.h>

#import "CCNMMaintainerEnvironment.h"
#import "../networkmanagerprefs/CCNMN78PolicyController.h"

typedef NS_ENUM(int, CCNMPostinstExitCode) {
    CCNMInstallAllowed = 0,
    CCNMPostinstBlocked = 74,
};

static BOOL CCNMActionMayClearRemovalGuard(NSString *action) {
    return [action isEqual:@"configure"] ||
        [action isEqual:@"abort-upgrade"] ||
        [action isEqual:@"abort-remove"] ||
        [action isEqual:@"abort-deconfigure"];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *action = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if (!CCNMActionMayClearRemovalGuard(action)) {
            return CCNMInstallAllowed;
        }
        if (geteuid() != 0) {
            fprintf(stderr, "NetworkManagerReborn: installation guard must run as root.\n");
            return CCNMPostinstBlocked;
        }

        NSDictionary<NSString *, id> *summary = CCNMClearN78PolicyRemovalGuardIfSafe();
        BOOL cleared = [summary[CCNMN78PolicySummarySuccessKey] boolValue] &&
            ![summary[@"removalGuardPresent"] boolValue];
        if (!cleared) {
            NSString *errorCode = [summary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
                ? summary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
            fprintf(stderr,
                "NetworkManagerReborn: installation guard could not be cleared safely (error=%s).\n",
                errorCode.UTF8String);
            return CCNMPostinstBlocked;
        }

        NSError *launchdError = nil;
        if (!CCNMRegisterMaintenanceLaunchd(&launchdError)) {
            fprintf(stderr,
                "NetworkManagerReborn: warning — maintenance owner could not be registered (%s).\n"
                "  The package will work without the maintenance daemon, but automatic\n"
                "  serving-state monitoring will be unavailable. The registration can be\n"
                "  retried by reinstalling or running the postinst manually.\n",
                launchdError.localizedDescription.UTF8String ?: "unknown");
        }
        return CCNMInstallAllowed;
    }
}
