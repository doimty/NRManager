#import "CCNMMaintainerEnvironment.h"

#import "CCNMLaunchctlProbe.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

NSString *const CCNMMaintenanceLaunchdLabel =
    @"me.nixuge.networkmanager.maintenance";

static NSString *const CCNMMaintenanceLaunchdRelativePath =
    @"/Library/LaunchDaemons/me.nixuge.networkmanager.maintenance.plist";
static NSString *const CCNMMaintenanceExecutableRelativePath =
    @"/usr/libexec/networkmanager-maintenance";
static NSString *const CCNMMaintenanceBaselineRelativePath =
    @"/var/mobile/Library/Preferences/"
     "me.nixuge.networkmanager.n78-policy.baseline.plist";
static NSString *const CCNMMaintainerErrorDomain =
    @"me.nixuge.networkmanager.maintainer";

typedef NS_ENUM(NSInteger, CCNMMaintainerErrorCode) {
    CCNMMaintainerErrorRoot = 1,
    CCNMMaintainerErrorPath,
    CCNMMaintainerErrorPlist,
    CCNMMaintainerErrorLaunchctl,
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
// file. On roothide it is empty, because a maintainer-script child already
// resolves bare paths inside the jailbreak root.
//
// The launchd prefix is what must appear inside the plist. launchd is not
// subject to any redirection, so it needs a real absolute path even when this
// process would reach the same file with a bare one.
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
// nil means it could not be determined and no installed path is trustworthy.
// @"" means bare paths already resolve, which is the normal roothide answer, so
// it must not be mistaken for absence.
NSString *CCNMMaintainerInstallPrefix(void) {
    static NSString *prefix;
    static BOOL resolved;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefix = CCNMPrefixFromEnvironment(CCNMInstallPrefixVariable, YES);
        if (prefix) {
            resolved = YES;
            return;
        }
        // Compile-time fallback for the rootless lane only, where the prefix is
        // a fixed property of the package rather than of the running system.
        // Deliberately no runtime derivation: a guard that guesses its root can
        // read a policy state that is not the live one, report it as clean, and
        // authorize removal while a forced band configuration is still applied.
#if defined(THEOS_PACKAGE_INSTALL_PREFIX)
        const char *compiled = THEOS_PACKAGE_INSTALL_PREFIX;
        if (compiled && compiled[0] == '/') {
            NSString *candidate = [NSString stringWithUTF8String:compiled];
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate
                                                     isDirectory:&isDirectory] &&
                isDirectory) {
                prefix = candidate;
                resolved = YES;
            }
        }
#endif
    });
    return resolved ? prefix : nil;
}

// The prefix that must appear inside the launchd plist. Never empty: launchd is
// not redirected, so a bare path there would point outside the jailbreak.
// Internal: every caller outside this file wants a path, not a prefix.
static NSString *CCNMMaintainerLaunchdPrefix(void) {
    static NSString *prefix;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefix = CCNMPrefixFromEnvironment(CCNMLaunchdPrefixVariable, NO);
#if defined(THEOS_PACKAGE_INSTALL_PREFIX)
        if (!prefix) {
            const char *compiled = THEOS_PACKAGE_INSTALL_PREFIX;
            if (compiled && compiled[0] == '/') {
                prefix = [NSString stringWithUTF8String:compiled];
            }
        }
#endif
    });
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

// The absolute path launchd itself will use. Only meaningful for comparison
// against the installed plist; this process may not be able to open it.
static NSString *CCNMMaintainerLaunchdPath(NSString *path) {
    NSString *prefix = CCNMMaintainerLaunchdPrefix();
    return prefix ? [prefix stringByAppendingString:path] : nil;
}

// launchctl lookup.
//
// The shipped probe table settled this. Two candidates came back with errno 1
// (EPERM), not 2 (ENOENT):
//
//   <jbroot>/bin/launchctl(errno 1)      the relative symlink
//   <jbroot>/usr/bin/launchctl(errno 1)  the real 113664-byte binary
//
// The binary exists and access(X_OK) refuses to answer for it. On this platform
// the X_OK check is routed through an exec-authorization hook, so it can fail
// for a binary that spawns perfectly well; it is not a usable oracle. Every
// bare-root candidate was ENOENT, which separately proves the maintainer
// script's `/` is not the jbroot even though the user's shell sees it that way,
// so jbroot-relative probing is required.
//
// Therefore: stat(2) answers only "is this definitively absent", and the real
// arbiter for "can I run it" is the operation itself. Candidates are spawned in
// order until one execs. A failed spawn runs nothing, so trying is free of side
// effects, and each failure is recorded with its errno so a future failure is
// still diagnosable from the dpkg log alone.

// Bounds both the probe table and the reported list so one failed lookup cannot
// flood dpkg output. PATH contributes at most a handful of directories.
static const size_t CCNMLaunchctlProbeCapacity = 64;
static const NSUInteger CCNMLaunchctlReportLimit = 24;

// Index into the probe order at which PATH-derived candidates begin. PATH is
// inherited from dpkg, so those candidates are held to a stricter trust standard
// than the known prefixes: a root process must not exec a binary that a non-root
// user could have replaced.
static NSUInteger CCNMLaunchctlPathSourcedFrom;

static NSArray<NSString *> *CCNMLaunchctlProbeOrder(void) {
    static NSArray<NSString *> *order;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        char **buffer = calloc(CCNMLaunchctlProbeCapacity, sizeof(char *));
        if (!buffer) {
            order = @[];
            return;
        }
        NSString *root = CCNMMaintainerJailbreakRoot();
        size_t pathSourcedFrom = 0;
        size_t count = CCNMBuildLaunchctlProbeOrder(
            root.length > 0 ? root.fileSystemRepresentation : NULL,
            getenv("PATH"), buffer, CCNMLaunchctlProbeCapacity,
            &pathSourcedFrom);
        NSMutableArray<NSString *> *paths =
            [NSMutableArray arrayWithCapacity:count];
        BOOL boundaryRecorded = NO;
        for (size_t index = 0; index < count; index++) {
            NSString *candidate = [NSString stringWithUTF8String:buffer[index]];
            if (candidate) {
                if (!boundaryRecorded && index >= pathSourcedFrom) {
                    CCNMLaunchctlPathSourcedFrom = paths.count;
                    boundaryRecorded = YES;
                }
                [paths addObject:candidate];
            }
            free(buffer[index]);
        }
        if (!boundaryRecorded) {
            // PATH contributed nothing, so no candidate is PATH-sourced.
            CCNMLaunchctlPathSourcedFrom = paths.count;
        }
        free(buffer);
        order = paths;
    });
    return order;
}

// Spawns one candidate and waits for it. Returns the exit status, and reports
// the exec failure separately: a nonzero exit means launchctl ran and answered,
// while a nonzero spawnErrno means this path is not runnable and the next
// candidate should be tried.
static int CCNMSpawnLaunchctl(NSString *launchctl,
                              NSArray<NSString *> *arguments,
                              BOOL quiet,
                              int *spawnErrno) {
    *spawnErrno = 0;
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    if (!argv) {
        *spawnErrno = ENOMEM;
        return -1;
    }
    argv[0] = (char *)launchctl.fileSystemRepresentation;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        argv[index + 1] = (char *)arguments[index].UTF8String;
    }

    posix_spawn_file_actions_t actions;
    BOOL actionsInitialized = NO;
    posix_spawn_file_actions_t *actionsPointer = NULL;
    if (quiet && posix_spawn_file_actions_init(&actions) == 0) {
        actionsInitialized = YES;
        if (posix_spawn_file_actions_addopen(
                &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0 &&
            posix_spawn_file_actions_addopen(
                &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0) {
            actionsPointer = &actions;
        }
    }

    pid_t pid = 0;
    // On Darwin posix_spawn is a single syscall, so exec failures are returned
    // here rather than surfacing as a child that exits nonzero. That is what
    // makes the spawn attempt usable as the authoritative runnability check.
    int spawnResult = posix_spawn(&pid, launchctl.fileSystemRepresentation,
        actionsPointer, NULL, argv, environ);
    if (actionsInitialized) {
        posix_spawn_file_actions_destroy(&actions);
    }
    free(argv);
    if (spawnResult != 0) {
        *spawnErrno = spawnResult;
        return -1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) == -1) {
        if (errno != EINTR) {
            return -1;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// The candidate that successfully execed, and the failure table from the
// resolving attempt. Resolution is cached both ways: a maintainer script is
// short-lived and nothing on disk changes underneath it, so re-probing would
// only repeat the spawn attempts and rebuild the same report.
static NSString *CCNMLaunchctlResolved;
static NSString *CCNMLaunchctlProbeReport;
static BOOL CCNMLaunchctlResolutionFailed;

static int CCNMRunLaunchctl(NSArray<NSString *> *arguments, BOOL quiet) {
    if (CCNMLaunchctlResolved) {
        int spawnErrno = 0;
        int status = CCNMSpawnLaunchctl(CCNMLaunchctlResolved, arguments,
            quiet, &spawnErrno);
        return spawnErrno == 0 ? status : -1;
    }
    if (CCNMLaunchctlResolutionFailed) {
        return -1;
    }

    NSArray<NSString *> *order = CCNMLaunchctlProbeOrder();
    // Two buckets. A path that simply does not exist carries no information
    // beyond "not here", and listing twenty of them buries the two entries that
    // matter. Paths that exist and still could not be run are reported in full.
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    NSUInteger absent = 0;
    NSUInteger position = 0;
    for (NSString *candidate in order) {
        BOOL pathSourced = position >= CCNMLaunchctlPathSourcedFrom;
        position++;
        int probeErrno = 0;
        if (CCNMLaunchctlCandidateIsUnusable(
                candidate.fileSystemRepresentation, pathSourced, &probeErrno)) {
            if (probeErrno == ENOENT || probeErrno == ENOTDIR) {
                absent++;
                continue;
            }
            if (failures.count < CCNMLaunchctlReportLimit) {
                [failures addObject:[NSString stringWithFormat:
                    @"%@(stat errno %d)", candidate, probeErrno]];
            }
            continue;
        }
        int spawnErrno = 0;
        int status = CCNMSpawnLaunchctl(candidate, arguments, quiet, &spawnErrno);
        if (spawnErrno == 0) {
            CCNMLaunchctlResolved = candidate;
            CCNMLaunchctlProbeReport = nil;
            return status;
        }
        if (failures.count < CCNMLaunchctlReportLimit) {
            [failures addObject:[NSString stringWithFormat:
                @"%@(spawn errno %d)", candidate, spawnErrno]];
        }
    }

    if (failures.count == 0) {
        CCNMLaunchctlProbeReport = [NSString stringWithFormat:
            @"no launchctl exists at any of the %lu probed paths",
            (unsigned long)order.count];
        CCNMLaunchctlResolutionFailed = YES;
        return -1;
    }
    NSMutableString *report = [NSMutableString stringWithFormat:@"probed %@",
        [failures componentsJoinedByString:@", "]];
    NSUInteger reported = failures.count + absent;
    if (order.count > reported) {
        [report appendFormat:@" and %lu more",
            (unsigned long)(order.count - reported)];
    }
    if (absent > 0) {
        [report appendFormat:@"; %lu other probed path%@ do%@ not exist",
            (unsigned long)absent, absent == 1 ? @"" : @"s",
            absent == 1 ? @"es" : @""];
    }
    CCNMLaunchctlProbeReport = report;
    CCNMLaunchctlResolutionFailed = YES;
    return -1;
}

// Availability check. `version` is side-effect free, so this can resolve the
// binary before any real command is issued. Only the exec result matters, not
// the exit status: an unrecognized subcommand still proves the binary runs.
static BOOL CCNMLaunchctlIsUsable(void) {
    if (!CCNMLaunchctlResolved && !CCNMLaunchctlResolutionFailed) {
        (void)CCNMRunLaunchctl(@[@"version"], YES);
    }
    return CCNMLaunchctlResolved != nil;
}

// Builds the user-facing message for a failed lookup, including the probe table.
static NSString *CCNMLaunchctlUnavailableMessage(void) {
    (void)CCNMLaunchctlIsUsable();
    return [NSString stringWithFormat:
        @"launchctl could not be run from any known location; %@.",
        CCNMLaunchctlProbeReport.length > 0
            ? CCNMLaunchctlProbeReport : @"no candidate path was probed"];
}

static BOOL CCNMJobIsLoaded(void) {
    NSString *target = [@"system/" stringByAppendingString:CCNMMaintenanceLaunchdLabel];
    return CCNMRunLaunchctl(@[@"print", target], YES) == 0;
}

BOOL CCNMPrepareMaintenanceLaunchd(NSError **error) {
    // Verification only. The shell postinst already substituted the jailbreak
    // root, the way roothide's own packages do, so there is nothing left to
    // write here — and writing was the one thing this process could not do: the
    // reporting device showed a maintainer-script child running as euid 0 whose
    // every read succeeded and every write returned EPERM. What remains is to
    // confirm that what shell produced is actually loadable, and to say exactly
    // what is wrong when it is not.
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
    // The path launchd will use is a different question from the path this
    // process reads. launchd is not redirected, so the plist must name a real
    // absolute path even where a bare one works here.
    NSString *expectedProgram = CCNMMaintainerLaunchdPath(
        CCNMMaintenanceExecutableRelativePath);
    NSString *expectedBaseline = CCNMMaintainerLaunchdPath(
        CCNMMaintenanceBaselineRelativePath);
    if (!expectedProgram || !expectedBaseline) {
        return CCNMSetError(error, CCNMMaintainerErrorRoot,
            [NSString stringWithFormat:
                @"The launchd path prefix could not be determined (%@ was %@).",
                CCNMLaunchdPrefixVariable,
                getenv(CCNMLaunchdPrefixVariable.UTF8String)
                    ? @"set to something that is not an absolute path"
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
    // Deliberately no launchctl requirement here. A correct plist on disk is
    // what makes the job loadable at the next boot, so demanding launchctl would
    // discard the durable part of the work because the immediate load failed.
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
    NSDictionary *pathState = [keepAlive[@"PathState"] isKindOfClass:NSDictionary.class]
        ? keepAlive[@"PathState"] : nil;
    NSString *program = [arguments.firstObject isKindOfClass:NSString.class]
        ? arguments.firstObject : nil;
    NSString *watchedPath = [pathState.allKeys.firstObject isKindOfClass:NSString.class]
        ? pathState.allKeys.firstObject : nil;
    NSDictionary *environment = [installed[@"EnvironmentVariables"]
        isKindOfClass:NSDictionary.class] ? installed[@"EnvironmentVariables"] : nil;
    if (arguments.count != 2 || ![arguments[1] isEqual:@"--daemon"] ||
        pathState.count != 1 || ![pathState[watchedPath] boolValue] ||
        keepAlive[@"SuccessfulExit"] != nil ||
        ![installed[@"UserName"] isEqual:@"root"] ||
        ![environment[@"DISABLE_TWEAKS"] isEqual:@"1"] ||
        installed[@"RunAtLoad"] != nil) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"The installed launchd plist violates the reviewed maintenance contract.");
    }
    // Exact paths, not hasSuffix:. A surviving @JBROOT@ placeholder or a
    // doubled prefix both end with the right relative path, and both leave a job
    // launchd cannot start. This is the check that catches a substitution that
    // did not happen, so it has to name what it found.
    if (![program isEqualToString:expectedProgram] ||
        ![watchedPath isEqualToString:expectedBaseline]) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            [NSString stringWithFormat:
                @"The installed launchd plist does not point at this install. "
                 "Program is %@ and the watched path is %@; expected %@ and %@.",
                program ?: @"absent", watchedPath ?: @"absent",
                expectedProgram, expectedBaseline]);
    }
    return YES;
}

BOOL CCNMStopMaintenanceLaunchd(NSError **error) {
    if (!CCNMLaunchctlIsUsable()) {
        return CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            CCNMLaunchctlUnavailableMessage());
    }
    if (!CCNMJobIsLoaded()) {
        return YES;
    }
    NSString *target = [@"system/" stringByAppendingString:CCNMMaintenanceLaunchdLabel];
    if (CCNMRunLaunchctl(@[@"bootout", target], NO) != 0 || CCNMJobIsLoaded()) {
        return CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            @"The maintenance launchd job could not be stopped and verified.");
    }
    return YES;
}

CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd(NSError **error) {
    // Preparing the plist is the only step whose failure is permanent. Once it
    // has succeeded the durable half of the work is on disk and launchd can load
    // the job at the next boot, so nothing after this point may report Failed:
    // that code means "will not load now or later", which would be a false
    // statement about a plist this function just validated.
    if (!CCNMPrepareMaintenanceLaunchd(error)) {
        return CCNMMaintenanceRegistrationFailed;
    }
    if (!CCNMLaunchctlIsUsable()) {
        (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            CCNMLaunchctlUnavailableMessage());
        return CCNMMaintenanceRegistrationDeferred;
    }
    if (!CCNMStopMaintenanceLaunchd(error)) {
        return CCNMMaintenanceRegistrationRejected;
    }
    // launchctl gets the launchd-prefixed path, not the one this process reads.
    // launchctl is a system binary outside the jailbreak root, so it is not
    // subject to the redirection this process may be under; a bare path would
    // resolve for us and fail for it.
    NSString *plistPath = CCNMMaintainerLaunchdPath(
        CCNMMaintenanceLaunchdRelativePath);
    if (!plistPath) {
        // Unreachable in practice: prepare already required this prefix. Kept as
        // a guard rather than an assertion, and reported as Rejected because the
        // plist it validated is still on disk.
        (void)CCNMSetError(error, CCNMMaintainerErrorRoot,
            @"The launchd path prefix could not be determined, so the job cannot be bootstrapped.");
        return CCNMMaintenanceRegistrationRejected;
    }
    if (CCNMRunLaunchctl(@[@"bootstrap", @"system", plistPath], NO) != 0 ||
        !CCNMJobIsLoaded()) {
        (void)CCNMStopMaintenanceLaunchd(NULL);
        (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            @"The maintenance launchd job could not be registered and verified.");
        return CCNMMaintenanceRegistrationRejected;
    }
    // Read through the install prefix: this is our own stat, not launchd's.
    NSString *baselinePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceBaselineRelativePath);
    if (baselinePath &&
        [[NSFileManager defaultManager] fileExistsAtPath:baselinePath]) {
        NSString *target = [@"system/"
            stringByAppendingString:CCNMMaintenanceLaunchdLabel];
        if (CCNMRunLaunchctl(@[@"kickstart", @"-k", target], NO) != 0 ||
            !CCNMJobIsLoaded()) {
            (void)CCNMStopMaintenanceLaunchd(NULL);
            (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
                @"The policy-scoped maintenance job could not be started.");
            return CCNMMaintenanceRegistrationRejected;
        }
    }
    return CCNMMaintenanceRegistrationActive;
}
