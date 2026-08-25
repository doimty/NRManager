#import <Foundation/Foundation.h>
#import <stdio.h>
#import <unistd.h>

#import "CCNMMaintainerEnvironment.h"

typedef NS_ENUM(int, CCNMPostinstExitCode) {
    CCNMInstallAllowed = 0,
    CCNMPostinstBlocked = 74,
};

// dpkg calls postinst for `configure` and for three abort actions. Only these
// four leave the package installed and expecting to work, so only these four have
// anything to verify. Any other action means dpkg is unwinding and something else
// is about to take over.
static BOOL CCNMActionExpectsAWorkingInstall(NSString *action) {
    return [action isEqual:@"configure"] ||
        [action isEqual:@"abort-upgrade"] ||
        [action isEqual:@"abort-remove"] ||
        [action isEqual:@"abort-deconfigure"];
}

// One job: check the installed launchd plist against the contract that was
// reviewed, and print a sentinel the shell reads as permission to load the job.
//
// This used to also retire a removal guard -- a durable record that told prerm
// the package still held a band configuration needing restoration before it
// could be uninstalled. That whole mechanism is gone. Recovery is now a carrier
// defaults reload, which discards the carrier configuration outright and so
// undoes a narrowed modem without needing to know what was narrowed. With
// nothing for removal to be gated on, there is no guard left to arm or clear.
//
// Still compiled rather than folded into the shell: the plist contract is a
// structural comparison against a binary plist, and the shell has no plist
// parser on either lane -- plutil was one of the tools this release retired.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *action = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if (!CCNMActionExpectsAWorkingInstall(action)) {
            return CCNMInstallAllowed;
        }
        if (geteuid() != 0) {
            // dpkg always runs maintainer scripts as root, so this is an
            // out-of-band invocation rather than a device condition. Reading the
            // plist needs root, and so does loading the job.
            fprintf(stderr, "NetworkManagerReborn: installation guard must run as root.\n");
            return CCNMPostinstBlocked;
        }

        NSError *launchdError = nil;
        if (CCNMVerifyMaintenanceLaunchdContract(&launchdError)) {
            // The one line on stdout, and the shell reads it as the permission
            // to load the job. Everything else goes to stderr, so this cannot
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
