#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <stdio.h>
#import <string.h>
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

// The band selection is user preference data, not policy evidence, so it is not
// in CCNMN78PolicyPaths() and is never retired with the durable records: it has
// to outlive the off state, because a selection can be edited while the feature
// is disabled. Removal is the one moment it has no owner left, and dpkg will not
// do it -- the file lives under /var/mobile/Library/Preferences and was never
// part of the package payload.
//
// Leaving it behind is worse than untidy. A stored band the current SIM no longer
// offers makes the toggle refuse, and nothing in Settings names the stored value,
// so the one remedy every user reaches for -- remove and reinstall -- would
// silently inherit the same selection and fail again.
//
// This runs from prerm even though postrm is dpkg's hook for discarding data on
// removal, because this package has no postrm and adding one to the removal path
// is the larger risk: a new maintainer script there has to resolve the install
// prefix for itself and can block a removal outright, which is the failure this
// project has already been burned by. The price of choosing prerm is that an
// aborted removal loses the selection, which resets the toggle to the shipped
// default and is re-picked in Settings in one tap.
//
// Never a block. Failing to unlink a preference file leaves the modem exactly as
// it was, so refusing removal over it would turn a stale plist into an
// unremovable package.
static void CCNMDiscardRetiredBandSelection(void) {
    NSString *path = CCNMN78SelectedBandsPath();
    if (unlink(path.fileSystemRepresentation) == 0 || errno == ENOENT) {
        return;
    }
    fprintf(stderr,
        "NetworkManagerReborn: warning \u2014 the stored NR band selection at %s could not be "
        "discarded (%s), so a later reinstall will inherit it.\n",
        path.UTF8String, strerror(errno));
    fflush(stderr);
}

// The single point that authorizes removal. Routing every allowed verdict through
// here is what keeps the cleanup from being skipped by a later early return added
// above it.
//
// Only a real retirement discards the selection. upgrade and failed-upgrade hand
// the same records to a successor package, and deconfigure leaves this one
// unpacked, so none of them may throw away a preference the user still owns.
static CCNMPrermExitCode CCNMAllowRemoval(NSString *action) {
    if ([action isEqual:@"remove"]) {
        CCNMDiscardRetiredBandSelection();
    }
    return CCNMRemovalAllowed;
}

// Removal proceeds even when the modem is still narrowed, and the justification is
// a fact about the device rather than a smaller appetite for risk.
//
// The fail-closed design rested on one premise: that a narrowed NR set with no
// installed restore implementation could not be undone. That premise is false.
// Restoring the device's carrier configuration clears it. That was established by
// operator report on the reporting device, not derived here, and it is the reason
// this file changed. So there are three independent ways out, and none of them
// needs this package to be installed at the moment the user changes their mind:
// reinstall it and recover from Settings, restore the carrier configuration, or --
// where this guard can still reach CoreTelephony -- the restore attempted below.
//
// Against that, blocking has a cost that is not hypothetical. A blocked removal is
// an unremovable package, and the refusal is delivered as dpkg exit 73 plus stderr,
// which a graphical package manager may truncate or discard. What the user
// experiences is "uninstall does nothing" with the explanation lost. Trading a
// recoverable radio configuration for an unremovable package is the wrong trade.
//
// What replaces the block is the part that actually helps: the durable policy
// records are deliberately left in place. They live under
// /var/mobile/Library/Preferences and were never package payload, so dpkg does not
// remove them, and a reinstall reads the same baseline and offers the same recovery.
// Removal is therefore reversible by reinstalling, which is the remedy every user
// reaches for first.
static CCNMPrermExitCode CCNMAllowRemovalWithModifiedModem(NSString *action,
                                                           const char *reason) {
    fprintf(stderr,
        "NetworkManagerReborn: warning \u2014 the NR band configuration this package applied is "
        "still in place, and removal is proceeding anyway (%s). LTE was never modified, so the "
        "device keeps service. The policy records are kept on purpose: reinstall this package "
        "and use Settings > NetworkManagerReborn to put the original NR bands back. Restoring "
        "the device's carrier configuration also clears it.\n",
        reason ?: "reason unavailable");
    fflush(stderr);
    return CCNMAllowRemoval(action);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *action = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        NSString *versionArgument = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"";
        if (!CCNMActionRequiresRestore(action)) {
            return CCNMAllowRemoval(action);
        }
        if (geteuid() != 0) {
            // dpkg always runs maintainer scripts as root, so this is an unexpected
            // invocation rather than a device condition. It stays fail-closed: with
            // no root there is nothing this guard can read, restore, or clean up, and
            // refusing an out-of-band invocation cannot strand a real removal.
            fprintf(stderr, "NetworkManagerReborn: removal guard must run as root.\n");
            return CCNMPrermBlocked;
        }

        // Stopping the daemon is the shell's job, and it does it after this
        // guard returns a clean verdict. It has to be the shell: posix_spawn
        // refused the real launchctl binary from this process on the reporting
        // device (EPERM), while the shell in the same dpkg run exec'd both
        // `jbroot` and this guard without trouble.
        //
        // Ordering that way is safe. A live daemon cannot change this verdict or
        // disturb a restore performed here: it only writes its own status and record
        // files and never touches the modem.

        // Upgrade to a restore-capable version keeps the recovery path
        // installed, so this script must not touch policy state at all: no
        // restore attempt, no recovery marker, no guard arming. Whatever the
        // current policy is, the successor package reads the same records and
        // the Settings UI stays able to disable and recover.
        if (CCNMActionKeepsRestoreCapabilityInstalled(action, versionArgument)) {
            return CCNMAllowRemoval(action);
        }

        NSDictionary<NSString *, id> *current = CCNMReadN78PolicyState();
        if (CCNMSummaryIsClean(current) &&
            [current[@"verifiedKnownOrphanRestore"] boolValue] &&
            ![current[@"removalGuardPresent"] boolValue]) {
            return CCNMAllowRemoval(action);
        }
        NSDictionary<NSString *, id> *orphanEligibility = CCNMReadKnownOrphanedN78RemovalSafety();
        if ([orphanEligibility[@"eligible"] boolValue]) {
            return CCNMAllowRemovalWithModifiedModem(action,
                "this device matches the reviewed orphaned-NR evidence");
        }

        // An inconclusive live probe is a warning, not a verdict.
        //
        // It used to be fatal, on the reasoning that the known-orphan condition is
        // precisely "the durable records say clean while the modem is still
        // narrowed", so durable evidence cannot detect it and only a live read can.
        // That reasoning is sound and the conclusion drawn from it was still wrong,
        // because of something the reporting device settled: this probe cannot
        // succeed here at all. CoreTelephony answered EACCES
        // ("The operation couldn't be completed. Permission denied") for a guard
        // running as euid 0. The guard links no libroothide and is exec'd through a
        // bare path, so it receives neither the jailbreak's path redirection nor its
        // exemptions -- the same process-scoped restriction that already took
        // posix_spawn away from this binary. Nothing it could pass to CoreTelephony
        // would change that.
        //
        // A check that can only ever return "inconclusive" is not a safety
        // mechanism, it is an unconditional deny, and it made this package
        // impossible to remove on any device. Keeping it fatal bought no protection
        // that was ever available.
        //
        // The probe is kept for its diagnostic value, not as a gate. It still
        // identifies the reviewed orphaned-NR state above, and if a future build
        // ever reaches CoreTelephony from here -- the rootless lane, or an entitled
        // guard -- the restore below starts working again with no further change. Its
        // inability to answer is reported rather than hidden, because "this decision
        // used records only" is exactly what a later bug report needs to know.
        BOOL liveProbeUnavailable = ![orphanEligibility[@"conclusive"] boolValue];
        const char *liveProbeError = [orphanEligibility[CCNMN78PolicySummaryErrorKey]
            isKindOfClass:NSString.class]
            ? [orphanEligibility[CCNMN78PolicySummaryErrorKey] UTF8String] : "unknown";
        if (liveProbeUnavailable) {
            fprintf(stderr,
                "NetworkManagerReborn: warning \u2014 the live band configuration could not be read from the "
                "package manager (error=%s), so this decision rests on the durable policy records alone.\n",
                liveProbeError);
            fflush(stderr);
        }
        if (CCNMSummaryAllowsRemoval(current)) {
            return CCNMAllowRemoval(action);
        }
        if (CCNMSummaryIsClean(current)) {
            // The guard closes the window between this verdict and dpkg actually
            // unpacking the removal. Failing to arm it does not leave a modified
            // modem behind -- the records say clean -- it only means a reinstall
            // arriving inside that window re-examines the records instead of seeing
            // an authorized removal. A lost optimisation, not a stranded radio, so
            // it is reported and removal continues.
            NSDictionary *armed = CCNMArmN78PolicyRemovalGuard();
            if (!CCNMSummaryAllowsRemoval(armed)) {
                fprintf(stderr,
                    "NetworkManagerReborn: warning \u2014 the policy records are clean but the removal "
                    "guard could not be armed (error=%s), so a reinstall during this removal will "
                    "re-examine the records from scratch.\n",
                    [armed[CCNMN78PolicySummaryErrorKey] isKindOfClass:NSString.class]
                        ? [armed[CCNMN78PolicySummaryErrorKey] UTF8String] : "unknown");
                fflush(stderr);
            }
            return CCNMAllowRemoval(action);
        }

        // Past this point the records say this package still owns a modified modem.
        // Restoring it here is the best available outcome, so it is attempted, but it
        // is no longer a precondition for removal.
        //
        // The restore needs the same CoreTelephony access the probe just failed to
        // get, so when the probe could not answer, attempting it is not merely
        // futile -- it is harmful. Every failure path inside the recovery routine
        // durably marks the policy state recoveryRequired/rebootRequired, and that
        // marker keeps the removal guard armed, so one failed attempt from here
        // turns every later install into a half-configured package whose Settings
        // UI can no longer perform the recovery the user needs. That is the same trap
        // the upgrade exemption above exists to avoid.
        //
        // Settings is the owner that can actually do this. It runs inside a host
        // that CoreTelephony will talk to, and its restore path is confirmed working
        // on the reporting device. So the honest answer here is to skip the attempt,
        // name that owner, and let the package go, rather than to burn the policy
        // state proving a point already proven.
        if (liveProbeUnavailable) {
            return CCNMAllowRemovalWithModifiedModem(action,
                "the modem cannot be reached from the package manager");
        }

        fprintf(stderr,
            "NetworkManagerReborn: restoring and verifying the original NR configuration before %s.\n",
            action.UTF8String);
        fflush(stderr);

        CCNMRecoverN78Preference(^(NSDictionary<NSString *, id> *summary) {
            NSDictionary *finalSummary = CCNMSummaryIsClean(summary)
                ? CCNMArmN78PolicyRemovalGuard() : summary;
            // A failed restore is reported with its own error code, and the modem is
            // left as the recovery routine left it, including any
            // recoveryRequired/rebootRequired marker it wrote. Removal still
            // proceeds, and preserving that marker is the reason it can: the marker
            // is what tells a reinstalled Settings UI there is something to recover.
            if (!CCNMSummaryAllowsRemoval(finalSummary)) {
                NSString *errorCode = [finalSummary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
                    ? finalSummary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
                fprintf(stderr,
                    "NetworkManagerReborn: the original NR configuration was not verified (error=%s, reboot=%s).\n",
                    errorCode.UTF8String,
                    [finalSummary[CCNMN78PolicySummaryRequiresRebootKey] boolValue] ? "required" : "not-required");
                fflush(stderr);
                CCNMExitWhenSetterSettled(
                    CCNMAllowRemovalWithModifiedModem(action, "the restore did not verify"));
                return;
            }
            CCNMExitWhenSetterSettled(CCNMAllowRemoval(action));
        });
        dispatch_main();
    }
}
