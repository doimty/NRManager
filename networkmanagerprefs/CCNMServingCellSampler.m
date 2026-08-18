#import "CCNMServingCellSampler.h"
#include <dlfcn.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

@protocol CCNMCellInfo <NSObject>
- (id)legacyInfo;
@end

@protocol CCNMServingCellClient <NSObject>
- (void)copyCellInfo:(id)context completion:(void(^)(id cellInfo, NSError *error))completion;
- (void)refreshCellMonitor:(id)context completion:(void(^)(NSError *error))completion;
- (void)getRatSelection:(id)context completion:(void(^)(NSString *selection, NSString *preferred, NSError *error))completion;
@end

static const NSUInteger CCNMServingCellMaximumSampleCount = 10;
static const NSUInteger CCNMServingCellRequiredConsecutiveNRSamples = 2;
static const NSUInteger CCNMServingCellRequiredConsecutiveServingSamples = 2;
static const int64_t CCNMServingCellAttemptTimeoutSeconds = 5;
static const useconds_t CCNMServingCellRefreshSettleMicroseconds = 500000;
static const useconds_t CCNMServingCellInterSampleDelayMicroseconds = 500000;
static const useconds_t CCNMServingCellResponsiveInterSampleDelayMicroseconds = 0;

static NSUInteger CCNMCellMonitorUnsafeOutstandingCount = 0;

static NSObject *CCNMCellMonitorUnsafeOutstandingLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void CCNMMarkCellMonitorUnsafeOutstanding(void) {
    @synchronized(CCNMCellMonitorUnsafeOutstandingLock()) {
        CCNMCellMonitorUnsafeOutstandingCount++;
    }
}

static void CCNMResolveCellMonitorUnsafeOutstanding(void) {
    @synchronized(CCNMCellMonitorUnsafeOutstandingLock()) {
        if (CCNMCellMonitorUnsafeOutstandingCount > 0) {
            CCNMCellMonitorUnsafeOutstandingCount--;
        }
    }
}

@interface CCNMCellMonitorAsyncState : NSObject
@property (atomic, strong) id result;
@property (atomic, strong) NSError *error;
@property (atomic, assign) NSTimeInterval callbackAt;
@property (atomic, assign) NSTimeInterval callbackMonotonic;
@property (atomic, assign, getter=isCompleted) BOOL completed;
@property (atomic, assign, getter=isUnsafeOutstanding) BOOL unsafeOutstanding;
- (BOOL)completeWithResult:(id)result
                     error:(NSError *)error
                callbackAt:(NSTimeInterval)callbackAt
         callbackMonotonic:(NSTimeInterval)callbackMonotonic
      wasUnsafeOutstanding:(BOOL *)wasUnsafeOutstanding;
- (BOOL)markUnsafeOutstanding;
@end

@implementation CCNMCellMonitorAsyncState
- (BOOL)completeWithResult:(id)result
                     error:(NSError *)error
                callbackAt:(NSTimeInterval)callbackAt
         callbackMonotonic:(NSTimeInterval)callbackMonotonic
      wasUnsafeOutstanding:(BOOL *)wasUnsafeOutstanding {
    @synchronized (self) {
        if (self.isCompleted) return NO;
        self.result = result;
        self.error = error;
        self.callbackAt = callbackAt;
        self.callbackMonotonic = callbackMonotonic;
        self.completed = YES;
        if (wasUnsafeOutstanding) {
            *wasUnsafeOutstanding = self.isUnsafeOutstanding;
        }
        return YES;
    }
}

- (BOOL)markUnsafeOutstanding {
    @synchronized (self) {
        if (self.isCompleted) return NO;
        if (!self.isUnsafeOutstanding) {
            CCNMMarkCellMonitorUnsafeOutstanding();
            self.unsafeOutstanding = YES;
        }
        return YES;
    }
}
@end

static NSTimeInterval CCNMMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (NSTimeInterval)now.tv_sec + ((NSTimeInterval)now.tv_nsec / 1000000000.0);
}

static NSNumber *CCNMMillisecondsBetween(NSTimeInterval startedMonotonic,
                                          NSTimeInterval finishedMonotonic) {
    if (startedMonotonic <= 0 || finishedMonotonic < startedMonotonic) return @0;
    return @((long long)((finishedMonotonic - startedMonotonic) * 1000.0));
}

static NSNumber *CCNMElapsedMillisecondsSince(NSTimeInterval startedMonotonic) {
    return CCNMMillisecondsBetween(startedMonotonic, CCNMMonotonicNow());
}

static NSString *CCNMCellMonitorSamplingStatusName(CCNMCellMonitorSamplingStatus status) {
    switch (status) {
        case CCNMCellMonitorSamplingComplete:
            return @"complete";
        case CCNMCellMonitorSamplingPartial:
            return @"partial";
        case CCNMCellMonitorSamplingFailed:
        default:
            return @"failed";
    }
}

static NSString *CCNMNRObservationStatusName(CCNMNRObservationStatus status) {
    switch (status) {
        case CCNMNRObservationObserved:
            return @"observed";
        case CCNMNRObservationNotObservedComplete:
            return @"notObservedComplete";
        case CCNMNRObservationIndeterminatePartial:
        default:
            return @"indeterminatePartial";
    }
}

static NSString *CCNMAdaptiveSamplerStopReasonName(CCNMAdaptiveSamplerStopReason reason) {
    switch (reason) {
        case CCNMAdaptiveSamplerStopExplicitNRConfirmed:
            return @"explicitNRConfirmed";
        case CCNMAdaptiveSamplerStopStableServingConfirmed:
            return @"stableServingConfirmed";
        case CCNMAdaptiveSamplerStopWindowExhausted:
            return @"windowExhausted";
        case CCNMAdaptiveSamplerStopTimedOut:
            return @"timedOut";
        case CCNMAdaptiveSamplerStopInvocationException:
            return @"invocationException";
        case CCNMAdaptiveSamplerStopInvalidConfiguration:
            return @"invalidConfiguration";
        case CCNMAdaptiveSamplerStopRunning:
        default:
            return @"notStarted";
    }
}

static const char *CCNMSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL CCNMValidateAsyncSelectorABI(id client, SEL selector, NSString **failure) {
    if (!client || ![client respondsToSelector:selector]) {
        if (failure) *failure = [NSString stringWithFormat:@"%@ is unavailable.", NSStringFromSelector(selector)];
        return NO;
    }

    NSMethodSignature *signature = [client methodSignatureForSelector:selector];
    const char *returnType = signature ? CCNMSkipTypeQualifiers(signature.methodReturnType) : NULL;
    const char *argumentType = signature && signature.numberOfArguments > 2
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    const char *completionType = signature && signature.numberOfArguments > 3
        ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:3]) : NULL;
    BOOL valid = signature &&
                 signature.numberOfArguments == 4 &&
                 returnType && strcmp(returnType, @encode(void)) == 0 &&
                 argumentType && argumentType[0] == '@' &&
                 completionType && completionType[0] == '@' && completionType[1] == '?';
    if (!valid && failure) {
        *failure = [NSString stringWithFormat:@"%@ runtime ABI is not void(context, block).",
            NSStringFromSelector(selector)];
    }
    return valid;
}

static NSArray<NSString *> *CCNMCellMonitorSymbolNames(void) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
            @"kCTCellMonitorCellType",
            @"kCTCellMonitorCellTypeServing",
            @"kCTCellMonitorCellRadioAccessTechnology",
            @"kCTCellMonitorIsSA",
            @"kCTCellMonitorNRARFCN",
            @"kCTCellMonitorChannelNumber",
            @"kCTCellMonitorUARFCN",
            @"kCTCellMonitorBandInfo",
            @"kCTCellMonitorBandwidth",
            @"kCTCellMonitorDeploymentType",
            @"kCTCellMonitorPCI",
            @"kCTCellMonitorPID",
            @"kCTCellMonitorCellId",
            @"kCTCellMonitorTAC",
            @"kCTCellMonitorMCC",
            @"kCTCellMonitorMNC",
            @"kCTCellMonitorRSRP",
            @"kCTCellMonitorRSRQ",
            @"kCTCellMonitorSNR",
            @"kCTCellMonitorGSCN"
        ];
    });
    return names;
}

static NSArray<NSString *> *CCNMCellMonitorCriticalClassificationSymbolNames(void) {
    return @[
        @"kCTCellMonitorCellType",
        @"kCTCellMonitorCellTypeServing",
        @"kCTCellMonitorCellRadioAccessTechnology"
    ];
}

static NSDictionary<NSString *, NSString *> *CCNMCellMonitorSymbols(void *ctHandle,
                                                                     NSArray<NSString *> **missingSymbols) {
    static NSDictionary<NSString *, NSString *> *resolvedSymbols = nil;
    static NSArray<NSString *> *unresolvedSymbols = nil;
    static dispatch_once_t onceToken;

    if (!ctHandle) {
        if (missingSymbols) *missingSymbols = CCNMCellMonitorSymbolNames();
        return @{};
    }

    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, NSString *> *resolved = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        for (NSString *symbolName in CCNMCellMonitorSymbolNames()) {
            CFStringRef *symbolAddress = (CFStringRef *)dlsym(ctHandle, symbolName.UTF8String);
            CFStringRef symbolValue = symbolAddress ? *symbolAddress : NULL;
            if (symbolValue && CFGetTypeID(symbolValue) == CFStringGetTypeID()) {
                resolved[symbolName] = (__bridge NSString *)symbolValue;
            } else {
                [missing addObject:symbolName];
            }
        }
        resolvedSymbols = [resolved copy];
        unresolvedSymbols = [missing copy];
    });

    if (missingSymbols) *missingSymbols = unresolvedSymbols ?: @[];
    return resolvedSymbols ?: @{};
}

static id CCNMCellMonitorValue(NSDictionary *cell,
                               NSDictionary<NSString *, NSString *> *symbols,
                               NSString *symbolName) {
    NSString *key = symbols[symbolName];
    return key ? cell[key] : nil;
}

static id CCNMTypedPropertyListEvidenceInternal(id object,
                                                 NSUInteger depth,
                                                 NSMutableSet<NSValue *> *containerStack) {
    if (!object) return @{@"class": @"(nil)", @"kind": @"nil"};

    NSString *className = NSStringFromClass([object class]) ?: @"(unknown)";
    if (depth >= 16) {
        return @{
            @"class": className,
            @"kind": @"depthLimit",
            @"description": [object description] ?: @""
        };
    }
    if ([object isKindOfClass:[NSString class]] ||
        [object isKindOfClass:[NSNumber class]] ||
        [object isKindOfClass:[NSDate class]] ||
        [object isKindOfClass:[NSData class]]) {
        return @{@"class": className, @"kind": @"propertyListScalar", @"value": object};
    }
    if ([object isKindOfClass:[NSNull class]]) {
        return @{@"class": className, @"kind": @"null"};
    }

    BOOL isDictionary = [object isKindOfClass:[NSDictionary class]];
    BOOL isArray = [object isKindOfClass:[NSArray class]];
    BOOL isSet = [object isKindOfClass:[NSSet class]];
    if (isDictionary || isArray || isSet) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
        if ([containerStack containsObject:identity]) {
            return @{@"class": className, @"kind": @"cycle"};
        }
        [containerStack addObject:identity];

        NSMutableArray *elements = [NSMutableArray array];
        if (isDictionary) {
            for (id key in (NSDictionary *)object) {
                id value = [(NSDictionary *)object objectForKey:key];
                [elements addObject:@{
                    @"key": CCNMTypedPropertyListEvidenceInternal(key, depth + 1, containerStack),
                    @"value": CCNMTypedPropertyListEvidenceInternal(value, depth + 1, containerStack)
                }];
            }
            [containerStack removeObject:identity];
            return @{@"class": className, @"kind": @"dictionary", @"entries": elements};
        }

        for (id value in isArray ? (id)object : [(NSSet *)object allObjects]) {
            [elements addObject:CCNMTypedPropertyListEvidenceInternal(value, depth + 1, containerStack)];
        }
        [containerStack removeObject:identity];
        return @{
            @"class": className,
            @"kind": isArray ? @"array" : @"set",
            @"elements": elements
        };
    }

    NSString *description = nil;
    @try {
        description = [object description];
    } @catch (NSException *exception) {
        description = [NSString stringWithFormat:@"description raised %@", exception.name];
    }
    return @{@"class": className, @"kind": @"description", @"description": description ?: @""};
}

static id CCNMTypedPropertyListEvidence(id object) {
    return CCNMTypedPropertyListEvidenceInternal(object, 0, [NSMutableSet set]);
}

id CCNMServingCellTypedPropertyListEvidence(id object) {
    return CCNMTypedPropertyListEvidence(object);
}

static NSDictionary *CCNMNSErrorEvidence(NSError *error) {
    if (!error) {
        return @{
            @"class": @"(nil)",
            @"domain": @"",
            @"code": @0,
            @"localizedDescription": @"",
            @"userInfoRaw": CCNMTypedPropertyListEvidence(nil)
        };
    }
    return @{
        @"class": NSStringFromClass([error class]) ?: @"(unknown)",
        @"domain": error.domain ?: @"",
        @"code": @(error.code),
        @"localizedDescription": error.localizedDescription ?: @"",
        @"userInfoRaw": CCNMTypedPropertyListEvidence(error.userInfo)
    };
}

static NSDictionary *CCNMExceptionEvidence(NSException *exception) {
    return @{
        @"class": exception ? (NSStringFromClass([exception class]) ?: @"(unknown)") : @"(nil)",
        @"name": exception.name ?: @"",
        @"reason": exception.reason ?: @"",
        @"userInfoRaw": CCNMTypedPropertyListEvidence(exception.userInfo)
    };
}

static id CCNMProbeFieldValue(id value) {
    if ([value isKindOfClass:[NSString class]] ||
        [value isKindOfClass:[NSNumber class]] ||
        [value isKindOfClass:[NSDate class]] ||
        [value isKindOfClass:[NSData class]]) {
        return value;
    }
    return value ? ([value description] ?: @"") : nil;
}

static void CCNMSetProbeField(NSMutableDictionary *fields, NSString *name, id value) {
    id safeValue = CCNMProbeFieldValue(value);
    if (safeValue) fields[name] = safeValue;
}

static NSMutableDictionary *CCNMParseCellMonitorSnapshot(
    id cellInfoResult,
    NSDictionary<NSString *, NSString *> *cellMonitorSymbols
) {
    NSMutableDictionary *snapshot = [@{@"cellMonitorSucceeded": @NO} mutableCopy];
    snapshot[@"cellInfoRuntimeClass"] = NSStringFromClass([cellInfoResult class]) ?: @"(unknown)";
    snapshot[@"cellInfoRaw"] = CCNMTypedPropertyListEvidence(cellInfoResult);

    NSMutableArray<NSString *> *criticalMissingSymbols = [NSMutableArray array];
    for (NSString *symbolName in CCNMCellMonitorCriticalClassificationSymbolNames()) {
        if (![cellMonitorSymbols[symbolName] isKindOfClass:[NSString class]]) {
            [criticalMissingSymbols addObject:symbolName];
        }
    }
    BOOL classificationAvailable = CCNMCellMonitorClassificationSymbolsAvailable(
        [cellMonitorSymbols[@"kCTCellMonitorCellType"] isKindOfClass:[NSString class]],
        [cellMonitorSymbols[@"kCTCellMonitorCellTypeServing"] isKindOfClass:[NSString class]],
        [cellMonitorSymbols[@"kCTCellMonitorCellRadioAccessTechnology"] isKindOfClass:[NSString class]]);
    snapshot[@"cellMonitorClassificationAvailable"] = @(classificationAvailable);
    snapshot[@"cellMonitorCriticalMissingSymbols"] = criticalMissingSymbols;
    if (!classificationAvailable) {
        snapshot[@"cellMonitorParseError"] = [NSString stringWithFormat:
            @"Critical Cell Monitor classification symbols are unavailable: %@",
            [criticalMissingSymbols componentsJoinedByString:@", "]];
    }

    id legacyInfo = nil;
    @try {
        if ([cellInfoResult respondsToSelector:@selector(legacyInfo)]) {
            legacyInfo = [(id<CCNMCellInfo>)cellInfoResult legacyInfo];
        } else {
            snapshot[@"cellMonitorParseError"] = @"CTCellInfo does not expose legacyInfo on this runtime.";
        }
    } @catch (NSException *exception) {
        snapshot[@"cellMonitorParseError"] = [NSString stringWithFormat:@"legacyInfo access raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
    }

    snapshot[@"legacyInfoRuntimeClass"] = legacyInfo
        ? (NSStringFromClass([legacyInfo class]) ?: @"(unknown)") : @"(nil)";
    snapshot[@"legacyInfoRaw"] = CCNMTypedPropertyListEvidence(legacyInfo);
    if (![legacyInfo isKindOfClass:[NSArray class]]) {
        if (legacyInfo) {
            snapshot[@"cellMonitorParseError"] = @"legacyInfo is not an array on this runtime.";
        } else if (!snapshot[@"cellMonitorParseError"]) {
            snapshot[@"cellMonitorParseError"] = @"legacyInfo is nil.";
        }
        return snapshot;
    }

    NSMutableArray *servingCells = [NSMutableArray array];
    NSMutableArray *allCells = [NSMutableArray array];
    NSMutableArray *entryResults = [NSMutableArray array];
    NSUInteger entryIndex = 0;
    NSUInteger structurallyInvalidEntryCount = 0;
    NSUInteger missingServingRATCount = 0;
    for (id legacyEntry in legacyInfo) {
        NSMutableDictionary *entryResult = [@{
            @"index": @(entryIndex++),
            @"runtimeClass": NSStringFromClass([legacyEntry class]) ?: @"(unknown)",
            @"raw": CCNMTypedPropertyListEvidence(legacyEntry)
        } mutableCopy];
        if (![legacyEntry isKindOfClass:[NSDictionary class]]) {
            structurallyInvalidEntryCount++;
            entryResult[@"parsed"] = @NO;
            entryResult[@"reason"] = @"legacyInfo entry is not a dictionary";
            [entryResults addObject:entryResult];
            continue;
        }

        NSDictionary *cellDict = legacyEntry;
        id cellType = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorCellType");
        BOOL hasClassifiableCellType = [cellType isKindOfClass:[NSString class]];
        if (!CCNMCellMonitorEntryIsStructurallyClassifiable(YES, hasClassifiableCellType)) {
            structurallyInvalidEntryCount++;
            entryResult[@"parsed"] = @NO;
            entryResult[@"reason"] = @"legacyInfo dictionary has no classifiable Cell Monitor cell-type value";
            [entryResults addObject:entryResult];
            continue;
        }
        id servingCellType = cellMonitorSymbols[@"kCTCellMonitorCellTypeServing"];
        BOOL isServingEntry = servingCellType && [cellType isEqual:servingCellType];
        id rat = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorCellRadioAccessTechnology");
        BOOL hasClassifiableRAT = [rat isKindOfClass:[NSString class]];
        if (!CCNMCellMonitorServingEntryHasClassifiableRAT(isServingEntry, hasClassifiableRAT)) {
            structurallyInvalidEntryCount++;
            missingServingRATCount++;
            entryResult[@"parsed"] = @NO;
            entryResult[@"reason"] = @"serving Cell Monitor entry has no classifiable radio-access-technology value";
            [entryResults addObject:entryResult];
            continue;
        }
        id isSA = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorIsSA");
        id nrarfcn = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorNRARFCN");
        id channel = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorChannelNumber");
        id uarfcn = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorUARFCN");
        id band = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorBandInfo");
        id bandwidth = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorBandwidth");
        id deploymentType = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorDeploymentType");
        id pci = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorPCI");
        id pid = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorPID");
        id cellId = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorCellId");
        id tac = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorTAC");
        id mcc = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorMCC");
        id mnc = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorMNC");
        id rsrp = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorRSRP");
        id rsrq = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorRSRQ");
        id snr = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorSNR");
        id gscn = CCNMCellMonitorValue(cellDict, cellMonitorSymbols, @"kCTCellMonitorGSCN");

        id physicalCellId = pci ?: pid;
        NSString *physicalCellIdSource = pci ? @"kCTCellMonitorPCI" : (pid ? @"kCTCellMonitorPID" : nil);
        id frequency = nrarfcn ?: channel ?: uarfcn;
        NSString *frequencySource = nrarfcn ? @"kCTCellMonitorNRARFCN" :
            (channel ? @"kCTCellMonitorChannelNumber" : (uarfcn ? @"kCTCellMonitorUARFCN" : nil));

        NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
        CCNMSetProbeField(parsed, @"cellType", cellType);
        CCNMSetProbeField(parsed, @"rat", rat);
        CCNMSetProbeField(parsed, @"isSA", isSA);
        CCNMSetProbeField(parsed, @"nrarfcn", nrarfcn);
        CCNMSetProbeField(parsed, @"channelNumber", channel);
        CCNMSetProbeField(parsed, @"uarfcn", uarfcn);
        CCNMSetProbeField(parsed, @"frequency", frequency);
        CCNMSetProbeField(parsed, @"frequencySource", frequencySource);
        CCNMSetProbeField(parsed, @"band", band);
        CCNMSetProbeField(parsed, @"bandwidth", bandwidth);
        CCNMSetProbeField(parsed, @"deploymentType", deploymentType);
        CCNMSetProbeField(parsed, @"pci", pci);
        CCNMSetProbeField(parsed, @"pid", pid);
        CCNMSetProbeField(parsed, @"physicalCellId", physicalCellId);
        CCNMSetProbeField(parsed, @"physicalCellIdSource", physicalCellIdSource);
        CCNMSetProbeField(parsed, @"cellId", cellId);
        CCNMSetProbeField(parsed, @"tac", tac);
        CCNMSetProbeField(parsed, @"mcc", mcc);
        CCNMSetProbeField(parsed, @"mnc", mnc);
        CCNMSetProbeField(parsed, @"rsrp", rsrp);
        CCNMSetProbeField(parsed, @"rsrq", rsrq);
        CCNMSetProbeField(parsed, @"snr", snr);
        CCNMSetProbeField(parsed, @"gscn", gscn);

        entryResult[@"parsed"] = @YES;
        entryResult[@"fields"] = parsed;
        [entryResults addObject:entryResult];
        [allCells addObject:parsed];

        if (isServingEntry) {
            [servingCells addObject:parsed];
        }
    }

    BOOL entriesStructurallyValid = structurallyInvalidEntryCount == 0;
    snapshot[@"servingCells"] = servingCells;
    snapshot[@"allCells"] = allCells;
    snapshot[@"cellMonitorEntryResults"] = entryResults;
    snapshot[@"cellMonitorStructurallyInvalidEntryCount"] = @(structurallyInvalidEntryCount);
    snapshot[@"cellMonitorMissingServingRATCount"] = @(missingServingRATCount);
    snapshot[@"cellMonitorEntriesStructurallyValid"] = @(entriesStructurallyValid);
    if (!entriesStructurallyValid && !snapshot[@"cellMonitorParseError"]) {
        snapshot[@"cellMonitorParseError"] = [NSString stringWithFormat:
            @"legacyInfo contains %lu structurally unclassifiable entr%@.",
            (unsigned long)structurallyInvalidEntryCount,
            structurallyInvalidEntryCount == 1 ? @"y" : @"ies"];
    }
    snapshot[@"cellMonitorSucceeded"] = @(classificationAvailable && entriesStructurallyValid);
    return snapshot;
}

static NSMutableDictionary *CCNMRunServingCellRatSelectionAttemptInternal(
    id<CCNMServingCellClient> client,
    id context
) {
    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    NSMutableDictionary *attempt = [@{
        @"ratSelectionRequestedAt": @([[NSDate date] timeIntervalSince1970]),
        @"ratSelectionRequestedMonotonic": @(startedMonotonic),
        @"status": @"invoking",
        @"ratSelectionWaitCompleted": @NO,
        @"ratSelectionTimedOut": @NO
    } mutableCopy];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    CCNMCellMonitorAsyncState *state = [CCNMCellMonitorAsyncState new];
    @try {
        [client getRatSelection:context completion:^(NSString *selection, NSString *preferred, NSError *error) {
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            if (selection) values[@"selection"] = selection;
            if (preferred) values[@"preferred"] = preferred;
            BOOL wasUnsafeOutstanding = NO;
            BOOL accepted = [state completeWithResult:values
                                                error:error
                                           callbackAt:[[NSDate date] timeIntervalSince1970]
                                    callbackMonotonic:CCNMMonotonicNow()
                                 wasUnsafeOutstanding:&wasUnsafeOutstanding];
            if (accepted) dispatch_semaphore_signal(semaphore);
            if (wasUnsafeOutstanding) CCNMResolveCellMonitorUnsafeOutstanding();
        }];
    } @catch (NSException *exception) {
        attempt[@"ratSelectionWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
        attempt[@"ratSelectionWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
        attempt[@"ratSelectionElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
        attempt[@"ratSelectionUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"invocationException";
        attempt[@"ratSelectionInvocationException"] = CCNMExceptionEvidence(exception);
        attempt[@"ratSelectionError"] = [NSString stringWithFormat:@"RAT-selection invocation raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
        return attempt;
    }

    long waitResult = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, CCNMServingCellAttemptTimeoutSeconds * NSEC_PER_SEC));
    attempt[@"ratSelectionWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
    attempt[@"ratSelectionWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
    attempt[@"ratSelectionElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
    attempt[@"ratSelectionWaitResult"] = @(waitResult);
    if (!CCNMProbeWaitCompleted(waitResult)) {
        attempt[@"ratSelectionUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"timeout";
        attempt[@"ratSelectionTimedOut"] = @YES;
        return attempt;
    }

    attempt[@"ratSelectionWaitCompleted"] = @YES;
    attempt[@"ratSelectionCallbackAt"] = @(state.callbackAt);
    attempt[@"ratSelectionCallbackMonotonic"] = @(state.callbackMonotonic);
    attempt[@"ratSelectionCallbackLatencyMilliseconds"] =
        CCNMMillisecondsBetween(startedMonotonic, state.callbackMonotonic);
    if (state.error) {
        attempt[@"status"] = @"callbackError";
        attempt[@"ratSelectionError"] = state.error.localizedDescription ?: @"(no description)";
        attempt[@"ratSelectionErrorEvidence"] = CCNMNSErrorEvidence(state.error);
        return attempt;
    }

    NSDictionary *values = [state.result isKindOfClass:[NSDictionary class]] ? state.result : @{};
    NSString *selection = [values[@"selection"] isKindOfClass:[NSString class]] ? values[@"selection"] : nil;
    NSString *preferred = [values[@"preferred"] isKindOfClass:[NSString class]] ? values[@"preferred"] : nil;
    if (!selection && !preferred) {
        attempt[@"status"] = @"nilResult";
        attempt[@"ratSelectionError"] = @"The callback completed without RAT-selection data.";
        return attempt;
    }
    attempt[@"status"] = @"succeeded";
    attempt[@"ratSelection"] = selection ?: @"";
    attempt[@"ratPreferred"] = preferred ?: @"";
    return attempt;
}

NSDictionary *CCNMRunServingCellRatSelectionAttempt(id client, id context) {
    NSString *abiFailure = nil;
    if (!CCNMValidateAsyncSelectorABI(client, @selector(getRatSelection:completion:), &abiFailure)) {
        return @{
            @"status": @"abiError",
            @"ratSelectionWaitCompleted": @NO,
            @"ratSelectionTimedOut": @NO,
            @"ratSelectionABIError": abiFailure ?: @"RAT-selection ABI validation failed.",
            @"ratSelectionError": abiFailure ?: @"RAT-selection ABI validation failed."
        };
    }
    return CCNMRunServingCellRatSelectionAttemptInternal((id<CCNMServingCellClient>)client, context);
}

static NSMutableDictionary *CCNMRunCellMonitorRefreshAttempt(
    id<CCNMServingCellClient> client,
    id context
) {
    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    NSTimeInterval requestedAt = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *attempt = [@{
        @"refreshRequestedAt": @(requestedAt),
        @"refreshRequestedMonotonic": @(startedMonotonic),
        @"status": @"invoking",
        @"cellMonitorRefreshWaitCompleted": @NO,
        @"cellMonitorRefreshTimedOut": @NO,
        @"cellMonitorRefreshSucceeded": @NO
    } mutableCopy];
    dispatch_semaphore_t refreshSema = dispatch_semaphore_create(0);
    CCNMCellMonitorAsyncState *state = [CCNMCellMonitorAsyncState new];
    @try {
        [client refreshCellMonitor:context completion:^(NSError *error) {
            BOOL wasUnsafeOutstanding = NO;
            BOOL accepted = [state completeWithResult:nil
                                                error:error
                                           callbackAt:[[NSDate date] timeIntervalSince1970]
                                    callbackMonotonic:CCNMMonotonicNow()
                                 wasUnsafeOutstanding:&wasUnsafeOutstanding];
            if (accepted) dispatch_semaphore_signal(refreshSema);
            if (wasUnsafeOutstanding) CCNMResolveCellMonitorUnsafeOutstanding();
        }];
    } @catch (NSException *exception) {
        attempt[@"refreshWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
        attempt[@"refreshWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
        attempt[@"refreshElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
        attempt[@"cellMonitorRefreshUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"invocationException";
        attempt[@"cellMonitorRefreshInvocationException"] = CCNMExceptionEvidence(exception);
        attempt[@"cellMonitorRefreshError"] = [NSString stringWithFormat:@"refresh invocation raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
        return attempt;
    }

    long refreshWaitResult = dispatch_semaphore_wait(
        refreshSema, dispatch_time(DISPATCH_TIME_NOW, CCNMServingCellAttemptTimeoutSeconds * NSEC_PER_SEC));
    attempt[@"refreshWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
    attempt[@"refreshWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
    attempt[@"refreshElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
    attempt[@"refreshWaitResult"] = @(refreshWaitResult);
    if (!CCNMProbeWaitCompleted(refreshWaitResult)) {
        attempt[@"cellMonitorRefreshUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"timeout";
        attempt[@"cellMonitorRefreshTimedOut"] = @YES;
        return attempt;
    }

    NSError *refreshError = state.error;
    attempt[@"cellMonitorRefreshWaitCompleted"] = @YES;
    attempt[@"refreshCallbackAt"] = @(state.callbackAt);
    attempt[@"refreshCallbackMonotonic"] = @(state.callbackMonotonic);
    attempt[@"refreshCallbackLatencyMilliseconds"] =
        CCNMMillisecondsBetween(startedMonotonic, state.callbackMonotonic);
    attempt[@"cellMonitorRefreshCallbackErrorRaw"] = CCNMTypedPropertyListEvidence(refreshError);
    if (refreshError) {
        attempt[@"status"] = @"callbackError";
        attempt[@"cellMonitorRefreshError"] = refreshError.localizedDescription ?: @"(no description)";
        attempt[@"cellMonitorRefreshErrorRaw"] = CCNMTypedPropertyListEvidence(refreshError);
        attempt[@"cellMonitorRefreshErrorEvidence"] = CCNMNSErrorEvidence(refreshError);
        attempt[@"cellMonitorRefreshErrorDomain"] = refreshError.domain ?: @"";
        attempt[@"cellMonitorRefreshErrorCode"] = @(refreshError.code);
        return attempt;
    }

    attempt[@"status"] = @"succeeded";
    attempt[@"cellMonitorRefreshSucceeded"] = @YES;
    return attempt;
}

static NSMutableDictionary *CCNMRunCellMonitorCopyAttempt(
    id<CCNMServingCellClient> client,
    id context,
    NSDictionary<NSString *, NSString *> *cellMonitorSymbols
) {
    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    NSTimeInterval requestedAt = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *attempt = [@{
        @"copyRequestedAt": @(requestedAt),
        @"copyRequestedMonotonic": @(startedMonotonic),
        @"sampledAt": @(requestedAt),
        @"status": @"invoking",
        @"cellMonitorCopyWaitCompleted": @NO,
        @"cellMonitorCopyTimedOut": @NO,
        @"cellMonitorCopySucceeded": @NO,
        @"cellMonitorSucceeded": @NO
    } mutableCopy];
    dispatch_semaphore_t copySema = dispatch_semaphore_create(0);
    CCNMCellMonitorAsyncState *state = [CCNMCellMonitorAsyncState new];
    @try {
        [client copyCellInfo:context completion:^(id cellInfo, NSError *error) {
            BOOL wasUnsafeOutstanding = NO;
            BOOL accepted = [state completeWithResult:cellInfo
                                                error:error
                                           callbackAt:[[NSDate date] timeIntervalSince1970]
                                    callbackMonotonic:CCNMMonotonicNow()
                                 wasUnsafeOutstanding:&wasUnsafeOutstanding];
            if (accepted) dispatch_semaphore_signal(copySema);
            if (wasUnsafeOutstanding) CCNMResolveCellMonitorUnsafeOutstanding();
        }];
    } @catch (NSException *exception) {
        attempt[@"copyWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
        attempt[@"copyWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
        attempt[@"copyElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
        attempt[@"cellMonitorCopyUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"invocationException";
        attempt[@"cellMonitorCopyInvocationException"] = CCNMExceptionEvidence(exception);
        attempt[@"cellMonitorError"] = [NSString stringWithFormat:@"copy invocation raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
        return attempt;
    }

    long copyWaitResult = dispatch_semaphore_wait(
        copySema, dispatch_time(DISPATCH_TIME_NOW, CCNMServingCellAttemptTimeoutSeconds * NSEC_PER_SEC));
    attempt[@"copyWaitFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
    attempt[@"copyWaitFinishedMonotonic"] = @(CCNMMonotonicNow());
    attempt[@"copyElapsedMilliseconds"] = CCNMElapsedMillisecondsSince(startedMonotonic);
    attempt[@"copyWaitResult"] = @(copyWaitResult);
    if (!CCNMProbeWaitCompleted(copyWaitResult)) {
        attempt[@"cellMonitorCopyUnsafeOutstandingLatchArmed"] = @([state markUnsafeOutstanding]);
        attempt[@"status"] = @"timeout";
        attempt[@"cellMonitorCopyTimedOut"] = @YES;
        return attempt;
    }

    id cellInfoResult = state.result;
    NSError *cellInfoError = state.error;
    attempt[@"cellMonitorCopyWaitCompleted"] = @YES;
    attempt[@"copyCallbackAt"] = @(state.callbackAt);
    attempt[@"copyCallbackMonotonic"] = @(state.callbackMonotonic);
    attempt[@"copyCallbackLatencyMilliseconds"] =
        CCNMMillisecondsBetween(startedMonotonic, state.callbackMonotonic);
    attempt[@"sampledAt"] = @(state.callbackAt);
    attempt[@"cellMonitorCopyResultRuntimeClass"] = cellInfoResult
        ? (NSStringFromClass([cellInfoResult class]) ?: @"(unknown)") : @"(nil)";
    attempt[@"cellMonitorCopyResultRaw"] = CCNMTypedPropertyListEvidence(cellInfoResult);
    if (cellInfoError) {
        attempt[@"status"] = @"callbackError";
        attempt[@"cellMonitorError"] = cellInfoError.localizedDescription ?: @"(no description)";
        attempt[@"cellMonitorErrorRaw"] = CCNMTypedPropertyListEvidence(cellInfoError);
        attempt[@"cellMonitorCopyErrorEvidence"] = CCNMNSErrorEvidence(cellInfoError);
        attempt[@"cellMonitorErrorDomain"] = cellInfoError.domain ?: @"";
        attempt[@"cellMonitorErrorCode"] = @(cellInfoError.code);
        return attempt;
    }
    if (!cellInfoResult) {
        attempt[@"status"] = @"nilResult";
        attempt[@"cellMonitorResult"] = @"(nil)";
        return attempt;
    }

    attempt[@"cellMonitorCopySucceeded"] = @YES;
    @try {
        [attempt addEntriesFromDictionary:CCNMParseCellMonitorSnapshot(cellInfoResult, cellMonitorSymbols)];
        attempt[@"status"] = [attempt[@"cellMonitorSucceeded"] boolValue] ? @"parsed" : @"parseError";
    } @catch (NSException *exception) {
        attempt[@"status"] = @"parseException";
        attempt[@"cellMonitorParseException"] = CCNMExceptionEvidence(exception);
        attempt[@"cellMonitorParseError"] = [NSString stringWithFormat:@"snapshot parsing raised %@: %@",
            exception.name, exception.reason ?: @"(no reason)"];
    }
    return attempt;
}

static NSArray<NSDictionary *> *CCNMNotAttemptedOperations(
    NSIndexSet *attemptedRefreshIndexes,
    NSIndexSet *attemptedCopyIndexes,
    NSDictionary<NSNumber *, NSString *> *copyOmissionReasons,
    NSString *remainingReason
);

NSDictionary *CCNMServingCellSamplerEmptyReport(void) {
    NSMutableArray<NSNumber *> *allIndexes = [NSMutableArray array];
    for (NSUInteger index = 0; index < CCNMServingCellMaximumSampleCount; index++) {
        [allIndexes addObject:@(index)];
    }
    NSArray<NSDictionary *> *notAttemptedOperations = CCNMNotAttemptedOperations(
        [NSIndexSet indexSet], [NSIndexSet indexSet], @{}, @"notStarted");
    return @{
        @"cellMonitorSucceeded": @NO,
        @"cellMonitorSamplingMode": @"adaptiveRefreshBeforeEachCopy",
        @"cellMonitorPlan": @{
            @"maximumSampleCount": @(CCNMServingCellMaximumSampleCount),
            @"requiredConsecutiveNRSamples": @(CCNMServingCellRequiredConsecutiveNRSamples),
            @"attemptTimeoutSeconds": @(CCNMServingCellAttemptTimeoutSeconds),
            @"interSampleDelaySeconds": @((double)CCNMServingCellInterSampleDelayMicroseconds / 1000000.0),
            @"refreshSettleSeconds": @((double)CCNMServingCellRefreshSettleMicroseconds / 1000000.0),
            @"negativeObservationRequiresFullCleanWindow": @YES
        },
        @"cellMonitorResolvedSymbols": @{},
        @"cellMonitorMissingSymbols": @[],
        @"cellMonitorRefreshAttempts": @[],
        @"cellMonitorRequestedRefreshCount": @(CCNMServingCellMaximumSampleCount),
        @"cellMonitorAttemptedRefreshCount": @0,
        @"cellMonitorCompletedRefreshCount": @0,
        @"cellMonitorSuccessfulRefreshCount": @0,
        @"cellMonitorNotAttemptedRefreshCount": @(CCNMServingCellMaximumSampleCount),
        @"cellMonitorNotAttemptedRefreshSampleIndexes": allIndexes,
        @"cellMonitorSamples": @[],
        @"cellMonitorRequestedSampleCount": @(CCNMServingCellMaximumSampleCount),
        @"cellMonitorAttemptedSampleCount": @0,
        @"cellMonitorCompletedSampleCount": @0,
        @"cellMonitorSuccessfulCopyCount": @0,
        @"cellMonitorSuccessfulSampleCount": @0,
        @"cellMonitorNotAttemptedSampleCount": @(CCNMServingCellMaximumSampleCount),
        @"cellMonitorNotAttemptedSampleIndexes": allIndexes,
        @"cellMonitorNotAttemptedOperations": notAttemptedOperations,
        @"cellMonitorSamplingStatus": @"failed",
        @"cellMonitorStopReason": @"notStarted",
        @"cellMonitorStoppedEarly": @NO,
        @"cellMonitorSamplingPartial": @NO,
        @"cellMonitorSamplingFailures": @[],
        @"cellMonitorSamplingFailure": @"Sampling did not start.",
        @"cellMonitorSamplingAbortedAfterTimeout": @NO,
        @"cellMonitorSamplingAbortedAfterInvocationException": @NO,
        @"cellMonitorSamplingElapsedMilliseconds": @0,
        @"cellMonitorScheduledDelayMilliseconds": @0,
        @"cellMonitorRefreshCallbackLatencyMilliseconds": @0,
        @"cellMonitorCopyCallbackLatencyMilliseconds": @0,
        @"observedServingCells": @[],
        @"nrServingCellObserved": @NO,
        @"nrObservationStatus": @"indeterminatePartial",
        @"explicitNRSampleCount": @0,
        @"explicitNRConfirmationCount": @0,
        @"servingObservationConfirmed": @NO,
        @"servingConfirmationScope": @"none",
        @"stableServingConfirmationCount": @0,
        @"confirmedServingCell": @{},
        @"confirmedServingSampledAt": @0
    };
}

static NSArray<NSDictionary *> *CCNMNotAttemptedOperations(
    NSIndexSet *attemptedRefreshIndexes,
    NSIndexSet *attemptedCopyIndexes,
    NSDictionary<NSNumber *, NSString *> *copyOmissionReasons,
    NSString *remainingReason
) {
    NSMutableArray<NSDictionary *> *operations = [NSMutableArray array];
    for (NSUInteger sampleIndex = 0; sampleIndex < CCNMServingCellMaximumSampleCount; sampleIndex++) {
        if (![attemptedRefreshIndexes containsIndex:sampleIndex]) {
            NSMutableDictionary *notAttempted = [@{
                @"operation": @"refresh",
                @"sampleIndex": @(sampleIndex)
            } mutableCopy];
            notAttempted[@"reason"] = remainingReason ?: @"notReached";
            [operations addObject:notAttempted];
        }
        if (![attemptedCopyIndexes containsIndex:sampleIndex]) {
            NSMutableDictionary *notAttempted = [@{
                @"operation": @"copy",
                @"sampleIndex": @(sampleIndex)
            } mutableCopy];
            notAttempted[@"reason"] = copyOmissionReasons[@(sampleIndex)] ?: remainingReason ?: @"notReached";
            [operations addObject:notAttempted];
        }
    }
    return operations;
}

static NSString *CCNMOmissionReasonForStop(CCNMAdaptiveSamplerStopReason stopReason) {
    switch (stopReason) {
        case CCNMAdaptiveSamplerStopExplicitNRConfirmed:
            return @"explicitNRConfirmed";
        case CCNMAdaptiveSamplerStopStableServingConfirmed:
            return @"stableServingConfirmed";
        case CCNMAdaptiveSamplerStopTimedOut:
            return @"abortedAfterTimeout";
        case CCNMAdaptiveSamplerStopInvocationException:
            return @"abortedAfterInvocationException";
        case CCNMAdaptiveSamplerStopInvalidConfiguration:
            return @"invalidSamplerConfiguration";
        case CCNMAdaptiveSamplerStopWindowExhausted:
            return @"windowExhausted";
        case CCNMAdaptiveSamplerStopRunning:
        default:
            return @"preflightFailed";
    }
}

static NSString *CCNMServingBandIdentity(id bandValue) {
    long long number = 0;
    if ([bandValue isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)bandValue) != CFBooleanGetTypeID()) {
        const char *type = [(NSNumber *)bandValue objCType];
        if (!type || !strchr("cCsSiIlLqQ", type[0])) return nil;
        number = [(NSNumber *)bandValue longLongValue];
    } else if ([bandValue isKindOfClass:[NSString class]]) {
        NSString *normalized = [(NSString *)bandValue lowercaseString];
        normalized = [normalized stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        for (NSString *prefix in @[ @"band", @"lte", @"nr", @"n", @"b" ]) {
            if ([normalized hasPrefix:prefix]) {
                normalized = [normalized substringFromIndex:prefix.length];
                normalized = [normalized stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                break;
            }
        }
        NSScanner *scanner = [NSScanner scannerWithString:normalized];
        if (![scanner scanLongLong:&number] || !scanner.isAtEnd) return nil;
    } else {
        return nil;
    }
    return number > 0 && number <= 1024 ? [NSString stringWithFormat:@"%lld", number] : nil;
}

static NSString *CCNMServingCellIdentity(NSDictionary *servingCell) {
    if (![servingCell isKindOfClass:[NSDictionary class]]) return nil;
    NSString *rat = [servingCell[@"rat"] isKindOfClass:[NSString class]]
        ? [servingCell[@"rat"] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
    NSString *band = CCNMServingBandIdentity(servingCell[@"band"]);
    if (rat.length == 0 || band.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", rat, band];
}

static NSInteger CCNMServingCellRATTier(NSDictionary *servingCell) {
    NSString *rat = [servingCell[@"rat"] isKindOfClass:[NSString class]]
        ? [servingCell[@"rat"] stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
    if (rat && CCNMCellMonitorRATIsNR(rat.UTF8String)) return 3;
    if ([rat isEqual:@"kCTCellMonitorRadioAccessTechnologyLTE"]) return 2;
    return rat.length > 0 ? 1 : 0;
}

static NSDictionary *CCNMPreferredServingCell(
    NSArray *servingCells,
    NSString **selectedIdentity,
    BOOL *ambiguous
) {
    if (selectedIdentity) *selectedIdentity = nil;
    if (ambiguous) *ambiguous = NO;

    NSInteger winningTier = 0;
    for (id value in servingCells) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        winningTier = MAX(winningTier, CCNMServingCellRATTier(value));
    }
    if (winningTier == 0) return nil;

    NSDictionary *selected = nil;
    NSString *identity = nil;
    BOOL invalidWinningTier = NO;
    for (id value in servingCells) {
        if (![value isKindOfClass:[NSDictionary class]] ||
            CCNMServingCellRATTier(value) != winningTier) continue;
        NSString *candidateIdentity = CCNMServingCellIdentity(value);
        if (candidateIdentity.length == 0) {
            invalidWinningTier = YES;
            continue;
        }
        if (identity && ![candidateIdentity isEqual:identity]) {
            invalidWinningTier = YES;
            continue;
        }
        identity = candidateIdentity;
        selected = value;
    }
    if (invalidWinningTier || !selected || identity.length == 0) {
        if (ambiguous) *ambiguous = YES;
        return nil;
    }
    if (selectedIdentity) *selectedIdentity = identity;
    return selected;
}

static NSDictionary *CCNMRunServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle,
    CCNMAdaptiveSamplerPolicy policy
) {
    id<CCNMServingCellClient> servingCellClient = (id<CCNMServingCellClient>)client;
    BOOL responsiveServing = policy == CCNMAdaptiveSamplerPolicyStableServing;
    useconds_t interSampleDelay = responsiveServing
        ? CCNMServingCellResponsiveInterSampleDelayMicroseconds
        : CCNMServingCellInterSampleDelayMicroseconds;
    NSMutableDictionary *report = [CCNMServingCellSamplerEmptyReport() mutableCopy];
    report[@"cellMonitorSamplingMode"] = responsiveServing
        ? @"responsiveStableServing"
        : (policy == CCNMAdaptiveSamplerPolicyFullWindow
            ? @"fullWindowRefreshBeforeEachCopy"
            : @"adaptiveRefreshBeforeEachCopy");
    NSMutableDictionary *samplingPlan = [report[@"cellMonitorPlan"] mutableCopy];
    samplingPlan[@"requiredConsecutiveServingSamples"] =
        @(CCNMServingCellRequiredConsecutiveServingSamples);
    samplingPlan[@"interSampleDelaySeconds"] = @((double)interSampleDelay / 1000000.0);
    samplingPlan[@"stopAfterExplicitNR"] = @(policy == CCNMAdaptiveSamplerPolicyEarlyNR);
    samplingPlan[@"stopAfterStableServing"] = @(responsiveServing);
    samplingPlan[@"servingConfirmationScope"] = responsiveServing ? @"ratBand" : @"none";
    samplingPlan[@"negativeObservationRequiresFullCleanWindow"] = @YES;
    report[@"cellMonitorPlan"] = samplingPlan;
    NSMutableArray<NSDictionary *> *failures = [NSMutableArray array];
    NSMutableIndexSet *attemptedRefreshIndexes = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *attemptedCopyIndexes = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSNumber *, NSString *> *copyOmissionReasons = [NSMutableDictionary dictionary];

    NSString *refreshABIFailure = nil;
    NSString *copyABIFailure = nil;
    BOOL refreshABIValid = CCNMValidateAsyncSelectorABI(
        client, @selector(refreshCellMonitor:completion:), &refreshABIFailure);
    BOOL copyABIValid = CCNMValidateAsyncSelectorABI(
        client, @selector(copyCellInfo:completion:), &copyABIFailure);
    if (!context || !refreshABIValid || !copyABIValid) {
        if (!context) {
            [failures addObject:@{
                @"stage": @"preflight",
                @"kind": @"missingContext",
                @"operation": @"preflight",
                @"status": @"missingContext",
                @"message": @"Slot-1 subscription context is unavailable.",
                @"reason": @"Slot-1 subscription context is unavailable."
            }];
        }
        if (!refreshABIValid) {
            NSString *reason = refreshABIFailure ?: @"Refresh ABI validation failed.";
            [failures addObject:@{
                @"stage": @"refresh",
                @"kind": @"abiError",
                @"operation": @"refresh",
                @"status": @"abiError",
                @"message": reason,
                @"reason": reason
            }];
        }
        if (!copyABIValid) {
            NSString *reason = copyABIFailure ?: @"Copy ABI validation failed.";
            [failures addObject:@{
                @"stage": @"copy",
                @"kind": @"abiError",
                @"operation": @"copy",
                @"status": @"abiError",
                @"message": reason,
                @"reason": reason
            }];
        }
        report[@"cellMonitorSamplingFailures"] = failures;
        report[@"cellMonitorSamplingFailure"] = failures.firstObject[@"reason"] ?: @"Cell Monitor preflight failed.";
        report[@"cellMonitorNotAttemptedOperations"] = CCNMNotAttemptedOperations(
            attemptedRefreshIndexes, attemptedCopyIndexes, copyOmissionReasons, @"preflightFailed");
        NSMutableArray *allIndexes = [NSMutableArray array];
        for (NSUInteger index = 0; index < CCNMServingCellMaximumSampleCount; index++) [allIndexes addObject:@(index)];
        report[@"cellMonitorNotAttemptedRefreshSampleIndexes"] = allIndexes;
        report[@"cellMonitorNotAttemptedSampleIndexes"] = allIndexes;
        return report;
    }

    NSArray<NSString *> *missingSymbols = nil;
    NSDictionary<NSString *, NSString *> *cellMonitorSymbols =
        CCNMCellMonitorSymbols(coreTelephonyHandle, &missingSymbols);
    report[@"cellMonitorResolvedSymbols"] = cellMonitorSymbols;
    report[@"cellMonitorMissingSymbols"] = missingSymbols ?: @[];

    NSMutableArray<NSDictionary *> *refreshAttempts = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *observedServingCells = [NSMutableArray array];
    CCNMAdaptiveSamplerState samplerState = CCNMAdaptiveSamplerStartWithPolicy(
        CCNMServingCellMaximumSampleCount,
        responsiveServing
            ? CCNMServingCellRequiredConsecutiveServingSamples
            : CCNMServingCellRequiredConsecutiveNRSamples,
        policy);
    NSTimeInterval samplingStartedMonotonic = CCNMMonotonicNow();
    report[@"cellMonitorSamplingStartedAt"] = @([[NSDate date] timeIntervalSince1970]);
    report[@"cellMonitorSamplingStartedMonotonic"] = @(samplingStartedMonotonic);

    NSUInteger attemptedRefreshCount = 0;
    NSUInteger completedRefreshCount = 0;
    NSUInteger successfulRefreshCount = 0;
    NSUInteger attemptedCopyCount = 0;
    NSUInteger completedCopyCount = 0;
    NSUInteger successfulCopyCount = 0;
    NSUInteger parsedSampleCount = 0;
    NSUInteger observedExplicitNRSampleCount = 0;
    NSUInteger consecutiveExplicitNRSampleCount = 0;
    unsigned long long scheduledDelayMicroseconds = 0;
    long long refreshCallbackLatencyMilliseconds = 0;
    long long copyCallbackLatencyMilliseconds = 0;
    BOOL nrServingCellObserved = NO;
    BOOL previousResponsiveAttemptUsable = YES;
    NSString *previousServingIdentity = nil;
    NSDictionary *confirmedServingCell = nil;
    NSNumber *confirmedServingSampledAt = nil;

    for (NSUInteger sampleIndex = 0; sampleIndex < CCNMServingCellMaximumSampleCount; sampleIndex++) {
        if (!CCNMAdaptiveSamplerShouldContinue(&samplerState)) break;
        useconds_t scheduledDelay = responsiveServing && !previousResponsiveAttemptUsable
            ? CCNMServingCellInterSampleDelayMicroseconds
            : interSampleDelay;
        if (sampleIndex > 0 && scheduledDelay > 0) {
            scheduledDelayMicroseconds += scheduledDelay;
            usleep(scheduledDelay);
        }

        NSMutableDictionary *sample = [@{
            @"sampleIndex": @(sampleIndex),
            @"relativeStartMilliseconds": CCNMElapsedMillisecondsSince(samplingStartedMonotonic),
            @"cellMonitorRefreshStatus": @"notAttempted",
            @"cellMonitorCopyStatus": @"notAttempted",
            @"explicitNRServingCellObserved": @NO
        } mutableCopy];

        attemptedRefreshCount++;
        [attemptedRefreshIndexes addIndex:sampleIndex];
        NSMutableDictionary *refreshAttempt = CCNMRunCellMonitorRefreshAttempt(servingCellClient, context);
        refreshAttempt[@"sampleIndex"] = @(sampleIndex);
        [refreshAttempts addObject:refreshAttempt];
        sample[@"cellMonitorRefreshStatus"] = refreshAttempt[@"status"] ?: @"unknown";
        sample[@"refreshAttempt"] = refreshAttempt;
        BOOL refreshCompleted = [refreshAttempt[@"cellMonitorRefreshWaitCompleted"] boolValue];
        BOOL refreshSucceeded = [refreshAttempt[@"cellMonitorRefreshSucceeded"] boolValue];
        BOOL refreshTimedOut = [refreshAttempt[@"cellMonitorRefreshTimedOut"] boolValue];
        BOOL refreshInvocationException = refreshAttempt[@"cellMonitorRefreshInvocationException"] != nil;
        if ([refreshAttempt[@"refreshCallbackLatencyMilliseconds"] isKindOfClass:[NSNumber class]]) {
            refreshCallbackLatencyMilliseconds +=
                [refreshAttempt[@"refreshCallbackLatencyMilliseconds"] longLongValue];
        }
        if (refreshCompleted) completedRefreshCount++;
        if (refreshSucceeded) successfulRefreshCount++;

        if (!refreshSucceeded) {
            NSString *reason = refreshAttempt[@"cellMonitorRefreshError"] ?: refreshAttempt[@"status"] ?: @"refreshFailed";
            copyOmissionReasons[@(sampleIndex)] = refreshTimedOut ? @"refreshTimedOut" :
                (refreshInvocationException ? @"refreshInvocationException" : @"refreshDidNotSucceed");
            sample[@"cellMonitorCopyNotAttemptedReason"] = copyOmissionReasons[@(sampleIndex)];
            NSString *kind = refreshAttempt[@"status"] ?: @"failed";
            [failures addObject:@{
                @"sampleIndex": @(sampleIndex),
                @"stage": @"refresh",
                @"kind": kind,
                @"operation": @"refresh",
                @"status": kind,
                @"message": reason,
                @"reason": reason
            }];
            [samples addObject:sample];
            if (CCNMPrivateAsyncAttemptRequiresAbort(refreshTimedOut, refreshInvocationException)) {
                CCNMAdaptiveSamplerAbort(&samplerState, refreshTimedOut, refreshInvocationException);
                break;
            }
            consecutiveExplicitNRSampleCount = 0;
            if (responsiveServing) {
                previousResponsiveAttemptUsable = NO;
                previousServingIdentity = nil;
                CCNMAdaptiveSamplerObserveServing(&samplerState, 0, 0, 0);
            } else {
                CCNMAdaptiveSamplerObserve(&samplerState, 0, 0);
            }
            continue;
        }

        scheduledDelayMicroseconds += CCNMServingCellRefreshSettleMicroseconds;
        usleep(CCNMServingCellRefreshSettleMicroseconds);
        attemptedCopyCount++;
        [attemptedCopyIndexes addIndex:sampleIndex];
        NSMutableDictionary *copyAttempt = CCNMRunCellMonitorCopyAttempt(servingCellClient, context, cellMonitorSymbols);
        copyAttempt[@"sampleIndex"] = @(sampleIndex);
        sample[@"cellMonitorCopyStatus"] = copyAttempt[@"status"] ?: @"unknown";
        sample[@"copyAttempt"] = copyAttempt;
        BOOL copyCompleted = [copyAttempt[@"cellMonitorCopyWaitCompleted"] boolValue];
        BOOL copySucceeded = [copyAttempt[@"cellMonitorCopySucceeded"] boolValue];
        BOOL parsed = [copyAttempt[@"cellMonitorSucceeded"] boolValue];
        BOOL copyTimedOut = [copyAttempt[@"cellMonitorCopyTimedOut"] boolValue];
        BOOL copyInvocationException = copyAttempt[@"cellMonitorCopyInvocationException"] != nil;
        if ([copyAttempt[@"copyCallbackLatencyMilliseconds"] isKindOfClass:[NSNumber class]]) {
            copyCallbackLatencyMilliseconds +=
                [copyAttempt[@"copyCallbackLatencyMilliseconds"] longLongValue];
        }
        if (copyCompleted) completedCopyCount++;
        if (copySucceeded) successfulCopyCount++;
        if (parsed) parsedSampleCount++;

        BOOL sampleObservedNR = NO;
        NSArray *servingCells = [copyAttempt[@"servingCells"] isKindOfClass:[NSArray class]]
            ? copyAttempt[@"servingCells"] : @[];
        sample[@"servingCells"] = servingCells;
        if (parsed) {
            for (id servingCell in servingCells) {
                if (![servingCell isKindOfClass:[NSDictionary class]]) continue;
                [observedServingCells addObject:@{
                    @"sampleIndex": @(sampleIndex),
                    @"servingCell": servingCell
                }];
                NSString *rat = [servingCell[@"rat"] isKindOfClass:[NSString class]]
                    ? servingCell[@"rat"] : nil;
                if (rat && CCNMCellMonitorRATIsNR(rat.UTF8String)) sampleObservedNR = YES;
            }
        }
        sample[@"explicitNRServingCellObserved"] = @(sampleObservedNR);
        if (parsed && sampleObservedNR) {
            nrServingCellObserved = YES;
            observedExplicitNRSampleCount++;
            consecutiveExplicitNRSampleCount++;
        } else {
            consecutiveExplicitNRSampleCount = 0;
        }

        NSString *servingIdentity = nil;
        BOOL servingIdentityAmbiguous = NO;
        NSDictionary *responsiveCandidate = responsiveServing && parsed
            ? CCNMPreferredServingCell(
                servingCells, &servingIdentity, &servingIdentityAmbiguous)
            : nil;
        BOOL sameServingIdentity = servingIdentity.length > 0 &&
            previousServingIdentity.length > 0 &&
            [servingIdentity isEqual:previousServingIdentity];
        if (responsiveServing) {
            previousResponsiveAttemptUsable = parsed && servingIdentity.length > 0;
            sample[@"servingIdentityAvailable"] = @(servingIdentity.length > 0);
            sample[@"servingIdentityAmbiguous"] = @(servingIdentityAmbiguous);
            sample[@"sameServingIdentityAsPrevious"] = @(sameServingIdentity);
            if (servingIdentity.length > 0) {
                sample[@"servingIdentity"] = servingIdentity;
                previousServingIdentity = servingIdentity;
            } else {
                previousServingIdentity = nil;
            }
        }

        if (!parsed) {
            NSString *reason = copyAttempt[@"cellMonitorParseError"] ?: copyAttempt[@"cellMonitorError"] ?:
                copyAttempt[@"status"] ?: @"copyOrParseFailed";
            NSString *kind = copyAttempt[@"status"] ?: @"failed";
            [failures addObject:@{
                @"sampleIndex": @(sampleIndex),
                @"stage": @"copy",
                @"kind": kind,
                @"operation": @"copy",
                @"status": kind,
                @"message": reason,
                @"reason": reason
            }];
        }
        [samples addObject:sample];

        if (CCNMPrivateAsyncAttemptRequiresAbort(copyTimedOut, copyInvocationException)) {
            CCNMAdaptiveSamplerAbort(&samplerState, copyTimedOut, copyInvocationException);
            break;
        }
        if (responsiveServing) {
            CCNMAdaptiveSamplerObserveServing(
                &samplerState,
                parsed,
                servingIdentity.length > 0,
                sameServingIdentity);
            if (samplerState.stopReason == CCNMAdaptiveSamplerStopStableServingConfirmed) {
                confirmedServingCell = [responsiveCandidate copy];
                confirmedServingSampledAt = [copyAttempt[@"sampledAt"] isKindOfClass:[NSNumber class]]
                    ? copyAttempt[@"sampledAt"] : nil;
            }
        } else {
            CCNMAdaptiveSamplerObserve(&samplerState, parsed, sampleObservedNR);
        }
    }

    NSString *remainingReason = CCNMOmissionReasonForStop(samplerState.stopReason);
    NSArray<NSDictionary *> *notAttemptedOperations = CCNMNotAttemptedOperations(
        attemptedRefreshIndexes, attemptedCopyIndexes, copyOmissionReasons, remainingReason);
    NSMutableArray<NSNumber *> *notAttemptedRefreshIndexes = [NSMutableArray array];
    NSMutableArray<NSNumber *> *notAttemptedCopyIndexes = [NSMutableArray array];
    for (NSDictionary *notAttempted in notAttemptedOperations) {
        if ([notAttempted[@"operation"] isEqual:@"refresh"]) {
            [notAttemptedRefreshIndexes addObject:notAttempted[@"sampleIndex"]];
        } else if ([notAttempted[@"operation"] isEqual:@"copy"]) {
            [notAttemptedCopyIndexes addObject:notAttempted[@"sampleIndex"]];
        }
    }

    BOOL explicitNRConfirmed = samplerState.stopReason == CCNMAdaptiveSamplerStopExplicitNRConfirmed;
    BOOL stableServingConfirmed =
        samplerState.stopReason == CCNMAdaptiveSamplerStopStableServingConfirmed;
    BOOL windowExhausted = samplerState.stopReason == CCNMAdaptiveSamplerStopWindowExhausted;
    BOOL fullCleanWindow = windowExhausted &&
        attemptedRefreshCount == CCNMServingCellMaximumSampleCount &&
        completedRefreshCount == CCNMServingCellMaximumSampleCount &&
        successfulRefreshCount == CCNMServingCellMaximumSampleCount &&
        attemptedCopyCount == CCNMServingCellMaximumSampleCount &&
        completedCopyCount == CCNMServingCellMaximumSampleCount &&
        successfulCopyCount == CCNMServingCellMaximumSampleCount &&
        parsedSampleCount == CCNMServingCellMaximumSampleCount;
    CCNMCellMonitorSamplingStatus samplingStatus = responsiveServing
        ? CCNMClassifyStableServingSamplingStatus(
            CCNMServingCellRequiredConsecutiveServingSamples,
            attemptedRefreshCount,
            completedRefreshCount,
            successfulRefreshCount,
            attemptedCopyCount,
            completedCopyCount,
            successfulCopyCount,
            parsedSampleCount,
            stableServingConfirmed)
        : CCNMClassifyAdaptiveCellMonitorSamplingStatus(
            CCNMServingCellMaximumSampleCount,
            CCNMServingCellRequiredConsecutiveNRSamples,
            attemptedRefreshCount,
            completedRefreshCount,
            successfulRefreshCount,
            attemptedCopyCount,
            completedCopyCount,
            successfulCopyCount,
            parsedSampleCount,
            explicitNRConfirmed,
            windowExhausted);
    CCNMNRObservationStatus nrObservationStatus = responsiveServing
        ? (nrServingCellObserved
            ? CCNMNRObservationObserved
            : (fullCleanWindow
                ? CCNMNRObservationNotObservedComplete
                : CCNMNRObservationIndeterminatePartial))
        : CCNMClassifyNRObservationStatus(nrServingCellObserved, samplingStatus);

    report[@"cellMonitorRefreshAttempts"] = refreshAttempts;
    report[@"cellMonitorAttemptedRefreshCount"] = @(attemptedRefreshCount);
    report[@"cellMonitorCompletedRefreshCount"] = @(completedRefreshCount);
    report[@"cellMonitorSuccessfulRefreshCount"] = @(successfulRefreshCount);
    report[@"cellMonitorNotAttemptedRefreshCount"] =
        @(CCNMServingCellMaximumSampleCount - attemptedRefreshCount);
    report[@"cellMonitorNotAttemptedRefreshSampleIndexes"] = notAttemptedRefreshIndexes;
    report[@"cellMonitorSamples"] = samples;
    report[@"cellMonitorAttemptedSampleCount"] = @(attemptedCopyCount);
    report[@"cellMonitorCompletedSampleCount"] = @(completedCopyCount);
    report[@"cellMonitorSuccessfulCopyCount"] = @(successfulCopyCount);
    report[@"cellMonitorSuccessfulSampleCount"] = @(parsedSampleCount);
    report[@"cellMonitorNotAttemptedSampleCount"] =
        @(CCNMServingCellMaximumSampleCount - attemptedCopyCount);
    report[@"cellMonitorNotAttemptedSampleIndexes"] = notAttemptedCopyIndexes;
    report[@"cellMonitorNotAttemptedOperations"] = notAttemptedOperations;
    report[@"cellMonitorSamplingStatus"] = CCNMCellMonitorSamplingStatusName(samplingStatus);
    report[@"cellMonitorStopReason"] = CCNMAdaptiveSamplerStopReasonName(samplerState.stopReason);
    report[@"cellMonitorStoppedEarly"] = @(CCNMAdaptiveSamplerStoppedEarly(&samplerState));
    report[@"cellMonitorSamplingPartial"] = @(samplingStatus == CCNMCellMonitorSamplingPartial);
    report[@"cellMonitorSamplingFailures"] = failures;
    report[@"cellMonitorSamplingFailure"] = failures.firstObject[@"reason"] ?: @"";
    report[@"cellMonitorSamplingAbortedAfterTimeout"] =
        @(samplerState.stopReason == CCNMAdaptiveSamplerStopTimedOut);
    report[@"cellMonitorSamplingAbortedAfterInvocationException"] =
        @(samplerState.stopReason == CCNMAdaptiveSamplerStopInvocationException);
    report[@"cellMonitorSamplingFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
    report[@"cellMonitorSamplingFinishedMonotonic"] = @(CCNMMonotonicNow());
    report[@"cellMonitorSamplingElapsedMilliseconds"] =
        CCNMElapsedMillisecondsSince(samplingStartedMonotonic);
    report[@"cellMonitorScheduledDelayMilliseconds"] =
        @((long long)(scheduledDelayMicroseconds / 1000));
    report[@"cellMonitorRefreshCallbackLatencyMilliseconds"] =
        @(refreshCallbackLatencyMilliseconds);
    report[@"cellMonitorCopyCallbackLatencyMilliseconds"] =
        @(copyCallbackLatencyMilliseconds);
    report[@"observedServingCells"] = observedServingCells;
    report[@"nrServingCellObserved"] = @(nrServingCellObserved);
    report[@"nrObservationStatus"] = CCNMNRObservationStatusName(nrObservationStatus);
    report[@"explicitNRSampleCount"] = @(responsiveServing
        ? observedExplicitNRSampleCount : samplerState.explicitNRSampleCount);
    report[@"explicitNRConfirmationCount"] = @(responsiveServing
        ? consecutiveExplicitNRSampleCount : samplerState.consecutiveNRSampleCount);
    report[@"servingObservationConfirmed"] = @(stableServingConfirmed);
    report[@"servingConfirmationScope"] = stableServingConfirmed ? @"ratBand" : @"none";
    report[@"stableServingConfirmationCount"] =
        @(samplerState.consecutiveStableServingSampleCount);
    report[@"confirmedServingCell"] = confirmedServingCell ?: @{};
    report[@"confirmedServingSampledAt"] = confirmedServingSampledAt ?: @0;
    report[@"cellMonitorSucceeded"] = @(samplingStatus == CCNMCellMonitorSamplingComplete);
    return report;
}

NSDictionary *CCNMRunAdaptiveServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
) {
    return CCNMRunServingCellSampler(
        client,
        context,
        coreTelephonyHandle,
        CCNMAdaptiveSamplerPolicyEarlyNR);
}

NSDictionary *CCNMRunResponsiveServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
) {
    return CCNMRunServingCellSampler(
        client,
        context,
        coreTelephonyHandle,
        CCNMAdaptiveSamplerPolicyStableServing);
}

NSDictionary *CCNMRunFullWindowServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
) {
    return CCNMRunServingCellSampler(
        client,
        context,
        coreTelephonyHandle,
        CCNMAdaptiveSamplerPolicyFullWindow);
}

BOOL CCNMServingCellSamplerHasUnsafeOutstandingAttempt(void) {
    @synchronized(CCNMCellMonitorUnsafeOutstandingLock()) {
        return CCNMCellMonitorUnsafeOutstandingCount > 0;
    }
}
