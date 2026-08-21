#import <Foundation/Foundation.h>
#import <stdio.h>
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
        // CCNMClearN78PolicyRemovalGuardIfSafe reports the whole policy summary,
        // and that summary carries success=NO whenever the live policy needs
        // recovery — including the case where no guard exists at all. Keying the
        // decision on the success flag therefore failed configure for a state
        // this script is not responsible for and cannot repair. Only a guard
        // that is still present is meaningful here.
        if ([summary[@"removalGuardPresent"] boolValue]) {
            NSString *errorCode = [summary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
                ? summary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
            // An armed guard cannot cause harm from here: it forces mayWrite to
            // NO, so no modem write can happen, and mayUninstall still requires
            // a verified system-default state, so removal stays gated. Blocking
            // configure would only strand the package half-configured and take
            // away the Settings UI that performs the recovery this needs.
            fprintf(stderr,
                "NetworkManagerReborn: warning — the package-removal guard is still armed (error=%s).\n"
                "  Band policy changes stay disabled while it is armed, and removal still\n"
                "  requires a verified restore. Recover the NR configuration in Settings,\n"
                "  then reinstall to retire the guard.\n",
                errorCode.UTF8String);
        }

        NSError *launchdError = nil;
        if (CCNMVerifyMaintenanceLaunchdContract(&launchdError)) {
            // The one line on stdout, and the shell reads it as the permission
            // to load the job. Everything above went to stderr, so this cannot
            // be confused with a diagnostic.
            printf("%s\n", CCNMMaintenanceLaunchdVerifiedSentinel.UTF8String);
            fflush(stdout);
        } else {
            // No sentinel, so the shell will not load the job, and it says so
            // itself. Configure still succeeds: the daemon only provides
            // automatic serving-state monitoring and owns no policy or modem
            // state, so a host where the plist or the helper is unusable must
            // still end up with a fully configured package rather than a
            // permanently half-installed one.
            fprintf(stderr,
                "NetworkManagerReborn: warning — the maintenance owner will not be started (%s).\n"
                "  Band policy changes work. Automatic serving-state monitoring is\n"
                "  unavailable until this is corrected.\n",
                launchdError.localizedDescription.UTF8String ?: "unknown");
        }
        return CCNMInstallAllowed;
    }
}
