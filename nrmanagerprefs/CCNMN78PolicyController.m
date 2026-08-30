#import "CCNMN78PolicyController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <pwd.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#if defined(CCNM_MAINTAINER_SCRIPT)
#import "../package-actions/CCNMMaintainerEnvironment.h"

// The install guards run as helpers invoked by the shell maintainer scripts.
// libroothide.dylib is not loaded there and @loader_path/.jbroot does not exist
// beside an installed helper, so jbroot() is unavailable.
//
// The prefix is not re-derived here. The shell already resolved it, and on
// roothide re-deriving it is not merely redundant but wrong: the guard is
// invoked through a bare path, so the executable path carries no .jbroot-
// component, and scanning /var/containers/Bundle/Application from a redirected
// process looks inside the jailbreak root rather than at it. Both former
// strategies would therefore fail or, worse, silently pick a wrong directory.
//
// An empty prefix is the normal roothide answer and means bare paths already
// resolve correctly, so it must not be treated as a failure.
static NSString *CCNMPolicyRootForMaintainer(NSString *path) {
    NSString *prefix = CCNMMaintainerInstallPrefix();
    if (!prefix) {
        // Deliberately unusable rather than falling back to a bare path: a
        // policy read that silently targets the wrong root would be reported as
        // a clean state and could authorize removal of a package that still
        // holds a forced band configuration.
        return [@"/.nrmanager-unresolved-install-prefix" stringByAppendingString:path];
    }
    // Plain concatenation, so an empty prefix yields the original absolute path.
    return [prefix stringByAppendingString:path];
}

#define CCNMPolicyRoot(path) CCNMPolicyRootForMaintainer(path)

#elif __has_include(<roothide.h>)
#import <roothide.h>
#define CCNMPolicyRoot(path) jbroot(path)
#else
#define CCNMPolicyRoot(path) (path)
#endif

static NSString *const CCNMPolicyOwner = @"com.doimty.nrmanager.n78-policy";
static NSString *const CCNMNRKey = @"kCTRegistrationRadioAccessTechnologyNR";
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
// Optional. CoreTelephony's own answer to "which subscription is the data line".
// Declared @optional so -respondsToSelector: can be asked for it without a
// compiler warning, and used only to pick a target on a device where more than one
// SIM could take the write. It is never consulted to validate an already-recorded
// target: the data line moves at runtime, a recorded target must not.
@optional
- (id)getCurrentDataSubscriptionContextSync:(NSError **)error;
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
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.state.plist");
}

NSString *CCNMN78PolicyBaselinePath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.baseline.plist");
}

NSString *CCNMN78PolicyIntentPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.intent.plist");
}

NSString *CCNMN78PolicyInFlightPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.inflight.plist");
}

NSString *CCNMN78PolicyLockPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.lock");
}

NSString *CCNMN78PolicyRemovalGuardPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-policy.removal-guard.plist");
}

// The pending band selection is ordinary user preference data, not policy
// evidence, so it lives outside CCNMN78PolicyPaths(): it is not created,
// retired or crash-recovered with the durable records, and it deliberately
// survives the off state so a selection can be edited while the feature is
// disabled. It is untrusted input. Every read canonicalises it and every write
// path revalidates it against the live domain, so a tampered file can still only
// pick a subset of what iOS already allowed.
NSString *CCNMN78SelectedBandsPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/com.doimty.nrmanager.n78-selection.plist");
}

NSArray<NSString *> *CCNMN78PolicyPaths(void) {
    return @[
        CCNMN78PolicyStatePath(),
        CCNMN78PolicyBaselinePath(),
        CCNMN78PolicyIntentPath(),
        CCNMN78PolicyInFlightPath(),
        CCNMN78PolicyLockPath()
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

static BOOL CCNMValidSlotID(id value) {
    return CCNMNSNumberIsInteger(value) && [value longLongValue] > 0;
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

// Ascending, unique, positive band identifiers, or nil.
//
// The ordering is a correctness requirement rather than tidiness.
// CCNMWaitForReadBack accepts only whole-dictionary equality, which reduces to
// NSArray equality, so the order we write becomes part of what the modem has to
// echo back. A single-band selection could never expose that. Ascending is the
// only order that is safe whether the modem echoes the array as written or
// normalises it, and every NR array in the reviewed device evidence is
// ascending. Canonicalising here, in the only place a payload is built, is what
// keeps a tap order from ever reaching the baseband.
NSArray<NSNumber *> *CCNMCanonicalNRSelection(NSArray *selection, NSString **failure) {
    if (![selection isKindOfClass:NSArray.class] || selection.count == 0) {
        if (failure) {
            *failure = @"An NR band selection must be a non-empty array.";
        }
        return nil;
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (id band in selection) {
        if (!CCNMNSNumberIsInteger(band) || [band longLongValue] <= 0 ||
            [band longLongValue] > CCNMMaximumBandIdentifier) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"The NR band selection contains an invalid identifier: %@.", band];
            }
            return nil;
        }
        if ([seen containsObject:band]) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"The NR band selection lists band %@ more than once.", band];
            }
            return nil;
        }
        [seen addObject:band];
    }
    return [selection sortedArrayUsingSelector:@selector(compare:)];
}

// The bands a user may choose from: what iOS already has enabled, intersected
// with what this modem declares it supports.
//
// Neither side alone is right. Offering the active list alone would present
// bands the modem does not report as supported; on the reviewed device that is
// 27 of its 46 active NR entries. Offering the supported list alone would offer
// bands iOS never had enabled, which is the expansion this feature must never
// perform. The BandInfo contract permits an active list to contain values absent
// from the supported list, so the intersection has to be computed rather than
// assumed equal to either input.
// Split into an array-level core and a dictionary-level wrapper so the settings
// pane, which holds only the two NR arrays out of a serving summary, computes the
// domain with the same code the write path uses rather than a lookalike.
static BOOL CCNMValidateNRBandArray(NSArray *bands, NSString *role, NSString **failure) {
    if (![bands isKindOfClass:NSArray.class]) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The %@ NR band list is missing or not an array.", role];
        }
        return NO;
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (id band in bands) {
        if (!CCNMNSNumberIsInteger(band) || [band longLongValue] <= 0 ||
            [band longLongValue] > CCNMMaximumBandIdentifier || [seen containsObject:band]) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"The %@ NR band list contains an invalid or duplicate identifier: %@.",
                    role, band];
            }
            return NO;
        }
        [seen addObject:band];
    }
    return YES;
}

static NSArray<NSNumber *> *CCNMSelectableNRDomainFromArrays(NSArray *activeNR,
                                                            NSArray *supportedNR,
                                                            NSString **failure) {
    NSMutableArray<NSNumber *> *domain = [NSMutableArray array];
    NSSet *supportedSet = [NSSet setWithArray:supportedNR];
    for (NSNumber *band in activeNR) {
        if ([supportedSet containsObject:band]) {
            [domain addObject:band];
        }
    }
    if (domain.count == 0) {
        if (failure) {
            *failure = @"No NR band is both enabled by the system and supported by this modem.";
        }
        return nil;
    }
    return [domain sortedArrayUsingSelector:@selector(compare:)];
}

static NSArray<NSNumber *> *CCNMSelectableNRDomain(NSDictionary *active,
                                                   NSDictionary *supported,
                                                   NSString **failure) {
    if (!CCNMValidateBandDictionary(active, failure) ||
        !CCNMValidateBandDictionary(supported, failure)) {
        return nil;
    }
    return CCNMSelectableNRDomainFromArrays(active[CCNMNRKey], supported[CCNMNRKey], failure);
}

NSArray<NSNumber *> *CCNMSelectableNRBandDomain(NSArray<NSNumber *> *activeNRBands,
                                                NSArray<NSNumber *> *supportedNRBands,
                                                NSString **failure) {
    if (!CCNMValidateNRBandArray(activeNRBands, @"system-enabled", failure) ||
        !CCNMValidateNRBandArray(supportedNRBands, @"modem-supported", failure)) {
        return nil;
    }
    return CCNMSelectableNRDomainFromArrays(activeNRBands, supportedNRBands, failure);
}

// The refusals CCNMBuildSelectedNRPayload applies, minus the payload. The pane
// needs the reason before the user commits, so it can decline to save with the
// real message instead of letting a later enable fail. This is a preview of the
// write path's decision, never a substitute for it: enable recomputes everything
// against band evidence read at that moment, and only its answer authorises a
// modem write.
//
// The "equals the live array" refusal is deliberately absent. Here the domain is
// the live active list narrowed by supported, so a selection equalling the live
// array is already caught by the whole-domain refusal in every case the pane can
// construct; restating it would only add a second message for one situation.
BOOL CCNMValidateNRBandSelectionAgainstDomain(NSArray<NSNumber *> *selection,
                                              NSArray<NSNumber *> *domain,
                                              NSString **failure) {
    NSArray *canonicalSelection = CCNMCanonicalNRSelection(selection, failure);
    if (!canonicalSelection || !CCNMValidateNRBandArray(domain, @"selectable", failure)) {
        return NO;
    }
    NSArray *canonicalDomain = [domain sortedArrayUsingSelector:@selector(compare:)];
    if (![[NSSet setWithArray:canonicalSelection] isSubsetOfSet:[NSSet setWithArray:canonicalDomain]]) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The NR selection %@ is not within the %lu band(s) this system currently allows.",
                canonicalSelection, (unsigned long)canonicalDomain.count];
        }
        return NO;
    }
    if ([canonicalSelection isEqualToArray:canonicalDomain]) {
        if (failure) {
            *failure = @"The NR selection is every band this system already allows; turn the feature off instead.";
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMValidateSelectedNRPayload(NSDictionary *original,
                                          NSDictionary *payload,
                                          NSArray<NSNumber *> *selection,
                                          NSString **failure) {
    NSArray *canonical = CCNMCanonicalNRSelection(selection, failure);
    if (!canonical ||
        !CCNMValidateBandDictionary(original, failure) ||
        !CCNMValidateBandDictionary(payload, failure) ||
        ![[NSSet setWithArray:original.allKeys] isEqualToSet:[NSSet setWithArray:payload.allKeys]]) {
        return NO;
    }
    for (NSString *key in original) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? canonical : original[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? [NSString stringWithFormat:
                        @"The requested NR array is not exactly the ascending selection %@.", canonical]
                    : [NSString stringWithFormat:@"The requested payload changed non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

static NSDictionary *CCNMBuildSelectedNRPayload(NSDictionary *active,
                                                NSDictionary *supported,
                                                NSArray<NSNumber *> *selection,
                                                NSString **failure) {
    NSArray *canonical = CCNMCanonicalNRSelection(selection, failure);
    NSArray *domain = CCNMSelectableNRDomain(active, supported, failure);
    if (!canonical || !domain) {
        return nil;
    }
    if (![[NSSet setWithArray:canonical] isSubsetOfSet:[NSSet setWithArray:domain]]) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The NR selection %@ is not within the %lu band(s) this system currently allows.",
                canonical, (unsigned long)domain.count];
        }
        return nil;
    }
    if ([canonical isEqualToArray:domain]) {
        // Pinning everything the system already allows is what "off" means.
        // Performing it would spend a modem write, a crash window and a baseline
        // for no change in behaviour.
        if (failure) {
            *failure = @"The NR selection is every band this system already allows; turn the feature off instead.";
        }
        return nil;
    }
    if ([canonical isEqualToArray:active[CCNMNRKey]]) {
        if (failure) {
            *failure = @"The live NR array already equals this selection without a retained policy baseline.";
        }
        return nil;
    }
    NSDictionary *copy = CCNMDeepCopyDictionary(active, failure);
    if (!copy) {
        return nil;
    }
    NSMutableDictionary *draft = [copy mutableCopy];
    draft[CCNMNRKey] = canonical;
    NSDictionary *payload = CCNMDeepCopyDictionary(draft, failure);
    return CCNMValidateSelectedNRPayload(active, payload, canonical, failure) ? payload : nil;
}

// The selection a persisted enable intent carries, checked against the evidence
// that intent recorded for itself. Used by both the intent builder and the
// intent validator so the two can never disagree.
static BOOL CCNMValidateSelectedNRIntentPayload(NSDictionary *active,
                                                NSDictionary *supported,
                                                NSDictionary *requested,
                                                NSString **failure) {
    if (!CCNMValidateBandDictionary(requested, failure)) {
        return NO;
    }
    NSArray *canonical = CCNMCanonicalNRSelection(requested[CCNMNRKey], failure);
    NSArray *domain = CCNMSelectableNRDomain(active, supported, failure);
    if (!canonical || !domain) {
        return NO;
    }
    if (![[NSSet setWithArray:canonical] isSubsetOfSet:[NSSet setWithArray:domain]]) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The recorded NR selection %@ is not within the bands its own pre-write evidence allowed.",
                canonical];
        }
        return NO;
    }
    return CCNMValidateSelectedNRPayload(active, requested, canonical, failure);
}

// Band 78 alone is the selection a user who has never opened the band pane gets,
// which keeps an upgrade from 1.5.0 byte-for-byte identical in behaviour.
static NSArray<NSNumber *> *CCNMDefaultNRSelection(void) {
    return @[ @78 ];
}

NSArray<NSNumber *> *CCNMReadSelectedNRBands(void) {
    id stored = [NSDictionary dictionaryWithContentsOfFile:CCNMN78SelectedBandsPath()][@"selectedNRBands"];
    NSArray *canonical = CCNMCanonicalNRSelection(stored, NULL);
    // A malformed or absent file is not an error to report: it means the user has
    // expressed no preference, and the shipped default is the right answer.
    return canonical ?: CCNMDefaultNRSelection();
}

BOOL CCNMHasStoredSelectedNRBands(void) {
    id stored = [NSDictionary dictionaryWithContentsOfFile:CCNMN78SelectedBandsPath()][@"selectedNRBands"];
    return CCNMCanonicalNRSelection(stored, NULL) != nil;
}

BOOL CCNMWriteSelectedNRBands(NSArray<NSNumber *> *selection, NSString **failure) {
    NSArray *canonical = CCNMCanonicalNRSelection(selection, failure);
    if (!canonical) {
        return NO;
    }
    return CCNMReplaceDurableRecord(@{
        @"schemaVersion": @1,
        @"owner": CCNMPolicyOwner,
        @"kind": @"selection",
        @"updatedAt": @(CCNMUnixMilliseconds()),
        @"selectedNRBands": canonical
    }, CCNMN78SelectedBandsPath(), failure);
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
            CCNMRecoveryStateCarrierResetPending, CCNMRecoveryStateCarrierResetFailed,
            CCNMRecoveryStateRebootRequired, CCNMRecoveryStateRecoveryFailed
        ]) &&
        [state[@"uncertain"] isKindOfClass:[NSNumber class]] &&
        [state[@"errorCode"] isKindOfClass:[NSString class]] &&
        [state[@"error"] isKindOfClass:[NSString class]];
    NSString *uuid = state[@"subscriptionUUID"];
    id slotID = state[@"slotID"];
    valid = valid && [uuid isKindOfClass:[NSString class]] &&
        ([(NSString *)uuid length] == 0 || CCNMCanonicalUUIDString(uuid) != nil) &&
        (!slotID || CCNMValidSlotID(slotID));
    // A verified enabled record must name the selection it applied, because that
    // array is the only thing the maintenance daemon can compare live NR against.
    //
    // The condition is deliberately narrower than "requestedMode is not
    // systemDefault". A disable checkpoint carries the pre-disable
    // n78Preferred mode with appliedPolicy=applying and no targetNRBands, and
    // enable refuses outright against a state record that fails validation. The
    // wider rule would therefore turn a crash mid-disable into an unusable
    // install. Only a settled enabled state has a selection in effect.
    if (valid &&
        [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        !CCNMCanonicalNRSelection(state[@"targetNRBands"], NULL)) {
        if (failure) {
            *failure = @"The verified enabled policy state does not record a valid NR band selection.";
        }
        return NO;
    }
    if (!valid && failure) {
        *failure = @"The durable n78 policy state record is malformed or foreign.";
    }
    return valid;
}

static NSDictionary *CCNMBuildBaselineRecord(NSDictionary *active,
                                              NSDictionary *supported,
                                              NSArray<NSString *> *modifiedBandKeys,
                                              NSDictionary *identity,
                                              NSString *subscriptionUUID,
                                              NSNumber *slotID,
                                              NSUInteger generation,
                                              NSString **failure) {
    NSString *bootSession = CCNMBootSessionIdentity();
    NSString *uuid = CCNMCanonicalUUIDString(subscriptionUUID);
    NSString *deviceModel = [identity[@"deviceModel"] isKindOfClass:NSString.class]
        ? identity[@"deviceModel"] : nil;
    NSString *systemVersion = [identity[@"systemVersion"] isKindOfClass:NSString.class]
        ? identity[@"systemVersion"] : nil;
    NSString *systemBuild = [identity[@"systemBuild"] isKindOfClass:NSString.class]
        ? identity[@"systemBuild"] : nil;
    BOOL ownedFieldsValid = [modifiedBandKeys isKindOfClass:NSArray.class] &&
        modifiedBandKeys.count == 1 && [modifiedBandKeys.firstObject isEqual:CCNMNRKey];
    if (!bootSession || !uuid || !CCNMValidSlotID(slotID) ||
        !deviceModel.length || !systemVersion.length || !systemBuild.length ||
        !CCNMValidateBandDictionary(active, failure) || !CCNMValidateBandDictionary(supported, failure) ||
        !ownedFieldsValid) {
        if (failure && !*failure) {
            *failure = @"A baseline requires valid identity, capability, and owned-band evidence.";
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
        @"slotID": slotID,
        @"subscriptionUUID": uuid,
        @"deviceModel": deviceModel,
        @"systemVersion": systemVersion,
        @"systemBuild": systemBuild,
        @"activeBands": active,
        @"supportedBands": supported,
        @"modifiedBandKeys": [modifiedBandKeys copy]
    };
}

static BOOL CCNMValidateBaselineRecord(NSDictionary *baseline, NSString **failure) {
    NSDictionary *bands = [baseline[@"activeBands"] isKindOfClass:[NSDictionary class]] ? baseline[@"activeBands"] : nil;
    BOOL hasCapabilitySnapshot = baseline[@"deviceModel"] != nil ||
        baseline[@"systemVersion"] != nil || baseline[@"systemBuild"] != nil ||
        baseline[@"supportedBands"] != nil || baseline[@"modifiedBandKeys"] != nil;
    BOOL capabilitySnapshotValid = !hasCapabilitySnapshot ||
        ([baseline[@"deviceModel"] isKindOfClass:NSString.class] && [baseline[@"deviceModel"] length] > 0 &&
         [baseline[@"systemVersion"] isKindOfClass:NSString.class] && [baseline[@"systemVersion"] length] > 0 &&
         [baseline[@"systemBuild"] isKindOfClass:NSString.class] && [baseline[@"systemBuild"] length] > 0 &&
         CCNMValidateBandDictionary(baseline[@"supportedBands"], failure) &&
         [baseline[@"modifiedBandKeys"] isKindOfClass:NSArray.class] &&
         [baseline[@"modifiedBandKeys"] count] == 1 &&
         [baseline[@"modifiedBandKeys"][0] isEqual:CCNMNRKey]);
    BOOL valid = [baseline isKindOfClass:[NSDictionary class]] &&
        [baseline[@"schemaVersion"] isEqual:@1] &&
        [baseline[@"owner"] isEqual:CCNMPolicyOwner] &&
        [baseline[@"kind"] isEqual:@"baseline"] &&
        [baseline[@"createdAt"] isKindOfClass:[NSNumber class]] && [baseline[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(baseline[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(baseline[@"operationGeneration"]) && [baseline[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        CCNMValidSlotID(baseline[@"slotID"]) &&
        CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]) != nil &&
        capabilitySnapshotValid && CCNMValidateBandDictionary(bands, failure);
    if (!valid && failure && !*failure) {
        *failure = @"The durable policy baseline is malformed, foreign, or has invalid capability evidence.";
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
    NSNumber *slotID = [baseline[@"slotID"] isKindOfClass:NSNumber.class]
        ? baseline[@"slotID"] : nil;
    BOOL enable = [operation isEqual:@"enable"];
    BOOL payloadValid = enable
        ? (CCNMBuildSelectedNRPayload(active, supported, requested[CCNMNRKey], failure) != nil &&
           CCNMValidateSelectedNRIntentPayload(active, supported, requested, failure))
        : CCNMValidateRestorePayload(active, baseline[@"activeBands"], requested, failure);
    if (!uuid || !CCNMValidSlotID(slotID) || !payloadValid) {
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
        @"slotID": slotID,
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
    // knownOrphanRecovery has no producer in this build. It stays in the domain
    // because 1.5.0 shipped, and a 1.5.0 device that crashed or lost a setter
    // outcome mid-replay has an intent record on disk naming it. Rejecting the
    // name would classify our own former record as foreign, and the consequence
    // is not cosmetic: an invalid record makes performRestoreOperation refuse too, so
    // the one escape hatch that could clear the record would be the thing the
    // record disables. Read-side compatibility only -- see the operation domain
    // in CCNMValidateInFlightRecord, which must stay identical.
    BOOL header = [intent isKindOfClass:[NSDictionary class]] &&
        [intent[@"schemaVersion"] isEqual:@1] &&
        [intent[@"owner"] isEqual:CCNMPolicyOwner] &&
        [intent[@"kind"] isEqual:@"intent"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"] containsObject:operation ?: @""] &&
        [intent[@"createdAt"] isKindOfClass:[NSNumber class]] && [intent[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(intent[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(intent[@"operationGeneration"]) && [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [intent[@"slotID"] isEqual:baseline[@"slotID"]] &&
        [CCNMCanonicalUUIDString(intent[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [intent[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
        [intent[@"baselineGeneration"] isEqual:baseline[@"operationGeneration"]] &&
        CCNMDictionariesEqual(intent[@"baselineActiveBands"], baseline[@"activeBands"]) &&
        CCNMValidateBandDictionary(active, failure) && CCNMValidateBandDictionary(supported, failure);
    BOOL payload = NO;
    if (header && [operation isEqual:@"enable"]) {
        payload = CCNMValidateSelectedNRIntentPayload(active, supported, requested, failure);
    } else if (header) {
        // Every other operation, retired knownOrphanRecovery included, wrote a
        // restore-shaped payload: the baseline's activeBands resent unchanged.
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
    NSNumber *slotID = [baseline[@"slotID"] isKindOfClass:NSNumber.class]
        ? baseline[@"slotID"] : nil;
    if (!bootSession || !uuid || !CCNMValidSlotID(slotID)) {
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
        @"slotID": slotID,
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
        [record[@"slotID"] isEqual:baseline[@"slotID"]] &&
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

static BOOL CCNMIsVerifiedRestoreCleanupCheckpoint(NSDictionary *state);

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
    // The applied selection, published only for a stable enabled state. The
    // daemon and the settings pane both need it, and CCNMSummaryFromState is the
    // only thing either of them reads, so without this the recorded selection is
    // invisible outside this file. It is deliberately omitted rather than
    // defaulted while a transition is in flight: during an enable the modem does
    // not yet hold the selection, and during a disable it no longer does, so any
    // value here would be a claim the state record cannot support.
    NSArray *appliedSelection = normalEnabled
        ? CCNMCanonicalNRSelection(base[@"targetNRBands"], NULL) : nil;
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
        CCNMN78PolicySummaryMayWriteKey: @((normalDefault || normalEnabled) && !requiresReboot),
        CCNMN78PolicySummaryMayUninstallKey: @(normalDefault),
        CCNMN78PolicySummaryCleanupCheckpointRecoverableKey: @NO,
        @"baselinePresent": @(baselinePresent),
        @"baselineValid": @(baselineValid),
        @"transitionPresent": @(transitionPresent),
        @"legacyRemovalGuardPresent": @(CCNMFileExists(CCNMN78PolicyRemovalGuardPath())),
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO,
        @"statePath": CCNMN78PolicyStatePath(),
        @"baselinePath": CCNMN78PolicyBaselinePath(),
        @"intentPath": CCNMN78PolicyIntentPath(),
        @"inFlightPath": CCNMN78PolicyInFlightPath(),
        @"lockPath": CCNMN78PolicyLockPath(),
        @"legacyRemovalGuardPath": CCNMN78PolicyRemovalGuardPath()
    } mutableCopy];
    if (appliedSelection) {
        summary[CCNMN78PolicySummaryTargetNRBandsKey] = appliedSelection;
    }
    if (details) {
        [summary addEntriesFromDictionary:details];
    }
    return [summary copy];
}

static NSDictionary *CCNMReadPolicyStateInternal(void) {
    BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO;
    NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
    NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
    NSDictionary *intent = CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
    NSDictionary *inFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);

    if (!stateExists && !baselineExists && !intentExists && !inFlightExists) {
        return CCNMSummaryFromState(CCNMDefaultState(), YES, @"read", CCNMN78PolicyErrorNone, @"", nil);
    }
    if ((stateExists && !CCNMValidateStateRecord(state, NULL)) ||
        (baselineExists && !CCNMValidateBaselineRecord(baseline, NULL)) ||
        (intentExists && (!baseline || !CCNMValidateIntentRecord(intent, baseline, NULL))) ||
        (inFlightExists && (!baseline || !CCNMValidateInFlightRecord(inFlight, baseline, intent, intentExists, NULL)))) {
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
    if (!baselineExists && !intentExists && !inFlightExists &&
        CCNMBootRelationForRecord(state) == CCNMBootRelationEarlier &&
        CCNMIsVerifiedRestoreCleanupCheckpoint(state)) {
        return CCNMSummaryFromState(state, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired,
            @"The modem restore was verified; durable cleanup remains pending.",
            @{CCNMN78PolicySummaryCleanupCheckpointRecoverableKey: @YES});
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

    if ([state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetPending] ||
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetFailed]) {
        // Neither state has a producer any more: 1.6.0's CommCenter-reload recovery
        // was retired once the target device showed it does not restore the bands.
        // They stay readable because that build shipped, and a device that pressed
        // the reload has one of them on disk right now. Report it from the state
        // record itself rather than letting it fall through to the enabled/clean
        // classification below, which would misread it as settled -- these records
        // own no transition files, so the branch above cannot see them.
        return CCNMSummaryFromState(state, NO, @"read",
            state[@"errorCode"] ?: CCNMN78PolicyErrorCarrierResetFailed,
            state[@"error"], nil);
    }

    BOOL enabled = [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] && baselineExists &&
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
        if (CCNMValidSlotID(baseline[@"slotID"])) {
            extra[@"slotID"] = baseline[@"slotID"];
        }
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

// Collects what device this is, for the record. No verdict.
static void CCNMRecordDeviceIdentity(NSMutableDictionary *details,
                                     NSString *model,
                                     NSString *build,
                                     NSString *version) {
    if (!details) {
        return;
    }
    details[@"deviceModel"] = model ?: @"";
    details[@"systemBuild"] = build ?: @"";
    details[@"systemVersion"] = version ?: @"";
}

static NSString *CCNMSystemVersionString(void) {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:@"%ld.%ld.%ld",
        (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion];
}

// Reads and records identity without using a model or OS allowlist as a
// capability verdict. The durable baseline still requires all three values.
static BOOL CCNMValidateTargetIdentity(NSMutableDictionary *details, NSString **failure) {
    NSString *model = CCNMSysctlString("hw.machine");
    NSString *build = CCNMSysctlString("kern.osversion");
    NSString *version = CCNMSystemVersionString();
    CCNMRecordDeviceIdentity(details, model, build, version);
    if (!model.length || !build.length || !version.length) {
        if (failure) {
            *failure = @"The device identity required by a durable baseline could not be read.";
        }
        return NO;
    }
    return YES;
}

// Gate for the one modem write this build performs: enable.
//
// Every byte it writes originated on the device receiving it. Enable reads live
// BandInfo and resends it with only the NR array narrowed, so the capability
// checks are runtime checks: ABI validation, an unambiguous subscription,
// complete fresh BandInfo, the selected bands present in both fresh active and
// supported NR arrays, and durable baseline/read-back validation. No model or OS
// allowlist is needed, and none is used.
//
// Undoing an enable is no longer a write. Disable and recover both reload carrier
// defaults, which discards the whole carrier configuration and so needs no record
// of what was narrowed -- which is also why the second gate that used to live
// here is gone. It guarded a historical-replay path carrying a reviewed BandInfo
// table captured from one device, and that was the only caller that ever wrote
// bands it had not read from the device in front of it.
//
// Kept as a named wrapper rather than folded into CCNMValidateTargetIdentity: the
// name records the invariant that every write in this build is self-sourced, and
// it is where a second gate would go if a path that is not ever returns.
static BOOL CCNMValidateSelfSourcedWriteTarget(NSMutableDictionary *details, NSString **failure) {
    return CCNMValidateTargetIdentity(details, failure);
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

// Renders what each subscription slot actually reported, so a refusal can name
// the observed layout instead of restating the rule that was violated. The write
// gate is the only place a user meets this, and a rule restatement does not tell a
// dual-line user which of their two lines is the problem.
static NSString *CCNMSubscriptionLayoutSummary(NSArray *reports) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *report in reports) {
        if (![report isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *uuid = [report[@"subscriptionUUID"] isKindOfClass:NSString.class]
            ? report[@"subscriptionUUID"] : @"";
        [parts addObject:[NSString stringWithFormat:@"slot%@ %@ %@ %@",
            report[@"slotID"],
            [report[@"isSimPresent"] boolValue] ? @"present" : @"absent",
            [report[@"isSimGood"] boolValue] ? @"good" : @"notGood",
            uuid.length > 0 ? @"hasUUID" : @"noUUID"]];
    }
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"no subscriptions";
}

// CoreTelephony's own answer to "which subscription is the data line". Used only
// to choose between several writable SIMs, and only on a first enable, where
// nothing has been recorded yet.
//
// Every no-answer path returns nil with a reason instead of a fallback guess,
// because this decides where a modem write lands. "CoreTelephony has no opinion"
// and "CoreTelephony named a line" must stay distinguishable; the read-only
// serving provider can afford to degrade quietly here, a write cannot.
//
// Runs on the caller's own client. The serving provider has an equivalent probe,
// but borrowing its client would reach across the shared modem lock domain.
static NSString *CCNMCurrentDataLineUUID(id<CCNMCoreTelephonyClient> client, NSString **reason) {
    SEL selector = @selector(getCurrentDataSubscriptionContextSync:);
    if (!CCNMValidateObjectErrorABI(client, selector, 0, NULL)) {
        if (reason) {
            *reason = @"this build of CoreTelephony does not vend a usable data-line query";
        }
        return nil;
    }
    NSError *error = nil;
    id context = nil;
    @try {
        context = [client getCurrentDataSubscriptionContextSync:&error];
    } @catch (NSException *exception) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"the data-line query raised %@", exception.name];
        }
        return nil;
    }
    if (error) {
        if (reason) {
            *reason = @"the data-line query returned an error";
        }
        return nil;
    }
    if (!context || ![context respondsToSelector:@selector(uuid)]) {
        if (reason) {
            *reason = @"the data-line query named no subscription";
        }
        return nil;
    }
    id rawUUID = [context uuid];
    NSString *uuid = [rawUUID isKindOfClass:[NSUUID class]] ? [(NSUUID *)rawUUID UUIDString] : nil;
    if (!uuid && reason) {
        *reason = @"the reported data line carries no stable UUID";
    }
    return uuid;
}

// How a write target may be obtained. Passed explicitly at every call site rather
// than inferred from whether the recorded fields happen to be nil, because a
// record written before those fields existed carries nothing, and inferring
// "choose freely" from "nothing recorded" is how a reconciliation of an old
// checkpoint would end up re-picking a different line on a dual-SIM phone.
typedef NS_ENUM(NSUInteger, CCNMTargetResolution) {
    // Confirms the target a durable record already names. Never chooses.
    CCNMTargetResolutionRecorded = 0,
    // Chooses a target. Legal only on a first enable, where nothing is recorded.
    CCNMTargetResolutionFirstEnable = 1
};

// Resolves the subscription a modem write may target.
//
// In CCNMTargetResolutionRecorded the caller already has a target and this only
// confirms it is still present; nothing is chosen. A legacy record naming neither
// an identity nor a slot still resolves only on a phone holding a single SIM,
// which is the one case with no choice to make.
//
// In CCNMTargetResolutionFirstEnable the target is picked: the sole present line,
// or on a dual-SIM device the line CoreTelephony itself reports as the data line.
// Ambiguity is refused rather than resolved by a guess.
//
// Keeping these apart is the safety property on a dual-SIM phone. The data line is
// a runtime property and moves on its own, so it may pick a target but must never
// validate one; a later revalidation or restore that consulted it would walk away
// from the subscription the policy was actually written to. The recorded identity
// is the binding key precisely because it does not move.
static id<CCNMSubscriptionContext> CCNMSafeTargetContext(id<CCNMCoreTelephonyClient> client,
                                                          CCNMTargetResolution resolution,
                                                          NSString *requiredUUID,
                                                          NSNumber *requiredSlotID,
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
    NSMutableArray *writable = [NSMutableArray array];
    NSUInteger presentCount = 0;
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
        if (slot > 0 && present && good && uuid.length > 0) {
            [writable addObject:context];
        }
    }
    if (details) {
        details[@"subscriptions"] = reports;
    }
    // Indexed only after the whole layout is known, so a refusal can report every
    // slot rather than the prefix scanned so far.
    NSString *observedLayout = CCNMSubscriptionLayoutSummary(reports);
    NSMutableDictionary *candidateByUUID = [NSMutableDictionary dictionary];
    NSMutableDictionary *candidateBySlot = [NSMutableDictionary dictionary];
    for (id<CCNMSubscriptionContext> context in writable) {
        NSString *uuid = [[context uuid] UUIDString];
        NSNumber *slot = @([context slotID]);
        // Two lines reporting the same slot or the same identity would make every
        // lookup below silently pick one of them. Nothing legitimate produces that
        // shape, so refuse rather than resolve it.
        if (!uuid || candidateByUUID[uuid] || candidateBySlot[slot]) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"Two subscriptions report the same slot or identity (%@).", observedLayout];
            }
            return nil;
        }
        candidateByUUID[uuid] = context;
        candidateBySlot[slot] = context;
    }

    // A recorded target is looked up, never re-chosen.
    BOOL hasRecordedTarget = requiredUUID.length > 0 || requiredSlotID != nil;
    if (resolution == CCNMTargetResolutionFirstEnable && hasRecordedTarget) {
        // A caller that has a recorded target must confirm it, not re-pick.
        if (failure) {
            *failure = @"A recorded write target cannot be reselected.";
        }
        return nil;
    }
    BOOL requiredSlotValid = !requiredSlotID || CCNMValidSlotID(requiredSlotID);
    NSString *required = requiredUUID.length ? CCNMCanonicalUUIDString(requiredUUID) : nil;
    if (!requiredSlotValid) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The recorded target slot %@ is not a valid slot identifier.", requiredSlotID];
        }
        return nil;
    }
    if (requiredUUID.length && !required) {
        if (failure) {
            *failure = @"The recorded target subscription identity is malformed.";
        }
        return nil;
    }
    if (writable.count == 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"No SIM can take a modem write; a present and good SIM with a stable UUID "
                 "in a positive slot is required (%@).", observedLayout];
        }
        return nil;
    }

    id<CCNMSubscriptionContext> target = nil;
    NSString *selection = nil;
    if (required) {
        target = candidateByUUID[required];
        selection = @"recordedIdentity";
        if (!target) {
            if (failure) {
                // Distinguish a swapped SIM from a missing one. A different
                // identity sitting in the recorded slot means the card was
                // replaced; nothing there at all means it was removed or has
                // gone bad, and only the second case can be fixed by putting
                // the original card back. The UUID itself is never printed.
                if (requiredSlotID && candidateBySlot[requiredSlotID]) {
                    *failure = [NSString stringWithFormat:
                        @"The subscription UUID in slot %@ no longer matches the recorded target (%@).",
                        requiredSlotID, observedLayout];
                } else {
                    *failure = [NSString stringWithFormat:
                        @"The recorded target subscription is not a writable line on this device (%@).",
                        observedLayout];
                }
            }
            return nil;
        }
    } else if (requiredSlotID) {
        // A record written before the identity field existed pins only a slot.
        target = candidateBySlot[requiredSlotID];
        selection = @"recordedSlot";
        if (!target) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"The recorded target slot %@ has no writable subscription (%@).",
                    requiredSlotID, observedLayout];
            }
            return nil;
        }
    } else if (presentCount == 1) {
        // Only one SIM is in the phone, so there is nothing to disambiguate. This
        // serves both a first enable and a legacy record that named no target at
        // all: in neither case is a choice being made.
        target = writable.firstObject;
        selection = @"onlyPresentLine";
    } else if (resolution != CCNMTargetResolutionFirstEnable) {
        // A record predating the identity fields, on a phone holding more than one
        // SIM. There is no way to tell which line it described, and picking the
        // current data line would be a guess about history rather than a lookup.
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"The stored policy record names no subscription and %lu SIMs are present, "
                 "so the line it was written for cannot be identified (%@).",
                (unsigned long)presentCount, observedLayout];
        }
        return nil;
    } else {
        // More than one SIM is in the phone and this is a first enable, so the
        // target comes from CoreTelephony's own answer to "which subscription is the
        // data line". A guess is not acceptable here: the wrong choice writes the
        // modem of a line the user did not intend and records that line as the thing
        // restore must find later.
        //
        // The presence count decides that this branch is needed, not the writable
        // count. If the data line happens to be the unwritable one, falling through
        // to the other line would quietly apply the preference to a line the user was
        // not asking about, so that case is refused rather than resolved.
        NSString *unavailable = nil;
        NSString *dataLineUUID = CCNMCurrentDataLineUUID(client, &unavailable);
        target = dataLineUUID ? candidateByUUID[dataLineUUID] : nil;
        selection = @"reportedDataLine";
        if (!target) {
            if (failure) {
                *failure = dataLineUUID
                    ? [NSString stringWithFormat:
                        @"%lu SIMs are present and the reported data line cannot take a modem "
                         "write (%@).", (unsigned long)presentCount, observedLayout]
                    : [NSString stringWithFormat:
                        @"%lu SIMs are present and the data line could not be identified: "
                         "%@ (%@).", (unsigned long)presentCount,
                        unavailable ?: @"no reason was reported", observedLayout];
            }
            return nil;
        }
    }

    NSString *uuid = [[target uuid] UUIDString];
    NSNumber *slotID = @([target slotID]);
    if (!uuid || !CCNMValidSlotID(slotID)) {
        if (failure) {
            *failure = @"The selected subscription no longer reports a usable identity.";
        }
        return nil;
    }
    if (requiredSlotID && ![slotID isEqual:requiredSlotID]) {
        if (failure) {
            // Reachable only through identity lookup, so the card itself is the
            // recorded one and it moved. A slot-pinned lookup cannot land here.
            *failure = [NSString stringWithFormat:
                @"The target SIM moved: expected slot %@, found slot %@.",
                requiredSlotID, slotID];
        }
        return nil;
    }
    if (details) {
        details[@"targetSubscriptionUUID"] = uuid;
        details[@"targetSlotID"] = slotID;
        details[@"targetSelection"] = selection ?: @"unknown";
        details[@"presentSubscriptionCount"] = @(presentCount);
        details[@"writableSubscriptionCount"] = @(writable.count);
        details[@"targetWasRecorded"] = @(hasRecordedTarget);
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
        "com.doimty.nrmanager.n78-policy.setter", DISPATCH_QUEUE_SERIAL);
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
                                          NSNumber *slotID,
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
        id<CCNMSubscriptionContext> context = CCNMSafeTargetContext(
            client, CCNMTargetResolutionRecorded, subscriptionUUID, slotID, nil,
            &identityFailure);
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
    // The applied selection is read out of the verified read-back rather than
    // passed in separately. Reaching this function means the read-back equalled
    // the payload exactly, so this array is the selection the modem confirmed,
    // already ascending. Canonicalising it again is a fail-closed check, not a
    // transformation: a record is the only thing the daemon can later compare
    // live NR against, so it must not be written from an unverified source.
    NSString *selectionFailure = nil;
    NSArray *selection = CCNMCanonicalNRSelection(verifiedBands[CCNMNRKey], &selectionFailure);
    if (!selection || ![selection isEqualToArray:verifiedBands[CCNMNRKey]]) {
        if (failure) {
            *failure = selectionFailure ?:
                @"The verified NR read-back is not a canonical band selection.";
        }
        return NO;
    }
    NSDictionary *proof = @{
        @"baselineCreatedAt": baseline[@"createdAt"],
        @"slotID": baseline[@"slotID"],
        @"readBackVerified": @YES,
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands,
        @"targetNRBands": selection,
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

static BOOL CCNMPersistOrReplaceTransition(NSDictionary *oldRecord,
                                           NSDictionary *newRecord,
                                           NSString *path,
                                           NSString **failure) {
    return oldRecord
        ? CCNMReplaceExpectedRecord(oldRecord, newRecord, path, failure)
        : CCNMCreateDurableRecord(newRecord, path, failure);
}

// Builds the exact payload a restore writes: the live dictionary with the NR
// array replaced by the saved one, and every other RAT left byte-identical.
// The package narrowed one key, so it puts back one key.
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

// True for the one state a restore can be resumed from after a reboot: the
// read-back already matched, the baseline was already retired, and only the
// final state rewrite was lost. Reaching it again must not issue a second write.
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

static BOOL CCNMBaselineNRBandsFitCurrentCapability(NSArray *savedNR,
                                                    NSArray *currentSupportedNR,
                                                    NSString *unsupportedFailure,
                                                    NSString **failure) {
    if (![savedNR isKindOfClass:NSArray.class] || ![currentSupportedNR isKindOfClass:NSArray.class]) {
        if (failure) {
            *failure = @"The retained baseline NR capability evidence is unavailable on this system.";
        }
        return NO;
    }
    for (NSNumber *band in savedNR) {
        if (![currentSupportedNR containsObject:band]) {
            if (failure) {
                *failure = unsupportedFailure;
            }
            return NO;
        }
    }
    return YES;
}

static BOOL CCNMValidateBaselineCompatibility(NSDictionary *baseline,
                                              NSDictionary *currentSupportedBands,
                                              NSDictionary *identity,
                                              NSString **failure) {
    BOOL hasCapabilitySnapshot = baseline[@"deviceModel"] != nil ||
        baseline[@"systemVersion"] != nil || baseline[@"systemBuild"] != nil ||
        baseline[@"supportedBands"] != nil || baseline[@"modifiedBandKeys"] != nil;
    // Keyed subscripting a non-dictionary raises, and this bundle loads into
    // SpringBoard. CCNMValidateBaselineRecord runs first in the current callers,
    // but this check must not depend on that ordering.
    NSDictionary *savedActive = [baseline[@"activeBands"] isKindOfClass:NSDictionary.class]
        ? baseline[@"activeBands"] : nil;
    NSDictionary *currentSupported = [currentSupportedBands isKindOfClass:NSDictionary.class]
        ? currentSupportedBands : nil;
    if (!savedActive || !currentSupported ||
        !CCNMValidateBandDictionary(savedActive, failure) ||
        !CCNMValidateBandDictionary(currentSupported, failure)) {
        if (failure && !*failure) {
            *failure = @"The retained baseline or current capability evidence is unavailable.";
        }
        return NO;
    }
    // Do not require saved active NR to be a subset of supported NR. The modem's
    // BandInfo contract permits an active list to contain values absent from its
    // supported list, and the target device's own verified restore read-back had
    // exactly that shape. The saved capability snapshot is the evidence that can
    // be compared across the restore boundary.
    if (!hasCapabilitySnapshot) {
        // Written before capability evidence existed. Refusing it is not an
        // option: a baseline is the only way back from an enable, so refusing one
        // for lacking a field that did not exist when it was written would strand
        // the device it was written to protect.
        return YES;
    }
    // Same hardware. System version and build stay recorded evidence rather than
    // a gate: an iOS update does not invalidate a rollback whose capability shape
    // and owned-band evidence still fit, and refusing on build alone would strand
    // every device that updates while the policy is enabled.
    BOOL sameDevice = [baseline[@"deviceModel"] isEqual:identity[@"deviceModel"]];
    NSDictionary *savedSupported = [baseline[@"supportedBands"] isKindOfClass:NSDictionary.class]
        ? baseline[@"supportedBands"] : nil;
    BOOL sameCapabilityShape = savedSupported &&
        [[NSSet setWithArray:savedSupported.allKeys] isEqualToSet:
            [NSSet setWithArray:currentSupported.allKeys]];
    NSArray *ownedKeys = baseline[@"modifiedBandKeys"];
    BOOL ownedFieldsValid = [ownedKeys isKindOfClass:NSArray.class] &&
        ownedKeys.count == 1 && [ownedKeys.firstObject isEqual:CCNMNRKey];
    if (!sameDevice || !sameCapabilityShape || !ownedFieldsValid) {
        if (failure) {
            *failure = @"The retained baseline belongs to a different device, capability shape, or owned-band set.";
        }
        return NO;
    }
    return CCNMBaselineNRBandsFitCurrentCapability(savedSupported[CCNMNRKey],
        currentSupported[CCNMNRKey],
        @"The retained baseline contains an owned band unsupported by the current system.", failure);
}

// Retires an enable in two durable steps. The intermediate restorePending
// checkpoint is what makes a crash between "baseline deleted" and "state says
// clean" recoverable: CCNMIsVerifiedRestoreCleanupCheckpoint recognises it and
// finishes without a second write.
static BOOL CCNMFinishSystemDefaultState(NSUInteger generation,
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
        @"slotID": baseline[@"slotID"],
        @"readBackVerified": @YES,
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands
    };
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
    if (!CCNMRetireTransitionRecords(intent, inFlight, failure)) {
        return NO;
    }
    if (!CCNMRemoveExpectedRecord(baseline, CCNMN78PolicyBaselinePath(), failure)) {
        return NO;
    }
    // Opportunistic migration cleanup, and only that. The removal-guard file was
    // armed by a version that asked a compiled prerm whether a saved BandInfo
    // could be replayed; nothing reads it now, and the shell removal deletes it
    // with the other records. A device that never removes the package would keep
    // it forever, and it is stale the moment the modem is back at system default.
    //
    // Deliberately not a failure condition and deliberately not a verdict: this is
    // the file whose mere presence a retired mechanism treated as permission, so
    // the only thing done with it here is deletion.
    if (CCNMFileExists(CCNMN78PolicyRemovalGuardPath())) {
        (void)unlink(CCNMN78PolicyRemovalGuardPath().fileSystemRepresentation);
        (void)CCNMSyncParentDirectory(CCNMN78PolicyRemovalGuardPath(), NULL);
    }
    NSDictionary *finalProof = @{
        @"verifiedAt": verifiedAt,
        @"verifiedActiveBands": verifiedBands,
        @"restoredBaselineCreatedAt": baseline[@"createdAt"],
        @"slotID": baseline[@"slotID"]
    };
    NSDictionary *state = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
        CCNMAppliedPolicyVerifiedSystemDefault, CCNMRecoveryStateClean,
        generation, subscriptionUUID, NO, CCNMN78PolicyErrorNone, @"",
        finalProof, failure);
    return state && CCNMReplaceExpectedRecord(checkpoint, state, CCNMN78PolicyStatePath(), failure);
}

@interface CCNMN78PolicyController ()
@property (nonatomic, strong) dispatch_queue_t operationQueue;

// Declared here because performDisable and performRecovery call it before it is
// defined. Clang resolves same-@implementation methods regardless of order, but
// the declaration also states the contract in one place: both callers differ only
// in the operation name they record and in whether incomplete evidence is
// acceptable.
- (NSDictionary *)performRestoreOperation:(NSString *)operation
                  allowIncompleteEvidence:(BOOL)allowIncomplete;
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
        _operationQueue = dispatch_queue_create("com.doimty.nrmanager.n78-policy", DISPATCH_QUEUE_SERIAL);
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
        BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO;
        NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
        CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
        CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
        CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
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
        if (!CCNMValidateSelfSourcedWriteTarget(details, &failure)) {
            return CCNMErrorSummary(@"enable", CCNMN78PolicyErrorUnsupportedTarget, failure, details);
        }
        id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
        id<CCNMSubscriptionContext> context = client
            ? CCNMSafeTargetContext(client, CCNMTargetResolutionFirstEnable, nil, nil,
                details, &failure) : nil;
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
        NSArray<NSNumber *> *selection = CCNMReadSelectedNRBands();
        NSDictionary *payload = CCNMBuildSelectedNRPayload(initial[@"activeBands"],
            initial[@"supportedBands"], selection, &failure);
        if (!payload) {
            // "not within" is the multi-band generalisation of the old
            // "n78 is not present" case: a selected band the system no longer
            // allows. The wire value is unchanged so existing UI keeps working.
            CCNMN78PolicyErrorCode code = [failure containsString:@"not within"] ||
                [failure containsString:@"No NR band"]
                ? CCNMN78PolicyErrorN78Unavailable : CCNMN78PolicyErrorInvalidBandInfo;
            return CCNMErrorSummary(@"enable", code, failure, details);
        }

        baseline = CCNMBuildBaselineRecord(
            initial[@"activeBands"], initial[@"supportedBands"], @[ CCNMNRKey ], details,
            subscriptionUUID, details[@"targetSlotID"], generation, &failure);
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

        context = CCNMSafeTargetContext(client, CCNMTargetResolutionRecorded,
            subscriptionUUID, baseline[@"slotID"], details, &failure);
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
        payload = CCNMBuildSelectedNRPayload(fresh[@"activeBands"], fresh[@"supportedBands"],
            selection, &failure);
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
            @{ @"baselineCreatedAt": baseline[@"createdAt"], @"slotID": baseline[@"slotID"] }, &failure);
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

        context = CCNMSafeTargetContext(client, CCNMTargetResolutionRecorded,
            subscriptionUUID, baseline[@"slotID"], details, &failure);
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

        NSDictionary *readBack = CCNMWaitForReadBack(client, subscriptionUUID, baseline[@"slotID"], payload);
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

// Returns the device to the band configuration that was saved before the enable.
//
// The recovery primitive is a reverse setActiveBandInfo: write of the retained
// baseline, not a CommCenter reload. 1.6.0 shipped the reload instead, on the
// assumption that killing CommCenter makes the modem reload carrier defaults.
// The target device disproved it: the bands stayed narrowed. The reverse write is
// the mechanism that has actually been observed to work there, so it is back.
//
// The write is exactly one array wide. CCNMBuildRestorePayload replaces the NR
// key with the saved one and leaves every other RAT byte-identical, which is the
// mirror of what the enable narrowed, and CCNMValidateRestorePayload refuses
// anything else.
//
// `allowIncompleteEvidence` separates the two callers. Disable is the toggle-off
// of a settled enabled state and refuses anything else. Recover is the explicit
// recovery action and accepts a wider set of record shapes, but only ones whose
// evidence is old enough to be safe: transition evidence from this boot means an
// earlier setter call may still be outstanding, and no amount of new writing
// makes that safe.
- (NSDictionary *)performRestoreOperation:(NSString *)operation
                  allowIncompleteEvidence:(BOOL)allowIncomplete {
    NSMutableDictionary *details = [@{ @"setterAttempted": @NO } mutableCopy];
    NSString *failure = nil;
    int lockDescriptor = CCNMAcquirePolicyLock(&failure);
    if (lockDescriptor < 0) {
        return CCNMErrorSummary(operation, CCNMN78PolicyErrorBusy, failure, details);
    }
    @try {
        @synchronized([CCNMN78PolicyController class]) {
            if (CCNMSetterUncertainLatch) {
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorSetterUncertain,
                    @"A setter outcome is uncertain in this process; reboot before recovery.", details);
            }
        }

        BOOL stateExists = NO, baselineExists = NO, intentExists = NO, inFlightExists = NO;
        NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
        NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
        NSDictionary *oldIntent = CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
        NSDictionary *oldInFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
        if ((stateExists && !CCNMValidateStateRecord(state, &failure)) ||
            (baselineExists && !CCNMValidateBaselineRecord(baseline, &failure)) ||
            (intentExists && (!baseline || !CCNMValidateIntentRecord(oldIntent, baseline, &failure))) ||
            (inFlightExists && (!baseline || !CCNMValidateInFlightRecord(oldInFlight, baseline, oldIntent, NO, &failure)))) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Recovery evidence is malformed or foreign and was preserved.", details);
        }
        state = state ?: CCNMDefaultState();

        if (!baselineExists) {
            // Nothing was narrowed, or the narrowing was already undone. Both are
            // success for a restore; there is nothing to write.
            if (!intentExists && !inFlightExists &&
                [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
                [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
                [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean]) {
                details[@"writeNotNeeded"] = @YES;
                return CCNMSummaryFromState(state, YES, operation, CCNMN78PolicyErrorNone, @"", details);
            }
            // The one resumable case: a previous restore verified its read-back
            // and retired the baseline, then lost the final state rewrite. The
            // modem is already restored, so this finishes the bookkeeping and
            // deliberately issues no second write. It is gated on the evidence
            // being from an earlier boot and on the live bands still equalling
            // the ones that read-back verified.
            if (allowIncomplete && !intentExists && !inFlightExists &&
                CCNMBootRelationForRecord(state) == CCNMBootRelationEarlier &&
                CCNMIsVerifiedRestoreCleanupCheckpoint(state)) {
                NSUInteger generation = CCNMNextGeneration(state, nil);
                if (!CCNMValidateSelfSourcedWriteTarget(details, &failure)) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorUnsupportedTarget, failure, details);
                }
                id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
                id<CCNMSubscriptionContext> context = client
                    ? CCNMSafeTargetContext(client, CCNMTargetResolutionRecorded,
                        state[@"subscriptionUUID"], state[@"slotID"], details, &failure) : nil;
                NSDictionary *fresh = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
                if (!fresh || !CCNMDictionariesEqual(fresh[@"activeBands"], state[@"verifiedActiveBands"])) {
                    failure = failure ?: @"Live modem BandInfo no longer matches the verified restore cleanup checkpoint.";
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
                }
                // The slot comes from the subscription just revalidated above, not
                // from the checkpoint: a state written before the slot field existed
                // has no slot at all, and defaulting that to 1 would record a slot
                // this device was never observed on. The UUID below is sourced the
                // same way. CCNMSafeTargetContext publishes both once it returns a
                // context, and a nil context cannot reach this point, but a nil in a
                // dictionary literal would raise inside Preferences, so verify it
                // and fail closed rather than depend on the invariant.
                NSNumber *cleanupSlotID = [details[@"targetSlotID"] isKindOfClass:NSNumber.class]
                    ? details[@"targetSlotID"] : nil;
                if (!CCNMValidSlotID(cleanupSlotID)) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorUnsafeSubscription,
                        @"The revalidated subscription slot is unavailable.", details);
                }
                details[@"writeNotNeeded"] = @YES;
                NSDictionary *clean = CCNMBuildStateRecord(CCNMRequestedModeSystemDefault,
                    CCNMAppliedPolicyVerifiedSystemDefault, CCNMRecoveryStateClean,
                    generation, details[@"targetSubscriptionUUID"], NO,
                    CCNMN78PolicyErrorNone, @"", @{
                        @"verifiedAt": state[@"verifiedAt"],
                        @"verifiedActiveBands": state[@"verifiedActiveBands"],
                        @"restoredBaselineCreatedAt": state[@"baselineCreatedAt"],
                        @"slotID": cleanupSlotID
                    }, &failure);
                if (!clean || !CCNMPersistState(clean, &failure)) {
                    return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
                }
                return CCNMSummaryFromState(clean, YES, operation, CCNMN78PolicyErrorNone, @"", details);
            }
            // No baseline and no resumable checkpoint. There is no honest way to
            // choose a payload, so nothing is written and the records are kept.
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                @"A required policy baseline is missing; no modem write was issued.", details);
        }

        BOOL stableEnabled = stateExists && !intentExists && !inFlightExists &&
            [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
            [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
            [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
            [state[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
            [CCNMCanonicalUUIDString(state[@"subscriptionUUID"])
                isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
            ![state[@"uncertain"] boolValue];
        if (!allowIncomplete && !stableEnabled) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                @"Disable requires a verified enabled state with its exact retained baseline and no transition records.",
                details);
        }
        if (allowIncomplete && !stableEnabled) {
            // Transition evidence from this boot means an earlier setter call may
            // still be outstanding. A second write cannot make that safe, so the
            // only correct answer is a reboot.
            //
            // The two carrier-reset states are exempt, and the exemption is about
            // what they can prove rather than about their age. 1.6.0's reload path
            // issued no modem write at all, so a state record naming it cannot be
            // hiding an outstanding setter call. Treating it like one would strand
            // exactly the devices that build left narrowed: they would have to
            // reboot before the restore they need becomes available, for evidence
            // that provably has no write behind it.
            BOOL resetStateOwnsNoModemWrite =
                [state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetPending] ||
                [state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetFailed];
            BOOL inFlightMayBeCurrent = inFlightExists &&
                CCNMBootRelationForRecord(oldInFlight) != CCNMBootRelationEarlier;
            BOOL intentMayBeCurrent = intentExists &&
                CCNMBootRelationForRecord(oldIntent) != CCNMBootRelationEarlier;
            BOOL pendingStateMayBeCurrent = stateExists && !resetStateOwnsNoModemWrite &&
                (![state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] ||
                 [state[@"uncertain"] boolValue]) &&
                CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier;
            BOOL baselineOnlyMayBeCurrent = !intentExists && !inFlightExists &&
                CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier;
            if (inFlightMayBeCurrent || intentMayBeCurrent || pendingStateMayBeCurrent ||
                baselineOnlyMayBeCurrent) {
                CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeSystemDefault,
                    CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                    [state[@"operationGeneration"] unsignedIntegerValue], baseline[@"subscriptionUUID"],
                    CCNMN78PolicyErrorRecoveryRequired,
                    @"Incomplete or uncertain transition evidence belongs to this boot; reboot before recovery.",
                    baseline, YES);
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                    @"Incomplete or uncertain transition evidence belongs to this boot; reboot before recovery.",
                    details);
            }
        }

        NSUInteger generation = CCNMNextGeneration(state, oldIntent);
        NSString *subscriptionUUID = CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]);
        if (generation == 0 || !CCNMBootSessionIdentity()) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorRecoveryRequired,
                @"A valid boot identity and new operation generation are required.", details);
        }
        if (!CCNMValidateSelfSourcedWriteTarget(details, &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorUnsupportedTarget, failure, details);
        }
        id<CCNMCoreTelephonyClient> client = CCNMCreateClient(&failure);
        id<CCNMSubscriptionContext> context = client
            ? CCNMSafeTargetContext(client, CCNMTargetResolutionRecorded,
                subscriptionUUID, baseline[@"slotID"], details, &failure) : nil;
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
        // `details` carries the device identity: CCNMValidateSelfSourcedWriteTarget
        // above records model/version/build into it through
        // CCNMRecordDeviceIdentity, which is the same dictionary the baseline was
        // built from on enable.
        if (!CCNMValidateBaselineCompatibility(baseline, fresh[@"supportedBands"], details, &failure)) {
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorBaselineIncompatible,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorBaselineIncompatible, failure, details);
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
            // The modem already holds the saved configuration. Writing it again
            // would be a modem call with nothing to change, so the records are
            // retired instead.
            details[@"writeNotNeeded"] = @YES;
            NSDictionary *expectedState = stateExists ? state : nil;
            if (!CCNMRecordsRemainExact(expectedState, baseline, oldIntent, oldInFlight, &failure)) {
                return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                    failure ?: @"Durable policy evidence changed during no-write recovery and was preserved.",
                    details);
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
            @{ @"baselineCreatedAt": baseline[@"createdAt"], @"slotID": baseline[@"slotID"] }, &failure);
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

        if (!CCNMRecordsRemainExact(pending, baseline, intent, inFlight, &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidRecords,
                failure ?: @"Durable policy evidence changed before the restore setter and was preserved.",
                details);
        }

        // Last look before the write. Re-resolving the context and re-reading the
        // bands is what makes the payload provably still correct for this
        // subscription at the moment of the call.
        context = CCNMSafeTargetContext(client, CCNMTargetResolutionRecorded,
            subscriptionUUID, baseline[@"slotID"], details, &failure);
        NSDictionary *lastGuard = context ? CCNMReadFreshBandInfo(client, context, &failure) : nil;
        BOOL bandsExact = lastGuard &&
            CCNMDictionariesEqual(fresh[@"activeBands"], lastGuard[@"activeBands"]) &&
            CCNMDictionariesEqual(fresh[@"supportedBands"], lastGuard[@"supportedBands"]);
        if (!bandsExact) {
            failure = failure ?: @"The final restore target or BandInfo guard changed.";
            CCNMMarkRecovery(state[@"requestedMode"] ?: CCNMRequestedModeN78Preferred,
                CCNMAppliedPolicyRecoveryRequired, CCNMRecoveryStateRebootRequired,
                generation, subscriptionUUID, CCNMN78PolicyErrorInvalidBandInfo,
                failure, baseline, YES);
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorInvalidBandInfo, failure, details);
        }

        CCNMSetterOutcome outcome = CCNMCallSetter(client, context, payloadInfo, generation,
            &lockDescriptor, details, &failure);
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

        NSDictionary *readBack = CCNMWaitForReadBack(client, subscriptionUUID, baseline[@"slotID"], payload);
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
                failure ?: @"Durable policy evidence changed after verified restore read-back and was preserved.",
                details);
        }
        if (!CCNMFinishSystemDefaultState(generation, subscriptionUUID, pending,
            baseline, intent, inFlight, readBack[@"lastActiveBands"], &failure)) {
            return CCNMErrorSummary(operation, CCNMN78PolicyErrorPersistence, failure, details);
        }
        NSDictionary *clean = [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyStatePath()];
        return CCNMSummaryFromState(clean, YES, operation, CCNMN78PolicyErrorNone, @"", details);
    } @finally {
        CCNMReleasePolicyLock(lockDescriptor);
    }
}

@end

NSDictionary<NSString *, id> *CCNMReadN78PolicyState(void) {
    return [[CCNMN78PolicyController sharedController] readState];
}

BOOL CCNMN78PolicyHasOutstandingSetter(void) {
    @synchronized([CCNMN78PolicyController class]) {
        return CCNMSetterCallActive || CCNMSetterRetainedPolicyLockDescriptor >= 0;
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
