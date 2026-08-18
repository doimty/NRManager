#import "CCNMServingStatusProvider.h"
#import "CCNMN78PolicyController.h"
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

NSString *const CCNMServingSummaryStateKey = @"servingState";
NSString *const CCNMServingSummaryDataLineKey = @"dataLine";
NSString *const CCNMServingSummarySampledAtMillisecondsKey = @"sampledAtMilliseconds";
NSString *const CCNMServingSummaryStaleKey = @"stale";
NSString *const CCNMServingSummaryRATKey = @"rat";
NSString *const CCNMServingSummaryBandKey = @"band";
NSString *const CCNMServingSummaryFrequencyMHzKey = @"frequencyMHz";
NSString *const CCNMServingSummaryErrorKey = @"error";
NSString *const CCNMServingSummarySuccessKey = @"success";
NSString *const CCNMServingSummarySamplingStatusKey = @"samplingStatus";
NSString *const CCNMServingSummaryUnsafeOutstandingKey = @"unsafeOutstanding";

static const long long CCNMServingFreshnessLifetimeMilliseconds = 30000;
static NSString *const CCNMServingCacheFilename = @"me.nixuge.networkmanager.serving-status.plist";

static NSString *CCNMServingCachePath(void) {
    return [CCNMN78PolicyStatePath().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:CCNMServingCacheFilename];
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
    return [summary copy];
}

static void CCNMServingPersistCachedSummary(NSDictionary *summary) {
    if (![summary isKindOfClass:NSDictionary.class]) {
        return;
    }
    NSDictionary *cache = @{
        @"schemaVersion": @1,
        @"summary": summary
    };
    [cache writeToFile:CCNMServingCachePath() atomically:YES];
}

@protocol CCNMServingCoreTelephonyClient <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (id)getSubscriptionInfoWithError:(NSError **)error;
@end

@protocol CCNMServingSubscriptionInfo <NSObject>
- (NSArray *)subscriptions;
@end

@protocol CCNMServingSubscriptionContext <NSObject>
- (long long)slotID;
- (BOOL)isSimGood;
- (BOOL)isSimPresent;
- (NSUUID *)uuid;
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

static BOOL CCNMServingValidateSubscriptionABI(id client, NSString **failure) {
    SEL selector = @selector(getSubscriptionInfoWithError:);
    if (!client || ![client respondsToSelector:selector]) {
        if (failure) {
            *failure = @"The subscription query is unavailable.";
        }
        return NO;
    }
    NSMethodSignature *signature = [client methodSignatureForSelector:selector];
    const char *returnType = signature ? CCNMServingSkipTypeQualifiers(signature.methodReturnType) : NULL;
    const char *errorType = signature && signature.numberOfArguments > 2
        ? CCNMServingSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    BOOL valid = signature && signature.numberOfArguments == 3 &&
        returnType && returnType[0] == '@' && errorType && errorType[0] == '^' && errorType[1] == '@';
    if (!valid && failure) {
        *failure = @"The subscription query has an unexpected private ABI.";
    }
    return valid;
}

static BOOL CCNMServingValidateTarget(NSString **failure) {
    NSString *model = CCNMServingSysctlString("hw.machine");
    NSString *build = CCNMServingSysctlString("kern.osversion");
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    BOOL valid = [model isEqual:@"iPhone14,3"] && [build isEqual:@"19B81"] &&
        version.majorVersion == 15 && version.minorVersion == 1 && version.patchVersion == 1;
    if (!valid && failure) {
        *failure = @"Serving status is restricted to the accepted iPhone14,3 / iOS 15.1.1 target.";
    }
    return valid;
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

static id<CCNMServingSubscriptionContext> CCNMServingTargetContext(
    id<CCNMServingCoreTelephonyClient> client,
    NSString **subscriptionUUID,
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

    NSUInteger presentCount = 0;
    NSUInteger targetCount = 0;
    id<CCNMServingSubscriptionContext> target = nil;
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
        BOOL present = context.isSimPresent;
        if (present) {
            presentCount++;
        }
        if (context.slotID == 1 && present && context.isSimGood &&
            [context.uuid isKindOfClass:NSUUID.class]) {
            target = context;
            targetCount++;
        }
    }
    if (presentCount != 1 || targetCount != 1 || !target) {
        if (failure) {
            *failure = @"Exactly one present and good SIM in slot 1 is required.";
        }
        return nil;
    }
    if (subscriptionUUID) {
        *subscriptionUUID = target.uuid.UUIDString;
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

static NSDictionary *CCNMLatestObservedCell(NSDictionary *current, NSDictionary *candidate) {
    if (![candidate isKindOfClass:NSDictionary.class] ||
        ![candidate[@"servingCell"] isKindOfClass:NSDictionary.class]) {
        return current;
    }
    if (!current || [candidate[@"sampleIndex"] integerValue] >= [current[@"sampleIndex"] integerValue]) {
        return candidate;
    }
    return current;
}

NSDictionary<NSString *, id> *CCNMServingStatusEmptySummary(void) {
    return @{
        CCNMServingSummarySuccessKey: @NO,
        CCNMServingSummaryStateKey: CCNMServingStateUnknown,
        CCNMServingSummaryDataLineKey: @"slot1",
        CCNMServingSummarySampledAtMillisecondsKey: @0,
        CCNMServingSummaryStaleKey: @YES,
        CCNMServingSummaryRATKey: @"",
        CCNMServingSummaryErrorKey: @"No fresh serving-cell sample is available.",
        CCNMServingSummarySamplingStatusKey: @"notStarted",
        CCNMServingSummaryUnsafeOutstandingKey: @NO,
    };
}

static NSDictionary *CCNMServingSummaryFromReport(NSDictionary *report,
                                                   NSString *subscriptionUUID,
                                                   BOOL unsafeOutstanding) {
    BOOL complete = [report[@"cellMonitorSamplingStatus"] isEqual:@"complete"];
    BOOL nrObserved = [report[@"nrObservationStatus"] isEqual:@"observed"];
    NSArray *observed = [report[@"observedServingCells"] isKindOfClass:NSArray.class]
        ? report[@"observedServingCells"] : @[];
    NSDictionary *latestNR = nil;
    NSDictionary *latestLTE = nil;
    NSDictionary *latestOther = nil;
    for (NSDictionary *entry in observed) {
        NSDictionary *cell = [entry[@"servingCell"] isKindOfClass:NSDictionary.class]
            ? entry[@"servingCell"] : nil;
        NSString *rat = [cell[@"rat"] isKindOfClass:NSString.class] ? cell[@"rat"] : nil;
        switch (CCNMRATKind(rat)) {
            case CCNMCellMonitorRATKindNR:
                latestNR = CCNMLatestObservedCell(latestNR, entry);
                break;
            case CCNMCellMonitorRATKindLTE:
                latestLTE = CCNMLatestObservedCell(latestLTE, entry);
                break;
            case CCNMCellMonitorRATKindOther:
                latestOther = CCNMLatestObservedCell(latestOther, entry);
                break;
        }
    }

    NSDictionary *selected = nil;
    CCNMServingState state = CCNMServingStateUnknown;
    if (complete && nrObserved && latestNR) {
        selected = latestNR[@"servingCell"];
        NSNumber *band = CCNMBandNumber(selected[@"band"]);
        state = band.longLongValue == 78 ? CCNMServingStateNRN78 : CCNMServingStateNROther;
    } else if (complete && !nrObserved && latestLTE) {
        selected = latestLTE[@"servingCell"];
        state = CCNMServingStateLTE;
    } else if (complete && !nrObserved && latestOther) {
        selected = latestOther[@"servingCell"];
        state = CCNMServingStateOther;
    }

    NSNumber *finishedSeconds = [report[@"cellMonitorSamplingFinishedAt"] isKindOfClass:NSNumber.class]
        ? report[@"cellMonitorSamplingFinishedAt"] : nil;
    long long sampledAtMilliseconds = finishedSeconds
        ? (long long)llround(finishedSeconds.doubleValue * 1000.0) : 0;
    BOOL success = selected != nil && sampledAtMilliseconds > 0 && !unsafeOutstanding;
    NSMutableDictionary *summary = [CCNMServingStatusEmptySummary() mutableCopy];
    summary[CCNMServingSummarySuccessKey] = @(success);
    summary[CCNMServingSummaryStateKey] = success ? state : CCNMServingStateUnknown;
    summary[CCNMServingSummaryDataLineKey] = @"slot1";
    summary[CCNMServingSummarySampledAtMillisecondsKey] = @(sampledAtMilliseconds);
    summary[CCNMServingSummaryStaleKey] = @(!success);
    summary[CCNMServingSummarySamplingStatusKey] = report[@"cellMonitorSamplingStatus"] ?: @"failed";
    summary[CCNMServingSummaryUnsafeOutstandingKey] = @(unsafeOutstanding);
    summary[@"subscriptionUUID"] = subscriptionUUID ?: @"";

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
        _operationQueue = dispatch_queue_create("me.nixuge.networkmanager.serving-status", DISPATCH_QUEUE_SERIAL);
        _lastSummary = CCNMServingReadCachedSummary() ?: CCNMServingStatusEmptySummary();
        _lastSupportEvidence = @{};
        _retainedSamplerLockDescriptor = -1;
    }
    return self;
}

- (NSDictionary<NSString *, id> *)currentSummary {
    NSDictionary *snapshot = nil;
    @synchronized(self) {
        snapshot = [self.lastSummary copy];
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
    NSDictionary *published = summary ?: CCNMServingStatusEmptySummary();
    @synchronized(self) {
        self.lastSummary = published;
        self.lastSupportEvidence = evidence ?: @{};
    }
    CCNMServingPersistCachedSummary(published);
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
    CCNMReleaseServingSamplerLock(self.retainedSamplerLockDescriptor);
    self.retainedSamplerLockDescriptor = -1;
    self.retainedSamplerClient = nil;
    self.retainedSamplerContext = nil;
    @synchronized(self) {
        NSMutableDictionary *resolved = [self.lastSummary mutableCopy] ?: [CCNMServingStatusEmptySummary() mutableCopy];
        resolved[CCNMServingSummaryUnsafeOutstandingKey] = @NO;
        resolved[CCNMServingSummarySuccessKey] = @NO;
        resolved[CCNMServingSummaryStateKey] = CCNMServingStateUnknown;
        resolved[CCNMServingSummaryStaleKey] = @YES;
        resolved[CCNMServingSummaryErrorKey] = @"The late Cell Monitor callback resolved; refresh serving status again.";
        self.lastSummary = resolved;
    }
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
                NSMutableDictionary *summary = [CCNMServingStatusEmptySummary() mutableCopy];
                summary[CCNMServingSummaryErrorKey] = failure ?: @"The shared modem lock is busy.";
                [self publishSummary:summary evidence:@{}];
                [self deliverCompletion:completion];
                return;
            }

            NSDictionary *report = nil;
            NSString *subscriptionUUID = nil;
            void *frameworkHandle = NULL;
            id<CCNMServingCoreTelephonyClient> client = nil;
            id context = nil;
            @try {
                if (!CCNMServingValidateTarget(&failure)) {
                    report = @{ @"cellMonitorSamplingFailure": failure ?: @"Unsupported target." };
                } else {
                    client = CCNMServingCreateClient(&frameworkHandle, &failure);
                    context = client ? CCNMServingTargetContext(client, &subscriptionUUID, &failure) : nil;
                    report = context
                        ? CCNMRunAdaptiveServingCellSampler(client, context, frameworkHandle)
                        : @{ @"cellMonitorSamplingFailure": failure ?: @"The data-line context is unavailable." };
                }
            } @catch (NSException *exception) {
                failure = [NSString stringWithFormat:@"Serving refresh raised %@: %@",
                    exception.name, exception.reason ?: @"(no reason)"];
                report = @{ @"cellMonitorSamplingFailure": failure };
            }

            BOOL unsafeOutstanding = CCNMServingCellSamplerHasUnsafeOutstandingAttempt();
            NSDictionary *summary = CCNMServingSummaryFromReport(report ?: @{}, subscriptionUUID, unsafeOutstanding);
            [self publishSummary:summary evidence:report ?: @{}];
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
