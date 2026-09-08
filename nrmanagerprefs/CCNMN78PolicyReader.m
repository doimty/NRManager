#import "CCNMN78PolicyReader.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

// Silence -Werror=objc-method-access for the duck-typed getCurrentDataSubscriptionContextSync:
// result. The protocol cannot declare -uuid because the query returns an opaque id and
// CoreTelephony's context class is private, but the respondsToSelector: guard at runtime
// proves the method exists before calling it.
@interface NSObject(CCNMReaderUUID)
- (id)uuid;
@end
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#if defined(CCNM_MAINTENANCE_DAEMON)
#import "../maintenance-daemon/CCNMDaemonRoot.h"
// The daemon cannot use jbroot(). libroothide's install name is
// @loader_path/.jbroot/usr/lib/libroothide.dylib, and launchd applies no
// bootstrap injection, so dyld found nothing to load and the job crashed on every
// one of its 108 launches with OS_REASON_DYLD. The prefix is recovered from the
// daemon's own executable path instead; see CCNMDaemonRoot.h.
#define CCNMPolicyRoot(path) CCNMDaemonRootedPath(path)
#elif __has_include(<roothide.h>)
#import <roothide.h>
#define CCNMPolicyRoot(path) jbroot(path)
#else
#define CCNMPolicyRoot(path) (path)
#endif

// ---------------------------------------------------------------------------
// Mark: constants
// ---------------------------------------------------------------------------

static NSString *const CCNMPolicyOwner = @"com.doimty.nrmanager.n78-policy";
static NSString *const CCNMNRKey = @"kCTRegistrationRadioAccessTechnologyNR";
static const long long CCNMMaximumBandIdentifier = 1024;

// ---------------------------------------------------------------------------
// Mark: path functions
// ---------------------------------------------------------------------------

static NSString *CCNMNormalizeUUID(NSString *uuid);
static NSString *CCNMGetActiveSubscriptionUUID(void);

// Multi-SIM support: per-UUID configuration paths, mirroring the controller's
// write path. The filename carries the normalized (lowercase, no dashes)
// subscription UUID; a nil or empty UUID falls back to the legacy unqualified
// file so a single-SIM upgrade still reads its old records. CCNMPolicyRoot is
// a function-like macro, so path construction stays outside the macro.
static NSString *CCNMN78PolicyStatePathForUUID(NSString *uuid) {
    NSString *filename = uuid.length > 0
        ? [NSString stringWithFormat:@"com.doimty.nrmanager.n78-policy.%@.state.plist", uuid]
        : @"com.doimty.nrmanager.n78-policy.state.plist";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", filename];
    return CCNMPolicyRoot(path);
}

static NSString *CCNMN78PolicyBaselinePathForUUID(NSString *uuid) {
    NSString *filename = uuid.length > 0
        ? [NSString stringWithFormat:@"com.doimty.nrmanager.n78-policy.%@.baseline.plist", uuid]
        : @"com.doimty.nrmanager.n78-policy.baseline.plist";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", filename];
    return CCNMPolicyRoot(path);
}

static NSString *CCNMN78PolicyIntentPathForUUID(NSString *uuid) {
    NSString *filename = uuid.length > 0
        ? [NSString stringWithFormat:@"com.doimty.nrmanager.n78-policy.%@.intent.plist", uuid]
        : @"com.doimty.nrmanager.n78-policy.intent.plist";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", filename];
    return CCNMPolicyRoot(path);
}

static NSString *CCNMN78PolicyInFlightPathForUUID(NSString *uuid) {
    NSString *filename = uuid.length > 0
        ? [NSString stringWithFormat:@"com.doimty.nrmanager.n78-policy.%@.inflight.plist", uuid]
        : @"com.doimty.nrmanager.n78-policy.inflight.plist";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", filename];
    return CCNMPolicyRoot(path);
}

static NSString *CCNMN78PolicyLockPathForUUID(NSString *uuid) {
    NSString *filename = uuid.length > 0
        ? [NSString stringWithFormat:@"com.doimty.nrmanager.n78-policy.%@.lock", uuid]
        : @"com.doimty.nrmanager.n78-policy.lock";
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@", filename];
    return CCNMPolicyRoot(path);
}

NSString *CCNMN78PolicyStatePath(void) {
    return CCNMN78PolicyStatePathForUUID(CCNMGetActiveSubscriptionUUID());
}

NSString *CCNMN78PolicyBaselinePath(void) {
    return CCNMN78PolicyBaselinePathForUUID(CCNMGetActiveSubscriptionUUID());
}

NSString *CCNMN78PolicyIntentPath(void) {
    return CCNMN78PolicyIntentPathForUUID(CCNMGetActiveSubscriptionUUID());
}

NSString *CCNMN78PolicyInFlightPath(void) {
    return CCNMN78PolicyInFlightPathForUUID(CCNMGetActiveSubscriptionUUID());
}

NSString *CCNMN78PolicyLockPath(void) {
    return CCNMN78PolicyLockPathForUUID(CCNMGetActiveSubscriptionUUID());
}

NSString *CCNMN78PolicyRemovalGuardPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "com.doimty.nrmanager.n78-policy.removal-guard.plist");
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

// ---------------------------------------------------------------------------
// Mark: current data line
// ---------------------------------------------------------------------------

// The daemon is compiled without the controller, so the reader carries its own
// read-only probe for the current data line. It mirrors the controller's probe
// and deliberately stops short of it: no setter is declared, validated, or
// called here, and every failure degrades to nil so callers fall back to the
// legacy unqualified files instead of guessing a SIM.
@protocol CCNMReaderCoreTelephonyClient <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
// CoreTelephony's own answer to "which subscription is the data line". Declared
// @optional so -respondsToSelector: can be asked for it without a compiler
// warning; it is only ever called after an ABI check.
@optional
- (id)getCurrentDataSubscriptionContextSync:(NSError **)error;
@end

static const char *CCNMReaderSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL CCNMReaderValidateObjectErrorABI(id object,
                                             SEL selector,
                                             NSString **failure) {
    if (!object || ![object respondsToSelector:selector]) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ is unavailable.",
                NSStringFromSelector(selector)];
        }
        return NO;
    }
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    const char *returnType = signature
        ? CCNMReaderSkipTypeQualifiers(signature.methodReturnType) : NULL;
    const char *errorType = signature && signature.numberOfArguments > 2
        ? CCNMReaderSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    BOOL valid = signature && signature.numberOfArguments == 3 &&
        returnType && returnType[0] == '@' &&
        errorType && errorType[0] == '^' && errorType[1] == '@';
    if (!valid && failure) {
        *failure = [NSString stringWithFormat:@"%@ has an unexpected private ABI.",
            NSStringFromSelector(selector)];
    }
    return valid;
}

static id<CCNMReaderCoreTelephonyClient> CCNMReaderCreateClient(NSString **failure) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
            RTLD_LAZY | RTLD_LOCAL);
    });
    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (!handle || !clientClass) {
        if (failure) {
            *failure = @"CoreTelephonyClient is unavailable.";
        }
        return nil;
    }
    id<CCNMReaderCoreTelephonyClient> client = [(id)clientClass alloc];
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
            *failure = [NSString stringWithFormat:
                @"CoreTelephonyClient initialization raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    if (!client && failure) {
        *failure = @"CoreTelephonyClient could not be created.";
    }
    return client;
}

// CoreTelephony's own answer to "which subscription is the data line". Every
// no-answer path returns nil with a reason instead of a fallback guess. This is
// the read-only counterpart of the controller's probe; on the daemon there is no
// write to aim, so a nil UUID simply selects the legacy unqualified files.
static NSString *CCNMCurrentDataLineUUID(id<CCNMReaderCoreTelephonyClient> client,
                                         NSString **reason) {
    SEL selector = @selector(getCurrentDataSubscriptionContextSync:);
    if (!CCNMReaderValidateObjectErrorABI(client, selector, NULL)) {
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

// Convenience wrapper: the normalized UUID of the current data line, or nil.
// Used by the path functions to route reads to the active subscription's files,
// mirroring the controller's write path.
static NSString *CCNMGetActiveSubscriptionUUID(void) {
    NSString *failure = nil;
    id<CCNMReaderCoreTelephonyClient> client = CCNMReaderCreateClient(&failure);
    if (!client) {
        return nil;
    }
    NSString *reason = nil;
    NSString *uuid = CCNMCurrentDataLineUUID(client, &reason);
    return CCNMNormalizeUUID(uuid);
}

static NSString *CCNMNormalizeUUID(NSString *uuid) {
    // Normalize UUID to lowercase without dashes for filename safety, matching
    // the controller's per-UUID file naming.
    if (!uuid || uuid.length == 0) return nil;
    return [[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
}

// ---------------------------------------------------------------------------
// Mark: time and identity
// ---------------------------------------------------------------------------

long long CCNMUnixMilliseconds(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

NSTimeInterval CCNMMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (NSTimeInterval)now.tv_sec +
        ((NSTimeInterval)now.tv_nsec / (NSTimeInterval)NSEC_PER_SEC);
}

NSString *CCNMSysctlString(const char *name) {
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

NSString *CCNMCanonicalUUIDString(id value) {
    NSString *string = nil;
    if ([value isKindOfClass:[NSUUID class]]) {
        string = [(NSUUID *)value UUIDString];
    } else if ([value isKindOfClass:[NSString class]]) {
        string = [(NSString *)value
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSUUID *uuid = string ? [[NSUUID alloc] initWithUUIDString:string] : nil;
    return uuid.UUIDString;
}

NSString *CCNMBootSessionIdentity(void) {
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

// ---------------------------------------------------------------------------
// Mark: file helpers
// ---------------------------------------------------------------------------

BOOL CCNMFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

NSDictionary *CCNMLoadRecord(NSString *path, BOOL *exists) {
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

// ---------------------------------------------------------------------------
// Mark: integer / set helpers
// ---------------------------------------------------------------------------

BOOL CCNMNSNumberIsInteger(id value) {
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

NSSet<NSString *> *CCNMRequiredRATKeys(void) {
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

// ---------------------------------------------------------------------------
// Mark: legacy record compatibility
// ---------------------------------------------------------------------------

// Older packages stored recovery provenance alongside the baseline. The carrier
// reset path does not interpret or replay that metadata; it remains tolerated as
// opaque fields so a reinstall can reset and retire the old records.

// ---------------------------------------------------------------------------
// Mark: dictionary validation
// ---------------------------------------------------------------------------

BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString **failure) {
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

BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil && [left isEqualToDictionary:right];
}

BOOL CCNMStringInDomain(id value, NSArray<NSString *> *domain) {
    return [value isKindOfClass:[NSString class]] && [domain containsObject:value];
}

NSDictionary *CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString **failure) {
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

static NSArray<NSNumber *> *CCNMCanonicalNRSelectionLocal(NSArray *selection,
                                                           NSString **failure) {
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

static NSArray<NSNumber *> *CCNMSelectableNRDomainLocal(NSDictionary *active,
                                                         NSDictionary *supported,
                                                         NSString **failure) {
    if (!CCNMValidateBandDictionary(active, failure) ||
        !CCNMValidateBandDictionary(supported, failure)) {
        return nil;
    }
    NSMutableArray<NSNumber *> *domain = [NSMutableArray array];
    NSSet *supportedNR = [NSSet setWithArray:supported[CCNMNRKey]];
    for (NSNumber *band in (NSArray *)active[CCNMNRKey]) {
        if ([supportedNR containsObject:band]) {
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

// ---------------------------------------------------------------------------
// Mark: record validation
// ---------------------------------------------------------------------------

BOOL CCNMValidateStateRecord(NSDictionary *state, NSString **failure) {
    BOOL valid = [state isKindOfClass:[NSDictionary class]] &&
        [state[@"schemaVersion"] isEqual:@1] &&
        [state[@"owner"] isEqual:CCNMPolicyOwner] &&
        [state[@"kind"] isEqual:@"state"] &&
        [state[@"updatedAt"] isKindOfClass:[NSNumber class]] &&
        [state[@"updatedAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(state[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(state[@"operationGeneration"]) &&
        [state[@"operationGeneration"] longLongValue] >= 0 &&
        CCNMStringInDomain(state[@"requestedMode"],
            @[CCNMRequestedModeSystemDefault, CCNMRequestedModeN78Preferred]) &&
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
    if (valid &&
        [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        !CCNMCanonicalNRSelectionLocal(state[@"targetNRBands"], NULL)) {
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

BOOL CCNMValidateBaselineRecord(NSDictionary *baseline, NSString **failure) {
    NSDictionary *bands = [baseline[@"activeBands"] isKindOfClass:[NSDictionary class]]
        ? baseline[@"activeBands"] : nil;
    BOOL hasCapabilitySnapshot = baseline[@"deviceModel"] != nil ||
        baseline[@"systemVersion"] != nil || baseline[@"systemBuild"] != nil ||
        baseline[@"supportedBands"] != nil || baseline[@"modifiedBandKeys"] != nil;
    BOOL capabilitySnapshotValid = !hasCapabilitySnapshot ||
        ([baseline[@"deviceModel"] isKindOfClass:NSString.class] &&
         [baseline[@"deviceModel"] length] > 0 &&
         [baseline[@"systemVersion"] isKindOfClass:NSString.class] &&
         [baseline[@"systemVersion"] length] > 0 &&
         [baseline[@"systemBuild"] isKindOfClass:NSString.class] &&
         [baseline[@"systemBuild"] length] > 0 &&
         CCNMValidateBandDictionary(baseline[@"supportedBands"], failure) &&
         [baseline[@"modifiedBandKeys"] isKindOfClass:NSArray.class] &&
         [baseline[@"modifiedBandKeys"] count] == 1 &&
         [baseline[@"modifiedBandKeys"][0] isEqual:CCNMNRKey]);
    BOOL valid = [baseline isKindOfClass:[NSDictionary class]] &&
        [baseline[@"schemaVersion"] isEqual:@1] &&
        [baseline[@"owner"] isEqual:CCNMPolicyOwner] &&
        [baseline[@"kind"] isEqual:@"baseline"] &&
        [baseline[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [baseline[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(baseline[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(baseline[@"operationGeneration"]) &&
        [baseline[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        CCNMValidSlotID(baseline[@"slotID"]) &&
        CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]) != nil &&
        capabilitySnapshotValid &&
        CCNMValidateBandDictionary(bands, failure);
    if (!valid && failure && !*failure) {
        *failure = @"The durable policy baseline is malformed, foreign, or has invalid capability evidence.";
    }
    return valid;
}

static BOOL CCNMValidateSelectedNRPayloadLocal(NSDictionary *original,
                                                NSDictionary *payload,
                                                NSArray<NSNumber *> *selection,
                                                NSString **failure);
static BOOL CCNMValidateSelectedNRIntentPayloadLocal(NSDictionary *active,
                                                      NSDictionary *supported,
                                                      NSDictionary *requested,
                                                      NSString **failure);
static BOOL CCNMValidateRestorePayloadLocal(NSDictionary *live,
                                             NSDictionary *baseline,
                                             NSDictionary *payload,
                                             NSString **failure);

BOOL CCNMValidateIntentRecord(NSDictionary *intent,
                               NSDictionary *baseline,
                               NSString **failure) {
    NSString *operation = [intent[@"operation"] isKindOfClass:[NSString class]]
        ? intent[@"operation"] : nil;
    NSDictionary *active = [intent[@"preWriteActiveBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"preWriteActiveBands"] : nil;
    NSDictionary *supported = [intent[@"preWriteSupportedBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"preWriteSupportedBands"] : nil;
    NSDictionary *requested = [intent[@"requestedActiveBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"requestedActiveBands"] : nil;
    // Mirrors CCNMValidateIntentRecord in the controller, knownOrphanRecovery
    // included. 1.5.0 shipped that operation, so a device that lost a setter
    // outcome mid-replay has an intent record naming it, and the two validators
    // disagreeing is worse than either verdict: the daemon reads through here and
    // Settings reads through the controller, so the same file would be legitimate
    // policy evidence to one and foreign to the other.
    BOOL header = [intent isKindOfClass:[NSDictionary class]] &&
        [intent[@"schemaVersion"] isEqual:@1] &&
        [intent[@"owner"] isEqual:CCNMPolicyOwner] &&
        [intent[@"kind"] isEqual:@"intent"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"]
            containsObject:operation ?: @""] &&
        [intent[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [intent[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(intent[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(intent[@"operationGeneration"]) &&
        [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [intent[@"slotID"] isEqual:baseline[@"slotID"]] &&
        [CCNMCanonicalUUIDString(intent[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [intent[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
        [intent[@"baselineGeneration"] isEqual:baseline[@"operationGeneration"]] &&
        CCNMDictionariesEqual(intent[@"baselineActiveBands"], baseline[@"activeBands"]) &&
        CCNMValidateBandDictionary(active, failure) &&
        CCNMValidateBandDictionary(supported, failure);
    BOOL enable = [operation isEqual:@"enable"];
    BOOL payload = NO;
    if (header && enable) {
        payload = CCNMValidateSelectedNRIntentPayloadLocal(
            active, supported, requested, failure);
    } else if (header) {
        payload = CCNMValidateRestorePayloadLocal(active, baseline[@"activeBands"],
            requested, failure);
    }
    if ((!header || !payload) && failure && !*failure) {
        *failure = @"The durable policy intent is malformed, foreign, or inconsistent with the baseline.";
    }
    return header && payload;
}

BOOL CCNMValidateInFlightRecord(NSDictionary *record,
                                 NSDictionary *baseline,
                                 NSDictionary *intent,
                                 BOOL requireIntentLink,
                                 NSString **failure) {
    BOOL valid = [record isKindOfClass:[NSDictionary class]] &&
        [record[@"schemaVersion"] isEqual:@1] &&
        [record[@"owner"] isEqual:CCNMPolicyOwner] &&
        [record[@"kind"] isEqual:@"inflight"] &&
        [record[@"state"] isEqual:@"setterInFlight"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"]
            containsObject:record[@"operation"] ?: @""] &&
        [record[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [record[@"createdAt"] longLongValue] > 0 &&
        [record[@"processID"] isKindOfClass:[NSNumber class]] &&
        [record[@"processID"] intValue] > 0 &&
        CCNMCanonicalUUIDString(record[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(record[@"operationGeneration"]) &&
        [record[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [record[@"slotID"] isEqual:baseline[@"slotID"]] &&
        [CCNMCanonicalUUIDString(record[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
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

// ---------------------------------------------------------------------------
// Mark: local payload validation (reader-only copies, no setter dependency)
// ---------------------------------------------------------------------------

static BOOL CCNMValidateSelectedNRPayloadLocal(NSDictionary *original,
                                                NSDictionary *payload,
                                                NSArray<NSNumber *> *selection,
                                                NSString **failure) {
    NSArray *canonical = CCNMCanonicalNRSelectionLocal(selection, failure);
    if (!canonical ||
        !CCNMValidateBandDictionary(original, failure) ||
        !CCNMValidateBandDictionary(payload, failure) ||
        ![[NSSet setWithArray:original.allKeys] isEqualToSet:
            [NSSet setWithArray:payload.allKeys]]) {
        return NO;
    }
    for (NSString *key in original) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? canonical : original[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? [NSString stringWithFormat:
                        @"The requested NR array is not exactly the ascending selection %@.", canonical]
                    : [NSString stringWithFormat:
                        @"The requested payload changed non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

static BOOL CCNMValidateSelectedNRIntentPayloadLocal(NSDictionary *active,
                                                      NSDictionary *supported,
                                                      NSDictionary *requested,
                                                      NSString **failure) {
    if (!CCNMValidateBandDictionary(requested, failure)) {
        return NO;
    }
    NSArray *canonical = CCNMCanonicalNRSelectionLocal(requested[CCNMNRKey], failure);
    NSArray *domain = CCNMSelectableNRDomainLocal(active, supported, failure);
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
    return CCNMValidateSelectedNRPayloadLocal(active, requested, canonical, failure);
}

static BOOL CCNMValidateRestorePayloadLocal(NSDictionary *live,
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
                    : [NSString stringWithFormat:
                        @"The restore payload changed current non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Mark: default state / summary builder
// ---------------------------------------------------------------------------

NSDictionary *CCNMDefaultState(void) {
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

static BOOL CCNMIsVerifiedRestoreCleanupCheckpoint(NSDictionary *state) {
    NSDictionary *verifiedBands = [state[@"verifiedActiveBands"] isKindOfClass:NSDictionary.class]
        ? state[@"verifiedActiveBands"] : nil;
    return CCNMValidateStateRecord(state, NULL) &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyApplying] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateRestorePending] &&
        [state[@"readBackVerified"] isEqual:@YES] &&
        [state[@"verifiedAt"] isKindOfClass:NSNumber.class] &&
        [state[@"verifiedAt"] longLongValue] > 0 &&
        [state[@"baselineCreatedAt"] isKindOfClass:NSNumber.class] &&
        [state[@"baselineCreatedAt"] longLongValue] > 0 &&
        ![state[@"uncertain"] boolValue] &&
        CCNMValidateBandDictionary(verifiedBands, NULL);
}

static NSDictionary *CCNMSummaryFromState(NSDictionary *state,
                                           BOOL success,
                                           NSString *operation,
                                           CCNMN78PolicyErrorCode errorCode,
                                           NSString *error,
                                           NSDictionary *details) {
    NSDictionary *base = state ?: CCNMDefaultState();
    NSString *uuid = CCNMGetActiveSubscriptionUUID();
    BOOL baselinePresent = CCNMFileExists(CCNMN78PolicyBaselinePathForUUID(uuid));
    NSDictionary *baselineRecord = baselinePresent
        ? [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyBaselinePathForUUID(uuid)] : nil;
    BOOL baselineValid = baselinePresent && CCNMValidateBaselineRecord(baselineRecord, NULL);
    BOOL transitionPresent = CCNMFileExists(CCNMN78PolicyIntentPathForUUID(uuid)) ||
        CCNMFileExists(CCNMN78PolicyInFlightPathForUUID(uuid));
    CCNMRecoveryState recovery = base[@"recoveryState"] ?: CCNMRecoveryStateRecoveryFailed;
    CCNMAppliedPolicy applied = base[@"appliedPolicy"] ?: CCNMAppliedPolicyUnknown;
    BOOL currentBootInFlight = NO;
    if (CCNMFileExists(CCNMN78PolicyInFlightPathForUUID(uuid))) {
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:
            CCNMN78PolicyInFlightPathForUUID(uuid)];
        currentBootInFlight = !record ||
            CCNMBootRelationForRecord(record) != CCNMBootRelationEarlier;
    }
    BOOL requiresReboot = [recovery isEqual:CCNMRecoveryStateRebootRequired] ||
        currentBootInFlight;
    BOOL normalEnabled = [recovery isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedN78Only] && baselinePresent &&
        !transitionPresent;
    BOOL normalDefault = [recovery isEqual:CCNMRecoveryStateClean] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedSystemDefault] && !baselinePresent &&
        !transitionPresent;
    NSDictionary *typedState = @{
        CCNMN78PolicySummaryRequestedModeKey:
            base[@"requestedMode"] ?: CCNMRequestedModeSystemDefault,
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO
    };
    NSArray *appliedSelection = normalEnabled
        ? CCNMCanonicalNRSelectionLocal(base[@"targetNRBands"], NULL) : nil;
    NSMutableDictionary *summary = [@{
        CCNMN78PolicySummarySuccessKey: @(success),
        CCNMN78PolicySummaryOperationKey: operation ?: @"read",
        CCNMN78PolicySummaryStateKey: typedState,
        CCNMN78PolicySummaryRequestedModeKey:
            typedState[CCNMN78PolicySummaryRequestedModeKey],
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        CCNMN78PolicySummaryErrorCodeKey: errorCode ?:
            base[@"errorCode"] ?: CCNMN78PolicyErrorNone,
        CCNMN78PolicySummaryErrorKey: error ?: base[@"error"] ?: @"",
        CCNMN78PolicySummaryRequiresRebootKey: @(requiresReboot),
        CCNMN78PolicySummaryMayWriteKey: @((normalDefault || normalEnabled) &&
            !requiresReboot),
        CCNMN78PolicySummaryMayUninstallKey: @(normalDefault),
        CCNMN78PolicySummaryCleanupCheckpointRecoverableKey: @NO,
        @"baselinePresent": @(baselinePresent),
        @"baselineValid": @(baselineValid),
        @"transitionPresent": @(transitionPresent),
        @"legacyRemovalGuardPresent": @(CCNMFileExists(CCNMN78PolicyRemovalGuardPath())),
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO,
        @"statePath": CCNMN78PolicyStatePathForUUID(uuid),
        @"baselinePath": CCNMN78PolicyBaselinePathForUUID(uuid),
        @"intentPath": CCNMN78PolicyIntentPathForUUID(uuid),
        @"inFlightPath": CCNMN78PolicyInFlightPathForUUID(uuid),
        @"lockPath": CCNMN78PolicyLockPathForUUID(uuid),
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

// ---------------------------------------------------------------------------
// Mark: read policy state (main entry point)
// ---------------------------------------------------------------------------

static NSDictionary *CCNMReadPolicyStateInternal(void) {
    NSString *uuid = CCNMGetActiveSubscriptionUUID();
    BOOL stateExists = NO, baselineExists = NO, intentExists = NO;
    BOOL inFlightExists = NO;
    NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePathForUUID(uuid), &stateExists);
    NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePathForUUID(uuid), &baselineExists);
    NSDictionary *intent = CCNMLoadRecord(CCNMN78PolicyIntentPathForUUID(uuid), &intentExists);
    NSDictionary *inFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPathForUUID(uuid), &inFlightExists);

    if (!stateExists && !baselineExists && !intentExists && !inFlightExists) {
        return CCNMSummaryFromState(CCNMDefaultState(), YES, @"read",
            CCNMN78PolicyErrorNone, @"", nil);
    }
    if ((stateExists && !CCNMValidateStateRecord(state, NULL)) ||
        (baselineExists && !CCNMValidateBaselineRecord(baseline, NULL)) ||
        (intentExists && (!baseline ||
            !CCNMValidateIntentRecord(intent, baseline, NULL))) ||
        (inFlightExists && (!baseline ||
            !CCNMValidateInFlightRecord(inFlight, baseline, intent, intentExists, NULL)))) {
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state,
            CCNMRecoveryStateRebootRequired,
            @"A durable policy record is malformed, foreign, or inconsistent.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorInvalidRecords, synthetic[@"error"], nil);
    }
    if (!stateExists) {
        BOOL evidenceMayBeCurrent =
            (inFlightExists &&
             CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists &&
             CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (baselineExists &&
             CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = evidenceMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(nil, recovery,
            @"Policy evidence exists without its state record.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorInvalidRecords, synthetic[@"error"], nil);
    }
    if (!baselineExists && !intentExists && !inFlightExists &&
        CCNMBootRelationForRecord(state) == CCNMBootRelationEarlier &&
        CCNMIsVerifiedRestoreCleanupCheckpoint(state)) {
        return CCNMSummaryFromState(state, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired,
            @"The modem restore was verified; durable cleanup remains pending.",
            @{CCNMN78PolicySummaryCleanupCheckpointRecoverableKey: @YES});
    }
    if ([state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetPending] ||
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateCarrierResetFailed]) {
        // Read-only counterpart of the controller's branch, and for the same
        // reason: neither state has a producer any more, but 1.6.0 shipped, so a
        // device that pressed the reload has one of them on disk right now. The
        // fallback text exists because a state written by that build may carry an
        // empty error string, and this daemon has nothing else to say about it.
        return CCNMSummaryFromState(state, NO, @"read",
            state[@"errorCode"] ?: CCNMN78PolicyErrorCarrierResetFailed,
            state[@"error"] ?: @"Carrier defaults reset is pending or failed.", nil);
    }
    if (intentExists || inFlightExists) {
        if ([state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyDiverged] &&
            [state[@"recoveryState"] isEqual:CCNMRecoveryStateRecoveryFailed]) {
            return CCNMSummaryFromState(state, NO, @"read",
                CCNMN78PolicyErrorReadBackMismatch, state[@"error"], nil);
        }
        BOOL transitionMayBeCurrent =
            (inFlightExists &&
             CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists &&
             CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (![state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
             CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = transitionMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state, recovery,
            @"A policy transition is incomplete and must be recovered before another write.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired, synthetic[@"error"], nil);
    }
    BOOL enabled = [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        baselineExists &&
        [CCNMCanonicalUUIDString(state[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [state[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]];
    BOOL systemDefault = [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] && !baselineExists &&
        ![state[@"uncertain"] boolValue];
    if (!enabled && !systemDefault) {
        BOOL evidenceMayBeCurrent =
            CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier ||
            (baselineExists &&
             CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state,
            evidenceMayBeCurrent
                ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed,
            @"Policy state and retained baseline do not form a verified stable state.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired, synthetic[@"error"], nil);
    }
    return CCNMSummaryFromState(state, YES, @"read",
        state[@"errorCode"], state[@"error"], nil);
}

NSDictionary *CCNMReadN78PolicyState(void) {
    return CCNMReadPolicyStateInternal();
}