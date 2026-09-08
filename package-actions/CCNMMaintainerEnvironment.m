#import "CCNMMaintainerEnvironment.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const CCNMMaintenanceLaunchdLabel =
    @"com.doimty.nrmanager.maintenance";

// The one machine-readable line the install guard writes to stdout, and only
// after the shipped plist has been verified against the reviewed contract.
// Everything else the guard says goes to stderr, so the shell can read stdout as
// a verdict rather than parse prose.
//
// The shell must not load a job this file has just reported as mismatched, and
// whether the shipped binary plist matches is the one question a shell cannot
// answer for itself. Answering it here is what the retired plutil dependency was.
NSString *const CCNMMaintenanceLaunchdVerifiedSentinel =
    @"launchd-contract-verified";

static NSString *const CCNMMaintenanceLaunchdRelativePath =
    @"/Library/LaunchDaemons/com.doimty.nrmanager.maintenance.plist";
static NSString *const CCNMMaintenanceExecutableRelativePath =
    @"/usr/libexec/nrmanager-maintenance";
static NSString *const CCNMMaintenanceBaselineRelativePath =
    @"/var/mobile/Library/Preferences/"
     "com.doimty.nrmanager.n78-policy.baseline.plist";
static NSString *const CCNMMaintenancePreferencesDirectory =
    @"/var/mobile/Library/Preferences";
static NSString *const CCNMMaintainerErrorDomain =
    @"com.doimty.nrmanager.maintainer";

typedef NS_ENUM(NSInteger, CCNMMaintainerErrorCode) {
    CCNMMaintainerErrorRoot = 1,
    CCNMMaintainerErrorPath,
    CCNMMaintainerErrorPlist,
};

static BOOL CCNMSetError(NSError **error,
                         CCNMMaintainerErrorCode code,
                         NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:CCNMMaintainerErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

// Two different prefixes are in play here and conflating them was the original
// mistake.
//
// The install prefix is what this process must prepend to reach an installed
// file. On roothide it is the real jailbreak root, because this process is not
// redirected: it links no libroothide and is exec'd through a bare path, so a
// bare path lands on the real root.
//
// The launchd prefix is what must literally appear inside the plist. On roothide
// it is *empty*, and that is not a degenerate case to be rejected. roothide's
// launchctl is itself redirected and rewrites every absolute path in the plist as
// jbroot(path) before launchd sees it, guarding re-entry only with a __Patched
// flag it sets itself. A plist that already carries the jailbreak root therefore
// gets a second one, which is what produced
//
//     program = <jbroot>/<jbroot>/usr/libexec/nrmanager-maintenance
//
// on the reporting device, and then the dyld failure that followed from it:
// @loader_path resolved into a directory that does not exist, so the daemon's
// libroothide.dylib could not be found beside it.
//
// So on roothide the two prefixes are genuinely different values, not the same
// value asked for twice. Rejecting an empty launchd prefix here was the second
// half of the same defect.
//
// Both are handed over by the shell maintainer script, which already had to
// determine them. Re-deriving either one here would be a second, weaker guess,
// and on roothide a wrong one: the guard is invoked through a bare path, so its
// own executable path carries no jbroot component, and scanning the bundle
// container from a redirected process looks inside the jailbreak root rather
// than at it.
static NSString *const CCNMInstallPrefixVariable =
    @"NETWORKMANAGER_INSTALL_PREFIX";
static NSString *const CCNMLaunchdPrefixVariable =
    @"NETWORKMANAGER_LAUNCHD_PREFIX";

// An absolute path with no trailing slash, or nil. Empty is accepted only where
// the caller asks for it, because the two prefixes differ on exactly that point.
static NSString *CCNMPrefixFromEnvironment(NSString *variable,
                                           BOOL emptyIsValid) {
    const char *value = getenv(variable.UTF8String);
    if (!value) {
        return nil;
    }
    if (value[0] == '\0') {
        return emptyIsValid ? @"" : nil;
    }
    NSString *prefix = [NSString stringWithUTF8String:value];
    // Anything relative would silently build paths against dpkg's working
    // directory; a trailing slash would produce a doubled separator inside the
    // plist, where the value is compared literally.
    if (![prefix hasPrefix:@"/"] || [prefix hasSuffix:@"/"]) {
        return nil;
    }
    return prefix;
}

// The prefix this process prepends to reach installed files.
//
// nil means it could not be determined, and no installed path is trustworthy.
//
// Never @"" unless a bare path was *measured* to work. An empty prefix is only
// correct for a process whose paths are rewritten for it, and this one's are not:
// it links no libroothide and is exec'd through a bare path, so it is not
// injected either. Accepting an exported empty prefix on faith pointed every read
// at the real root. That produced a launchd plist reported missing seconds after
// the shell wrote it, and — the serious half — policy records that all read as
// absent, which is indistinguishable from a clean band configuration.
//
// So the exported value is a hint, not a contract. Candidates are still supplied
// rather than derived, because deriving one here is a weaker guess: the
// executable path carries no .jbroot- component to work from. But each candidate
// is now checked against this package's own anchor file before it is trusted,
// which is a question this process can answer for itself.
static NSString *CCNMInstallPrefixProbeReport = nil;

typedef NS_ENUM(NSInteger, CCNMPrefixVerdict) {
    CCNMPrefixAbsent = 0,
    CCNMPrefixInconclusive,
    CCNMPrefixUsable,
};

// stat(2) only, and deliberately no access(X_OK). On this platform that check is
// routed through an exec-authorization hook and returned EPERM for a freshly
// unpacked, perfectly runnable binary on the reporting device. Nothing here
// executes the anchor; it only has to be present.
static CCNMPrefixVerdict CCNMVerdictForPrefix(NSString *prefix, int *outErrno) {
    NSString *anchor =
        [prefix stringByAppendingString:CCNMMaintenanceExecutableRelativePath];
    struct stat info;
    if (stat(anchor.fileSystemRepresentation, &info) == 0) {
        *outErrno = 0;
        // Something that is not a regular file where our helper belongs is not
        // this package's install root.
        return S_ISREG(info.st_mode) ? CCNMPrefixUsable : CCNMPrefixAbsent;
    }
    *outErrno = errno;
    switch (errno) {
    case ENOENT:
    case ENOTDIR:
    case ENAMETOOLONG:
    case ELOOP:
        // The path was resolved and there is nothing at the end of it.
        return CCNMPrefixAbsent;
    default:
        // EPERM and friends mean stat declined to answer, which is not an answer
        // of "absent". Ranked below a confirmed hit and above a confirmed miss.
        return CCNMPrefixInconclusive;
    }
}

NSString *CCNMMaintainerInstallPrefix(void) {
    static NSString *prefix;
    static BOOL resolved;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        void (^offer)(NSString *) = ^(NSString *candidate) {
            if (candidate && ![candidates containsObject:candidate]) {
                [candidates addObject:candidate];
            }
        };
        // Both maintainer-script variables can carry a real absolute root, so
        // either one can answer this; empty is rejected for both here, because an
        // empty answer is what this function no longer takes on trust. On roothide
        // the launchd variable is legitimately empty and simply contributes
        // nothing, which is correct: it is not a filesystem root.
        offer(CCNMPrefixFromEnvironment(CCNMInstallPrefixVariable, NO));
        offer(CCNMPrefixFromEnvironment(CCNMLaunchdPrefixVariable, NO));
        // Compile-time value for the rootless lane, where the prefix is a fixed
        // property of the package rather than of the running system. Empty on
        // roothide, where it is not a property of anything.
#if defined(THEOS_PACKAGE_INSTALL_PREFIX)
        const char *compiled = THEOS_PACKAGE_INSTALL_PREFIX;
        if (compiled && compiled[0] == '/') {
            offer([NSString stringWithUTF8String:compiled]);
        }
#endif
        // Last, and only if the anchor is actually reachable that way: bare
        // paths, which are correct for a process whose paths are rewritten for
        // it. The probe decides whether this process is one, not a comment.
        offer(@"");

        NSMutableArray<NSString *> *report = [NSMutableArray array];
        NSMutableArray<NSString *> *inconclusive = [NSMutableArray array];
        for (NSString *candidate in candidates) {
            int probeErrno = 0;
            CCNMPrefixVerdict verdict = CCNMVerdictForPrefix(candidate, &probeErrno);
            NSString *shown = candidate.length > 0 ? candidate : @"(bare paths)";
            [report addObject:[NSString stringWithFormat:@"%@ %@", shown,
                verdict == CCNMPrefixUsable ? @"holds the maintenance helper"
                    : [NSString stringWithFormat:@"errno %d", probeErrno]]];
            if (verdict == CCNMPrefixUsable && !resolved) {
                prefix = candidate;
                resolved = YES;
            } else if (verdict == CCNMPrefixInconclusive) {
                [inconclusive addObject:candidate];
            }
        }
        // Nothing was confirmed, but something refused to answer. Prefer that
        // over giving up: a prefix stat cannot see into is still more likely to
        // be the right one than a prefix stat positively ruled out.
        if (!resolved && inconclusive.count > 0) {
            prefix = inconclusive.firstObject;
            resolved = YES;
        }
        CCNMInstallPrefixProbeReport = [report componentsJoinedByString:@", "];
    });
    return resolved ? prefix : nil;
}

// The prefix that must appear inside the launchd plist.
//
// Empty is a valid answer and is distinct from unset. Empty means "bare paths
// belong in the plist", which is correct on roothide because launchctl prepends
// the jailbreak root itself. Unset means the maintainer script did not say, and
// then there is nothing to compare the installed plist against.//
// *resolved therefore carries set-ness and the return value carries the prefix;
// a nil return with *resolved == YES is impossible.
//
// Internal: every caller outside this file wants a path, not a prefix.
static NSString *CCNMMaintainerLaunchdPrefix(BOOL *resolved) {
    static NSString *prefix;
    static BOOL didResolve;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *raw = getenv(CCNMLaunchdPrefixVariable.UTF8String);
        if (raw) {
            // Set, so it answers the question even when empty. A malformed
            // non-empty value is still rejected: it would be compared literally
            // against the plist and could only ever mismatch, so reporting "not
            // determined" is more accurate than reporting a mismatch.
            prefix = CCNMPrefixFromEnvironment(CCNMLaunchdPrefixVariable, YES);
            didResolve = prefix != nil;
            return;
        }
#if defined(THEOS_PACKAGE_INSTALL_PREFIX)
        // Compile-time value for the rootless lane only. Not a fallback for an
        // empty export, which is already an answer.
        const char *compiled = THEOS_PACKAGE_INSTALL_PREFIX;
        if (compiled && compiled[0] == '/') {
            prefix = [NSString stringWithUTF8String:compiled];
            didResolve = prefix != nil;
        }
#endif
    });
    if (resolved) {
        *resolved = didResolve;
    }
    return prefix;
}

// A real absolute jailbreak root, or nil when installed paths resolve bare.
// Distinct from the install prefix: an empty prefix is a valid answer there but
// is not a root that can be prepended to a launchctl candidate.
NSString *CCNMMaintainerJailbreakRoot(void) {
    NSString *prefix = CCNMMaintainerInstallPrefix();
    return prefix.length > 0 ? prefix : nil;
}

NSString *CCNMMaintainerRootedPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) {
        return nil;
    }
    NSString *prefix = CCNMMaintainerInstallPrefix();
    if (!prefix) {
        return nil;
    }
    // Concatenation rather than stringByAppendingPathComponent:, so an empty
    // prefix yields the original absolute path instead of a relative one.
    return [prefix stringByAppendingString:path];
}

// The absolute path launchd itself will resolve, which on roothide means the path
// as launchctl will rewrite it -- so a bare one. roothide's launchctl is itself a
// redirected binary: _patch_plist replaces every absolute path in the
// launchd-recognised keys with jbroot(path), writes the result back, and guards
// re-entry only with its own __Patched marker without checking whether the value
// already carries a jailbreak root. A prefix written here would therefore be
// doubled. Only meaningful for comparison against the installed plist; this
// process may not be able to open it.
static NSString *CCNMMaintainerLaunchdPath(NSString *path) {
    BOOL resolved = NO;
    NSString *prefix = CCNMMaintainerLaunchdPrefix(&resolved);
    return resolved ? [prefix stringByAppendingString:path] : nil;
}

// ---------------------------------------------------------------------------
// launchctl used to be run from here. It is not any more, and it must not come
// back.
//
// The shipped probe table settled the question. Every candidate the guard found
// was refused by posix_spawn itself, including the real binary:
//
//   probed <jbroot>/bin/launchctl(spawn errno 1),
//          <jbroot>/usr/bin/launchctl(spawn errno 1);
//          18 other probed paths do not exist
//
// errno 1 is EPERM, not ENOENT, and <jbroot>/usr/bin/launchctl is the real
// 113664-byte binary. Two further facts from the same dpkg run identify the
// cause. This process saw every bare path as ENOENT while jbroot-absolute paths
// resolved, so it has no path redirection; and the shell that exec'd it ran both
// `jbroot` and this guard without trouble. On roothide the redirection and the
// exec exemption both arrive through basebin/bootstrap.dylib via
// DYLD_INSERT_LIBRARIES, and a compiled maintainer-script child does not get it.
//
// The restriction is therefore on this process, not on the paths it tried, so no
// probe table could have fixed it. The shell maintainer scripts are the injected
// half and own every launchctl invocation now; see package-actions/launchctl.sh.inc.
// What is left here reads and reports: the launchd contract check below decides
// whether the shipped plist is loadable at all, and the shell refuses to load one
// this file has rejected.
// ---------------------------------------------------------------------------

BOOL CCNMVerifyMaintenanceLaunchdContract(NSError **error) {
    // Verification only, and now there is nothing else it could be: the plist
    // ships complete and the shell owns launchctl. It used to be verification of
    // a substitution the shell postinst performed, which was itself the bug -- on
    // roothide the plist must hold bare paths, because launchctl prepends the
    // jailbreak root on load.
    //
    // Writing was never an option here anyway: the reporting device showed a
    // maintainer-script child running as euid 0 whose every read succeeded and
    // every write returned EPERM. What remains is to confirm that what shipped is
    // actually loadable, and to say exactly what is wrong when it is not.
    NSString *installPrefix = CCNMMaintainerInstallPrefix();
    if (!installPrefix) {
        return CCNMSetError(error, CCNMMaintainerErrorRoot,
            [NSString stringWithFormat:
                @"The install prefix could not be determined (%@ was %@).",
                CCNMInstallPrefixVariable,
                getenv(CCNMInstallPrefixVariable.UTF8String)
                    ? @"set to something that is not an absolute path"
                    : @"not set by the maintainer script"]);
    }
    // The path launchd will resolve is a different question from the path this
    // process reads, and on roothide the answers differ in the opposite
    // direction from the obvious guess: launchctl rewrites the plist on load, so
    // the file must name a *bare* path there, while this process needs a real
    // prefix to open anything.
    NSString *expectedProgram = CCNMMaintainerLaunchdPath(
        CCNMMaintenanceExecutableRelativePath);
    if (!expectedProgram) {
        const char *raw = getenv(CCNMLaunchdPrefixVariable.UTF8String);
        return CCNMSetError(error, CCNMMaintainerErrorRoot,
            [NSString stringWithFormat:
                @"The launchd path prefix could not be determined (%@ was %@).",
                CCNMLaunchdPrefixVariable,
                raw ? @"set to something that is neither empty nor an absolute "
                       "path without a trailing slash"
                    : @"not set by the maintainer script"]);
    }
    NSString *plistPath = CCNMMaintainerRootedPath(
        CCNMMaintenanceLaunchdRelativePath);
    NSString *executablePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceExecutableRelativePath);
    if (!plistPath || !executablePath) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            @"A required maintenance path could not be resolved against the install prefix.");
    }
    // Deliberately no launchctl requirement here, and none is possible: this
    // process cannot exec. A correct plist on disk is what makes the job loadable
    // at the next install, and the shell decides whether to load it now. Not at
    // the next boot: nothing in the jailbreak walks this LaunchDaemons directory
    // on the way up, and a re-jailbreak relocates the whole tree to a fresh
    // jailbreak root, so a maintainer script is the only loader this job has.
    //
    // Report each failing input separately. They fail for unrelated reasons and
    // each needs a different fix on the device; one combined message is not
    // actionable.
    //
    // No access(2) prechecks either. On this platform access(X_OK) is routed
    // through an exec-authorization hook and returns EPERM for files that are
    // present and perfectly usable; the reporting device hit exactly that on the
    // freshly unpacked helper (errno 1) even though dpkg had just written it.
    // Readability is decided by the read that follows, and the helper is judged
    // by its stat mode, since nothing here needs to execute it.
    NSError *readError = nil;
    NSData *plistData = [NSData dataWithContentsOfFile:plistPath
                                              options:0
                                                error:&readError];
    if (!plistData) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            [NSString stringWithFormat:
                @"The launchd plist is not readable at %@ (%@).",
                plistPath,
                readError.localizedDescription ?: @"unknown read failure"]);
    }
    struct stat helperInfo;
    if (stat(executablePath.fileSystemRepresentation, &helperInfo) != 0) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            [NSString stringWithFormat:
                @"The maintenance helper is missing at %@ (stat errno %d).",
                executablePath, errno]);
    }
    if (!S_ISREG(helperInfo.st_mode) ||
        (helperInfo.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) == 0) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            [NSString stringWithFormat:
                @"The maintenance helper is not executable at %@ (mode %o).",
                executablePath, (unsigned)(helperInfo.st_mode & 07777)]);
    }

    NSDictionary *installed = [NSPropertyListSerialization
        propertyListWithData:plistData
                     options:NSPropertyListImmutable
                      format:NULL
                       error:NULL];
    if (![installed isKindOfClass:NSDictionary.class] ||
        ![installed[@"Label"] isEqual:CCNMMaintenanceLaunchdLabel]) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"The installed launchd plist has an invalid label or format.");
    }
    NSArray *arguments = [installed[@"ProgramArguments"] isKindOfClass:NSArray.class]
        ? installed[@"ProgramArguments"] : nil;
    NSDictionary *keepAlive = [installed[@"KeepAlive"] isKindOfClass:NSDictionary.class]
        ? installed[@"KeepAlive"] : nil;
    NSArray *watchPaths = [installed[@"WatchPaths"] isKindOfClass:NSArray.class]
        ? installed[@"WatchPaths"] : nil;
    NSString *program = [arguments.firstObject isKindOfClass:NSString.class]
        ? arguments.firstObject : nil;
    NSString *watchedDirectory = [watchPaths.firstObject isKindOfClass:NSString.class]
        ? watchPaths.firstObject : nil;
    NSDictionary *environment = [installed[@"EnvironmentVariables"]
        isKindOfClass:NSDictionary.class] ? installed[@"EnvironmentVariables"] : nil;
    // New KeepAlive contract (1.7.1+): RunAtLoad boots the daemon on startup;
    // KeepAlive.SuccessfulExit=false restarts on crash but not on clean exit;
    // WatchPaths on Preferences directory wakes the daemon when Settings writes
    // a per-UUID baseline or renames a legacy one during SIM migration. The old
    // PathState contract (盯无 UUID baseline 文件) no longer works after dual-SIM
    // adaptation, because switching SIMs renames the baseline and the file the
    // plist watches disappears, causing idle restarts or a death loop.
    if (arguments.count != 2 || ![arguments[1] isEqual:@"--daemon"] ||
        ![installed[@"RunAtLoad"] boolValue] ||
        ![keepAlive isEqual:@{@"SuccessfulExit": @NO}] ||
        watchPaths.count != 1 ||
        ![watchedDirectory hasSuffix:@"/var/mobile/Library/Preferences"] ||
        ![installed[@"UserName"] isEqual:@"root"] ||
        ![environment[@"DISABLE_TWEAKS"] isEqual:@"1"]) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"The installed launchd plist violates the reviewed maintenance contract.");
    }
    // Exact paths, not hasSuffix:. A doubled prefix and a bare path both end with
    // the right relative path, and only one of them is loadable. This is the check
    // that catches a plist staged for the wrong lane, so it has to name what it
    // found.
    //
    // Two spellings are correct, for one file, at two different moments.
    //
    // What ships is the launchd-contract form, which on roothide is bare, because
    // launchctl prepends the root on load. But launchctl does not prepend it in
    // memory -- _patch_plist writes the rewritten values back to the file and
    // stamps __Patched. So after the first successful load, the file on disk holds
    // the install-prefix form, and it stays that way until dpkg unpacks over it.
    //
    // Any postinst run that does not unpack therefore sees the rewritten file:
    // `dpkg --configure`, and the abort-remove rerun after a blocked prerm. Both
    // are ordinary, and the reporting device hit the second one. Judging only the
    // shipped spelling reports a contract violation against a plist that is
    // correct and already loaded, and the shell then refuses to start a daemon
    // that nothing is wrong with.
    //
    // The rewritten form is accepted only on the evidence that launchctl is what
    // rewrote it: __Patched present and true, which is launchctl's own marker and
    // is not something this package ever writes. The comparison stays exact, so
    // the doubled path this project has already shipped once
    // (<jbroot>/<jbroot>/usr/libexec/...) is still a mismatch, and so is a
    // prefix left over from a previous jailbreak root -- which a re-jailbreak
    // produces, and which correctly needs a reinstall rather than a load.
    //
    // Only roothide widens here. On rootless both prefixes are /var/jb, so the two
    // spellings are the same string and this accepts exactly what it did before.
    BOOL launchctlRewrote = [installed[@"__Patched"] isKindOfClass:NSNumber.class] &&
        [installed[@"__Patched"] boolValue];
    NSString *rewrittenProgram = executablePath;
    NSString *expectedDirectory = CCNMMaintenancePreferencesDirectory;
    NSString *rewrittenDirectory = CCNMMaintainerRootedPath(
        CCNMMaintenancePreferencesDirectory);
    BOOL programMatches = [program isEqualToString:expectedProgram] ||
        (launchctlRewrote && rewrittenProgram && [program isEqualToString:rewrittenProgram]);
    BOOL directoryMatches = [watchedDirectory isEqualToString:expectedDirectory] ||
        (launchctlRewrote && rewrittenDirectory && [watchedDirectory isEqualToString:rewrittenDirectory]);
    if (!programMatches || !directoryMatches) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            [NSString stringWithFormat:
                @"The installed launchd plist does not point at this install. "
                 "Program is %@ and the watched directory is %@; expected %@ and %@%@.",
                program ?: @"absent", watchedDirectory ?: @"absent",
                expectedProgram, expectedDirectory,
                launchctlRewrote
                    ? [NSString stringWithFormat:
                        @", or %@ and %@ once launchctl has rewritten them",
                        rewrittenProgram ?: @"an unresolved path",
                        rewrittenDirectory ?: @"an unresolved path"]
                    : @""]);
    }
    return YES;
}
