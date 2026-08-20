#import "CCNMMaintainerEnvironment.h"

#import "CCNMLaunchctlProbe.h"

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
// This has now failed twice on a real roothide device while the same bare path
// was executable from the user's shell, which means the interesting variable is
// not the candidate list but the filesystem *view* the maintainer script runs
// in. The ordering therefore lives in CCNMLaunchctlProbe.c, where it is host
// testable, and this file only performs the access() probes and reports them.
//
// A lookup failure must be diagnosable from the dpkg log alone instead of
// costing another build round, so every probe is recorded with its errno.

// Bounds both the probe table and the reported list so one failed lookup cannot
// flood dpkg output. PATH contributes at most a handful of directories.
static const size_t CCNMLaunchctlProbeCapacity = 64;
static const NSUInteger CCNMLaunchctlReportLimit = 24;

static NSArray<NSString *> *CCNMLaunchctlProbeOrder(void) {
    char **buffer = calloc(CCNMLaunchctlProbeCapacity, sizeof(char *));
    if (!buffer) {
        return @[];
    }
    NSString *root = CCNMMaintainerJailbreakRoot();
    size_t count = CCNMBuildLaunchctlProbeOrder(
        root.length > 0 ? root.fileSystemRepresentation : NULL,
        getenv("PATH"), buffer, CCNMLaunchctlProbeCapacity);
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        NSString *candidate = [NSString stringWithUTF8String:buffer[index]];
        if (candidate) {
            [paths addObject:candidate];
        }
        free(buffer[index]);
    }
    free(buffer);
    return paths;
}

static NSString *CCNMLaunchctlResolution(NSString **report) {
    static NSString *resolved;
    static NSString *probeReport;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *order = CCNMLaunchctlProbeOrder();
        NSMutableArray<NSString *> *failures = [NSMutableArray array];
        for (NSString *candidate in order) {
            errno = 0;
            if (access(candidate.fileSystemRepresentation, X_OK) == 0) {
                resolved = candidate;
                break;
            }
            if (failures.count < CCNMLaunchctlReportLimit) {
                [failures addObject:[NSString stringWithFormat:@"%@(errno %d)",
                    candidate, errno]];
            }
        }
        if (!resolved) {
            NSString *suffix = order.count > failures.count
                ? [NSString stringWithFormat:@" and %lu more",
                       (unsigned long)(order.count - failures.count)]
                : @"";
            probeReport = [NSString stringWithFormat:@"probed %@%@",
                [failures componentsJoinedByString:@", "], suffix];
        }
    });
    if (report) {
        *report = probeReport;
    }
    return resolved;
}

static NSString *CCNMLaunchctlPath(void) {
    return CCNMLaunchctlResolution(NULL);
}

// Builds the user-facing message for a failed lookup, including the probe table.
static NSString *CCNMLaunchctlUnavailableMessage(void) {
    NSString *report = nil;
    (void)CCNMLaunchctlResolution(&report);
    return [NSString stringWithFormat:
        @"launchctl was not found in any known location; %@.",
        report.length > 0 ? report : @"no candidate path was probed"];
}

static int CCNMRunLaunchctl(NSArray<NSString *> *arguments, BOOL quiet) {
    NSString *launchctl = CCNMLaunchctlPath();
    if (!launchctl) {
        return -1;
    }
    char **argv = calloc(arguments.count + 2, sizeof(char *));
    if (!argv) {
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
    int spawnResult = posix_spawn(&pid, launchctl.fileSystemRepresentation,
        actionsPointer, NULL, argv, environ);
    if (actionsInitialized) {
        posix_spawn_file_actions_destroy(&actions);
    }
    free(argv);
    if (spawnResult != 0) {
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
    NSString *temporary = [path stringByAppendingFormat:
        @".networkmanager.%d.part", getpid()];
    int descriptor = open(temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (descriptor < 0) {
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"Could not create the launchd plist replacement.");
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL success = YES;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            success = NO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (success) {
        success = fchmod(descriptor, 0644) == 0 &&
            fchown(descriptor, 0, 0) == 0 && fsync(descriptor) == 0;
    }
    if (close(descriptor) != 0) {
        success = NO;
    }
    if (success) {
        success = rename(temporary.fileSystemRepresentation,
            path.fileSystemRepresentation) == 0;
    }
    if (!success) {
        (void)unlink(temporary.fileSystemRepresentation);
        return CCNMSetError(error, CCNMMaintainerErrorPlist,
            @"Could not durably replace the launchd plist.");
    }
    return YES;
}

BOOL CCNMPrepareMaintenanceLaunchd(NSError **error) {
    NSString *root = CCNMMaintainerJailbreakRoot();
    if (root.length == 0) {
        return CCNMSetError(error, CCNMMaintainerErrorRoot,
            @"The active jailbreak root could not be resolved uniquely.");
    }
    NSString *launchctl = CCNMLaunchctlPath();
    NSString *plistPath = CCNMMaintainerRootedPath(
        CCNMMaintenanceLaunchdRelativePath);
    NSString *executablePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceExecutableRelativePath);
    NSString *baselinePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceBaselineRelativePath);
    // Report the failing item individually. A single combined message cannot be
    // acted on: the four inputs fail for unrelated reasons (missing launchctl,
    // unresolvable rooted path, unpacked-but-not-executable helper) and each
    // needs a different fix on the device.
    if (!launchctl) {
        return CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            CCNMLaunchctlUnavailableMessage());
    }
    if (!plistPath || !executablePath || !baselinePath) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            @"A required maintenance path could not be resolved against the jailbreak root.");
    }
    if (access(plistPath.fileSystemRepresentation, R_OK) != 0) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            [NSString stringWithFormat:
                @"The launchd plist is not readable at %@ (errno %d).",
                plistPath, errno]);
    }
    if (access(executablePath.fileSystemRepresentation, X_OK) != 0) {
        return CCNMSetError(error, CCNMMaintainerErrorPath,
            [NSString stringWithFormat:
                @"The maintenance helper is not executable at %@ (errno %d).",
                executablePath, errno]);
    }

    NSDictionary *source = [NSDictionary dictionaryWithContentsOfFile:plistPath];
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
    if (!CCNMLaunchctlPath()) {
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

BOOL CCNMRegisterMaintenanceLaunchd(NSError **error) {
    if (!CCNMPrepareMaintenanceLaunchd(error) ||
        !CCNMStopMaintenanceLaunchd(error)) {
        return NO;
    }
    NSString *plistPath = CCNMMaintainerRootedPath(
        CCNMMaintenanceLaunchdRelativePath);
    if (CCNMRunLaunchctl(@[@"bootstrap", @"system", plistPath], NO) != 0 ||
        !CCNMJobIsLoaded()) {
        (void)CCNMStopMaintenanceLaunchd(NULL);
        return CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
            @"The maintenance launchd job could not be registered and verified.");
    }
    NSString *baselinePath = CCNMMaintainerRootedPath(
        CCNMMaintenanceBaselineRelativePath);
    if ([[NSFileManager defaultManager] fileExistsAtPath:baselinePath]) {
        NSString *target = [@"system/"
            stringByAppendingString:CCNMMaintenanceLaunchdLabel];
        if (CCNMRunLaunchctl(@[@"kickstart", @"-k", target], NO) != 0 ||
            !CCNMJobIsLoaded()) {
            (void)CCNMStopMaintenanceLaunchd(NULL);
            return CCNMSetError(error, CCNMMaintainerErrorLaunchctl,
                @"The policy-scoped maintenance job could not be started.");
        }
    }
    return YES;
}
