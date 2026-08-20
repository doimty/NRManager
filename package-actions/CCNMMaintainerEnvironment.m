#import "CCNMMaintainerEnvironment.h"

#import "CCNMLaunchctlProbe.h"
#import "CCNMPlistWrite.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
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

static BOOL CCNMIsJBRootName(const char *name) {
    if (!name) {
        return NO;
    }
    static const char prefix[] = ".jbroot-";
    const size_t prefixLength = sizeof(prefix) - 1;
    if (strlen(name) != prefixLength + 16 ||
        strncmp(name, prefix, prefixLength) != 0) {
        return NO;
    }
    char *end = NULL;
    unsigned long long value = strtoull(name + prefixLength, &end, 16);
    if (!end || *end != '\0') {
        return NO;
    }
    uint8_t check = (uint8_t)(value >> 8) ^ (uint8_t)(value >> 16) ^
        (uint8_t)(value >> 24) ^ (uint8_t)(value >> 32) ^
        (uint8_t)(value >> 40) ^ (uint8_t)(value >> 48) ^
        (uint8_t)(value >> 56);
    return check == (uint8_t)value;
}

static NSString *CCNMCompiledInstallPrefix(void) {
#if defined(THEOS_PACKAGE_INSTALL_PREFIX)
    const char *prefix = THEOS_PACKAGE_INSTALL_PREFIX;
    return prefix && prefix[0] != '\0'
        ? [NSString stringWithUTF8String:prefix] : @"";
#else
    return @"";
#endif
}

static NSString *CCNMJBRootFromExecutable(void) {
    uint32_t size = 0;
    (void)_NSGetExecutablePath(NULL, &size);
    if (size == 0) {
        return nil;
    }
    char *buffer = calloc(1, size);
    if (!buffer) {
        return nil;
    }
    NSString *root = nil;
    if (_NSGetExecutablePath(buffer, &size) == 0) {
        NSString *executable = [NSString stringWithUTF8String:buffer];
        NSMutableArray<NSString *> *components = [NSMutableArray array];
        for (NSString *component in executable.pathComponents) {
            [components addObject:component];
            if (CCNMIsJBRootName(component.UTF8String)) {
                root = [NSString pathWithComponents:components];
                break;
            }
        }
    }
    free(buffer);
    return root;
}

static NSString *CCNMUniqueScannedJBRoot(void) {
    NSString *parent = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:parent error:NULL];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (CCNMIsJBRootName(entry.UTF8String)) {
            [matches addObject:[parent stringByAppendingPathComponent:entry]];
        }
    }
    return matches.count == 1 ? matches.firstObject : nil;
}

NSString *CCNMMaintainerJailbreakRoot(void) {
    static NSString *root;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *compiledPrefix = CCNMCompiledInstallPrefix();
        if (compiledPrefix.length > 0) {
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:compiledPrefix
                                                     isDirectory:&isDirectory] &&
                isDirectory) {
                root = compiledPrefix;
            }
            return;
        }
        root = CCNMJBRootFromExecutable() ?: CCNMUniqueScannedJBRoot();
    });
    return root;
}

NSString *CCNMMaintainerRootedPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) {
        return nil;
    }
    NSString *root = CCNMMaintainerJailbreakRoot();
    return root.length > 0 ? [root stringByAppendingPathComponent:path] : nil;
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

static BOOL CCNMWritePlist(NSDictionary *plist,
                           NSString *path,
                           NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    if (!data) {
        return NO;
    }

    CCNMFileWriteOutcome outcome;
    CCNMReplaceFileContents(path.fileSystemRepresentation, data.bytes,
                            data.length, 0, 0, 0644, &outcome);
    if (outcome.ok) {
        return YES;
    }

    NSString *step = outcome.failingStep
        ? @(outcome.failingStep) : @"unknown";
    NSMutableString *detail = [NSMutableString stringWithFormat:
        @"step %@", step];
    if (outcome.failureErrno != 0) {
        [detail appendFormat:@" errno %d", outcome.failureErrno];
    }
    if ([step isEqualToString:@"in-place-open"]) {
        [detail appendFormat:@", after a new sibling was refused with errno %d",
            outcome.siblingErrno];
    } else if (outcome.stage == CCNMFileWriteStageInPlace) {
        [detail appendFormat:@", rewriting in place because a new sibling was "
                              "refused with errno %d", outcome.siblingErrno];
    }
    if ([step isEqualToString:@"write"]) {
        [detail appendFormat:@", %lu of %lu bytes left",
            (unsigned long)outcome.bytesRemaining,
            (unsigned long)outcome.bytesTotal];
    }
    if ([step isEqualToString:@"mode"] ||
        [step isEqualToString:@"ownership"]) {
        [detail appendFormat:@", ended up mode %o owned by %u:%u instead of "
                              "root:root 0644, which launchd would refuse",
            outcome.resultMode, outcome.resultUid, outcome.resultGid];
    }

    // Surroundings come from the writer, which captured them at the moment of
    // failure. Re-inspecting here would report a different instant and, as root,
    // permission bits alone cannot explain a refusal to create a file: the
    // mount state is the field that separates a read-only volume from a policy
    // hook. Guessing between those has already cost several rounds.
    NSMutableString *context = [NSMutableString stringWithFormat:
        @"euid %d", (int)geteuid()];
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (outcome.directoryStatErrno != 0) {
        [context appendFormat:@", %@ could not be inspected (stat errno %d)",
            directory, outcome.directoryStatErrno];
    } else {
        [context appendFormat:@", %@ is mode %o owned by uid %u",
            directory, outcome.directoryMode, outcome.directoryUid];
    }
    if (outcome.targetStatErrno != 0) {
        [context appendFormat:@", the plist itself is absent (stat errno %d)",
            outcome.targetStatErrno];
    } else {
        [context appendFormat:@", the plist itself is mode %o owned by uid %u",
            outcome.targetMode, outcome.targetUid];
    }
    if (outcome.readOnlyMount < 0) {
        [context appendFormat:@", mount flags unavailable (errno %d)",
            outcome.mountStatErrno];
    } else {
        [context appendFormat:@", the filesystem is mounted %@",
            outcome.readOnlyMount ? @"read-only" : @"read-write"];
    }

    return CCNMSetError(error, CCNMMaintainerErrorPlist,
        [NSString stringWithFormat:
            @"Could not durably replace the launchd plist at %@: %@. %@.",
            path, detail, context]);
}

BOOL CCNMPrepareMaintenanceLaunchd(NSError **error) {
    NSString *root = CCNMMaintainerJailbreakRoot();
    if (root.length == 0) {
        return CCNMSetError(error, CCNMMaintainerErrorRoot,
            @"The active jailbreak root could not be resolved uniquely.");
    }
    NSString *plistPath = CCNMMaintainerRootedPath(
        CCNMMaintenanceLaunchdRelativePath);
    NSString *executablePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceExecutableRelativePath);
    NSString *baselinePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceBaselineRelativePath);
    // Deliberately no launchctl requirement here. This function's whole job is
    // to leave a correct plist on disk, and that is what makes the job loadable
    // at the next boot. Demanding launchctl would throw away the durable part of
    // the work just because the immediate load is impossible.
    //
    // Report the failing item individually. A single combined message cannot be
    // acted on: these inputs fail for unrelated reasons (unresolvable rooted
    // path, unpacked-but-not-executable helper) and each needs a different fix.
    if (!plistPath || !executablePath || !baselinePath) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            @"A required maintenance path could not be resolved against the jailbreak root.");
    }
    // No access(2) prechecks here. On this platform access(X_OK) is routed
    // through an exec-authorization hook and returns EPERM for files that are
    // present and perfectly usable; the reporting device hit exactly that on the
    // freshly unpacked helper (errno 1) even though dpkg had just written it.
    // Readability is decided by the read that follows, and the helper is judged
    // by its stat mode, since nothing in this function needs to execute it.
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

    NSDictionary *source = [NSPropertyListSerialization
        propertyListWithData:plistData
                     options:NSPropertyListImmutable
                      format:NULL
                       error:NULL];
    if (![source isKindOfClass:NSDictionary.class] ||
        ![source[@"Label"] isEqual:CCNMMaintenanceLaunchdLabel]) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"The installed launchd plist has an invalid label or format.");
    }
    NSArray *arguments = [source[@"ProgramArguments"] isKindOfClass:NSArray.class]
        ? source[@"ProgramArguments"] : nil;
    NSDictionary *keepAlive = [source[@"KeepAlive"] isKindOfClass:NSDictionary.class]
        ? source[@"KeepAlive"] : nil;
    NSDictionary *pathState = [keepAlive[@"PathState"] isKindOfClass:NSDictionary.class]
        ? keepAlive[@"PathState"] : nil;
    NSString *oldProgram = [arguments.firstObject isKindOfClass:NSString.class]
        ? arguments.firstObject : nil;
    NSString *oldPath = [pathState.allKeys.firstObject isKindOfClass:NSString.class]
        ? pathState.allKeys.firstObject : nil;
    NSDictionary *environment = [source[@"EnvironmentVariables"]
        isKindOfClass:NSDictionary.class] ? source[@"EnvironmentVariables"] : nil;
    if (arguments.count != 2 || ![arguments[1] isEqual:@"--daemon"] ||
        ![oldProgram hasSuffix:CCNMMaintenanceExecutableRelativePath] ||
        pathState.count != 1 || ![pathState[oldPath] boolValue] ||
        ![oldPath hasSuffix:CCNMMaintenanceBaselineRelativePath] ||
        keepAlive[@"SuccessfulExit"] != nil ||
        ![source[@"UserName"] isEqual:@"root"] ||
        ![environment[@"DISABLE_TWEAKS"] isEqual:@"1"] ||
        source[@"RunAtLoad"] != nil) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"The installed launchd plist violates the reviewed maintenance contract.");
    }

    NSMutableDictionary *updated = [source mutableCopy];
    updated[@"ProgramArguments"] = @[executablePath, @"--daemon"];
    NSMutableDictionary *updatedKeepAlive = [keepAlive mutableCopy];
    updatedKeepAlive[@"PathState"] = @{baselinePath: @YES};
    updated[@"KeepAlive"] = updatedKeepAlive;
    return CCNMWritePlist(updated, plistPath, error);
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
    // The plist must be correct regardless of whether launchctl can run, so it
    // is written first and its failure is the only hard failure.
    if (!CCNMPrepareMaintenanceLaunchd(error)) {
        return CCNMMaintenanceRegistrationFailed;
    }
    if (!CCNMLaunchctlIsUsable()) {
        (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            CCNMLaunchctlUnavailableMessage());
        return CCNMMaintenanceRegistrationDeferred;
    }
    if (!CCNMStopMaintenanceLaunchd(error)) {
        return CCNMMaintenanceRegistrationFailed;
    }
    NSString *plistPath = CCNMMaintainerRootedPath(
        CCNMMaintenanceLaunchdRelativePath);
    if (CCNMRunLaunchctl(@[@"bootstrap", @"system", plistPath], NO) != 0 ||
        !CCNMJobIsLoaded()) {
        (void)CCNMStopMaintenanceLaunchd(NULL);
        (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            @"The maintenance launchd job could not be registered and verified.");
        return CCNMMaintenanceRegistrationFailed;
    }
    NSString *baselinePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceBaselineRelativePath);
    if ([[NSFileManager defaultManager] fileExistsAtPath:baselinePath]) {
        NSString *target = [@"system/"
            stringByAppendingString:CCNMMaintenanceLaunchdLabel];
        if (CCNMRunLaunchctl(@[@"kickstart", @"-k", target], NO) != 0 ||
            !CCNMJobIsLoaded()) {
            (void)CCNMStopMaintenanceLaunchd(NULL);
            (void)CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
                @"The policy-scoped maintenance job could not be started.");
            return CCNMMaintenanceRegistrationFailed;
        }
    }
    return CCNMMaintenanceRegistrationActive;
}
