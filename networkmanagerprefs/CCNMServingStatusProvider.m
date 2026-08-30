#import "CCNMServingStatusProvider.h"
#import "CCNMN78PolicyReader.h"
#import "CCNMServingCellSampler.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <unistd.h>

#ifndef CCNM_SERVING_USE_LIVECC_NAMESPACE
#define CCNM_SERVING_USE_LIVECC_NAMESPACE 0
#endif

NSString *const CCNMServingSummaryStateKey = @"servingState";
NSString *const CCNMServingSummaryDataLineKey = @"dataLine";
NSString *const CCNMServingSummarySlotIDKey = @"slotID";
NSString *const CCNMServingSummaryDeviceModelKey = @"deviceModel";
NSString *const CCNMServingSummarySystemBuildKey = @"systemBuild";
NSString *const CCNMServingSummarySystemVersionKey = @"systemVersion";
NSString *const CCNMServingSummarySampledAtMillisecondsKey = @"sampledAtMilliseconds";
NSString *const CCNMServingSummaryPublishedAtMillisecondsKey = @"publishedAtMilliseconds";
NSString *const CCNMServingSummaryStaleKey = @"stale";
NSString *const CCNMServingSummaryRATKey = @"rat";
NSString *const CCNMServingSummaryBandKey = @"band";
NSString *const CCNMServingSummaryFrequencyMHzKey = @"frequencyMHz";
NSString *const CCNMServingSummaryErrorKey = @"error";
NSString *const CCNMServingSummarySuccessKey = @"success";
NSString *const CCNMServingSummarySamplingStatusKey = @"samplingStatus";
NSString *const CCNMServingSummaryUnsafeOutstandingKey = @"unsafeOutstanding";
NSString *const CCNMServingSummarySubscriptionUUIDKey = @"subscriptionUUID";
NSString *const CCNMServingSummaryCapabilityReadSuccessKey = @"capabilityReadSuccess";
NSString *const CCNMServingSummaryCapabilityN78SupportedKey = @"capabilityN78Supported";
NSString *const CCNMServingSummaryCapabilityN78ActiveKey = @"capabilityN78Active";
NSString *const CCNMServingSummaryCapabilitySupportedNRBandsKey = @"capabilitySupportedNRBands";
NSString *const CCNMServingSummaryCapabilityActiveNRBandsKey = @"capabilityActiveNRBands";
NSString *const CCNMServingSummaryCapabilitySupportedRATKeysKey = @"capabilitySupportedRATKeys";
NSString *const CCNMServingSummaryCapabilitySampledAtMillisecondsKey = @"capabilitySampledAtMilliseconds";
NSString *const CCNMServingSummaryCapabilityErrorKey = @"capabilityError";
#if CCNM_SERVING_USE_LIVECC_NAMESPACE
NSString *const CCNMServingStatusDidChangeDarwinNotification =
    @"com.doimty.nrmanager.livecc.serving-status-changed";
#else
NSString *const CCNMServingStatusDidChangeDarwinNotification =
    @"com.doimty.nrmanager.serving-status-changed";
#endif

static const long long CCNMServingFreshnessLifetimeMilliseconds = 30000;
#if CCNM_SERVING_USE_LIVECC_NAMESPACE
static NSString *const CCNMServingCacheFilename =
    @"com.doimty.nrmanager.livecc.serving-status.plist";
static NSString *const CCNMServingCacheLockFilename =
    @"com.doimty.nrmanager.livecc.serving-status.lock";
#else
static NSString *const CCNMServingCacheFilename =
    @"com.doimty.nrmanager.serving-status.plist";
static NSString *const CCNMServingCacheLockFilename =
    @"com.doimty.nrmanager.serving-status.lock";
#endif

static NSString *CCNMServingCachePath(void) {
    return [CCNMN78PolicyStatePath().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:CCNMServingCacheFilename];
}

static NSString *CCNMServingCacheLockPath(void) {
    return [CCNMN78PolicyStatePath().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:CCNMServingCacheLockFilename];
}

static int CCNMServingAcquireCacheLock(void) {
    int descriptor = open(CCNMServingCacheLockPath().fileSystemRepresentation,
        O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
    if (descriptor < 0) return -1;
    while (flock(descriptor, LOCK_EX) != 0) {
        if (errno == EINTR) continue;
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static void CCNMServingReleaseCacheLock(int descriptor) {
    if (descriptor < 0) return;
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

static NSDictionary *CCNMServingReadCachedSummary(void) {
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:CCNMServingCachePath()];
    NSDictionary *summary = [cache[@"summary"] isKindOfClass:NSDictionary.class]
        ? cache[@"summary"] : nil;
    if (![summary isKindOfClass:NSDictionary.class] ||
        ![summary[CCNMServingSummarySampledAtMillisecondsKey] isKindOfClass:NSNumber.class] ||
        ![summary[CCNMServingSummaryStateKey] isKindOfClass:NSString.class]) {
        return nil;
    }
    NSMutableDictionary *normalized = [summary mutableCopy];
    if (![normalized[CCNMServingSummaryPublishedAtMillisecondsKey] isKindOfClass:NSNumber.class]) {
        normalized[CCNMServingSummaryPublishedAtMillisecondsKey] =
            normalized[CCNMServingSummarySampledAtMillisecondsKey] ?: @0;
    }
    return [normalized copy];
}

static BOOL CCNMServingPersistCachedSummary(NSDictionary *summary) {
    if (![summary isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *cache = @{
        @"schemaVersion": @2,
        @"summary": summary
    };
    return [cache writeToFile:CCNMServingCachePath() atomically:YES];
}

@protocol CCNMServingCoreTelephonyClient <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (id)getSubscriptionInfoWithError:(NSError **)error;
- (id)getBandInfo:(id)context error:(NSError **)error;
// Optional. CoreTelephony's own answer to "which subscription is the data line".
// Declared @optional and always guarded by -respondsToSelector: plus an ABI check,
// because a build that does not vend it must degrade instead of failing.
@optional
- (id)getCurrentDataSubscriptionContextSync:(NSError **)error;
@end

@protocol CCNMServingBandInfo <NSObject>
- (NSDictionary *)activeBands;
- (NSDictionary *)supportedBands;
@end

@protocol CCNMServingSubscriptionInfo <NSObject>
- (NSArray *)subscriptions;
@end

@protocol CCNMServingSubscriptionContext <NSObject>
- (long long)slotID;
- (BOOL)isSimGood;
- (BOOL)isSimPresent;
- (NSUUID *)uuid;
// Optional. Declared so -respondsToSelector: can be asked for it without a
// compiler warning; the caller degrades gracefully when it is absent.
@optional
- (NSNumber *)userDataPreferred;
@end
typedef NS_ENUM(NSInteger, CCNMCellMonitorRATKind) {
    CCNMCellMonitorRATKindOther = 0,
    CCNMCellMonitorRATKindLTE,
    CCNMCellMonitorRATKindNR,
};

static long long CCNMServingUnixMilliseconds(void) {
    return (long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
}

static NSString *CCNMServingSysctlString(const char *name) {
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

static const char *CCNMServingSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL CCNMServingValidateObjectErrorABI(id client,
                                                SEL selector,
                                                NSUInteger objectArgumentCount,
                                                NSString *unavailableMessage,
                                                NSString *abiMessage,
                                                NSString **failure) {
    if (!client || ![client respondsToSelector:selector]) {
        if (failure) {
            *failure = unavailableMessage;
        }
        return NO;
    }
    NSMethodSignature *signature = [client methodSignatureForSelector:selector];
    const char *returnType = signature ? CCNMServingSkipTypeQualifiers(signature.methodReturnType) : NULL;
    NSUInteger errorIndex = 2 + objectArgumentCount;
    const char *errorType = signature && signature.numberOfArguments > errorIndex
        ? CCNMServingSkipTypeQualifiers([signature getArgumentTypeAtIndex:errorIndex]) : NULL;
    BOOL valid = signature && signature.numberOfArguments == errorIndex + 1 &&
        returnType && returnType[0] == '@' && errorType && errorType[0] == '^' && errorType[1] == '@';
    for (NSUInteger index = 0; valid && index < objectArgumentCount; index++) {
        const char *argumentType = CCNMServingSkipTypeQualifiers(
            [signature getArgumentTypeAtIndex:2 + index]);
        valid = argumentType && argumentType[0] == '@';
    }
    if (!valid && failure) {
        *failure = abiMessage;
    }
    return valid;
}

static BOOL CCNMServingValidateSubscriptionABI(id client, NSString **failure) {
    return CCNMServingValidateObjectErrorABI(
        client, @selector(getSubscriptionInfoWithError:), 0,
        @"The subscription query is unavailable.",
        @"The subscription query has an unexpected private ABI.", failure);
}

static BOOL CCNMServingValidateBandInfoABI(id client, NSString **failure) {
    return CCNMServingValidateObjectErrorABI(
        client, @selector(getBandInfo:error:), 1,
        @"The BandInfo query is unavailable.",
        @"The BandInfo query has an unexpected private ABI.", failure);
}

// Reports what device this is running on, for the record. This is deliberately
// not a gate. The write path performs its own runtime ABI, capability, durable
// evidence, and read-back checks; this read path only reports serving-cell and
// capability data and changes nothing. Every private call it makes is ABI
// checked and bounded before use.
static NSDictionary<NSString *, id> *CCNMServingDeviceIdentity(void) {
    NSString *model = CCNMServingSysctlString("hw.machine");
    NSString *build = CCNMServingSysctlString("kern.osversion");
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return @{
        CCNMServingSummaryDeviceModelKey: model ?: @"",
        CCNMServingSummarySystemBuildKey: build ?: @"",
        CCNMServingSummarySystemVersionKey: [NSString stringWithFormat:@"%ld.%ld.%ld",
            (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion]
    };
}

static void *CCNMServingCoreTelephonyHandle(void) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony",
            RTLD_LAZY | RTLD_LOCAL);
    });
    return handle;
}

static id<CCNMServingCoreTelephonyClient> CCNMServingCreateClient(void **frameworkHandle,
                                                                  NSString **failure) {
    void *handle = CCNMServingCoreTelephonyHandle();
    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (!handle || !clientClass) {
        if (failure) {
            *failure = @"CoreTelephonyClient is unavailable.";
        }
        return nil;
    }
    id<CCNMServingCoreTelephonyClient> client = [(id)clientClass alloc];
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
    if (!CCNMServingValidateSubscriptionABI(client, failure)) {
        return nil;
    }
    if (frameworkHandle) {
        *frameworkHandle = handle;
    }
    return client;
}

// Asks CoreTelephony which subscription is the current data line, as a UUID.
//
// Returns nil whenever the answer is not trustworthy, which the caller treats as
// "no opinion" rather than as a failure. This selector is not part of the reviewed
// baseline on the verified device, so it is guarded by -respondsToSelector: and
// the same ABI check as every other private call here.
static NSString *CCNMServingPreferredDataLineUUID(id<CCNMServingCoreTelephonyClient> client) {
    SEL selector = @selector(getCurrentDataSubscriptionContextSync:);
    if (!CCNMServingValidateObjectErrorABI(client, selector, 0,
            @"unavailable", @"unexpected ABI", NULL)) {
        return nil;
    }
    NSError *error = nil;
    id context = nil;
    @try {
        context = [client getCurrentDataSubscriptionContextSync:&error];
    } @catch (NSException *exception) {
        // No opinion, not a failure: the caller falls back to the other rules.
        (void)exception;
        return nil;
    }
    if (error || !context || ![context respondsToSelector:@selector(uuid)]) {
        return nil;
    }
    id rawUUID = [context uuid];
    return [rawUUID isKindOfClass:NSUUID.class] ? [(NSUUID *)rawUUID UUIDString] : nil;
}

// Picks the subscription whose serving cell is worth showing, and reports which
// one that was.
//
// The write path binds a modem write to one subscription and then has to find that
// same subscription again on every later revalidation and restore, so it refuses
// any ambiguity it cannot resolve from CoreTelephony's own data-line answer.
// Reading has no such constraint, and refusing to read on a dual-SIM phone was
// never a safety property, only a leftover from sharing the write path's shape.
//
// Order of preference: the data line CoreTelephony itself reports, then the
// per-context userDataPreferred flag, then the single usable subscription. Each
// candidate must still appear in the usable set, so a stale or foreign answer
// cannot select a SIM that is absent or unusable. Only a genuinely ambiguous
// choice fails.
static id<CCNMServingSubscriptionContext> CCNMServingTargetContext(
    id<CCNMServingCoreTelephonyClient> client,
    NSString **subscriptionUUID,
    NSNumber **slotID,
    NSString **selectionReason,
    NSString **failure
) {
    NSError *error = nil;
    id<CCNMServingSubscriptionInfo> info = nil;
    @try {
        info = [client getSubscriptionInfoWithError:&error];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Subscription query raised %@: %@",
                exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    NSArray *subscriptions = [info respondsToSelector:@selector(subscriptions)] ? info.subscriptions : nil;
    if (error || ![subscriptions isKindOfClass:NSArray.class]) {
        if (failure) {
            *failure = error.localizedDescription ?: @"No subscription contexts were returned.";
        }
        return nil;
    }

    NSMutableArray<id<CCNMServingSubscriptionContext>> *usable = [NSMutableArray array];
    NSMutableArray<id<CCNMServingSubscriptionContext>> *flagged = [NSMutableArray array];
    NSString *reportedDataLineUUID = CCNMServingPreferredDataLineUUID(client);
    id<CCNMServingSubscriptionContext> reported = nil;
    for (id<CCNMServingSubscriptionContext> context in subscriptions) {
        if (![context respondsToSelector:@selector(slotID)] ||
            ![context respondsToSelector:@selector(isSimGood)] ||
            ![context respondsToSelector:@selector(isSimPresent)] ||
            ![context respondsToSelector:@selector(uuid)]) {
            if (failure) {
                *failure = @"A subscription context lacks required identity selectors.";
            }
            return nil;
        }
        if (!context.isSimPresent || !context.isSimGood ||
            ![context.uuid isKindOfClass:NSUUID.class]) {
            continue;
        }
        [usable addObject:context];
        if (reportedDataLineUUID.length &&
            [context.uuid.UUIDString isEqualToString:reportedDataLineUUID]) {
            reported = context;
        }
        // -userDataPreferred is the user's data-line selection as CoreTelephony
        // records it (CTXPCServiceSubscriptionContext, iOS 15). Optional: a build
        // that does not answer it degrades to the next rule.
        if ([context respondsToSelector:@selector(userDataPreferred)]) {
            NSNumber *flag = context.userDataPreferred;
            if ([flag isKindOfClass:NSNumber.class] && flag.boolValue) {
                [flagged addObject:context];
            }
        }
    }

    id<CCNMServingSubscriptionContext> target = nil;
    NSString *reason = nil;
    if (reported) {
        target = reported;
        reason = @"currentDataSubscription";
    } else if (flagged.count == 1) {
        target = flagged.firstObject;
        reason = @"userDataPreferred";
    } else if (usable.count == 1) {
        target = usable.firstObject;
        reason = @"onlyUsableSubscription";
    }
    if (!target) {
        if (failure) {
            *failure = usable.count == 0
                ? @"No present and usable SIM was found."
                : @"Several usable SIMs are present and none is marked as the data line.";
        }
        return nil;
    }
    if (subscriptionUUID) {
        *subscriptionUUID = target.uuid.UUIDString;
    }
    if (slotID) {
        *slotID = @(target.slotID);
    }
    if (selectionReason) {
        *selectionReason = reason;
    }
    return target;
}

static int CCNMAcquireServingSamplerLock(NSString **failure) {
    int descriptor = open(CCNMN78PolicyLockPath().fileSystemRepresentation,
        O_RDWR | O_CREAT, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not open the shared modem lock: %s", strerror(errno)];
        }
        return -1;
    }
    while (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EINTR) {
            continue;
        }
        if (failure) {
            *failure = (errno == EWOULDBLOCK || errno == EAGAIN)
                ? @"A policy operation or serving refresh is already active."
                : [NSString stringWithFormat:@"Could not acquire the shared modem lock: %s", strerror(errno)];
        }
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static void CCNMReleaseServingSamplerLock(int descriptor) {
    if (descriptor < 0) {
        return;
    }
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

static BOOL CCNMNumberIsInteger(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    const char *type = [(NSNumber *)value objCType];
    return type && strchr("cCsSiIlLqQ", type[0]) != NULL;
}

static NSNumber *CCNMBandNumber(id value) {
    if (CCNMNumberIsInteger(value)) {
        long long number = [value longLongValue];
        return number > 0 && number <= 1024 ? @(number) : nil;
    }
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *normalized = [(NSString *)value lowercaseString];
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *prefix in @[ @"band", @"nr", @"lte", @"n", @"b" ]) {
        if ([normalized hasPrefix:prefix]) {
            normalized = [normalized substringFromIndex:prefix.length];
            normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    NSScanner *scanner = [NSScanner scannerWithString:normalized];
    long long number = 0;
    return [scanner scanLongLong:&number] && scanner.isAtEnd && number > 0 && number <= 1024
        ? @(number) : nil;
}

static NSNumber *CCNMIntegerNumber(id value) {
    if (CCNMNumberIsInteger(value)) {
        return @([value longLongValue]);
    }
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:value];
    long long number = 0;
    return [scanner scanLongLong:&number] && scanner.isAtEnd ? @(number) : nil;
}

static NSArray<NSString *> *CCNMServingRequiredRATKeys(void) {
    return @[
        @"kCTRegistrationRadioAccessTechnologyCDMAHybrid",
        @"kCTRegistrationRadioAccessTechnologyGSM",
        @"kCTRegistrationRadioAccessTechnologyLTE",
        @"kCTRegistrationRadioAccessTechnologyNR",
        @"kCTRegistrationRadioAccessTechnologyTDSCDMA",
        @"kCTRegistrationRadioAccessTechnologyUTRAN"
    ];
}

static NSArray<NSNumber *> *CCNMServingNormalizedBandArray(id value) {
    if (![value isKindOfClass:NSArray.class]) {
        return nil;
    }
    NSMutableArray<NSNumber *> *bands = [NSMutableArray array];
    for (id rawBand in (NSArray *)value) {
        NSNumber *band = CCNMBandNumber(rawBand);
        if (!band || [bands containsObject:band]) {
            return nil;
        }
        [bands addObject:band];
    }
    [bands sortUsingComparator:^NSComparisonResult(NSNumber *left, NSNumber *right) {
        return [left compare:right];
    }];
    return [bands copy];
}

static NSDictionary *CCNMServingNormalizedBandDictionary(id value) {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSArray *requiredKeys = CCNMServingRequiredRATKeys();
    NSDictionary *dictionary = (NSDictionary *)value;
    if (![[NSSet setWithArray:dictionary.allKeys] isEqualToSet:
          [NSSet setWithArray:requiredKeys]]) {
        return nil;
    }
    NSMutableDictionary *normalized = [NSMutableDictionary dictionaryWithCapacity:requiredKeys.count];
    for (NSString *key in requiredKeys) {
        NSArray *bands = CCNMServingNormalizedBandArray(value[key]);
        if (!bands) {
            return nil;
        }
        normalized[key] = bands;
    }
    return [normalized copy];
}

static NSDictionary *CCNMServingCapabilityFailure(NSString *error) {
    return @{
        CCNMServingSummaryCapabilityReadSuccessKey: @NO,
        CCNMServingSummaryCapabilityN78SupportedKey: @NO,
        CCNMServingSummaryCapabilityN78ActiveKey: @NO,
        CCNMServingSummaryCapabilitySupportedNRBandsKey: @[],
        CCNMServingSummaryCapabilityActiveNRBandsKey: @[],
        CCNMServingSummaryCapabilitySupportedRATKeysKey: @[],
        CCNMServingSummaryCapabilitySampledAtMillisecondsKey: @0,
        CCNMServingSummaryCapabilityErrorKey: error ?: @"Current BandInfo capability is unavailable."
    };
}

static NSDictionary *CCNMServingReadCapability(id<CCNMServingCoreTelephonyClient> client,
                                                 id context,
                                                 NSString **failure) {
    NSString *abiFailure = nil;
    if (!CCNMServingValidateBandInfoABI(client, &abiFailure)) {
        if (failure) *failure = abiFailure;
        return CCNMServingCapabilityFailure(abiFailure);
    }
    NSError *error = nil;
    id<CCNMServingBandInfo> info = nil;
    @try {
        info = [client getBandInfo:context error:&error];
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"BandInfo query raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
        if (failure) *failure = message;
        return CCNMServingCapabilityFailure(message);
    }
    NSDictionary *active = [info respondsToSelector:@selector(activeBands)] ? info.activeBands : nil;
    NSDictionary *supported = [info respondsToSelector:@selector(supportedBands)] ? info.supportedBands : nil;
    NSArray *requiredKeys = CCNMServingRequiredRATKeys();
    NSDictionary *normalizedActive = CCNMServingNormalizedBandDictionary(active);
    NSDictionary *normalizedSupported = CCNMServingNormalizedBandDictionary(supported);
    if (error || !normalizedActive || !normalizedSupported) {
        NSString *message = error.localizedDescription ?: @"BandInfo capability shape is incomplete.";
        if (failure) *failure = message;
        return CCNMServingCapabilityFailure(message);
    }

    NSArray<NSNumber *> *activeNR = normalizedActive[@"kCTRegistrationRadioAccessTechnologyNR"];
    NSArray<NSNumber *> *supportedNR = normalizedSupported[@"kCTRegistrationRadioAccessTechnologyNR"];
    if (!activeNR || !supportedNR) {
        NSString *message = @"BandInfo NR capability arrays are invalid.";
        if (failure) *failure = message;
        return CCNMServingCapabilityFailure(message);
    }
    NSMutableDictionary *result = [@{
        CCNMServingSummaryCapabilityReadSuccessKey: @YES,
        CCNMServingSummaryCapabilityN78SupportedKey: @([supportedNR containsObject:@78]),
        CCNMServingSummaryCapabilityN78ActiveKey: @([activeNR containsObject:@78]),
        CCNMServingSummaryCapabilitySupportedNRBandsKey: supportedNR,
        CCNMServingSummaryCapabilityActiveNRBandsKey: activeNR,
        CCNMServingSummaryCapabilitySupportedRATKeysKey: [requiredKeys sortedArrayUsingSelector:@selector(compare:)],
        CCNMServingSummaryCapabilitySampledAtMillisecondsKey: @(CCNMServingUnixMilliseconds()),
        CCNMServingSummaryCapabilityErrorKey: @""
    } mutableCopy];
    return [result copy];
}

static CCNMCellMonitorRATKind CCNMRATKind(NSString *rat) {
    if ([rat isEqual:@"kCTCellMonitorRadioAccessTechnologyNR"] ||
        [rat isEqual:@"kCTCellMonitorRadioAccessTechnologyNRNSA"]) {
        return CCNMCellMonitorRATKindNR;
    }
    if ([rat isEqual:@"kCTCellMonitorRadioAccessTechnologyLTE"]) {
        return CCNMCellMonitorRATKindLTE;
    }
    return CCNMCellMonitorRATKindOther;
}

NSDictionary<NSString *, id> *CCNMServingStatusEmptySummary(void) {
    return @{
        CCNMServingSummarySuccessKey: @NO,
        CCNMServingSummaryStateKey: CCNMServingStateUnknown,
        // Unknown until a subscription has actually been chosen. The read path
        // supports any slot, so this must not be pre-filled with slot 1.
        CCNMServingSummaryDataLineKey: @"",
        CCNMServingSummarySlotIDKey: @0,
        CCNMServingSummaryDeviceModelKey: @"",
        CCNMServingSummarySystemBuildKey: @"",
        CCNMServingSummarySystemVersionKey: @"",
        CCNMServingSummarySampledAtMillisecondsKey: @0,
        CCNMServingSummaryPublishedAtMillisecondsKey: @0,
        CCNMServingSummaryStaleKey: @YES,
        CCNMServingSummaryRATKey: @"",
        CCNMServingSummaryErrorKey: @"No fresh serving-cell sample is available.",
        CCNMServingSummarySamplingStatusKey: @"notStarted",
        CCNMServingSummaryUnsafeOutstandingKey: @NO,
        CCNMServingSummarySubscriptionUUIDKey: @"",
        CCNMServingSummaryCapabilityReadSuccessKey: @NO,
        CCNMServingSummaryCapabilityN78SupportedKey: @NO,
        CCNMServingSummaryCapabilityN78ActiveKey: @NO,
        CCNMServingSummaryCapabilitySupportedNRBandsKey: @[],
        CCNMServingSummaryCapabilityActiveNRBandsKey: @[],
        CCNMServingSummaryCapabilitySupportedRATKeysKey: @[],
        CCNMServingSummaryCapabilitySampledAtMillisecondsKey: @0,
        CCNMServingSummaryCapabilityErrorKey: @"Current BandInfo capability is unavailable."
    };
}

static NSDictionary *CCNMServingSummaryFromReport(NSDictionary *report,
                                                   NSString *subscriptionUUID,
                                                   NSNumber *slotID,
                                                   BOOL unsafeOutstanding) {
    BOOL complete = [report[@"cellMonitorSamplingStatus"] isEqual:@"complete"];
    BOOL responsiveMode = [report[@"cellMonitorSamplingMode"] isEqual:@"responsiveStableServing"];
    BOOL servingConfirmed = [report[@"servingObservationConfirmed"] boolValue];
    NSDictionary *confirmedServingCell =
        [report[@"confirmedServingCell"] isKindOfClass:NSDictionary.class]
            ? report[@"confirmedServingCell"] : nil;
    NSString *confirmedRAT = [confirmedServingCell[@"rat"] isKindOfClass:NSString.class]
        ? [confirmedServingCell[@"rat"] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
    BOOL confirmedServingCellValid = confirmedRAT.length > 0 &&
        CCNMBandNumber(confirmedServingCell[@"band"]) != nil;

    NSDictionary *selected = nil;
    CCNMServingState state = CCNMServingStateUnknown;
    if (responsiveMode && complete && servingConfirmed && confirmedServingCellValid) {
        selected = confirmedServingCell;
        NSString *rat = [selected[@"rat"] isKindOfClass:NSString.class] ? selected[@"rat"] : nil;
        switch (CCNMRATKind(rat)) {
            case CCNMCellMonitorRATKindNR: {
                NSNumber *band = CCNMBandNumber(selected[@"band"]);
                state = band.longLongValue == 78 ? CCNMServingStateNRN78 : CCNMServingStateNROther;
                break;
            }
            case CCNMCellMonitorRATKindLTE:
                state = CCNMServingStateLTE;
                break;
            case CCNMCellMonitorRATKindOther:
                state = CCNMServingStateOther;
                break;
        }
    }

    NSNumber *sampledSeconds = [report[@"confirmedServingSampledAt"] isKindOfClass:NSNumber.class]
        ? report[@"confirmedServingSampledAt"] : nil;
    long long sampledAtMilliseconds = sampledSeconds
        ? (long long)llround(sampledSeconds.doubleValue * 1000.0) : 0;
    BOOL success = selected != nil && sampledAtMilliseconds > 0 && !unsafeOutstanding;
    NSMutableDictionary *summary = [CCNMServingStatusEmptySummary() mutableCopy];
    summary[CCNMServingSummarySuccessKey] = @(success);
    summary[CCNMServingSummaryStateKey] = success ? state : CCNMServingStateUnknown;
    summary[CCNMServingSummaryDataLineKey] = slotID
        ? [NSString stringWithFormat:@"slot%lld", slotID.longLongValue] : @"";
    summary[CCNMServingSummarySlotIDKey] = slotID ?: @0;
    [summary addEntriesFromDictionary:CCNMServingDeviceIdentity()];
    summary[CCNMServingSummarySampledAtMillisecondsKey] = @(sampledAtMilliseconds);
    summary[CCNMServingSummaryStaleKey] = @(!success);
    summary[CCNMServingSummarySamplingStatusKey] = report[@"cellMonitorSamplingStatus"] ?: @"failed";
    summary[CCNMServingSummaryUnsafeOutstandingKey] = @(unsafeOutstanding);
    summary[CCNMServingSummarySubscriptionUUIDKey] = subscriptionUUID ?: @"";
    for (NSString *telemetryKey in @[
        @"cellMonitorSamplingMode",
        @"cellMonitorStopReason",
        @"cellMonitorSamplingElapsedMilliseconds",
        @"cellMonitorScheduledDelayMilliseconds",
        @"cellMonitorRefreshCallbackLatencyMilliseconds",
        @"cellMonitorCopyCallbackLatencyMilliseconds",
        @"cellMonitorAttemptedSampleCount",
        @"cellMonitorAttemptedRefreshCount",
        @"stableServingConfirmationCount"
    ]) {
        id value = report[telemetryKey];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
            summary[telemetryKey] = value;
        }
    }

    if (success) {
        NSString *rat = [selected[@"rat"] isKindOfClass:NSString.class] ? selected[@"rat"] : @"";
        NSNumber *band = CCNMBandNumber(selected[@"band"]);
        summary[CCNMServingSummaryRATKey] = rat;
        if (band) {
            summary[CCNMServingSummaryBandKey] = band;
        }
        if (state == CCNMServingStateNRN78 || state == CCNMServingStateNROther) {
            NSNumber *nrarfcn = CCNMIntegerNumber(selected[@"nrarfcn"] ?: selected[@"frequency"]);
            double frequencyMHz = nrarfcn ? CCNMNRARFCNToMHz(nrarfcn.longLongValue) : -1.0;
            if (CCNMServingFrequencyIsValid(frequencyMHz)) {
                summary[CCNMServingSummaryFrequencyMHzKey] = @(frequencyMHz);
            }
        }
        summary[CCNMServingSummaryErrorKey] = @"";
    } else {
        NSString *error = unsafeOutstanding
            ? @"A private Cell Monitor callback is still outstanding; close and reopen Settings before another modem operation."
            : ([report[@"cellMonitorSamplingFailure"] isKindOfClass:NSString.class]
                ? report[@"cellMonitorSamplingFailure"] : nil);
        summary[CCNMServingSummaryErrorKey] = error.length ? error : @"Serving-cell evidence was incomplete.";
    }
    return [summary copy];
}

@interface CCNMServingStatusProvider ()
@property (nonatomic, strong) dispatch_queue_t operationQueue;
@property (nonatomic, copy) NSDictionary<NSString *, id> *lastSummary;
@property (nonatomic, copy) NSDictionary<NSString *, id> *lastSupportEvidence;
@property (nonatomic, assign) int retainedSamplerLockDescriptor;
@property (nonatomic, strong) id retainedSamplerClient;
@property (nonatomic, strong) id retainedSamplerContext;
@end

@implementation CCNMServingStatusProvider

+ (instancetype)sharedProvider {
    static CCNMServingStatusProvider *provider;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[self alloc] init];
    });
    return provider;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _operationQueue = dispatch_queue_create("com.doimty.nrmanager.serving-status", DISPATCH_QUEUE_SERIAL);
        _lastSummary = CCNMServingReadCachedSummary() ?: CCNMServingStatusEmptySummary();
        _lastSupportEvidence = @{};
        _retainedSamplerLockDescriptor = -1;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)currentSummary {
    NSDictionary *cached = CCNMServingReadCachedSummary();
    NSDictionary *snapshot = nil;
    @synchronized(self) {
        snapshot = [self.lastSummary copy];
        long long cachedAt = [cached[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue];
        long long memoryAt = [snapshot[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue];
        if (cachedAt > memoryAt) {
            self.lastSummary = cached;
            snapshot = cached;
        }
    }
    NSMutableDictionary *current = [snapshot mutableCopy] ?: [CCNMServingStatusEmptySummary() mutableCopy];
    long long sampledAt = [current[CCNMServingSummarySampledAtMillisecondsKey] longLongValue];
    long long age = CCNMServingUnixMilliseconds() - sampledAt;
    BOOL stale = sampledAt <= 0 || age < 0 || age > CCNMServingFreshnessLifetimeMilliseconds;
    current[CCNMServingSummaryStaleKey] = @(stale);
    if (stale) {
        current[CCNMServingSummarySuccessKey] = @NO;
        current[CCNMServingSummaryStateKey] = CCNMServingStateUnknown;
    }
    return [current copy];
}

- (NSDictionary<NSString *, id> *)supportEvidence {
    @synchronized(self) {
        return [self.lastSupportEvidence copy] ?: @{};
    }
}

- (void)publishSummary:(NSDictionary *)summary evidence:(NSDictionary *)evidence {
    int cacheLockDescriptor = CCNMServingAcquireCacheLock();
    NSDictionary *cached = cacheLockDescriptor >= 0 ? CCNMServingReadCachedSummary() : nil;
    NSMutableDictionary *published =
        [(summary ?: CCNMServingStatusEmptySummary()) mutableCopy];
    @synchronized(self) {
        long long previousPublishedAt = MAX(
            [cached[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue],
            [self.lastSummary[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue]);
        long long publishedAt = MAX(CCNMServingUnixMilliseconds(), previousPublishedAt + 1);
        published[CCNMServingSummaryPublishedAtMillisecondsKey] = @(publishedAt);
        self.lastSummary = [published copy];
        self.lastSupportEvidence = evidence ?: @{};
    }
    BOOL persisted = cacheLockDescriptor >= 0 && CCNMServingPersistCachedSummary(published);
    CCNMServingReleaseCacheLock(cacheLockDescriptor);
    if (persisted) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)CCNMServingStatusDidChangeDarwinNotification,
            NULL, NULL, true);
    }
}

- (void)deliverCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
    if (!completion) {
        return;
    }
    NSDictionary *summary = [self currentSummary];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(summary);
    });
}

- (void)releaseRetainedSamplerLockWhenSafe {
    if (self.retainedSamplerLockDescriptor < 0) {
        return;
    }
    if (CCNMServingCellSamplerHasUnsafeOutstandingAttempt()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.operationQueue, ^{
            [self releaseRetainedSamplerLockWhenSafe];
        });
        return;
    }
    NSMutableDictionary *resolved = nil;
    @synchronized(self) {
        resolved = [self.lastSummary mutableCopy] ?: [CCNMServingStatusEmptySummary() mutableCopy];
    }
    resolved[CCNMServingSummarySampledAtMillisecondsKey] = @0;
    resolved[CCNMServingSummaryUnsafeOutstandingKey] = @NO;
    resolved[CCNMServingSummarySuccessKey] = @NO;
    resolved[CCNMServingSummaryStateKey] = CCNMServingStateUnknown;
    resolved[CCNMServingSummaryStaleKey] = @YES;
    resolved[CCNMServingSummaryErrorKey] =
        @"The late Cell Monitor callback resolved; refresh serving status again.";
    [self publishSummary:resolved evidence:self.lastSupportEvidence];
    CCNMReleaseServingSamplerLock(self.retainedSamplerLockDescriptor);
    self.retainedSamplerLockDescriptor = -1;
    self.retainedSamplerClient = nil;
    self.retainedSamplerContext = nil;
}

- (void)refreshWithCompletion:(void (^)(NSDictionary<NSString *, id> *))completion {
    dispatch_async(self.operationQueue, ^{
        @autoreleasepool {
            NSString *failure = nil;
            if (self.retainedSamplerLockDescriptor >= 0) {
                NSMutableDictionary *summary = [CCNMServingStatusEmptySummary() mutableCopy];
                summary[CCNMServingSummaryUnsafeOutstandingKey] = @YES;
                summary[CCNMServingSummaryErrorKey] = @"A previous Cell Monitor callback is still outstanding.";
                [self publishSummary:summary evidence:self.lastSupportEvidence];
                [self deliverCompletion:completion];
                return;
            }
            int lockDescriptor = CCNMAcquireServingSamplerLock(&failure);
            if (lockDescriptor < 0) {
                // A different process may own an unsafe private callback latch.
                // Never overwrite shared serving truth merely because this caller
                // could not acquire the modem lock.
                [self deliverCompletion:completion];
                return;
            }

            NSDictionary *report = nil;
            NSDictionary *capability = CCNMServingCapabilityFailure(
                @"Current BandInfo capability was not sampled.");
            NSString *subscriptionUUID = nil;
            NSNumber *slotID = nil;
            NSString *selectionReason = nil;
            void *frameworkHandle = NULL;
            id<CCNMServingCoreTelephonyClient> client = nil;
            id context = nil;
            @try {
                // No device allowlist here. Reading the serving cell and the band
                // capability changes nothing on the modem, so there is no restore
                // to have verified and no reason to refuse an unknown model. Every
                // private call below is ABI checked and bounded; that is what makes
                // this safe on an unverified device. The write path performs its
                // own runtime capability and durable-evidence checks.
                client = CCNMServingCreateClient(&frameworkHandle, &failure);
                context = client
                    ? CCNMServingTargetContext(client, &subscriptionUUID, &slotID,
                        &selectionReason, &failure)
                    : nil;
                if (context) {
                    // Read capability before the Cell Monitor sampler so a
                    // late sampler callback never shares the client with a
                    // second CoreTelephony query.
                    capability = CCNMServingReadCapability(client, context, &failure);
                }
                report = context
                    ? CCNMRunResponsiveServingCellSampler(client, context, frameworkHandle)
                    : @{ @"cellMonitorSamplingFailure": failure ?: @"The data-line context is unavailable." };
            } @catch (NSException *exception) {
                failure = [NSString stringWithFormat:@"Serving refresh raised %@: %@",
                    exception.name, exception.reason ?: @"(no reason)"];
                report = @{ @"cellMonitorSamplingFailure": failure };
                capability = CCNMServingCapabilityFailure(failure);
            }

            BOOL unsafeOutstanding = CCNMServingCellSamplerHasUnsafeOutstandingAttempt();
            NSMutableDictionary *summary = [CCNMServingSummaryFromReport(
                report ?: @{}, subscriptionUUID, slotID, unsafeOutstanding) mutableCopy];
            [summary addEntriesFromDictionary:capability ?: @{}];
            NSMutableDictionary *evidence = [report mutableCopy] ?: [NSMutableDictionary dictionary];
            evidence[@"capability"] = capability ?: @{};
            evidence[@"deviceIdentity"] = CCNMServingDeviceIdentity();
            if (selectionReason) {
                evidence[@"dataLineSelectionReason"] = selectionReason;
            }
            [self publishSummary:[summary copy] evidence:[evidence copy]];
            if (unsafeOutstanding) {
                self.retainedSamplerLockDescriptor = lockDescriptor;
                self.retainedSamplerClient = client;
                self.retainedSamplerContext = context;
                [self releaseRetainedSamplerLockWhenSafe];
            } else {
                CCNMReleaseServingSamplerLock(lockDescriptor);
            }
            [self deliverCompletion:completion];
        }
    });
}

@end
