#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

#import "CCNMMaintainerEnvironment.h"
#import "../networkmanagerprefs/CCNMN78PolicyController.h"

typedef NS_ENUM(int, CCNMPrermExitCode) {
    CCNMRemovalAllowed = 0,
    CCNMPrermBlocked = 73,
};

static BOOL CCNMActionRequiresRestore(NSString *action) {
    return [action isEqual:@"remove"] ||
        [action isEqual:@"upgrade"] ||
        [action isEqual:@"deconfigure"] ||
        [action isEqual:@"failed-upgrade"];
}

static BOOL CCNMSummaryIsClean(NSDictionary<NSString *, id> *summary) {
    return [summary[CCNMN78PolicySummarySuccessKey] boolValue] &&
        [summary[CCNMN78PolicySummaryMayUninstallKey] boolValue] &&
        ![summary[@"baselinePresent"] boolValue] &&
        ![summary[@"transitionPresent"] boolValue] &&
        [summary[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeSystemDefault] &&
        [summary[CCNMN78PolicySummaryAppliedPolicyKey] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [summary[CCNMN78PolicySummaryRecoveryStateKey] isEqual:CCNMRecoveryStateClean];
}

static BOOL CCNMSummaryAllowsRemoval(NSDictionary<NSString *, id> *summary) {
    return CCNMSummaryIsClean(summary) &&
        [summary[@"removalGuardPresent"] boolValue] &&
        [summary[@"removalGuardValid"] boolValue];
}

static void CCNMExitWhenSetterSettled(CCNMPrermExitCode exitCode) {
    if (CCNMN78PolicyHasOutstandingSetter()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            CCNMExitWhenSetterSettled(exitCode);
        });
        return;
    }
    _exit(exitCode);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *action = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if (!CCNMActionRequiresRestore(action)) {
            return CCNMRemovalAllowed;
        }
        if (geteuid() != 0) {
            fprintf(stderr, "NetworkManagerReborn: removal guard must run as root.\n");
            return CCNMPrermBlocked;
        }

        NSError *launchdError = nil;
        if (!CCNMStopMaintenanceLaunchd(&launchdError)) {
            fprintf(stderr,
                "NetworkManagerReborn: removal blocked; maintenance owner is still active (%s).\n",
                launchdError.localizedDescription.UTF8String ?: "unknown");
            return CCNMPrermBlocked;
        }

        NSDictionary<NSString *, id> *current = CCNMReadN78PolicyState();
        if (CCNMSummaryIsClean(current) &&
            [current[@"verifiedKnownOrphanRestore"] boolValue] &&
            ![current[@"removalGuardPresent"] boolValue]) {
            return CCNMRemovalAllowed;
        }
        NSDictionary<NSString *, id> *orphanEligibility = CCNMReadKnownOrphanedN78RemovalSafety();
        if ([orphanEligibility[@"eligible"] boolValue]) {
            fprintf(stderr,
                "NetworkManagerReborn: removal blocked; confirm the reviewed one-time NR recovery in Settings first.\n");
            fflush(stderr);
            return CCNMPrermBlocked;
        }

        if (![orphanEligibility[@"conclusive"] boolValue]) {
            fprintf(stderr,
                "NetworkManagerReborn: removal blocked; the live band configuration could not be proven clean (error=%s).\n",
                [orphanEligibility[CCNMN78PolicySummaryErrorKey] isKindOfClass:NSString.class]
                    ? [orphanEligibility[CCNMN78PolicySummaryErrorKey] UTF8String] : "unknown");
            fflush(stderr);
            return CCNMPrermBlocked;
        }
        if (CCNMSummaryAllowsRemoval(current)) {
            return CCNMRemovalAllowed;
        }
        if (CCNMSummaryIsClean(current)) {
            NSDictionary *armed = CCNMArmN78PolicyRemovalGuard();
            return CCNMSummaryAllowsRemoval(armed) ? CCNMRemovalAllowed : CCNMPrermBlocked;
        }

        fprintf(stderr,
            "NetworkManagerReborn: restoring and verifying the original NR configuration before %s.\n",
            [action isEqual:@"upgrade"] ? "upgrade/downgrade" : action.UTF8String);
        fflush(stderr);

        CCNMRecoverN78Preference(^(NSDictionary<NSString *, id> *summary) {
            NSDictionary *finalSummary = CCNMSummaryIsClean(summary)
                ? CCNMArmN78PolicyRemovalGuard() : summary;
            BOOL allowed = CCNMSummaryAllowsRemoval(finalSummary);
            if (!allowed) {
                NSString *errorCode = [finalSummary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
                    ? finalSummary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
                fprintf(stderr,
                    "NetworkManagerReborn: removal blocked; original NR configuration was not verified (error=%s, reboot=%s).\n",
                    errorCode.UTF8String,
                    [finalSummary[CCNMN78PolicySummaryRequiresRebootKey] boolValue] ? "required" : "not-required");
                fflush(stderr);
            }
            CCNMExitWhenSetterSettled(allowed ? CCNMRemovalAllowed : CCNMPrermBlocked);
        });
        dispatch_main();
    }
}
