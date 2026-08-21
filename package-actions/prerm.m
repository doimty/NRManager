#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdio.h>
#import <unistd.h>

#import "CCNMDpkgVersion.h"
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

// Only a departure of the code itself can strand a modified modem. On remove
// and deconfigure the restore implementation goes away, so an unverified
// restore must stay fail-closed.
//
// upgrade and failed-upgrade are different in kind. The successor package
// ships the same baseline path and the same restore implementation, and the
// durable policy records live outside the package payload, so there is nothing
// to strand. Worse, attempting the restore here is not side-effect free: every
// failure path inside the recovery routine durably marks the policy state as
// recoveryRequired/rebootRequired. That marker then keeps the removal guard
// armed, so a single failed restore attempt turns every later install into a
// half-configured package with no working Settings UI to perform the recovery
// the error message demands.
//
// The exemption is not unconditional. dpkg invokes `old-prerm upgrade
// <new-version>`, and a downgrade uses the same action, so a downgrade to a
// build that predates the policy controller really would orphan the baseline.
// The floor below is the first release that can restore it.
static NSString *const CCNMFirstRestoreCapableVersion = @"1.5.0";

static BOOL CCNMActionKeepsRestoreCapabilityInstalled(NSString *action,
                                                      NSString *versionArgument) {
    // `new-prerm failed-upgrade <old-version>`: this binary belongs to the
    // incoming package, so the restore implementation is the one taking over.
    if ([action isEqual:@"failed-upgrade"]) {
        return YES;
    }
    if (![action isEqual:@"upgrade"]) {
        return NO;
    }
    // `old-prerm upgrade <new-version>`.
    if (![versionArgument isKindOfClass:NSString.class]) {
        return NO;
    }
    return CCNMDpkgVersionIsAtLeast(versionArgument.UTF8String,
        CCNMFirstRestoreCapableVersion.UTF8String);
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
        NSString *versionArgument = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"";
        if (!CCNMActionRequiresRestore(action)) {
            return CCNMRemovalAllowed;
        }
        if (geteuid() != 0) {
            fprintf(stderr, "NetworkManagerReborn: removal guard must run as root.\n");
            return CCNMPrermBlocked;
        }

        // Stopping the daemon is the shell's job, and it does it after this
        // guard returns a clean verdict. It has to be the shell: posix_spawn
        // refused the real launchctl binary from this process on the reporting
        // device (EPERM), while the shell in the same dpkg run exec'd both
        // `jbroot` and this guard without trouble.
        //
        // Ordering that way is safe in both directions. A live daemon cannot
        // change this verdict or disturb a restore performed here: it only writes
        // its own status and record files and never touches the modem. And on a
        // blocked removal the daemon is deliberately left running, because the
        // package stays installed and monitoring should keep working while the
        // user performs the recovery they are being told to perform.

        // Upgrade to a restore-capable version keeps the recovery path
        // installed, so this script must not touch policy state at all: no
        // restore attempt, no recovery marker, no guard arming. Whatever the
        // current policy is, the successor package reads the same records and
        // the Settings UI stays able to disable and recover.
        if (CCNMActionKeepsRestoreCapabilityInstalled(action, versionArgument)) {
            return CCNMRemovalAllowed;
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
            action.UTF8String);
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
