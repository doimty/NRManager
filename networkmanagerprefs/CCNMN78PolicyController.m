#import "CCNMN78PolicyController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <pwd.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#if defined(CCNM_MAINTAINER_SCRIPT)

// Maintainer scripts run inside dpkg, where libroothide.dylib is not loaded
// and @loader_path/.jbroot does not exist. Resolve the jbroot directory
// ourselves using the same convention as roothide Bootstrap: a directory
// named .jbroot-<16 hex chars> under /var/containers/Bundle/Application/.
static BOOL CCNMIsJBResourceName(const char *name) {
    if (!name) {
        return NO;
    }
    static const char prefix[] = ".jbroot-";
    size_t prefixLength = sizeof(prefix) - 1;
    if (strlen(name) != prefixLength + 16) {
        return NO;
    }
    if (strncmp(name, prefix, prefixLength) != 0) {
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

static NSString *CCNMJBResourceRootFromExecutable(void) {
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
        NSString *executablePath = [NSString stringWithUTF8String:buffer];
        NSMutableArray<NSString *> *prefix = [NSMutableArray array];
        for (NSString *component in executablePath.pathComponents) {
            [prefix addObject:component];
            if (CCNMIsJBResourceName(component.UTF8String)) {
                root = [NSString pathWithComponents:prefix];
                break;
            }
        }
    }
    free(buffer);
    return root;
}

static NSString *CCNMJBResourceRootByScan(void) {
    NSString *applicationDirectory = @"/var/containers/Bundle/Application/";
    NSArray *entries = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:applicationDirectory error:NULL];
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (CCNMIsJBResourceName(entry.UTF8String)) {
            [matches addObject:[applicationDirectory stringByAppendingPathComponent:entry]];
        }
    }
    return matches.count == 1 ? matches.firstObject : nil;
}

static NSString *CCNMJBResourceRoot(void) {
    static NSString *cachedRoot;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedRoot = CCNMJBResourceRootFromExecutable() ?: CCNMJBResourceRootByScan();
    });
    return cachedRoot;
}

static NSString *CCNMPolicyRootForMaintainer(NSString *path) {
    NSString *root = CCNMJBResourceRoot();
    if (root.length == 0) {
        return [@"/.networkmanager-invalid-jbroot" stringByAppendingPathComponent:path];
    }
    return [root stringByAppendingPathComponent:path];
}

#define CCNMPolicyRoot(path) CCNMPolicyRootForMaintainer(path)

#elif __has_include(<roothide.h>)
#import <roothide.h>
#define CCNMPolicyRoot(path) jbroot(path)
#else
#define CCNMPolicyRoot(path) (path)
#endif

CCNMRequestedMode const CCNMRequestedModeSystemDefault = @"systemDefault";
CCNMRequestedMode const CCNMRequestedModeN78Preferred = @"n78Preferred";

CCNMAppliedPolicy const CCNMAppliedPolicyUnknown = @"unknown";
CCNMAppliedPolicy const CCNMAppliedPolicyApplying = @"applying";
CCNMAppliedPolicy const CCNMAppliedPolicyVerifiedSystemDefault = @"verifiedSystemDefault";
CCNMAppliedPolicy const CCNMAppliedPolicyVerifiedN78Only = @"verifiedN78Only";
CCNMAppliedPolicy const CCNMAppliedPolicyDiverged = @"diverged";
CCNMAppliedPolicy const CCNMAppliedPolicyRecoveryRequired = @"recoveryRequired";

CCNMServingState const CCNMServingStateNRN78 = @"nrN78";
CCNMServingState const CCNMServingStateNROther = @"nrOther";
CCNMServingState const CCNMServingStateLTE = @"lteBand";
CCNMServingState const CCNMServingStateOther = @"other";
CCNMServingState const CCNMServingStateUnknown = @"unknown";

CCNMRecoveryState const CCNMRecoveryStateClean = @"clean";
CCNMRecoveryState const CCNMRecoveryStateEnablePending = @"enablePending";
CCNMRecoveryState const CCNMRecoveryStateEnabledWithBaseline = @"enabledWithBaseline";
CCNMRecoveryState const CCNMRecoveryStateRestorePending = @"restorePending";
CCNMRecoveryState const CCNMRecoveryStateRebootRequired = @"rebootRequired";
CCNMRecoveryState const CCNMRecoveryStateRecoveryFailed = @"recoveryFailed";

CCNMN78PolicyErrorCode const CCNMN78PolicyErrorNone = @"none";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorBusy = @"busy";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUnsupportedTarget = @"unsupportedTarget";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUnsafeSubscription = @"unsafeSubscription";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorInvalidBandInfo = @"invalidBandInfo";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorN78Unavailable = @"n78Unavailable";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorInvalidRecords = @"invalidRecords";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUUIDDrift = @"uuidDrift";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorPersistence = @"persistence";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorSetterFailed = @"setterFailed";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorSetterUncertain = @"setterUncertain";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorReadBackMismatch = @"readBackMismatch";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorRecoveryRequired = @"recoveryRequired";

NSString *const CCNMN78PolicySummarySuccessKey = @"success";
NSString *const CCNMN78PolicySummaryOperationKey = @"operation";
NSString *const CCNMN78PolicySummaryStateKey = @"state";
NSString *const CCNMN78PolicySummaryRequestedModeKey = @"requestedMode";
NSString *const CCNMN78PolicySummaryAppliedPolicyKey = @"appliedPolicy";
NSString *const CCNMN78PolicySummaryRecoveryStateKey = @"recoveryState";
NSString *const CCNMN78PolicySummaryErrorCodeKey = @"errorCode";
NSString *const CCNMN78PolicySummaryErrorKey = @"error";
NSString *const CCNMN78PolicySummaryRequiresRebootKey = @"requiresReboot";
NSString *const CCNMN78PolicySummaryMayWriteKey = @"mayWrite";
NSString *const CCNMN78PolicySummaryMayUninstallKey = @"mayUninstall";
NSString *const CCNMN78PolicyDidChangeDarwinNotification = @"me.nixuge.networkmanager/n78-policy-changed";

static NSString *const CCNMPolicyOwner = @"me.nixuge.networkmanager.n78-policy";
static NSString *const CCNMNRKey = @"kCTRegistrationRadioAccessTechnologyNR";
static NSString *const CCNMKnownOrphanRecoverySource = @"known-device-orphaned-n78";
static NSString *const CCNMKnownOrphanEvidenceSHA256 = @"9e6230dfae679537b5b827518975e7675abf864cd403e96f97f11de63316ac76";
// This exact placeholder is part of the reviewed private-API evidence and is
// intentionally required again at recovery time; it is not a general SIM ID.
static NSString *const CCNMKnownOrphanSubscriptionUUID = @"00000000-0000-0000-0000-000000000001";
static const long long CCNMMaximumBandIdentifier = 1024;
static const NSTimeInterval CCNMSetterDeadlineSeconds = 20.0;
static const useconds_t CCNMReadBackPollMicroseconds = 1000000;
static const NSUInteger CCNMReadBackMaximumAttempts = 31;
static const NSTimeInterval CCNMReadBackDeadlineSeconds = 30.0;

@protocol CCNMCoreTelephonyClient <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (id)getSubscriptionInfoWithError:(NSError **)error;
- (id)getBandInfo:(id)context error:(NSError **)error;
- (void)setActiveBandInfo:(id)context bands:(id)bands error:(NSError **)error;
@end

@protocol CCNMSubscriptionInfo <NSObject>
- (NSArray *)subscriptions;
@end

@protocol CCNMSubscriptionContext <NSObject>
- (long long)slotID;
- (BOOL)isSimGood;
- (BOOL)isSimPresent;
- (NSUUID *)uuid;
@end

@protocol CCNMBandInfo <NSObject>
- (instancetype)initWithActiveBands:(NSDictionary *)bands;
- (NSDictionary *)activeBands;
- (NSDictionary *)supportedBands;
@end

typedef NS_ENUM(NSInteger, CCNMSetterOutcome) {
    CCNMSetterOutcomeNotAttempted = 0,
    CCNMSetterOutcomeReturned,
    CCNMSetterOutcomeFailed,
    CCNMSetterOutcomeUncertain
};

static BOOL CCNMSetterUncertainLatch = NO;
static BOOL CCNMSetterCallActive = NO;
static NSUInteger CCNMSetterGeneration = 0;
static NSTimeInterval CCNMSetterStartedMonotonic = 0;
static int CCNMSetterRetainedPolicyLockDescriptor = -1;
static NSUInteger CCNMSetterRetainedPolicyLockGeneration = 0;

NSString *CCNMN78PolicyStatePath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.state.plist");
}

NSString *CCNMN78PolicyBaselinePath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.baseline.plist");
}

NSString *CCNMN78PolicyIntentPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.intent.plist");
}

NSString *CCNMN78PolicyInFlightPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.inflight.plist");
}

NSString *CCNMN78PolicyLockPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.lock");
}

NSString *CCNMN78PolicyRemovalGuardPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.n78-policy.removal-guard.plist");
}

NSArray<NSString *> *CCNMN78PolicyPaths(void) {
    return @[
        CCNMN78PolicyStatePath(),
        CCNMN78PolicyBaselinePath(),
        CCNMN78PolicyIntentPath(),
        CCNMN78PolicyInFlightPath(),
        CCNMN78PolicyLockPath(),
        CCNMN78PolicyRemovalGuardPath()
    ];
}

static void CCNMPostPolicyDidChange(void) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
        NULL,
        NULL,
        true);
}

static long long CCNMUnixMilliseconds(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static NSTimeInterval CCNMMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (NSTimeInterval)now.tv_sec + ((NSTimeInterval)now.tv_nsec / (NSTimeInterval)NSEC_PER_SEC);
}

static NSString *CCNMSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) {
        return nil;
    }
    char *buffer = calloc(1, size);
    if (!buffer) {
        return nil;
    }
    NSString *value = nil;
    if (sysctlbyname(name, buffer, &size, NULL, 0) == 0) {
        value = [NSString stringWithUTF8String:buffer];
    }
    free(buffer);
    return value;
}

static NSString *CCNMCanonicalUUIDString(id value) {
    NSString *string = nil;
    if ([value isKindOfClass:[NSUUID class]]) {
        string = [(NSUUID *)value UUIDString];
    } else if ([value isKindOfClass:[NSString class]]) {
        string = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSUUID *uuid = string ? [[NSUUID alloc] initWithUUIDString:string] : nil;
    return uuid.UUIDString;
}

static NSString *CCNMBootSessionIdentity(void) {
    return CCNMCanonicalUUIDString(CCNMSysctlString("kern.bootsessionuuid"));
}

typedef NS_ENUM(NSInteger, CCNMBootRelation) {
    CCNMBootRelationUnknown = 0,
    CCNMBootRelationCurrent,
    CCNMBootRelationEarlier
};

static CCNMBootRelation CCNMBootRelationForRecord(NSDictionary *record) {
    NSString *current = CCNMBootSessionIdentity();
    NSString *recorded = CCNMCanonicalUUIDString(record[@"bootSessionUUID"]);
    if (!current || !recorded) {
        return CCNMBootRelationUnknown;
    }
    return [current isEqualToString:recorded] ? CCNMBootRelationCurrent : CCNMBootRelationEarlier;
}

static BOOL CCNMFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSDictionary *CCNMLoadRecord(NSString *path, BOOL *exists) {
    BOOL present = CCNMFileExists(path);
    if (exists) {
        *exists = present;
    }
    if (!present) {
        return nil;
    }
    id record = [NSDictionary dictionaryWithContentsOfFile:path];
    return [record isKindOfClass:[NSDictionary class]] ? record : nil;
}

static BOOL CCNMSyncParentDirectory(NSString *path, NSString **failure) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    int descriptor = open(directory.fileSystemRepresentation, O_RDONLY);
    if (descriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not open the policy directory: %s", strerror(errno)];
        }
        return NO;
    }
    int result = fsync(descriptor);
    int savedError = errno;
    close(descriptor);
    if (result != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not sync the policy directory: %s", strerror(savedError ?: EIO)];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMNormalizePolicyDescriptorOwnership(int descriptor, NSString **failure) {
    if (geteuid() != 0) {
        return YES;
    }
    struct passwd *mobile = getpwnam("mobile");
    uid_t uid = mobile ? mobile->pw_uid : 501;
    gid_t gid = mobile ? mobile->pw_gid : 501;
    if (fchown(descriptor, uid, gid) != 0 || fchmod(descriptor, S_IRUSR | S_IWUSR) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not preserve mobile ownership for policy evidence: %s",
                strerror(errno ?: EIO)];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMFullSync(int descriptor, NSString **failure) {
#ifdef F_FULLFSYNC
    if (fcntl(descriptor, F_FULLFSYNC, 0) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not fully sync a policy record: %s", strerror(errno ?: EIO)];
        }
        return NO;
    }
#else
    if (fsync(descriptor) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not sync a policy record: %s", strerror(errno ?: EIO)];
        }
        return NO;
    }
#endif
    return YES;
}

static NSData *CCNMSerializeRecord(NSDictionary *record, NSString **failure) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (!data || error) {
        if (failure) {
            *failure = error.localizedDescription ?: @"The policy record is not a valid property list.";
        }
        return nil;
    }
    return data;
}

static BOOL CCNMWriteDataExclusively(NSData *data, NSString *path, NSString **failure) {
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        if (failure) {
            *failure = errno == EEXIST
                ? [NSString stringWithFormat:@"%@ already exists.", path.lastPathComponent]
                : [NSString stringWithFormat:@"Could not create %@: %s", path.lastPathComponent, strerror(errno)];
        }
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    NSString *ownershipFailure = nil;
    BOOL success = CCNMNormalizePolicyDescriptorOwnership(descriptor, &ownershipFailure);
    int savedError = success ? 0 : (errno ?: EIO);
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            success = NO;
            savedError = errno ?: EIO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    NSString *syncFailure = nil;
    if (success && !CCNMFullSync(descriptor, &syncFailure)) {
        success = NO;
        savedError = EIO;
    }
    if (close(descriptor) != 0 && success) {
        success = NO;
        savedError = errno ?: EIO;
    }
    if (!success) {
        unlink(path.fileSystemRepresentation);
        CCNMSyncParentDirectory(path, NULL);
        if (failure) {
            *failure = ownershipFailure ?: syncFailure ?:
                [NSString stringWithFormat:@"Could not durably write %@: %s", path.lastPathComponent, strerror(savedError ?: EIO)];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMCreateDurableRecord(NSDictionary *record, NSString *path, NSString **failure) {
    NSData *data = CCNMSerializeRecord(record, failure);
    if (!data || !CCNMWriteDataExclusively(data, path, failure)) {
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:record]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ failed durable read-back verification.", path.lastPathComponent];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMReplaceDurableRecord(NSDictionary *record, NSString *path, NSString **failure) {
    NSData *data = CCNMSerializeRecord(record, failure);
    NSString *token = [NSUUID UUID].UUIDString;
    if (!data || !token) {
        if (failure && !*failure) {
            *failure = @"Could not allocate an atomic policy-record path.";
        }
        return NO;
    }
    NSString *temporary = [NSString stringWithFormat:@"%@.tmp.%d.%@", path, getpid(), token];
    if (!CCNMWriteDataExclusively(data, temporary, failure)) {
        return NO;
    }
    if (rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        int savedError = errno;
        unlink(temporary.fileSystemRepresentation);
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not replace %@ atomically: %s", path.lastPathComponent, strerror(savedError ?: EIO)];
        }
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:record]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ failed replacement verification.", path.lastPathComponent];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMReplaceExpectedRecord(NSDictionary *expected,
                                      NSDictionary *replacement,
                                      NSString *path,
                                      NSString **failure) {
    NSDictionary *live = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![live isEqualToDictionary:expected]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ changed before durable handoff.", path.lastPathComponent];
        }
        return NO;
    }
    NSData *data = CCNMSerializeRecord(replacement, failure);
    NSString *token = [NSUUID UUID].UUIDString;
    if (!data || !token) {
        return NO;
    }
    NSString *temporary = [NSString stringWithFormat:@"%@.handoff.%d.%@", path, getpid(), token];
    if (!CCNMWriteDataExclusively(data, temporary, failure)) {
        return NO;
    }
    live = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![live isEqualToDictionary:expected]) {
        unlink(temporary.fileSystemRepresentation);
        CCNMSyncParentDirectory(path, NULL);
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ changed during durable handoff.", path.lastPathComponent];
        }
        return NO;
    }
    if (rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        int savedError = errno;
        unlink(temporary.fileSystemRepresentation);
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not hand off %@: %s", path.lastPathComponent, strerror(savedError ?: EIO)];
        }
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:replacement]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ handoff verification failed.", path.lastPathComponent];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMRemoveExpectedRecord(NSDictionary *expected, NSString *path, NSString **failure) {
    NSDictionary *live = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![live isEqualToDictionary:expected]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ changed before retirement; it was preserved.", path.lastPathComponent];
        }
        return NO;
    }
    if (unlink(path.fileSystemRepresentation) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not retire %@: %s", path.lastPathComponent, strerror(errno)];
        }
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    if (CCNMFileExists(path)) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ still exists after retirement.", path.lastPathComponent];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMNSNumberIsInteger(id value) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    const char *type = [(NSNumber *)value objCType];
    return type && type[0] && type[1] == '\0' && strchr("cCsSiIlLqQ", type[0]) != NULL;
}

static NSSet<NSString *> *CCNMRequiredRATKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid",
            @"kCTRegistrationRadioAccessTechnologyGSM",
            @"kCTRegistrationRadioAccessTechnologyLTE",
            @"kCTRegistrationRadioAccessTechnologyNR",
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA",
            @"kCTRegistrationRadioAccessTechnologyUTRAN"
        ]];
    });
    return keys;
}

static NSDictionary *CCNMKnownOrphanHistoricalOriginalBands(void) {
    static NSDictionary *bands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bands = @{
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10,
                @11, @12, @13, @14, @15, @16, @17, @18, @19, @20
            ],
            @"kCTRegistrationRadioAccessTechnologyGSM": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9
            ],
            @"kCTRegistrationRadioAccessTechnologyLTE": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12, @13, @14,
                @17, @18, @19, @20, @21, @24, @25, @26, @27, @28, @29, @30,
                @33, @34, @35, @36, @37, @38, @39, @40, @41, @42, @43, @46,
                @48, @66, @71
            ],
            @"kCTRegistrationRadioAccessTechnologyNR": @[
                @1, @2, @3, @5, @7, @8, @12, @13, @14, @18, @20, @25, @26,
                @28, @30, @34, @38, @39, @40, @41, @48, @50, @51, @53, @65,
                @66, @70, @71, @74, @75, @76, @77, @78, @79, @80, @81, @82,
                @83, @84, @85, @86, @257, @258, @259, @260, @261
            ],
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA": @[ @1, @2, @3, @4, @5, @6 ],
            @"kCTRegistrationRadioAccessTechnologyUTRAN": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11
            ]
        };
    });
    return bands;
}

static NSDictionary *CCNMKnownOrphanHistoricalActiveBands(void) {
    static NSDictionary *bands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *active = [CCNMKnownOrphanHistoricalOriginalBands() mutableCopy];
        active[CCNMNRKey] = @[ @78 ];
        bands = [active copy];
    });
    return bands;
}

static NSDictionary *CCNMKnownOrphanHistoricalSupportedBands(void) {
    static NSDictionary *bands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bands = @{
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid": @[ @1, @2, @3, @12 ],
            @"kCTRegistrationRadioAccessTechnologyGSM": @[ @1, @2, @7, @9 ],
            @"kCTRegistrationRadioAccessTechnologyLTE": @[
                @1, @2, @3, @4, @5, @7, @8, @12, @13, @17, @18, @19, @20,
                @25, @26, @28, @30, @34, @38, @39, @40, @41, @42, @46, @48,
                @66
            ],
            @"kCTRegistrationRadioAccessTechnologyNR": @[
                @1, @2, @3, @5, @7, @8, @12, @20, @25, @28, @30, @38, @40,
                @41, @48, @66, @77, @78, @79
            ],
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA": @[],
            @"kCTRegistrationRadioAccessTechnologyUTRAN": @[ @1, @2, @4, @5, @6, @8 ]
        };
    });
    return bands;
}

static BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString **failure) {
    if (![bands isKindOfClass:[NSDictionary class]] ||
        ![[NSSet setWithArray:bands.allKeys] isEqualToSet:CCNMRequiredRATKeys()]) {
        if (failure) {
            *failure = @"BandInfo does not contain the exact complete RAT key set.";
        }
        return NO;
    }
    for (id key in bands) {
        id values = bands[key];
        if (![key isKindOfClass:[NSString class]] ||
            ![(NSString *)key hasPrefix:@"kCTRegistrationRadioAccessTechnology"] ||
            ![values isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"BandInfo contains an invalid RAT key or value type.";
            }
            return NO;
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (id band in (NSArray *)values) {
            if (!CCNMNSNumberIsInteger(band) || [band longLongValue] <= 0 ||
                [band longLongValue] > CCNMMaximumBandIdentifier || [seen containsObject:band]) {
                if (failure) {
                    *failure = @"BandInfo contains an invalid or duplicate band identifier.";
                }
                return NO;
            }
            [seen addObject:band];
        }
    }
    return YES;
}

static BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil && [left isEqualToDictionary:right];
}

static BOOL CCNMKnownOrphanBandInfoMatches(NSDictionary *bandInfo,
                                            NSDictionary *expectedActiveBands) {
    return [bandInfo isKindOfClass:NSDictionary.class] &&
        CCNMDictionariesEqual(bandInfo[@"activeBands"], expectedActiveBands) &&
        CCNMDictionariesEqual(bandInfo[@"supportedBands"],
            CCNMKnownOrphanHistoricalSupportedBands());
}

static BOOL CCNMKnownOrphanBaselineMatchesEvidence(NSDictionary *baseline) {
    return [baseline isKindOfClass:NSDictionary.class] &&
        [baseline[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource] &&
        [baseline[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256] &&
        [CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])
            isEqualToString:CCNMKnownOrphanSubscriptionUUID] &&
        CCNMDictionariesEqual(baseline[@"activeBands"],
            CCNMKnownOrphanHistoricalOriginalBands());
}

static BOOL CCNMStateHasVerifiedKnownOrphanRestore(NSDictionary *state) {
    if (![state isKindOfClass:NSDictionary.class] ||
        ![state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] ||
        ![state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] ||
        ![state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] ||
        ![CCNMCanonicalUUIDString(state[@"subscriptionUUID"])
            isEqualToString:CCNMKnownOrphanSubscriptionUUID] ||
        [state[@"uncertain"] boolValue] ||
        ![state[@"verifiedAt"] isKindOfClass:NSNumber.class] ||
        ![state[@"restoredBaselineCreatedAt"] isKindOfClass:NSNumber.class] ||
        !CCNMDictionariesEqual(state[@"verifiedActiveBands"],
            CCNMKnownOrphanHistoricalOriginalBands())) {
        return NO;
    }
    BOOL fixedProvenance = [state[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource] &&
        [state[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256];
    // Compatibility for the already-verified package state created before
    // final clean-state provenance was persisted.
    BOOL legacyVerifiedShape = !state[@"recoverySource"] && !state[@"evidenceSHA256"];
    return fixedProvenance || legacyVerifiedShape;
}

static NSDictionary *CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString **failure) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"A complete BandInfo dictionary is required.";
        }
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    id copy = data ? [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:&error] : nil;
    if (![copy isKindOfClass:[NSDictionary class]] || error) {
        if (failure) {
            *failure = error.localizedDescription ?: @"BandInfo could not be deep-copied.";
        }
        return nil;
    }
    return copy;
}

static BOOL CCNMValidateN78OnlyPayload(NSDictionary *original,
                                       NSDictionary *payload,
                                       NSString **failure) {
    if (!CCNMValidateBandDictionary(original, failure) ||
        !CCNMValidateBandDictionary(payload, failure) ||
        ![[NSSet setWithArray:original.allKeys] isEqualToSet:[NSSet setWithArray:payload.allKeys]]) {
        return NO;
    }
    for (NSString *key in original) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? @[ @78 ] : original[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? @"The requested NR array is not exactly [78]."
                    : [NSString stringWithFormat:@"The requested payload changed non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

static NSDictionary *CCNMBuildN78Payload(NSDictionary *active,
                                          NSDictionary *supported,
                                          NSString **failure) {
    if (!CCNMValidateBandDictionary(active, failure) || !CCNMValidateBandDictionary(supported, failure)) {
        return nil;
    }
    NSArray *activeNR = active[CCNMNRKey];
    NSArray *supportedNR = supported[CCNMNRKey];
    if (![activeNR containsObject:@78] || ![supportedNR containsObject:@78]) {
        if (failure) {
            *failure = @"Band n78 is not present in both fresh active and supported NR arrays.";
        }
        return nil;
    }
    if ([activeNR isEqualToArray:@[ @78 ]]) {
        if (failure) {
            *failure = @"The live NR array is already exactly [78] without a retained policy baseline.";
        }
        return nil;
    }
    NSDictionary *copy = CCNMDeepCopyDictionary(active, failure);
    if (!copy) {
        return nil;
    }
    NSMutableDictionary *draft = [copy mutableCopy];
    draft[CCNMNRKey] = @[ @78 ];
    NSDictionary *payload = CCNMDeepCopyDictionary(draft, failure);
    return CCNMValidateN78OnlyPayload(active, payload, failure) ? payload : nil;
}

static BOOL CCNMValidateRestorePayload(NSDictionary *live,
                                       NSDictionary *baseline,
                                       NSDictionary *payload,
                                       NSString **failure) {
    if (!CCNMValidateBandDictionary(live, failure) ||
        !CCNMValidateBandDictionary(baseline, failure) ||
        !CCNMValidateBandDictionary(payload, failure)) {
        return NO;
    }
    if (![[NSSet setWithArray:live.allKeys] isEqualToSet:[NSSet setWithArray:baseline.allKeys]] ||
        ![[NSSet setWithArray:live.allKeys] isEqualToSet:[NSSet setWithArray:payload.allKeys]]) {
        if (failure) {
            *failure = @"Restore dictionaries do not have identical complete RAT key sets.";
        }
        return NO;
    }
    for (NSString *key in live) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? baseline[key] : live[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? @"The restore payload does not contain the exact saved NR array."
                    : [NSString stringWithFormat:@"The restore payload changed current non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

static NSDictionary *CCNMBuildRestorePayload(NSDictionary *live,
                                              NSDictionary *baseline,
                                              NSString **failure) {
    NSDictionary *copy = CCNMDeepCopyDictionary(live, failure);
    if (!copy || !CCNMValidateBandDictionary(baseline, failure)) {
        return nil;
    }
    NSMutableDictionary *draft = [copy mutableCopy];
    draft[CCNMNRKey] = [baseline[CCNMNRKey] copy];
    NSDictionary *payload = CCNMDeepCopyDictionary(draft, failure);
    return CCNMValidateRestorePayload(live, baseline, payload, failure) ? payload : nil;
}

static BOOL CCNMStringInDomain(id value, NSArray<NSString *> *domain) {
    return [value isKindOfClass:[NSString class]] && [domain containsObject:value];
}

static NSDictionary *CCNMBuildStateRecord(CCNMRequestedMode requested,
                                           CCNMAppliedPolicy applied,
                                           CCNMRecoveryState recovery,
                                           NSUInteger generation,
                                           NSString *subscriptionUUID,
                                           BOOL uncertain,
                                           CCNMN78PolicyErrorCode errorCode,
                                           NSString *error,
                                           NSDictionary *extra,
                                           NSString **failure) {
    NSString *bootSession = CCNMBootSessionIdentity();
    if (!bootSession) {
        if (failure) {
            *failure = @"The boot session identity is unavailable.";
        }
        return nil;
    }
    NSMutableDictionary *record = [@{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"state",
        @"updatedAt": @(CCNMUnixMilliseconds()),
        @"bootSessionUUID": bootSession,
        @"operationGeneration": @(generation),
        @"requestedMode": requested,
        @"appliedPolicy": applied,
        @"recoveryState": recovery,
        @"subscriptionUUID": CCNMCanonicalUUIDString(subscriptionUUID) ?: @"",
        @"uncertain": @(uncertain),
        @"errorCode": errorCode ?: CCNMN78PolicyErrorNone,
        @"error": error ?: @""
    } mutableCopy];
    if (extra) {
        [record addEntriesFromDictionary:extra];
    }
    return record;
}

static BOOL CCNMValidateStateRecord(NSDictionary *state, NSString **failure) {
    BOOL valid = [state isKindOfClass:[NSDictionary class]] &&
        [state[@"schemaVersion"] isEqual:@1] &&
        [state[@"owner"] isEqual:CCNMPolicyOwner] &&
        [state[@"kind"] isEqual:@"state"] &&
        [state[@"updatedAt"] isKindOfClass:[NSNumber class]] && [state[@"updatedAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(state[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(state[@"operationGeneration"]) && [state[@"operationGeneration"] longLongValue] >= 0 &&
        CCNMStringInDomain(state[@"requestedMode"], @[CCNMRequestedModeSystemDefault, CCNMRequestedModeN78Preferred]) &&
        CCNMStringInDomain(state[@"appliedPolicy"], @[
            CCNMAppliedPolicyUnknown, CCNMAppliedPolicyApplying,
            CCNMAppliedPolicyVerifiedSystemDefault, CCNMAppliedPolicyVerifiedN78Only,
            CCNMAppliedPolicyDiverged, CCNMAppliedPolicyRecoveryRequired
        ]) &&
        CCNMStringInDomain(state[@"recoveryState"], @[
            CCNMRecoveryStateClean, CCNMRecoveryStateEnablePending,
            CCNMRecoveryStateEnabledWithBaseline, CCNMRecoveryStateRestorePending,
            CCNMRecoveryStateRebootRequired, CCNMRecoveryStateRecoveryFailed
        ]) &&
        [state[@"uncertain"] isKindOfClass:[NSNumber class]] &&
        [state[@"errorCode"] isKindOfClass:[NSString class]] &&
        [state[@"error"] isKindOfClass:[NSString class]];
    NSString *uuid = state[@"subscriptionUUID"];
    valid = valid && [uuid isKindOfClass:[NSString class]] &&
        ([(NSString *)uuid length] == 0 || CCNMCanonicalUUIDString(uuid) != nil);
    if (!valid && failure) {
        *failure = @"The durable n78 policy state record is malformed or foreign.";
    }
    return valid;
}

static NSDictionary *CCNMBuildRemovalGuardRecord(NSDictionary *summary, NSString **failure) {
    NSString *bootSession = CCNMBootSessionIdentity();
    NSString *nonce = NSUUID.UUID.UUIDString;
    if (!bootSession || !nonce) {
        if (failure) {
            *failure = @"Boot identity and nonce are required for the removal guard.";
        }
        return nil;
    }
    return @{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"removalGuard",
        @"createdAt": @(CCNMUnixMilliseconds()),
        @"bootSessionUUID": bootSession,
        @"nonce": nonce,
        @"operationGeneration": summary[@"operationGeneration"] ?: @0,
        @"requestedMode": CCNMRequestedModeSystemDefault,
        @"appliedPolicy": CCNMAppliedPolicyVerifiedSystemDefault,
        @"recoveryState": CCNMRecoveryStateClean
    };
}

static BOOL CCNMValidateRemovalGuardRecord(NSDictionary *guard, NSString **failure) {
    BOOL valid = [guard isKindOfClass:NSDictionary.class] &&
        [guard[@"schemaVersion"] isEqual:@1] &&
        [guard[@"owner"] isEqual:CCNMPolicyOwner] &&
        [guard[@"kind"] isEqual:@"removalGuard"] &&
        [guard[@"createdAt"] isKindOfClass:NSNumber.class] && [guard[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(guard[@"bootSessionUUID"]) != nil &&
        CCNMCanonicalUUIDString(guard[@"nonce"]) != nil &&
        CCNMNSNumberIsInteger(guard[@"operationGeneration"]) && [guard[@"operationGeneration"] longLongValue] >= 0 &&
        [guard[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [guard[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [guard[@"recoveryState"] isEqual:CCNMRecoveryStateClean];
    if (!valid && failure) {
        *failure = @"The durable package-removal guard is malformed or foreign.";
    }
    return valid;
}

static NSDictionary *CCNMBuildBaselineRecord(NSDictionary *active,
                                              NSString *subscriptionUUID,
                                              NSUInteger generation,
                                              NSString **failure) {
    NSString *bootSession = CCNMBootSessionIdentity();
    NSString *uuid = CCNMCanonicalUUIDString(subscriptionUUID);
    if (!bootSession || !uuid || !CCNMValidateBandDictionary(active, failure)) {
        if (failure && !*failure) {
            *failure = @"A baseline requires valid boot and subscription identities.";
        }
        return nil;
    }
    return @{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"baseline",
        @"createdAt": @(CCNMUnixMilliseconds()),
        @"bootSessionUUID": bootSession,
        @"operationGeneration": @(generation),
        @"slotID": @1,
        @"subscriptionUUID": uuid,
        @"activeBands": active
    };
}

static BOOL CCNMValidateBaselineRecord(NSDictionary *baseline, NSString **failure) {
    NSDictionary *bands = [baseline[@"activeBands"] isKindOfClass:[NSDictionary class]] ? baseline[@"activeBands"] : nil;
    BOOL hasRecoverySource = baseline[@"recoverySource"] != nil;
    BOOL hasEvidenceDigest = baseline[@"evidenceSHA256"] != nil;
    BOOL provenanceValid = (!hasRecoverySource && !hasEvidenceDigest) ||
        CCNMKnownOrphanBaselineMatchesEvidence(baseline);
    BOOL valid = [baseline isKindOfClass:[NSDictionary class]] &&
        [baseline[@"schemaVersion"] isEqual:@1] &&
        [baseline[@"owner"] isEqual:CCNMPolicyOwner] &&
        [baseline[@"kind"] isEqual:@"baseline"] &&
        [baseline[@"createdAt"] isKindOfClass:[NSNumber class]] && [baseline[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(baseline[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(baseline[@"operationGeneration"]) && [baseline[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [baseline[@"slotID"] isEqual:@1] &&
        CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]) != nil && provenanceValid &&
        CCNMValidateBandDictionary(bands, failure);
    if (!valid && failure && !*failure) {
        *failure = @"The durable policy baseline is malformed, foreign, or has invalid recovery provenance.";
    }
    return valid;
}

static NSDictionary *CCNMBuildIntentRecord(NSString *operation,
                                            NSUInteger generation,
                                            NSDictionary *baseline,
                                            NSDictionary *preWrite,
                                            NSDictionary *requested,
                                            NSDictionary *previousState,
                                            NSDictionary *priorIntent,
                                            NSDictionary *priorInFlight,
                                            NSString **failure) {
    NSDictionary *active = preWrite[@"activeBands"];
    NSDictionary *supported = preWrite[@"supportedBands"];
    NSString *uuid = CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]);
    BOOL enable = [operation isEqual:@"enable"];
    BOOL payloadValid = enable
        ? (CCNMBuildN78Payload(active, supported, failure) != nil && CCNMValidateN78OnlyPayload(active, requested, failure))
        : CCNMValidateRestorePayload(active, baseline[@"activeBands"], requested, failure);
    if (!uuid || !payloadValid) {
        return nil;
    }
    NSString *bootSession = CCNMBootSessionIdentity();
    if (!bootSession) {
        if (failure) {
            *failure = @"The current boot identity is required for a durable write intent.";
        }
        return nil;
    }
    NSMutableDictionary *intent = [@{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"intent",
        @"operation": operation,
        @"createdAt": @(CCNMUnixMilliseconds()),
        @"bootSessionUUID": bootSession,
        @"operationGeneration": @(generation),
        @"slotID": @1,
        @"subscriptionUUID": uuid,
        @"baselineCreatedAt": baseline[@"createdAt"],
        @"baselineGeneration": baseline[@"operationGeneration"],
        @"baselineActiveBands": baseline[@"activeBands"],
        @"preWriteActiveBands": active,
        @"preWriteSupportedBands": supported,
        @"requestedActiveBands": requested,
        @"previousState": previousState ?: @{}
    } mutableCopy];
    if (priorIntent) {
        intent[@"priorIntent"] = priorIntent;
    }
    if (priorInFlight) {
        intent[@"priorInFlight"] = priorInFlight;
    }
    return intent;
}

static BOOL CCNMValidateIntentRecord(NSDictionary *intent,
                                     NSDictionary *baseline,
                                     NSString **failure) {
    NSString *operation = [intent[@"operation"] isKindOfClass:[NSString class]] ? intent[@"operation"] : nil;
    NSDictionary *active = [intent[@"preWriteActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"preWriteActiveBands"] : nil;
    NSDictionary *supported = [intent[@"preWriteSupportedBands"] isKindOfClass:[NSDictionary class]] ? intent[@"preWriteSupportedBands"] : nil;
    NSDictionary *requested = [intent[@"requestedActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"requestedActiveBands"] : nil;
    BOOL header = [intent isKindOfClass:[NSDictionary class]] &&
        [intent[@"schemaVersion"] isEqual:@1] &&
        [intent[@"owner"] isEqual:CCNMPolicyOwner] &&
        [intent[@"kind"] isEqual:@"intent"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"] containsObject:operation ?: @""] &&
        [intent[@"createdAt"] isKindOfClass:[NSNumber class]] && [intent[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(intent[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(intent[@"operationGeneration"]) && [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [intent[@"slotID"] isEqual:@1] &&
        [CCNMCanonicalUUIDString(intent[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [intent[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
        [intent[@"baselineGeneration"] isEqual:baseline[@"operationGeneration"]] &&
        CCNMDictionariesEqual(intent[@"baselineActiveBands"], baseline[@"activeBands"]) &&
        CCNMValidateBandDictionary(active, failure) && CCNMValidateBandDictionary(supported, failure);
    BOOL payload = NO;
    if (header && [operation isEqual:@"enable"]) {
        payload = [active[CCNMNRKey] containsObject:@78] && [supported[CCNMNRKey] containsObject:@78] &&
            CCNMValidateN78OnlyPayload(active, requested, failure);
    } else if (header) {
        payload = CCNMValidateRestorePayload(active, baseline[@"activeBands"], requested, failure);
    }
    if ((!header || !payload) && failure && !*failure) {
        *failure = @"The durable policy intent is malformed, foreign, or inconsistent with the baseline.";
    }
    return header && payload;
}

static NSDictionary *CCNMBuildInFlightRecord(NSString *operation,
                                              NSUInteger generation,
                                              NSDictionary *baseline,
                                              NSDictionary *intent,
                                              NSString **failure) {
    NSString *bootSession = CCNMBootSessionIdentity();
    NSString *uuid = CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]);
    if (!bootSession || !uuid) {
        if (failure) {
            *failure = @"Current boot and subscription identities are required before the setter call.";
        }
        return nil;
    }
    return @{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"inflight",
        @"state": @"setterInFlight",
        @"operation": operation,
        @"createdAt": @(CCNMUnixMilliseconds()),
        @"processID": @(getpid()),
        @"bootSessionUUID": bootSession,
        @"operationGeneration": @(generation),
        @"slotID": @1,
        @"subscriptionUUID": uuid,
        @"baselineCreatedAt": baseline[@"createdAt"],
        @"intentCreatedAt": intent[@"createdAt"]
    };
}

static BOOL CCNMValidateInFlightRecord(NSDictionary *record,
                                       NSDictionary *baseline,
                                       NSDictionary *intent,
                                       BOOL requireIntentLink,
                                       NSString **failure) {
    BOOL valid = [record isKindOfClass:[NSDictionary class]] &&
        [record[@"schemaVersion"] isEqual:@1] &&
        [record[@"owner"] isEqual:CCNMPolicyOwner] &&
        [record[@"kind"] isEqual:@"inflight"] &&
        [record[@"state"] isEqual:@"setterInFlight"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"] containsObject:record[@"operation"] ?: @""] &&
        [record[@"createdAt"] isKindOfClass:[NSNumber class]] && [record[@"createdAt"] longLongValue] > 0 &&
        [record[@"processID"] isKindOfClass:[NSNumber class]] && [record[@"processID"] intValue] > 0 &&
        CCNMCanonicalUUIDString(record[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(record[@"operationGeneration"]) && [record[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [record[@"slotID"] isEqual:@1] &&
        [CCNMCanonicalUUIDString(record[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [record[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]];
    if (valid && requireIntentLink) {
        valid = intent &&
            [record[@"operation"] isEqual:intent[@"operation"]] &&
            [record[@"operationGeneration"] isEqual:intent[@"operationGeneration"]] &&
            [record[@"intentCreatedAt"] isEqual:intent[@"createdAt"]];
    }
    if (!valid && failure) {
        *failure = @"The setter in-flight record is malformed, foreign, or inconsistent.";
    }
    return valid;
}

static NSDictionary *CCNMDefaultState(void) {
    return @{
        @"operationGeneration": @0,
        @"requestedMode": CCNMRequestedModeSystemDefault,
        @"appliedPolicy": CCNMAppliedPolicyVerifiedSystemDefault,
        @"recoveryState": CCNMRecoveryStateClean,
        @"subscriptionUUID": @"",
        @"uncertain": @NO,
        @"errorCode": CCNMN78PolicyErrorNone,
        @"error": @""
    };
}

static NSDictionary *CCNMSyntheticRecoveryState(NSDictionary *state,
                                                 CCNMRecoveryState recovery,
                                                 NSString *error) {
    NSDictionary *base = CCNMValidateStateRecord(state, NULL) ? state : CCNMDefaultState();
    NSMutableDictionary *synthetic = [base mutableCopy];
    synthetic[@"appliedPolicy"] = CCNMAppliedPolicyRecoveryRequired;
    synthetic[@"recoveryState"] = recovery;
    synthetic[@"uncertain"] = @YES;
    synthetic[@"errorCode"] = CCNMN78PolicyErrorInvalidRecords;
    synthetic[@"error"] = error ?: @"Durable policy evidence is inconsistent.";
    return synthetic;
}

static NSDictionary *CCNMSummaryFromState(NSDictionary *state,
                                          BOOL success,
                                          NSString *operation,
                                          CCNMN78PolicyErrorCode errorCode,
                                          NSString *error,
                                          NSDictionary *details) {
    NSDictionary *base = state ?: CCNMDefaultState();
    BOOL baselinePresent = CCNMFileExists(CCNMN78PolicyBaselinePath());
    NSDictionary *baselineRecord = baselinePresent
        ? [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyBaselinePath()] : nil;
    BOOL baselineValid = baselinePresent && CCNMValidateBaselineRecord(baselineRecord, NULL);
    BOOL transitionPresent = CCNMFileExists(CCNMN78PolicyIntentPath()) || CCNMFileExists(CCNMN78PolicyInFlightPath());
    BOOL removalGuardPresent = CCNMFileExists(CCNMN78PolicyRemovalGuardPath());
    NSDictionary *removalGuard = removalGuardPresent
        ? [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyRemovalGuardPath()] : nil;
    BOOL removalGuardValid = removalGuardPresent && CCNMValidateRemovalGuardRecord(removalGuard, NULL);
    CCNMRecoveryState recovery = base[@"recoveryState"] ?: CCNMRecoveryStateRecoveryFailed;
    CCNMAppliedPolicy applied = base[@"appliedPolicy"] ?: CCNMAppliedPolicyUnknown;
    BOOL currentBootInFlight = NO;
    if (CCNMFileExists(CCNMN78PolicyInFlightPath())) {
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyInFlightPath()];
        currentBootInFlight = !record || CCNMBootRelationForRecord(record) != CCNMBootRelationEarlier;
    }
    BOOL requiresReboot = [recovery isEqual:CCNMRecoveryStateRebootRequired] || currentBootInFlight;
    BOOL normalEnabled = [recovery isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedN78Only] && baselinePresent && !transitionPresent;
    BOOL normalDefault = [recovery isEqual:CCNMRecoveryStateClean] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedSystemDefault] && !baselinePresent && !transitionPresent;
    NSDictionary *typedState = @{
        CCNMN78PolicySummaryRequestedModeKey: base[@"requestedMode"] ?: CCNMRequestedModeSystemDefault,
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO
    };
    NSMutableDictionary *summary = [@{
        CCNMN78PolicySummarySuccessKey: @(success),
        CCNMN78PolicySummaryOperationKey: operation ?: @"read",
        CCNMN78PolicySummaryStateKey: typedState,
        CCNMN78PolicySummaryRequestedModeKey: typedState[CCNMN78PolicySummaryRequestedModeKey],
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        CCNMN78PolicySummaryErrorCodeKey: errorCode ?: base[@"errorCode"] ?: CCNMN78PolicyErrorNone,
        CCNMN78PolicySummaryErrorKey: error ?: base[@"error"] ?: @"",
        CCNMN78PolicySummaryRequiresRebootKey: @(requiresReboot),
        CCNMN78PolicySummaryMayWriteKey: @((normalDefault || normalEnabled) && !requiresReboot && !removalGuardPresent),
        CCNMN78PolicySummaryMayUninstallKey: @(normalDefault && (!removalGuardPresent || removalGuardValid)),
        @"baselinePresent": @(baselinePresent),
        @"baselineValid": @(baselineValid),
        @"transitionPresent": @(transitionPresent),
        @"removalGuardPresent": @(removalGuardPresent),
        @"removalGuardValid": @(removalGuardValid),
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO,
        @"statePath": CCNMN78PolicyStatePath(),
        @"baselinePath": CCNMN78PolicyBaselinePath(),
        @"intentPath": CCNMN78PolicyIntentPath(),
        @"inFlightPath": CCNMN78PolicyInFlightPath(),
        @"lockPath": CCNMN78PolicyLockPath(),
        @"removalGuardPath": CCNMN78PolicyRemovalGuardPath(),
        @"verifiedKnownOrphanRestore": @(CCNMStateHasVerifiedKnownOrphanRestore(base))
    } mutableCopy];
    if (details) {
        [summary addEntriesFromDictionary:details];
    }
    return [summary copy];
}

static NSDictionary *CCNMReadPolicyStateInternal(void) {
    BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO, removalGuardExists = NO;
    NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
    NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
    NSDictionary *intent = CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
    NSDictionary *inFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
    NSDictionary *removalGuard = CCNMLoadRecord(CCNMN78PolicyRemovalGuardPath(), &removalGuardExists);

    if (!stateExists && !baselineExists && !intentExists && !inFlightExists &&
        (!removalGuardExists || CCNMValidateRemovalGuardRecord(removalGuard, NULL))) {
        return CCNMSummaryFromState(CCNMDefaultState(), YES, @"read", CCNMN78PolicyErrorNone, @"", nil);
    }
    if ((stateExists && !CCNMValidateStateRecord(state, NULL)) ||
        (baselineExists && !CCNMValidateBaselineRecord(baseline, NULL)) ||
        (intentExists && (!baseline || !CCNMValidateIntentRecord(intent, baseline, NULL))) ||
        (inFlightExists && (!baseline || !CCNMValidateInFlightRecord(inFlight, baseline, intent, intentExists, NULL))) ||
        (removalGuardExists && !CCNMValidateRemovalGuardRecord(removalGuard, NULL))) {
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state, CCNMRecoveryStateRebootRequired,
            @"A durable policy record is malformed, foreign, or inconsistent.");
        return CCNMSummaryFromState(synthetic, NO, @"read", CCNMN78PolicyErrorInvalidRecords,
            synthetic[@"error"], nil);
    }
    if (!stateExists) {
        BOOL evidenceMayBeCurrent = (inFlightExists && CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists && CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (baselineExists && CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = evidenceMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(nil, recovery,
            @"Policy evidence exists without its state record.");
        return CCNMSummaryFromState(synthetic, NO, @"read", CCNMN78PolicyErrorInvalidRecords,
            synthetic[@"error"], nil);
    }
    if (intentExists || inFlightExists) {
        if ([state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyDiverged] &&
            [state[@"recoveryState"] isEqual:CCNMRecoveryStateRecoveryFailed]) {
            return CCNMSummaryFromState(state, NO, @"read", CCNMN78PolicyErrorReadBackMismatch,
                state[@"error"], nil);
        }
        BOOL transitionMayBeCurrent = (inFlightExists && CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists && CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (![state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
             CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = transitionMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state, recovery,
            @"A policy transition is incomplete and must be recovered before another write.");
        return CCNMSummaryFromState(synthetic, NO, @"read", CCNMN78PolicyErrorRecoveryRequired,
            synthetic[@"error"], nil);
    }

    BOOL enabled = [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] && baselineExists && !removalGuardExists &&
        [CCNMCanonicalUUIDString(state[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [state[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]];
    BOOL systemDefault = [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] && !baselineExists && ![state[@"uncertain"] boolValue];
    if (!enabled && !systemDefault) {
        BOOL evidenceMayBeCurrent = CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier ||
            (baselineExists && CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state,
            evidenceMayBeCurrent ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed,
            @"Policy state and retained baseline do not form a verified stable state.");
        return CCNMSummaryFromState(synthetic, NO, @"read", CCNMN78PolicyErrorRecoveryRequired,
            synthetic[@"error"], nil);
    }
    return CCNMSummaryFromState(state, YES, @"read", state[@"errorCode"], state[@"error"], nil);
}

static NSDictionary *CCNMErrorSummary(NSString *operation,
                                       CCNMN78PolicyErrorCode errorCode,
                                       NSString *error,
                                       NSDictionary *details) {
    NSDictionary *current = CCNMReadPolicyStateInternal();
    NSMutableDictionary *summary = [current mutableCopy];
    summary[CCNMN78PolicySummarySuccessKey] = @NO;
    summary[CCNMN78PolicySummaryOperationKey] = operation ?: @"unknown";
    summary[CCNMN78PolicySummaryErrorCodeKey] = errorCode ?: CCNMN78PolicyErrorRecoveryRequired;
    summary[CCNMN78PolicySummaryErrorKey] = error ?: @"The policy operation failed.";
    if (details) {
        [summary addEntriesFromDictionary:details];
    }
    return [summary copy];
}

static BOOL CCNMPersistState(NSDictionary *state, NSString **failure) {
    return CCNMReplaceDurableRecord(state, CCNMN78PolicyStatePath(), failure);
}

static NSDictionary *CCNMMarkRecovery(CCNMRequestedMode requested,
                                       CCNMAppliedPolicy applied,
                                       CCNMRecoveryState recovery,
                                       NSUInteger generation,
                                       NSString *subscriptionUUID,
                                       CCNMN78PolicyErrorCode errorCode,
                                       NSString *error,
                                       NSDictionary *baseline,
                                       BOOL uncertain) {
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    if (baseline) {
        extra[@"baselineCreatedAt"] = baseline[@"createdAt"];
    }
    NSString *buildFailure = nil;
    NSDictionary *state = CCNMBuildStateRecord(requested, applied, recovery, generation,
        subscriptionUUID, uncertain, errorCode, error, extra, &buildFailure);
    NSString *persistFailure = nil;
    if (state && CCNMPersistState(state, &persistFailure)) {
        return state;
    }
    return CCNMSyntheticRecoveryState(state, recovery,
        persistFailure ?: buildFailure ?: error ?: @"Recovery state could not be persisted.");
}

static int CCNMAcquirePolicyLock(NSString **failure) {
    int descriptor = open(CCNMN78PolicyLockPath().fileSystemRepresentation,
        O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not open the policy lock: %s", strerror(errno)];
        }
        return -1;
    }
    if (!CCNMNormalizePolicyDescriptorOwnership(descriptor, failure)) {
        close(descriptor);
        return -1;
    }
    while (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EINTR) {
            continue;
        }
        if (failure) {
            *failure = (errno == EWOULDBLOCK || errno == EAGAIN)
                ? @"Another process owns the n78 policy lock."
                : [NSString stringWithFormat:@"Could not acquire the policy lock: %s", strerror(errno)];
        }
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static void CCNMReleasePolicyLock(int descriptor) {
    if (descriptor < 0) {
        return;
    }
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

static BOOL CCNMValidateTarget(NSMutableDictionary *details, NSString **failure) {
    NSString *model = CCNMSysctlString("hw.machine");
    NSString *build = CCNMSysctlString("kern.osversion");
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (details) {
        details[@"deviceModel"] = model ?: @"";
        details[@"systemBuild"] = build ?: @"";
        details[@"systemVersion"] = [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
    }
    BOOL valid = [model isEqualToString:@"iPhone14,3"] && [build isEqualToString:@"19B81"] &&
        version.majorVersion == 15 && version.minorVersion == 1 && version.patchVersion == 1;
    if (!valid && failure) {
        *failure = @"The formal policy is restricted to iPhone14,3 running iOS 15.1.1 build 19B81.";
    }
    return valid;
}

static const char *CCNMSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL CCNMValidateObjectErrorABI(id object,
                                       SEL selector,
                                       NSUInteger objectArgumentCount,
                                       NSString **failure) {
    if (!object || ![object respondsToSelector:selector]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ is unavailable.", NSStringFromSelector(selector)];
        }
        return NO;
    }
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    NSUInteger errorIndex = 2 + objectArgumentCount;
    const char *returnType = signature ? CCNMSkipTypeQualifiers(signature.methodReturnType) : NULL;
    const char *errorType = signature && signature.numberOfArguments > errorIndex
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:errorIndex]) : NULL;
    BOOL valid = signature && signature.numberOfArguments == errorIndex + 1 &&
        returnType && returnType[0] == '@' && errorType && errorType[0] == '^' && errorType[1] == '@';
    for (NSUInteger index = 0; valid && index < objectArgumentCount; index++) {
        const char *type = CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:2 + index]);
        valid = type && type[0] == '@';
    }
    if (!valid && failure) {
        *failure = [NSString stringWithFormat:@"%@ has an unexpected private ABI.", NSStringFromSelector(selector)];
    }
    return valid;
}

static BOOL CCNMValidateSetterABI(id<CCNMCoreTelephonyClient> client, NSString **failure) {
    SEL selector = @selector(setActiveBandInfo:bands:error:);
    if (![client respondsToSelector:selector]) {
        if (failure) {
            *failure = @"The active-band setter is unavailable.";
        }
        return NO;
    }
    NSMethodSignature *signature = [(id)client methodSignatureForSelector:selector];
    const char *returnType = signature ? CCNMSkipTypeQualifiers(signature.methodReturnType) : NULL;
    const char *contextType = signature && signature.numberOfArguments > 2
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    const char *bandsType = signature && signature.numberOfArguments > 3
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:3]) : NULL;
    const char *errorType = signature && signature.numberOfArguments > 4
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:4]) : NULL;
    BOOL valid = signature && signature.numberOfArguments == 5 &&
        returnType && strcmp(returnType, @encode(void)) == 0 &&
        contextType && contextType[0] == '@' && bandsType && bandsType[0] == '@' &&
        errorType && errorType[0] == '^' && errorType[1] == '@';
    if (!valid && failure) {
        *failure = @"The active-band setter private ABI is not void(context, BandInfo, NSError **).";
    }
    return valid;
}

static id<CCNMCoreTelephonyClient> CCNMCreateClient(NSString **failure) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
    });
    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (!handle || !clientClass) {
        if (failure) {
            *failure = @"CoreTelephonyClient is unavailable.";
        }
        return nil;
    }
    id<CCNMCoreTelephonyClient> client = [(id)clientClass alloc];
    if (![client respondsToSelector:@selector(initWithQueue:)]) {
        if (failure) {
            *failure = @"CoreTelephonyClient does not expose initWithQueue:.";
        }
        return nil;
    }
    @try {
        client = [client initWithQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"CoreTelephonyClient initialization raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    if (!CCNMValidateObjectErrorABI(client, @selector(getSubscriptionInfoWithError:), 0, failure) ||
        !CCNMValidateObjectErrorABI(client, @selector(getBandInfo:error:), 1, failure) ||
        !CCNMValidateSetterABI(client, failure)) {
        return nil;
    }
    return client;
}

static id<CCNMSubscriptionContext> CCNMSafeTargetContext(id<CCNMCoreTelephonyClient> client,
                                                          NSString *requiredUUID,
                                                          NSMutableDictionary *details,
                                                          NSString **failure) {
    NSError *queryError = nil;
    id<CCNMSubscriptionInfo> info = nil;
    @try {
        info = [client getSubscriptionInfoWithError:&queryError];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Subscription query raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    NSArray *subscriptions = [info respondsToSelector:@selector(subscriptions)] ? [info subscriptions] : nil;
    if (queryError || ![subscriptions isKindOfClass:[NSArray class]] || subscriptions.count == 0) {
        if (failure) {
            *failure = queryError.localizedDescription ?: @"No subscription contexts were returned.";
        }
        return nil;
    }

    NSMutableArray *reports = [NSMutableArray array];
    id<CCNMSubscriptionContext> target = nil;
    NSUInteger presentCount = 0;
    NSUInteger targetCount = 0;
    for (id<CCNMSubscriptionContext> context in subscriptions) {
        if (![context respondsToSelector:@selector(slotID)] ||
            ![context respondsToSelector:@selector(isSimPresent)] ||
            ![context respondsToSelector:@selector(isSimGood)] ||
            ![context respondsToSelector:@selector(uuid)]) {
            if (failure) {
                *failure = @"A subscription context lacks required identity or SIM selectors.";
            }
            return nil;
        }
        long long slot = [context slotID];
        BOOL present = [context isSimPresent];
        BOOL good = [context isSimGood];
        id rawUUID = [context uuid];
        NSString *uuid = [rawUUID isKindOfClass:[NSUUID class]] ? [(NSUUID *)rawUUID UUIDString] : nil;
        [reports addObject:@{
            @"slotID": @(slot),
            @"isSimPresent": @(present),
            @"isSimGood": @(good),
            @"subscriptionUUID": uuid ?: @""
        }];
        if (present) {
            presentCount++;
        }
        if (slot == 1 && present && good && uuid.length > 0) {
            target = context;
            targetCount++;
        }
    }
    if (details) {
        details[@"subscriptions"] = reports;
    }
    if (presentCount != 1 || targetCount != 1 || !target) {
        if (failure) {
            *failure = @"Exactly one present/good SIM with a stable UUID in slot 1 is required.";
        }
        return nil;
    }
    NSString *uuid = [[target uuid] UUIDString];
    NSString *required = requiredUUID.length ? CCNMCanonicalUUIDString(requiredUUID) : nil;
    if (!uuid || (requiredUUID.length && (!required || ![uuid isEqualToString:required]))) {
        if (failure) {
            *failure = @"The slot-1 subscription UUID changed.";
        }
        return nil;
    }
    if (details) {
        details[@"targetSubscriptionUUID"] = uuid;
    }
    return target;
}

static NSDictionary *CCNMReadFreshBandInfo(id<CCNMCoreTelephonyClient> client,
                                            id<CCNMSubscriptionContext> context,
                                            NSString **failure) {
    NSError *error = nil;
    id<CCNMBandInfo> info = nil;
    @try {
        info = [client getBandInfo:context error:&error];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"BandInfo read raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    if (error || !info) {
        if (failure) {
            *failure = error.localizedDescription ?: @"BandInfo read returned no object.";
        }
        return nil;
    }
    NSDictionary *active = [info respondsToSelector:@selector(activeBands)] ? [info activeBands] : nil;
    NSDictionary *supported = [info respondsToSelector:@selector(supportedBands)] ? [info supportedBands] : nil;
    NSDictionary *activeCopy = CCNMDeepCopyDictionary(active, failure);
    NSDictionary *supportedCopy = activeCopy ? CCNMDeepCopyDictionary(supported, failure) : nil;
    if (!activeCopy || !supportedCopy ||
        !CCNMValidateBandDictionary(activeCopy, failure) || !CCNMValidateBandDictionary(supportedCopy, failure)) {
        return nil;
    }
    return @{ @"activeBands": activeCopy, @"supportedBands": supportedCopy };
}

static BOOL CCNMKnownOrphanStateIsExactClean(NSDictionary *state, BOOL stateExists) {
    if (!stateExists) {
        return YES;
    }
    return CCNMValidateStateRecord(state, NULL) &&
        [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] &&
        ![state[@"uncertain"] boolValue] && state[@"recoverySource"] == nil &&
        state[@"evidenceSHA256"] == nil;
}

static BOOL CCNMValidateKnownOrphanedN78HistoricalPredicate(
    id<CCNMCoreTelephonyClient> client,
    NSMutableDictionary *details,
    id<CCNMSubscriptionContext> *targetContext,
    NSDictionary **freshBandInfo,
    BOOL *observedValidBandInfo,
    NSString **failure) {
    if (observedValidBandInfo) {
        *observedValidBandInfo = NO;
    }
    if (!CCNMValidateTarget(details, failure)) {
        return NO;
    }
    id<CCNMSubscriptionContext> context = CCNMSafeTargetContext(
        client, CCNMKnownOrphanSubscriptionUUID, details, failure);
    if (!context) {
        return NO;
    }
    NSDictionary *fresh = CCNMReadFreshBandInfo(client, context, failure);
    if (!fresh) {
        return NO;
    }
    if (observedValidBandInfo) {
        *observedValidBandInfo = YES;
    }
    if (!CCNMKnownOrphanBandInfoMatches(
        fresh, CCNMKnownOrphanHistoricalActiveBands())) {
        if (failure) {
            *failure = @"Live active or supported BandInfo does not exactly match the reviewed orphaned-n78 evidence.";
        }
        return NO;
    }
    if (targetContext) {
        *targetContext = context;
    }
    if (freshBandInfo) {
        *freshBandInfo = fresh;
    }
    if (details) {
        details[@"historicalPredicateMatched"] = @YES;
        details[@"recoverySource"] = CCNMKnownOrphanRecoverySource;
        details[@"evidenceSHA256"] = CCNMKnownOrphanEvidenceSHA256;
    }
    return YES;
}

static NSDictionary *CCNMKnownOrphanEligibilityResult(BOOL eligible,
                                                        BOOL conclusive,
                                                        CCNMN78PolicyErrorCode errorCode,
                                                        NSString *error,
                                                        NSDictionary *details) {
    NSMutableDictionary *result = [@{
        CCNMN78PolicySummarySuccessKey: @(conclusive),
        CCNMN78PolicySummaryOperationKey: @"knownOrphanEligibility",
        @"eligible": @(eligible),
        @"conclusive": @(conclusive),
        @"recoverySource": CCNMKnownOrphanRecoverySource,
        @"evidenceSHA256": CCNMKnownOrphanEvidenceSHA256,
        CCNMN78PolicySummaryErrorCodeKey: errorCode ?: CCNMN78PolicyErrorNone,
        CCNMN78PolicySummaryErrorKey: error ?: @""
    } mutableCopy];
    if (details) {
        [result addEntriesFromDictionary:details];
    }
    return [result copy];
}

static NSDictionary *CCNMEvaluateKnownOrphanEligibilityWithHeldLock(BOOL allowValidRemovalGuard) {
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    NSString *failure = nil;
    @synchronized([CCNMN78PolicyController class]) {
        if (CCNMSetterUncertainLatch || CCNMSetterCallActive) {
            return CCNMKnownOrphanEligibilityResult(NO, NO,
                CCNMN78PolicyErrorSetterUncertain,
                @"A setter is active or uncertain in this process.", details);
        }
    }

    BOOL stateExists = NO, baselineExists = NO, intentExists = NO;
    BOOL inFlightExists = NO, removalGuardExists = NO;
    NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
    CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
    CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
    CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
    NSDictionary *removalGuard = CCNMLoadRecord(
        CCNMN78PolicyRemovalGuardPath(), &removalGuardExists);
    BOOL removalGuardAllowed = removalGuardExists && allowValidRemovalGuard &&
        CCNMValidateRemovalGuardRecord(removalGuard, &failure);
    if (baselineExists || intentExists || inFlightExists ||
        (removalGuardExists && !removalGuardAllowed) ||
        !CCNMKnownOrphanStateIsExactClean(state, stateExists)) {
        return CCNMKnownOrphanEligibilityResult(NO, YES,
            removalGuardExists && !removalGuardAllowed
                ? CCNMN78PolicyErrorInvalidRecords : CCNMN78PolicyErrorRecoveryRequired,
            failure ?: @"Known-orphan recovery requires an absent or exact clean state and no conflicting records.",
            details);
    }
    if (!CCNMValidateTarget(details, &failure)) {
        return CCNMKnownOrphanEligibilityResult(NO, YES,
            CCNMN78PolicyErrorUnsupportedTarget, failure, details);
    }
    id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
    if (!client) {
        return CCNMKnownOrphanEligibilityResult(NO, NO,
            CCNMN78PolicyErrorInvalidBandInfo, failure, details);
    }
    BOOL observedValidBandInfo = NO;
    BOOL matched = CCNMValidateKnownOrphanedN78HistoricalPredicate(
        client, details, NULL, NULL, &observedValidBandInfo, &failure);
    return CCNMKnownOrphanEligibilityResult(matched,
        matched || observedValidBandInfo,
        matched ? CCNMN78PolicyErrorNone : CCNMN78PolicyErrorInvalidBandInfo,
        matched ? @"" : failure, details);
}

static id<CCNMBandInfo> CCNMCreateBandPayload(NSDictionary *payload, NSString **failure) {
    Class bandInfoClass = NSClassFromString(@"CTBandInfo");
    if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
        if (failure) {
            *failure = @"CTBandInfo initWithActiveBands: is unavailable.";
        }
        return nil;
    }
    id<CCNMBandInfo> info = nil;
    @try {
        info = [[(id)bandInfoClass alloc] initWithActiveBands:[payload mutableCopy]];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    NSDictionary *actual = [info respondsToSelector:@selector(activeBands)] ? [info activeBands] : nil;
    if (!CCNMDictionariesEqual(payload, actual)) {
        if (failure) {
            *failure = @"CTBandInfo changed the exact payload before the write.";
        }
        return nil;
    }
    return info;
}

static NSUInteger CCNMNextGeneration(NSDictionary *state, NSDictionary *intent) {
    NSUInteger generation = [state[@"operationGeneration"] unsignedIntegerValue];
    generation = MAX(generation, [intent[@"operationGeneration"] unsignedIntegerValue]);
    return generation == NSUIntegerMax ? 0 : generation + 1;
}

static BOOL CCNMRecordMatches(NSDictionary *expected, NSString *path) {
    if (!expected) {
        return !CCNMFileExists(path);
    }
    NSDictionary *live = [NSDictionary dictionaryWithContentsOfFile:path];
    return [live isEqualToDictionary:expected];
}

static BOOL CCNMRecordsRemainExact(NSDictionary *state,
                                   NSDictionary *baseline,
                                   NSDictionary *intent,
                                   NSDictionary *inFlight,
                                   NSString **failure) {
    BOOL exact = CCNMRecordMatches(state, CCNMN78PolicyStatePath()) &&
        CCNMRecordMatches(baseline, CCNMN78PolicyBaselinePath()) &&
        CCNMRecordMatches(intent, CCNMN78PolicyIntentPath()) &&
        CCNMRecordMatches(inFlight, CCNMN78PolicyInFlightPath());
    if (!exact && failure) {
        *failure = @"Durable policy evidence changed immediately before the setter call.";
    }
    return exact;
}

static BOOL CCNMBeginSetter(NSUInteger generation) {
    NSTimeInterval started = CCNMMonotonicNow();
    @synchronized([CCNMN78PolicyController class]) {
        if (generation == 0 || started <= 0 || CCNMSetterUncertainLatch || CCNMSetterCallActive) {
            return NO;
        }
        CCNMSetterCallActive = YES;
        CCNMSetterGeneration = generation;
        CCNMSetterStartedMonotonic = started;
        return YES;
    }
}

static BOOL CCNMRetainPolicyLockForTimedOutSetter(NSUInteger generation,
                                                    int *policyLockDescriptor) {
    @synchronized([CCNMN78PolicyController class]) {
        CCNMSetterUncertainLatch = YES;
        if (!policyLockDescriptor || *policyLockDescriptor < 0) {
            return NO;
        }
        if (!CCNMSetterCallActive || CCNMSetterGeneration != generation) {
            return NO;
        }
        if (CCNMSetterRetainedPolicyLockDescriptor >= 0) {
            return NO;
        }
        CCNMSetterRetainedPolicyLockDescriptor = *policyLockDescriptor;
        CCNMSetterRetainedPolicyLockGeneration = generation;
        *policyLockDescriptor = -1;
        return YES;
    }
}

static void CCNMReleasePolicyLockAfterLateSetter(NSUInteger generation) {
    int descriptor = -1;
    @synchronized([CCNMN78PolicyController class]) {
        if (CCNMSetterRetainedPolicyLockDescriptor >= 0 &&
            CCNMSetterRetainedPolicyLockGeneration == generation) {
            descriptor = CCNMSetterRetainedPolicyLockDescriptor;
            CCNMSetterRetainedPolicyLockDescriptor = -1;
            CCNMSetterRetainedPolicyLockGeneration = 0;
        }
    }
    CCNMReleasePolicyLock(descriptor);
}

static CCNMSetterOutcome CCNMFinishSetter(NSUInteger generation,
                                           BOOL returnedNormally,
                                           NSTimeInterval finished,
                                           BOOL *overDeadline) {
    @synchronized([CCNMN78PolicyController class]) {
        BOOL matching = CCNMSetterCallActive && CCNMSetterGeneration == generation;
        NSTimeInterval elapsed = matching && CCNMSetterStartedMonotonic > 0 && finished >= CCNMSetterStartedMonotonic
            ? finished - CCNMSetterStartedMonotonic : 0;
        BOOL late = matching && (finished <= 0 || finished < CCNMSetterStartedMonotonic || elapsed >= CCNMSetterDeadlineSeconds);
        if (overDeadline) {
            *overDeadline = late;
        }
        if (!matching || !returnedNormally || late) {
            CCNMSetterUncertainLatch = YES;
        }
        BOOL uncertain = CCNMSetterUncertainLatch;
        CCNMSetterCallActive = NO;
        CCNMSetterGeneration = 0;
        CCNMSetterStartedMonotonic = 0;
        return uncertain ? CCNMSetterOutcomeUncertain : CCNMSetterOutcomeReturned;
    }
}

static CCNMSetterOutcome CCNMCallSetter(id<CCNMCoreTelephonyClient> client,
                                        id<CCNMSubscriptionContext> context,
                                        id<CCNMBandInfo> payload,
                                        NSUInteger generation,
                                        int *policyLockDescriptor,
                                        NSMutableDictionary *details,
                                        NSString **failure) {
    if (!CCNMBeginSetter(generation)) {
        if (failure) {
            *failure = @"The in-process setter latch refused a new write.";
        }
        return CCNMSetterOutcomeUncertain;
    }
    details[@"setterAttempted"] = @YES;
    details[@"setterDeadlineSeconds"] = @(CCNMSetterDeadlineSeconds);
    details[@"setterStartedAt"] = @(CCNMUnixMilliseconds());

    dispatch_queue_t setterQueue = dispatch_queue_create(
        "me.nixuge.networkmanager.n78-policy.setter", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t setterFinished = dispatch_semaphore_create(0);
    __block NSError *setterError = nil;
    __block NSException *caught = nil;
    __block BOOL returnedNormally = NO;
    __block BOOL overDeadline = NO;
    __block CCNMSetterOutcome outcome = CCNMSetterOutcomeUncertain;
    __block long long completedAt = 0;

    dispatch_async(setterQueue, ^{
        @autoreleasepool {
            @try {
                [client setActiveBandInfo:context bands:payload error:&setterError];
                returnedNormally = YES;
            } @catch (NSException *exception) {
                caught = exception;
            }
            completedAt = CCNMUnixMilliseconds();
            outcome = CCNMFinishSetter(generation, returnedNormally,
                CCNMMonotonicNow(), &overDeadline);
            CCNMReleasePolicyLockAfterLateSetter(generation);
            dispatch_semaphore_signal(setterFinished);
        }
    });

    long waitResult = dispatch_semaphore_wait(setterFinished,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCNMSetterDeadlineSeconds * NSEC_PER_SEC)));
    if (waitResult != 0) {
        BOOL lockTransferred = CCNMRetainPolicyLockForTimedOutSetter(generation, policyLockDescriptor);
        details[@"setterTimedOut"] = @YES;
        details[@"setterTimedOutAt"] = @(CCNMUnixMilliseconds());
        details[@"setterLockRetained"] = @(lockTransferred);
        if (failure) {
            *failure = @"The active-band setter exceeded its deadline; its server-side outcome is uncertain.";
        }
        return CCNMSetterOutcomeUncertain;
    }

    details[@"setterCompletedAt"] = @(completedAt);
    details[@"setterTimedOut"] = @NO;
    details[@"setterOverDeadline"] = @(overDeadline);
    details[@"setterError"] = setterError.localizedDescription ?: @"";
    if (caught) {
        details[@"setterException"] = [NSString stringWithFormat:@"%@: %@", caught.name, caught.reason ?: @"(no reason)"];
    }
    if (outcome == CCNMSetterOutcomeUncertain) {
        if (failure) {
            *failure = caught
                ? @"The active-band setter raised an exception; its server-side outcome is uncertain."
                : @"The active-band setter returned outside its deadline; its outcome is uncertain.";
        }
        return outcome;
    }
    if (setterError) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"The active-band setter failed: %@", setterError.localizedDescription];
        }
        return CCNMSetterOutcomeFailed;
    }
    return CCNMSetterOutcomeReturned;
}

static NSDictionary *CCNMWaitForReadBack(id<CCNMCoreTelephonyClient> client,
                                          NSString *subscriptionUUID,
                                          NSDictionary *expected) {
    NSMutableDictionary *result = [@{
        @"matched": @NO,
        @"sawValid": @NO,
        @"sawInvalid": @NO,
        @"identityUncertain": @NO,
        @"deadlineExceeded": @NO,
        @"attempts": @0,
        @"error": @""
    } mutableCopy];
    NSTimeInterval started = CCNMMonotonicNow();
    for (NSUInteger attempt = 1; attempt <= CCNMReadBackMaximumAttempts; attempt++) {
        NSTimeInterval beforeAttempt = CCNMMonotonicNow();
        if (attempt > 1 && started > 0 && beforeAttempt > 0 &&
            beforeAttempt - started >= CCNMReadBackDeadlineSeconds) {
            result[@"deadlineExceeded"] = @YES;
            result[@"error"] = @"The complete BandInfo read-back deadline expired.";
            break;
        }
        result[@"attempts"] = @(attempt);
        NSString *identityFailure = nil;
        id<CCNMSubscriptionContext> context = CCNMSafeTargetContext(client, subscriptionUUID, nil, &identityFailure);
        if (!context) {
            result[@"identityUncertain"] = @YES;
            result[@"error"] = identityFailure ?: @"The target subscription could not be revalidated.";
            break;
        }
        NSString *readFailure = nil;
        NSDictionary *fresh = CCNMReadFreshBandInfo(client, context, &readFailure);
        if (fresh) {
            NSDictionary *active = fresh[@"activeBands"];
            result[@"sawValid"] = @YES;
            result[@"lastActiveBands"] = active;
            result[@"error"] = @"";
            NSTimeInterval afterRead = CCNMMonotonicNow();
            BOOL deadlineExceeded = started > 0 && afterRead > 0 &&
                afterRead - started >= CCNMReadBackDeadlineSeconds;
            if (deadlineExceeded) {
                result[@"deadlineExceeded"] = @YES;
                result[@"error"] = @"The complete BandInfo read-back returned after its deadline.";
                break;
            }
            if (CCNMDictionariesEqual(active, expected)) {
                result[@"matched"] = @YES;
                result[@"matchedAt"] = @(CCNMUnixMilliseconds());
                break;
            }
        } else {
            result[@"sawInvalid"] = @YES;
            result[@"error"] = readFailure ?: @"No valid complete BandInfo read-back was returned.";
        }
        if (attempt < CCNMReadBackMaximumAttempts) {
            usleep(CCNMReadBackPollMicroseconds);
        }
    }
    NSTimeInterval finished = CCNMMonotonicNow();
    result[@"elapsedMilliseconds"] = @((long long)((started > 0 && finished >= started ? finished - started : 0) * 1000.0));
    return [result copy];
}

static BOOL CCNMRetireTransitionRecords(NSDictionary *intent,
                                         NSDictionary *inFlight,
                                         NSString **failure) {
    if (!CCNMRemoveExpectedRecord(inFlight, CCNMN78PolicyInFlightPath(), failure)) {
        return NO;
    }
    return CCNMRemoveExpectedRecord(intent, CCNMN78PolicyIntentPath(), failure);
}

static BOOL CCNMFinishEnabledState(NSUInteger generation,
                                   NSString *subscriptionUUID,
                                   NSDictionary *expectedState,
                                   NSDictionary *baseline,
                                   NSDictionary *intent,
                                   NSDictionary *inFlight,
                                   NSDictionary *verifiedBands,
                                   NSString **failure) {
    NSNumber *verifiedAt = @(CCNMUnixMilliseconds());
    NSDictionary *proof = @{
        @"baselineCreatedAt": baseline[@"createdAt"],
        @"readBackVerified": @YES,
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands,
        @"targetNRBands": @[ @78 ],
        @"nonNRUnchanged": @YES
    };
    NSDictionary *checkpoint = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
        CCNMAppliedPolicyApplying, CCNMRecoveryStateEnablePending,
        generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"", proof, failure);
    if (!checkpoint || !CCNMReplaceExpectedRecord(expectedState, checkpoint,
        CCNMN78PolicyStatePath(), failure)) {
        return NO;
    }
    if (!CCNMRetireTransitionRecords(intent, inFlight, failure)) {
        return NO;
    }
    NSDictionary *state = CCNMBuildStateRecord(CCNMRequestedModeN78Preferred,
        CCNMAppliedPolicyVerifiedN78Only, CCNMRecoveryStateEnabledWithBaseline,
        generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"", proof, failure);
    return state && CCNMReplaceExpectedRecord(checkpoint, state, CCNMN78PolicyStatePath(), failure);
}

static NSDictionary *CCNMProvenanceForBaseline(NSDictionary *baseline) {
    if (CCNMKnownOrphanBaselineMatchesEvidence(baseline)) {
        return @{
            @"recoverySource": CCNMKnownOrphanRecoverySource,
            @"evidenceSHA256": CCNMKnownOrphanEvidenceSHA256
        };
    }
    return @{};
}

static BOOL CCNMFinishSystemDefaultState(NSUInteger generation,
                                         NSString *subscriptionUUID,
                                         NSDictionary *expectedState,
                                         NSDictionary *baseline,
                                         NSDictionary *intent,
                                         NSDictionary *inFlight,
                                         NSDictionary *verifiedBands,
                                         NSString **failure) {
    NSNumber *verifiedAt = @(CCNMUnixMilliseconds());
    NSMutableDictionary *proof = [@{
        @"baselineCreatedAt": baseline[@"createdAt"],
        @"readBackVerified": @YES,
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands
    } mutableCopy];
    [proof addEntriesFromDictionary:CCNMProvenanceForBaseline(baseline)];
    CCNMRequestedMode requested = expectedState[@"requestedMode"] ?: CCNMRequestedModeN78Preferred;
    NSDictionary *checkpoint = CCNMBuildStateRecord(requested,
        CCNMAppliedPolicyApplying, CCNMRecoveryStateRestorePending,
        generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"", proof, failure);
    BOOL checkpointSaved = checkpoint && (expectedState
        ? CCNMReplaceExpectedRecord(expectedState, checkpoint, CCNMN78PolicyStatePath(), failure)
        : CCNMCreateDurableRecord(checkpoint, CCNMN78PolicyStatePath(), failure));
    if (!checkpointSaved) {
        return NO;
    }
    if (inFlight && !CCNMRemoveExpectedRecord(inFlight, CCNMN78PolicyInFlightPath(), failure)) {
        return NO;
    }
    if (intent && !CCNMRemoveExpectedRecord(intent, CCNMN78PolicyIntentPath(), failure)) {
        return NO;
    }
    if (!CCNMRemoveExpectedRecord(baseline, CCNMN78PolicyBaselinePath(), failure)) {
        return NO;
    }
    NSMutableDictionary *finalProof = [@{
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands,
        @"restoredBaselineCreatedAt": baseline[@"createdAt"]
    } mutableCopy];
    [finalProof addEntriesFromDictionary:CCNMProvenanceForBaseline(baseline)];
    NSDictionary *state = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
        CCNMAppliedPolicyVerifiedSystemDefault, CCNMRecoveryStateClean,
        generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"",
        finalProof, failure);
    return state && CCNMReplaceExpectedRecord(checkpoint, state, CCNMN78PolicyStatePath(), failure);
}

static BOOL CCNMPersistOrReplaceTransition(NSDictionary *oldRecord,
                                           NSDictionary *newRecord,
                                           NSString *path,
                                           NSString **failure) {
    return oldRecord
        ? CCNMReplaceExpectedRecord(oldRecord, newRecord, path, failure)
        : CCNMCreateDurableRecord(newRecord, path, failure);
}

static BOOL CCNMIsVerifiedRestoreCleanupCheckpoint(NSDictionary *state) {
    NSDictionary *verifiedBands = [state[@"verifiedActiveBands"] isKindOfClass:NSDictionary.class]
        ? state[@"verifiedActiveBands"] : nil;
    return CCNMValidateStateRecord(state, NULL) &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyApplying] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateRestorePending] &&
        [state[@"readBackVerified"] isEqual:@YES] &&
        [state[@"verifiedAt"] isKindOfClass:NSNumber.class] && [state[@"verifiedAt"] longLongValue] > 0 &&
        [state[@"baselineCreatedAt"] isKindOfClass:NSNumber.class] && [state[@"baselineCreatedAt"] longLongValue] > 0 &&
        ![state[@"uncertain"] boolValue] &&
        CCNMValidateBandDictionary(verifiedBands, NULL);
}

@interface CCNMN78PolicyController ()
@property (nonatomic, strong) dispatch_queue_t operationQueue;
@end

@implementation CCNMN78PolicyController

+ (instancetype)sharedController {
    static CCNMN78PolicyController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _operationQueue = dispatch_queue_create("me.nixuge.networkmanager.n78-policy", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSDictionary<NSString *,id> *)readState {
    return CCNMReadPolicyStateInternal();
}

- (void)deliverCompletion:(CCNMN78PolicyCompletion)completion result:(NSDictionary *)result {
    CCNMPostPolicyDidChange();
    if (!completion) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(result);
    });
}

- (void)enableWithCompletion:(CCNMN78PolicyCompletion)completion {
    dispatch_async(self.operationQueue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = [self performEnable];
            } @catch (NSException *exception) {
                result = CCNMErrorSummary(@"enable", CCNMN78PolicyErrorRecoveryRequired,
                    [NSString stringWithFormat:@"Enable raised %@: %@", exception.name, exception.reason ?: @"(no reason)"], nil);
            }
            [self deliverCompletion:completion result:result];
        }
    });
}

- (void)disableWithCompletion:(CCNMN78PolicyCompletion)completion {
    dispatch_async(self.operationQueue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = [self performDisable];
            } @catch (NSException *exception) {
                result = CCNMErrorSummary(@"disable", CCNMN78PolicyErrorRecoveryRequired,
                    [NSString stringWithFormat:@"Disable raised %@: %@", exception.name, exception.reason ?: @"(no reason)"], nil);
            }
            [self deliverCompletion:completion result:result];
        }
    });
}

- (void)recoverWithCompletion:(CCNMN78PolicyCompletion)completion {
    dispatch_async(self.operationQueue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = [self performRecovery];
            } @catch (NSException *exception) {
                result = CCNMErrorSummary(@"recover", CCNMN78PolicyErrorRecoveryRequired,
                    [NSString stringWithFormat:@"Recovery raised %@: %@", exception.name, exception.reason ?: @"(no reason)"], nil);
            }
            [self deliverCompletion:completion result:result];
        }
    });
}

- (void)recoverKnownOrphanedN78WithCompletion:(CCNMN78PolicyCompletion)completion {
    dispatch_async(self.operationQueue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = [self performKnownOrphanedN78Recovery];
            } @catch (NSException *exception) {
                result = CCNMErrorSummary(@"knownOrphanRecovery", CCNMN78PolicyErrorRecoveryRequired,
                    [NSString stringWithFormat:@"Known-orphan recovery raised %@: %@",
                        exception.name, exception.reason ?: @"(no reason)"], nil);
            }
            [self deliverCompletion:completion result:result];
        }
    });
}

- (NSDictionary *)performEnable {
    NSMutableDictionary *details = [@{ @"setterAttempted": @NO } mutableCopy];
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorBusy, failure, details);
    }

    NSDictionary *baseline = nil;
    NSDictionary *intent = nil;
    NSDictionary *inFlight = nil;
    NSUInteger generation = 0;
    NSString *subscriptionUUID = nil;
    @try {
        @synchronized([CCNMN78PolicyController class]) {
            if (CCNMSetterUncertainLatch) {
                return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorSetterUncertain,
                    @"A setter outcome is uncertain in this process; reboot before recovery.", details);
            }
        }
        BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO, removalGuardExists = NO;
        NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
        CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
        CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
        CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
        NSDictionary *removalGuard = CCNMLoadRecord(CCNMN78PolicyRemovalGuardPath(), &removalGuardExists);
        if (removalGuardExists) {
            CCNMN78PolicyErrorCode code = CCNMValidateRemovalGuardRecord(removalGuard, &failure)
                ? CCNMN78PolicyErrorBusy : CCNMN78PolicyErrorInvalidRecords;
            failure = failure ?: @"Package removal or upgrade is in progress; enabling is blocked.";
            return CCNMErrorSummary(@"enable", code, failure, details);
        }
        if ((stateExists && !CCNMValidateStateRecord(state, &failure)) || baselineExists || intentExists || inFlightExists) {
            failure = failure ?: @"Existing policy or transition evidence must be recovered before enabling.";
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidRecords, failure, details);
        }
        if (stateExists && (![state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] ||
            ![state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] ||
            ![state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] || [state[@"uncertain"] boolValue])) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorRecoveryRequired,
                @"The current policy state is not a verified clean system-default state.", details);
        }
        state = state ?: CCNMDefaultState();
        generation = CCNMNextGeneration(state, nil);
        if (generation == 0 || !CCNMBootSessionIdentity()) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorRecoveryRequired,
                @"A valid boot identity and operation generation are required.", details);
        }
        if (!CCNMValidateTarget(details, &failure)) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorUnsupportedTarget, failure, details);
        }
        id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
        id<CCNMSubscriptionContext> context = client ? CCNMSafeTargetContext(client, nil, details, &failure) : nil;
        if (!context) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorUnsafeSubscription, failure, details);
        }
        subscriptionUUID = details[@"targetSubscriptionUUID"];
        NSDictionary *initial = CCNMReadFreshBandInfo(client, context, &failure);
        if (!initial) {
            // No baseline, intent, in-flight marker, or setter call exists yet.
            // A read-only preflight failure must leave the durable clean state unchanged.
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }
        NSDictionary *payload = CCNMBuildN78Payload(initial[@"activeBands"], initial[@"supportedBands"], &failure);
        if (!payload) {
            CCNMN78PolicyErrorCode code = [failure containsString:@"not present"]
                ? CCNMN78PolicyErrorN78Unavailable : CCNMN78PolicyErrorInvalidBandInfo;
            return CCNMErrorSummary(@"enable", code, failure, details);
        }

        baseline = CCNMBuildBaselineRecord(initial[@"activeBands"], subscriptionUUID, generation, &failure);
        if (!baseline || !CCNMCreateDurableRecord(baseline, CCNMN78PolicyBaselinePath(), &failure)) {
            // Only create a recovery state when durable baseline evidence actually
            // remains. A serialization/write failure that left no file made no
            // modem change and must not manufacture an uninstall blocker.
            if (CCNMFileExists(CCNMN78PolicyBaselinePath())) {
                CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                    CCNMRecoveryStateRecoveryFailed, generation, subscriptionUUID,
                    CCNMN78PolicyErrorPersistence, failure, baseline, NO);
            }
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorPersistence, failure, details);
        }
        details[@"baselineCreated"] = @YES;

        context = CCNMSafeTargetContext(client, subscriptionUUID, details, &failure);
        NSDictionary *fresh = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
        if (!fresh || !CCNMDictionariesEqual(initial[@"activeBands"], fresh[@"activeBands"]) ||
            !CCNMDictionariesEqual(initial[@"supportedBands"], fresh[@"supportedBands"])) {
            failure = failure ?: @"Fresh active or supported BandInfo changed after baseline creation.";
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRebootRequired, generation, subscriptionUUID,
                context ? CCNMN78PolicyErrorInvalidBandInfo : CCNMN78PolicyErrorUUIDDrift,
                failure, baseline, YES);
            return CCNMErrorSummary(@"enable", context ? CCNMN78PolicyErrorInvalidBandInfo : CCNMN78PolicyErrorUUIDDrift,
                failure, details);
        }
        payload = CCNMBuildN78Payload(fresh[@"activeBands"], fresh[@"supportedBands"], &failure);
        id<CCNMBandInfo> payloadInfo = payload ? CCNMCreateBandPayload(payload, &failure) : nil;
        if (!payloadInfo) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRecoveryFailed, generation, subscriptionUUID,
                CCNMN78PolicyErrorInvalidBandInfo, failure, baseline, NO);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }

        intent = CCNMBuildIntentRecord(@"enable", generation, baseline, fresh, payload,
            state, nil, nil, &failure);
        if (!intent || !CCNMCreateDurableRecord(intent, CCNMN78PolicyIntentPath(), &failure)) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRecoveryFailed, generation, subscriptionUUID,
                CCNMN78PolicyErrorPersistence, failure, baseline, NO);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *applying = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
            CCNMAppliedPolicyApplying, CCNMRecoveryStateEnablePending, generation,
            subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"",
            @{ @"baselineCreatedAt": baseline[@"createdAt"] }, &failure);
        if (!applying || !CCNMPersistState(applying, &failure)) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRecoveryFailed, generation, subscriptionUUID,
                CCNMN78PolicyErrorPersistence, failure, baseline, NO);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorPersistence, failure, details);
        }
        inFlight = CCNMBuildInFlightRecord(@"enable", generation, baseline, intent, &failure);
        if (!inFlight || !CCNMCreateDurableRecord(inFlight, CCNMN78PolicyInFlightPath(), &failure)) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRebootRequired, generation, subscriptionUUID,
                CCNMN78PolicyErrorPersistence, failure, baseline, YES);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorPersistence, failure, details);
        }

        context = CCNMSafeTargetContext(client, subscriptionUUID, details, &failure);
        NSDictionary *lastGuard = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
        BOOL recordsExact = CCNMRecordsRemainExact(applying, baseline, intent, inFlight, &failure);
        BOOL bandsExact = lastGuard && CCNMDictionariesEqual(fresh[@"activeBands"], lastGuard[@"activeBands"]) &&
            CCNMDictionariesEqual(fresh[@"supportedBands"], lastGuard[@"supportedBands"]);
        if (!recordsExact) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Durable policy evidence changed before the setter and was preserved.", details);
        }
        if (!bandsExact) {
            failure = failure ?: @"The final target or BandInfo guard changed before the setter.";
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRebootRequired, generation, subscriptionUUID,
                CCNMN78PolicyErrorInvalidBandInfo, failure, baseline, YES);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }

        CCNMSetterOutcome outcome = CCNMCallSetter(client, context, payloadInfo, generation,
            &lockDescriptor, details, &failure);
        if (outcome == CCNMSetterOutcomeUncertain) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRebootRequired, generation, subscriptionUUID,
                CCNMN78PolicyErrorSetterUncertain, failure, baseline, YES);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorSetterUncertain, failure, details);
        }
        if (outcome == CCNMSetterOutcomeFailed) {
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, CCNMAppliedPolicyRecoveryRequired,
                CCNMRecoveryStateRecoveryFailed, generation, subscriptionUUID,
                CCNMN78PolicyErrorSetterFailed, failure, baseline, NO);
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorSetterFailed, failure, details);
        }

        NSDictionary *readBack = CCNMWaitForReadBack(client, subscriptionUUID, payload);
        details[@"readBack"] = readBack;
        if (![readBack[@"matched"] boolValue]) {
            BOOL uncertain = ![readBack[@"sawValid"] boolValue] ||
                [readBack[@"sawInvalid"] boolValue] || [readBack[@"identityUncertain"] boolValue] ||
                [readBack[@"deadlineExceeded"] boolValue];
            CCNMAppliedPolicy applied = uncertain ? CCNMAppliedPolicyRecoveryRequired : CCNMAppliedPolicyDiverged;
            CCNMRecoveryState recovery = uncertain ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
            CCNMN78PolicyErrorCode code = uncertain ? CCNMN78PolicyErrorSetterUncertain : CCNMN78PolicyErrorReadBackMismatch;
            failure = readBack[@"error"];
            if (!failure.length) {
                failure = uncertain ? @"No trustworthy complete read-back was obtained."
                    : @"Complete read-back did not equal the requested policy payload.";
            }
            CCNMMarkRecovery(CCNMRequestedModeSystemDefault, applied, recovery, generation,
                subscriptionUUID, code, failure, baseline, uncertain);
            return CCNMErrorSummary(@"enable", code, failure, details);
        }

        NSDictionary *verified = readBack[@"lastActiveBands"];
        if (!CCNMRecordsRemainExact(applying, baseline, intent, inFlight, &failure)) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Durable policy evidence changed after verified read-back and was preserved.", details);
        }
        if (!CCNMFinishEnabledState(generation, subscriptionUUID, applying,
            baseline, intent, inFlight, verified, &failure)) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *finalState = [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyStatePath()];
        return CCNMSummaryFromState(finalState, YES, @"enable", CCNMN78PolicyErrorNone, @"", details);
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

- (NSDictionary *)performDisable {
    return [self performRestoreOperation:@"disable" allowIncompleteEvidence:NO];
}

- (NSDictionary *)performRecovery {
    return [self performRestoreOperation:@"recover" allowIncompleteEvidence:YES];
}

- (NSDictionary *)performKnownOrphanedN78Recovery {
    NSMutableDictionary *details = [@{ @"setterAttempted": @NO } mutableCopy];
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(@"knownOrphanRecovery", CCNMN78PolicyErrorBusy, failure, details);
    }

    @try {
        NSDictionary *eligibility = CCNMEvaluateKnownOrphanEligibilityWithHeldLock(NO);
        details[@"eligibility"] = eligibility;
        if (![eligibility[@"eligible"] boolValue]) {
            CCNMN78PolicyErrorCode code = eligibility[CCNMN78PolicySummaryErrorCodeKey]
                ?: CCNMN78PolicyErrorRecoveryRequired;
            return CCNMErrorSummary(@"knownOrphanRecovery", code,
                eligibility[CCNMN78PolicySummaryErrorKey] ?: @"Known-orphan recovery is not eligible.", details);
        }

        BOOL stateExists = NO;
        NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
        NSUInteger generation = CCNMNextGeneration(state ?: CCNMDefaultState(), nil);
        if (generation == 0 || !CCNMBootSessionIdentity()) {
            return CCNMErrorSummary(@"knownOrphanRecovery", CCNMN78PolicyErrorRecoveryRequired,
                @"A valid boot identity and operation generation are required.", details);
        }

        NSDictionary *builtBaseline = CCNMBuildBaselineRecord(
            CCNMKnownOrphanHistoricalOriginalBands(), CCNMKnownOrphanSubscriptionUUID,
            generation, &failure);
        NSMutableDictionary *baselineDraft = [builtBaseline mutableCopy];
        baselineDraft[@"recoverySource"] = CCNMKnownOrphanRecoverySource;
        baselineDraft[@"evidenceSHA256"] = CCNMKnownOrphanEvidenceSHA256;
        NSDictionary *baseline = [baselineDraft copy];
        if (!builtBaseline || !CCNMValidateBaselineRecord(baseline, &failure) ||
            !CCNMCreateDurableRecord(baseline, CCNMN78PolicyBaselinePath(), &failure)) {
            return CCNMErrorSummary(@"knownOrphanRecovery", CCNMN78PolicyErrorPersistence,
                failure ?: @"The reviewed historical baseline could not be persisted.", details);
        }
        details[@"baselineCreated"] = @YES;

        NSNumber *verifiedAt = @(CCNMUnixMilliseconds());
        NSDictionary *proof = @{
            @"baselineCreatedAt": baseline[@"createdAt"],
            @"readBackVerified": @YES,
            @"verifiedAt": verifiedAt,
            @"verifiedActiveBands": CCNMKnownOrphanHistoricalActiveBands(),
            @"targetNRBands": @[ @78 ],
            @"nonNRUnchanged": @YES,
            @"recoverySource": CCNMKnownOrphanRecoverySource,
            @"evidenceSHA256": CCNMKnownOrphanEvidenceSHA256
        };
        NSDictionary *adopted = CCNMBuildStateRecord(CCNMRequestedModeN78Preferred,
            CCNMAppliedPolicyVerifiedN78Only, CCNMRecoveryStateEnabledWithBaseline,
            generation, CCNMKnownOrphanSubscriptionUUID, NO,
            CCNMN78PolicyErrorNone, @"", proof, &failure);
        BOOL adoptedSaved = adopted && (stateExists
            ? CCNMReplaceExpectedRecord(state, adopted, CCNMN78PolicyStatePath(), &failure)
            : CCNMCreateDurableRecord(adopted, CCNMN78PolicyStatePath(), &failure));
        if (!adoptedSaved) {
            return CCNMErrorSummary(@"knownOrphanRecovery", CCNMN78PolicyErrorPersistence,
                failure ?: @"The adopted stable n78 state could not be persisted.", details);
        }
        details[@"adoptedStableEnabledState"] = @YES;

        return [self performRestoreOperation:@"knownOrphanRecovery"
                    allowIncompleteEvidence:NO
                         heldLockDescriptor:&lockDescriptor
                requireKnownOrphanFinalGuard:YES];
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

- (NSDictionary *)performRestoreOperation:(NSString *)operation allowIncompleteEvidence:(BOOL)allowIncomplete {
    NSMutableDictionary *details = [@{ @"setterAttempted": @NO } mutableCopy];
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(operation, CCNMN78PolicyErrorBusy, failure, details);
    }
    @try {
        return [self performRestoreOperation:operation
                    allowIncompleteEvidence:allowIncomplete
                         heldLockDescriptor:&lockDescriptor
                requireKnownOrphanFinalGuard:NO];
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

- (NSDictionary *)performRestoreOperation:(NSString *)operation
                   allowIncompleteEvidence:(BOOL)allowIncomplete
                        heldLockDescriptor:(int *)lockDescriptor
               requireKnownOrphanFinalGuard:(BOOL)requireKnownOrphanFinalGuard {
    NSMutableDictionary *details = [@{ @"setterAttempted": @NO } mutableCopy];
    NSString *failure = nil;
    if (!lockDescriptor || *lockDescriptor < 0) {
        return CCNMErrorSummary(operation, CCNMN78PolicyErrorBusy,
            @"Restore core requires an already-held policy lock.", details);
    }

        @synchronized([CCNMN78PolicyController class]) {
            if (CCNMSetterUncertainLatch) {
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorSetterUncertain,
                    @"A setter outcome is uncertain in this process; reboot before recovery.", details);
            }
        }
        BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO, removalGuardExists = NO;
        NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
        NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
        NSDictionary *oldIntent = CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
        NSDictionary *oldInFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
        NSDictionary *removalGuard = CCNMLoadRecord(CCNMN78PolicyRemovalGuardPath(), &removalGuardExists);
        if ((stateExists && !CCNMValidateStateRecord(state, &failure)) ||
            (removalGuardExists && !CCNMValidateRemovalGuardRecord(removalGuard, &failure)) ||
            (baselineExists && !CCNMValidateBaselineRecord(baseline, &failure)) ||
            (intentExists && (!baseline || !CCNMValidateIntentRecord(oldIntent, baseline, &failure))) ||
            (inFlightExists && (!baseline || !CCNMValidateInFlightRecord(oldInFlight, baseline, oldIntent, NO, &failure)))) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Recovery evidence is malformed or foreign and was preserved.", details);
        }
        state = state ?: CCNMDefaultState();
        BOOL knownEvidenceBaseline = baselineExists &&
            CCNMKnownOrphanBaselineMatchesEvidence(baseline);
        if (requireKnownOrphanFinalGuard && !knownEvidenceBaseline) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                @"Known-orphan recovery requires the exact reviewed baseline provenance and payload.", details);
        }
        BOOL enforceKnownOrphanGuard = requireKnownOrphanFinalGuard || knownEvidenceBaseline;

        if (!baselineExists) {
            if (!intentExists && !inFlightExists &&
                [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
                [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
                [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean]) {
                return CCNMSummaryFromState(state, YES, operation, CCNMN78PolicyErrorNone, @"", details);
            }
            if (allowIncomplete && !intentExists && !inFlightExists &&
                CCNMBootRelationForRecord(state) == CCNMBootRelationEarlier &&
                CCNMIsVerifiedRestoreCleanupCheckpoint(state)) {
                NSUInteger generation = CCNMNextGeneration(state, nil);
                if (!CCNMValidateTarget(details, &failure)) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorUnsupportedTarget, failure, details);
                }
                id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
                id context = client
                    ? CCNMSafeTargetContext(client, state[@"subscriptionUUID"], details, &failure) : nil;
                NSDictionary *fresh = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
                if (!fresh || !CCNMDictionariesEqual(fresh[@"activeBands"], state[@"verifiedActiveBands"])) {
                    failure = failure ?: @"Live BandInfo no longer matches the verified restore cleanup checkpoint.";
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
                }
                NSMutableDictionary *cleanupProof = [@{
                    @"verifiedAt": state[@"verifiedAt"],
                    @"verifiedActiveBands": state[@"verifiedActiveBands"],
                    @"restoredBaselineCreatedAt": state[@"baselineCreatedAt"]
                } mutableCopy];
                if ([state[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource] &&
                    [state[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256]) {
                    cleanupProof[@"recoverySource"] = CCNMKnownOrphanRecoverySource;
                    cleanupProof[@"evidenceSHA256"] = CCNMKnownOrphanEvidenceSHA256;
                }
                NSDictionary *clean = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
                    CCNMAppliedPolicyVerifiedSystemDefault, CCNMRecoveryStateClean,
                    generation, details[@"targetSubscriptionUUID"], NO,
                    CCNMN78PolicyErrorNone, @"", cleanupProof, &failure);
                if (!clean || !CCNMPersistState(clean, &failure)) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
                }
                return CCNMSummaryFromState(clean, YES, operation, CCNMN78PolicyErrorNone, @"", details);
            }
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                @"A required policy baseline is missing; no modem write was issued.", details);
        }

        BOOL stableEnabled = stateExists && !intentExists && !inFlightExists &&
            [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
            [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
            [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
            [state[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
            [CCNMCanonicalUUIDString(state[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
            ![state[@"uncertain"] boolValue];
        if (!allowIncomplete && !stableEnabled) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                @"Disable requires a verified enabled state with its exact retained baseline and no transition records.", details);
        }
        if (allowIncomplete && !stableEnabled) {
            BOOL inFlightMayBeCurrent = inFlightExists &&
                CCNMBootRelationForRecord(oldInFlight) != CCNMBootRelationEarlier;
            BOOL intentMayBeCurrent = intentExists &&
                CCNMBootRelationForRecord(oldIntent) != CCNMBootRelationEarlier;
            BOOL pendingStateMayBeCurrent = stateExists &&
                (![state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] ||
                 [state[@"uncertain"] boolValue]) &&
                CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier;
            BOOL baselineOnlyMayBeCurrent = !intentExists && !inFlightExists &&
                CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier;
            if (inFlightMayBeCurrent || intentMayBeCurrent || pendingStateMayBeCurrent || baselineOnlyMayBeCurrent) {
                CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeSystemDefault,
                    CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                    [state[@"operationGeneration"] unsignedIntegerValue], baseline[@"subscriptionUUID"],
                    CCNMN78PolicyErrorRecoveryRequired,
                    @"Incomplete or uncertain transition evidence belongs to this boot; reboot before recovery.",
                    baseline, YES);
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                    @"Incomplete or uncertain transition evidence belongs to this boot; reboot before recovery.", details);
            }
        }

        NSUInteger generation = CCNMNextGeneration(state, oldIntent);
        NSString *subscriptionUUID = CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]);
        if (generation == 0 || !CCNMBootSessionIdentity()) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                @"A valid boot identity and new operation generation are required.", details);
        }
        if (!CCNMValidateTarget(details, &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorUnsupportedTarget, failure, details);
        }
        id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
        id<CCNMSubscriptionContext> context = client
            ? CCNMSafeTargetContext(client, subscriptionUUID, details, &failure) : nil;
        if (!context) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorUUIDDrift,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorUUIDDrift, failure, details);
        }
        NSDictionary *fresh = CCNMReadFreshBandInfo(client, context, &failure);
        if (!fresh) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorInvalidBandInfo,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }
        if (enforceKnownOrphanGuard &&
            !CCNMKnownOrphanBandInfoMatches(fresh, CCNMKnownOrphanHistoricalActiveBands()) &&
            !CCNMKnownOrphanBandInfoMatches(fresh, CCNMKnownOrphanHistoricalOriginalBands())) {
            failure = @"Live BandInfo no longer matches either reviewed known-device recovery checkpoint.";
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorInvalidBandInfo,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }
        NSDictionary *payload = CCNMBuildRestorePayload(fresh[@"activeBands"], baseline[@"activeBands"], &failure);
        if (!payload) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorInvalidBandInfo,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }

        if (CCNMDictionariesEqual(payload, fresh[@"activeBands"])) {
            details[@"writeNotNeeded"] = @YES;
            NSDictionary *expectedState = stateExists ? state : nil;
            if (!CCNMRecordsRemainExact(expectedState, baseline, oldIntent, oldInFlight, &failure)) {
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                    failure ?: @"Durable policy evidence changed during no-write recovery and was preserved.", details);
            }
            if (enforceKnownOrphanGuard) {
                context = CCNMSafeTargetContext(client, subscriptionUUID, details, &failure);
                NSDictionary *lastNoWriteGuard = context
                    ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
                if (!CCNMKnownOrphanBandInfoMatches(
                    lastNoWriteGuard, CCNMKnownOrphanHistoricalOriginalBands())) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo,
                        failure ?: @"The final known-device no-write recovery guard changed.", details);
                }
            }
            if (!CCNMFinishSystemDefaultState(generation, subscriptionUUID, expectedState,
                baseline, oldIntent, oldInFlight, fresh[@"activeBands"], &failure)) {
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
            }
            NSDictionary *clean = [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyStatePath()];
            return CCNMSummaryFromState(clean, YES, operation, CCNMN78PolicyErrorNone, @"", details);
        }

        id<CCNMBandInfo> payloadInfo = CCNMCreateBandPayload(payload, &failure);
        if (!payloadInfo) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }
        NSDictionary *intent = CCNMBuildIntentRecord(operation, generation, baseline, fresh, payload,
            state, oldIntent, oldInFlight, &failure);
        if (!intent || !CCNMPersistOrReplaceTransition(oldIntent, intent,
            CCNMN78PolicyIntentPath(), &failure)) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRecoveryFailed,
                generation, subscriptionUUID, CCNMN78PolicyErrorPersistence,
                failure, baseline, NO);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *pending = CCNMBuildStateRecord(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
            CCNMAppliedPolicyApplying, CCNMRecoveryStateRestorePending,
            generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"",
            @{ @"baselineCreatedAt": baseline[@"createdAt"] }, &failure);
        if (!pending || !CCNMPersistState(pending, &failure)) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRecoveryFailed,
                generation, subscriptionUUID, CCNMN78PolicyErrorPersistence,
                failure, baseline, NO);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *inFlight = CCNMBuildInFlightRecord(operation, generation, baseline, intent, &failure);
        if (!inFlight || !CCNMPersistOrReplaceTransition(oldInFlight, inFlight,
            CCNMN78PolicyInFlightPath(), &failure)) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorPersistence,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
        }

        BOOL recordsExact = CCNMRecordsRemainExact(pending, baseline, intent, inFlight, &failure);
        if (!recordsExact) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Durable policy evidence changed before the restore setter and was preserved.", details);
        }

        NSDictionary *lastGuard = nil;
        BOOL bandsExact = NO;
        if (enforceKnownOrphanGuard) {
            context = nil;
            bandsExact = CCNMValidateKnownOrphanedN78HistoricalPredicate(
                client, details, &context, &lastGuard, NULL, &failure);
        } else {
            context = CCNMSafeTargetContext(client, subscriptionUUID, details, &failure);
            lastGuard = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
            bandsExact = lastGuard &&
                CCNMDictionariesEqual(fresh[@"activeBands"], lastGuard[@"activeBands"]) &&
                CCNMDictionariesEqual(fresh[@"supportedBands"], lastGuard[@"supportedBands"]);
        }
        if (!bandsExact) {
            failure = failure ?: @"The final restore target or BandInfo guard changed.";
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorInvalidBandInfo,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }

        CCNMSetterOutcome outcome = CCNMCallSetter(client, context, payloadInfo, generation,
            lockDescriptor, details, &failure);
        if (outcome == CCNMSetterOutcomeUncertain) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorSetterUncertain,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorSetterUncertain, failure, details);
        }
        if (outcome == CCNMSetterOutcomeFailed) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRecoveryFailed,
                generation, subscriptionUUID, CCNMN78PolicyErrorSetterFailed,
                failure, baseline, NO);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorSetterFailed, failure, details);
        }

        NSDictionary *readBack = CCNMWaitForReadBack(client, subscriptionUUID, payload);
        details[@"readBack"] = readBack;
        if (![readBack[@"matched"] boolValue]) {
            BOOL uncertain = ![readBack[@"sawValid"] boolValue] ||
                [readBack[@"sawInvalid"] boolValue] || [readBack[@"identityUncertain"] boolValue] ||
                [readBack[@"deadlineExceeded"] boolValue];
            CCNMAppliedPolicy applied = uncertain ? CCNMAppliedPolicyRecoveryRequired : CCNMAppliedPolicyDiverged;
            CCNMRecoveryState recovery = uncertain ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
            CCNMN78PolicyErrorCode code = uncertain ? CCNMN78PolicyErrorSetterUncertain : CCNMN78PolicyErrorReadBackMismatch;
            failure = readBack[@"error"];
            if (!failure.length) {
                failure = uncertain ? @"No trustworthy complete restore read-back was obtained."
                    : @"Complete restore read-back did not equal the exact restore payload.";
            }
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                applied, recovery, generation, subscriptionUUID, code,
                failure, baseline, uncertain);
            return CCNMErrorSummary(operation, code, failure, details);
        }

        if (!CCNMRecordsRemainExact(pending, baseline, intent, inFlight, &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Durable policy evidence changed after verified restore read-back and was preserved.", details);
        }
        if (!CCNMFinishSystemDefaultState(generation, subscriptionUUID, pending,
            baseline, intent, inFlight, readBack[@"lastActiveBands"], &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *clean = [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyStatePath()];
        return CCNMSummaryFromState(clean, YES, operation, CCNMN78PolicyErrorNone, @"", details);
}

@end

NSDictionary<NSString *, id> *CCNMReadKnownOrphanedN78RecoveryEligibility(void) {
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMKnownOrphanEligibilityResult(NO, NO,
            CCNMN78PolicyErrorBusy, failure, nil);
    }
    @try {
        return CCNMEvaluateKnownOrphanEligibilityWithHeldLock(NO);
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

NSDictionary<NSString *, id> *CCNMReadKnownOrphanedN78RemovalSafety(void) {
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMKnownOrphanEligibilityResult(NO, NO,
            CCNMN78PolicyErrorBusy, failure, nil);
    }
    @try {
        return CCNMEvaluateKnownOrphanEligibilityWithHeldLock(YES);
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

NSDictionary<NSString *, id> *CCNMReadN78PolicyState(void) {
    return [[CCNMN78PolicyController sharedController] readState];
}

BOOL CCNMN78PolicyHasOutstandingSetter(void) {
    @synchronized([CCNMN78PolicyController class]) {
        return CCNMSetterCallActive || CCNMSetterRetainedPolicyLockDescriptor >= 0;
    }
}

static NSDictionary *CCNMRemovalGuardOperationSummary(NSDictionary *summary, NSString *operation) {
    NSMutableDictionary *result = [summary mutableCopy] ?: [NSMutableDictionary dictionary];
    result[CCNMN78PolicySummaryOperationKey] = operation ?: @"removalGuard";
    return [result copy];
}

NSDictionary<NSString *, id> *CCNMArmN78PolicyRemovalGuard(void) {
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(@"armRemovalGuard", CCNMN78PolicyErrorBusy, failure, nil);
    }
    @try {
        BOOL guardExists = NO;
        NSDictionary *guard = CCNMLoadRecord(CCNMN78PolicyRemovalGuardPath(), &guardExists);
        if (guardExists && !CCNMValidateRemovalGuardRecord(guard, &failure)) {
            return CCNMErrorSummary(@"armRemovalGuard", CCNMN78PolicyErrorInvalidRecords,
                failure, nil);
        }
        NSDictionary *summary = CCNMReadPolicyStateInternal();
        BOOL clean = [summary[CCNMN78PolicySummaryMayUninstallKey] boolValue] &&
            ![summary[@"baselinePresent"] boolValue] && ![summary[@"transitionPresent"] boolValue];
        if (!clean) {
            return CCNMErrorSummary(@"armRemovalGuard", CCNMN78PolicyErrorRecoveryRequired,
                @"The package-removal guard can be armed only after verified policy restoration.", nil);
        }
        if (!guardExists) {
            NSDictionary *newGuard = CCNMBuildRemovalGuardRecord(summary, &failure);
            if (!newGuard || !CCNMCreateDurableRecord(newGuard, CCNMN78PolicyRemovalGuardPath(), &failure)) {
                return CCNMErrorSummary(@"armRemovalGuard", CCNMN78PolicyErrorPersistence,
                    failure, nil);
            }
        }
        NSDictionary *verified = CCNMReadPolicyStateInternal();
        if (![verified[@"removalGuardPresent"] boolValue] || ![verified[@"removalGuardValid"] boolValue] ||
            ![verified[CCNMN78PolicySummaryMayUninstallKey] boolValue]) {
            return CCNMErrorSummary(@"armRemovalGuard", CCNMN78PolicyErrorPersistence,
                @"The package-removal guard could not be verified after persistence.", nil);
        }
        CCNMPostPolicyDidChange();
        return CCNMRemovalGuardOperationSummary(verified, @"armRemovalGuard");
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

NSDictionary<NSString *, id> *CCNMClearN78PolicyRemovalGuardIfSafe(void) {
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(@"clearRemovalGuard", CCNMN78PolicyErrorBusy, failure, nil);
    }
    @try {
        BOOL guardExists = NO;
        NSDictionary *guard = CCNMLoadRecord(CCNMN78PolicyRemovalGuardPath(), &guardExists);
        if (!guardExists) {
            return CCNMRemovalGuardOperationSummary(CCNMReadPolicyStateInternal(), @"clearRemovalGuard");
        }
        if (!CCNMValidateRemovalGuardRecord(guard, &failure)) {
            return CCNMErrorSummary(@"clearRemovalGuard", CCNMN78PolicyErrorInvalidRecords,
                failure, nil);
        }
        NSDictionary *summary = CCNMReadPolicyStateInternal();
        BOOL clean = [summary[CCNMN78PolicySummaryMayUninstallKey] boolValue] &&
            ![summary[@"baselinePresent"] boolValue] && ![summary[@"transitionPresent"] boolValue];
        if (!clean) {
            return CCNMErrorSummary(@"clearRemovalGuard", CCNMN78PolicyErrorRecoveryRequired,
                @"The package-removal guard cannot be cleared while policy evidence requires recovery.", nil);
        }
        if (!CCNMRemoveExpectedRecord(guard, CCNMN78PolicyRemovalGuardPath(), &failure)) {
            return CCNMErrorSummary(@"clearRemovalGuard", CCNMN78PolicyErrorPersistence,
                failure, nil);
        }
        NSDictionary *verified = CCNMReadPolicyStateInternal();
        if ([verified[@"removalGuardPresent"] boolValue]) {
            return CCNMErrorSummary(@"clearRemovalGuard", CCNMN78PolicyErrorPersistence,
                @"The package-removal guard still exists after verified retirement.", nil);
        }
        CCNMPostPolicyDidChange();
        return CCNMRemovalGuardOperationSummary(verified, @"clearRemovalGuard");
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

void CCNMEnableN78Preference(CCNMN78PolicyCompletion completion) {
    [[CCNMN78PolicyController sharedController] enableWithCompletion:completion];
}

void CCNMDisableN78Preference(CCNMN78PolicyCompletion completion) {
    NSString *requiredBaseline = CCNMN78PolicyBaselinePath();
    (void)requiredBaseline;
    [[CCNMN78PolicyController sharedController] disableWithCompletion:completion];
}

void CCNMRecoverN78Preference(CCNMN78PolicyCompletion completion) {
    [[CCNMN78PolicyController sharedController] recoverWithCompletion:completion];
}

void CCNMRecoverKnownOrphanedN78WithCompletion(CCNMN78PolicyCompletion completion) {
    [[CCNMN78PolicyController sharedController]
        recoverKnownOrphanedN78WithCompletion:completion];
}
