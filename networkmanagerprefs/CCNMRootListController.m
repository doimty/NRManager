#include "CCNMRootListController.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

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

static const NSTimeInterval CCNMSameValueWriteWatchdogSeconds = 20.0;
// Device traces show that setActiveBandInfo: returns before getBandInfo: exposes
// the new dictionary. The observed propagation delay was about 100 seconds, so
// allow a bounded two-minute window rather than mistaking a stale read for an
// ignored write or a failed restore.
static const useconds_t CCNMBandReadBackPollIntervalMicroseconds = 1000000;
static const NSUInteger CCNMBandReadBackMaximumAttempts = 121;
static const long long CCNMMaximumExpectedBandIdentifier = 1024;
static const NSTimeInterval CCNMNR78ObservationSeconds = 60.0;
static BOOL CCNMBandOperationInProgress = NO;
static BOOL CCNMRecoveryOperationInProgress = NO;
static BOOL CCNMManualRestoreInProgress = NO;
static BOOL CCNMTestSetterInProgress = NO;
static BOOL CCNMTestSetterCallStarted = NO;
static NSTimeInterval CCNMTestSetterStartedMonotonic = 0;
static BOOL CCNMRestoreSetterCallStarted = NO;
static NSUInteger CCNMRestoreSetterGeneration = 0;
static NSUInteger CCNMRestoreSetterAttemptSerial = 0;
static NSUInteger CCNMActiveRestoreSetterAttemptToken = 0;
static NSTimeInterval CCNMRestoreSetterStartedMonotonic = 0;
// Set only when a test setter returned normally inside its monotonic deadline.
// It is the in-process proof that the durable marker for that generation describes a
// call that is already finished rather than one that may still be outstanding.
static NSUInteger CCNMTestSetterReturnedGeneration = 0;
// This is a one-way process latch. It is never cleared before process termination.
static BOOL CCNMSetterTimeoutUncertain = NO;
static NSUInteger CCNMCurrentBandOperationGeneration = 0;
static NSUInteger CCNMManualRecoveryGeneration = 0;

// The write probe is locked to one device and one iOS build, so the complete set
// of radio-technology keys slot 1 reports is a known constant. Requiring the exact
// set makes a transiently partial activeBands dictionary fail closed instead of
// being persisted as if it were the complete original.
static NSSet<NSString *> *CCNMRequiredRATKeys(void) {
    static NSSet<NSString *> *keys = nil;
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

static NSString *CCNMBandProbePath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandprobe.plist");
}

static NSString *CCNMBandSnapshotPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.snapshot.plist");
}

static NSString *CCNMBandWriteIntentPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.intent.plist");
}

static NSString *CCNMBandWriteResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.result.plist");
}

static NSString *CCNMBandWatchdogResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.watchdog.plist");
}

static NSString *CCNMBandSetterInFlightPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.setter-inflight.plist");
}

static NSString *CCNMBandRestoreInFlightPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.restore-inflight.plist");
}

static NSString *CCNMBandRecoveryLockPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.recovery.lock");
}

static NSString *CCNMBandManualRestoreResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.manual-restore.plist");
}

static NSString *CCNMBandRemovalResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.removal.plist");
}

static NSString *CCNMBandNR78ResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.nr78.plist");
}

static NSString *CCNMBandClearStateResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.clearstate.plist");
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

static NSNumber *CCNMBootTimeSeconds(void) {
    struct timeval bootTime = {0};
    size_t size = sizeof(bootTime);
    if (sysctlbyname("kern.boottime", &bootTime, &size, NULL, 0) != 0 || size != sizeof(bootTime)) {
        return nil;
    }
    return @(bootTime.tv_sec);
}

static NSString *CCNMCanonicalUUIDString(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:trimmed];
    return uuid.UUIDString;
}

// kern.boottime is derived from wall-clock time, so a clock correction can change
// it inside a single boot. The boot session UUID is regenerated only by an actual
// boot, which is why it is the authoritative identity for "is that stuck setter
// still potentially alive". Callers must fail closed when it cannot be read.
static NSString *CCNMBootSessionIdentity(void) {
    return CCNMCanonicalUUIDString(CCNMSysctlString("kern.bootsessionuuid"));
}

typedef NS_ENUM(NSInteger, CCNMBootRelation) {
    CCNMBootRelationUnknown = 0,
    CCNMBootRelationCurrentBoot,
    CCNMBootRelationEarlierBoot
};

static CCNMBootRelation CCNMMarkerBootRelation(NSDictionary *marker) {
    NSString *current = CCNMBootSessionIdentity();
    NSString *recorded = CCNMCanonicalUUIDString(marker[@"bootSessionUUID"]);
    if (!current || !recorded) {
        return CCNMBootRelationUnknown;
    }
    return [recorded isEqualToString:current] ? CCNMBootRelationCurrentBoot : CCNMBootRelationEarlierBoot;
}

static BOOL CCNMValidateSetterInFlightMarkerHeader(NSDictionary *record, NSString **failure) {
    NSArray<NSString *> *allowedOperations = @[@"same_value_write", @"cold_band_removal", @"nr78_only"];
    BOOL valid = [record isKindOfClass:[NSDictionary class]] &&
                 [record[@"schemaVersion"] isEqual:@1] &&
                 [record[@"state"] isEqual:@"setter_in_flight"] &&
                 [record[@"operation"] isKindOfClass:[NSString class]] &&
                 [allowedOperations containsObject:record[@"operation"]] &&
                 [record[@"createdAt"] isKindOfClass:[NSNumber class]] &&
                 [record[@"createdAt"] longLongValue] > 0 &&
                 [record[@"processID"] isKindOfClass:[NSNumber class]] &&
                 [record[@"processID"] intValue] > 0 &&
                 CCNMCanonicalUUIDString(record[@"bootSessionUUID"]) != nil &&
                 [record[@"bootTimeSeconds"] isKindOfClass:[NSNumber class]] &&
                 [record[@"bootTimeSeconds"] longLongValue] > 0 &&
                 [record[@"operationGeneration"] isKindOfClass:[NSNumber class]] &&
                 [record[@"operationGeneration"] unsignedIntegerValue] > 0 &&
                 [record[@"slotID"] isEqual:@1] &&
                 CCNMCanonicalUUIDString(record[@"subscriptionUUID"]) != nil &&
                 [record[@"snapshotCreatedAt"] isKindOfClass:[NSNumber class]] &&
                 [record[@"snapshotCreatedAt"] longLongValue] > 0 &&
                 [record[@"writeIntentCreatedAt"] isKindOfClass:[NSNumber class]] &&
                 [record[@"writeIntentCreatedAt"] longLongValue] > 0;
    if (!valid && failure) {
        *failure = @"The setter-in-flight record is invalid; preserving recovery evidence.";
    }
    return valid;
}

static BOOL CCNMValidateRestoreInFlightMarkerHeader(NSDictionary *record, NSString **failure) {
    NSArray<NSString *> *allowedOperations = @[
        @"same_value_automatic_restore",
        @"cold_band_removal_automatic_restore",
        @"nr78_only_automatic_restore",
        @"manual_restore"
    ];
    BOOL valid = [record isKindOfClass:[NSDictionary class]] &&
                 [record[@"schemaVersion"] isEqual:@1] &&
                 [record[@"state"] isEqual:@"restore_setter_in_flight"] &&
                 [record[@"operation"] isKindOfClass:[NSString class]] &&
                 [allowedOperations containsObject:record[@"operation"]] &&
                 [record[@"createdAt"] isKindOfClass:[NSNumber class]] &&
                 [record[@"createdAt"] longLongValue] > 0 &&
                 [record[@"processID"] isKindOfClass:[NSNumber class]] &&
                 [record[@"processID"] intValue] > 0 &&
                 CCNMCanonicalUUIDString(record[@"bootSessionUUID"]) != nil &&
                 [record[@"bootTimeSeconds"] isKindOfClass:[NSNumber class]] &&
                 [record[@"bootTimeSeconds"] longLongValue] > 0 &&
                 [record[@"operationGeneration"] isKindOfClass:[NSNumber class]] &&
                 [record[@"operationGeneration"] unsignedIntegerValue] > 0 &&
                 [record[@"slotID"] isEqual:@1] &&
                 CCNMCanonicalUUIDString(record[@"subscriptionUUID"]) != nil &&
                 [record[@"snapshotCreatedAt"] isKindOfClass:[NSNumber class]] &&
                 [record[@"snapshotCreatedAt"] longLongValue] > 0;
    if (!valid && failure) {
        *failure = @"The restore-in-flight record is invalid; preserving recovery evidence.";
    }
    return valid;
}

// Any durable in-flight marker that is not provably from an earlier boot means a
// synchronous setter started in this boot may still be outstanding. In that state
// no further write may be issued and no recovery evidence may be deleted, because
// a late completion could silently reinstate the modified band set.
//
// `returnedSetterRecord` is the single deliberate exception: a caller passes the
// exact, valid test-setter marker it created in this process, and only after that
// synchronous call returned normally inside its deadline. The restore marker is
// never exempt.
static BOOL CCNMCurrentBootSetterMayBeOutstanding(NSDictionary *returnedSetterRecord, NSString **detail) {
    for (NSString *path in @[CCNMBandSetterInFlightPath(), CCNMBandRestoreInFlightPath()]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            continue;
        }
        NSDictionary *marker = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![marker isKindOfClass:[NSDictionary class]]) {
            if (detail) {
                *detail = [NSString stringWithFormat:@"%@ exists but is unreadable, so an outstanding setter cannot be ruled out.", path.lastPathComponent];
            }
            return YES;
        }

        BOOL setterMarker = [path isEqualToString:CCNMBandSetterInFlightPath()];
        NSString *headerFailure = nil;
        BOOL validHeader = setterMarker
            ? CCNMValidateSetterInFlightMarkerHeader(marker, &headerFailure)
            : CCNMValidateRestoreInFlightMarkerHeader(marker, &headerFailure);
        if (!validHeader) {
            if (detail) {
                *detail = headerFailure ?: @"An in-flight record is invalid, so an outstanding setter cannot be ruled out.";
            }
            return YES;
        }

        if (setterMarker &&
            [returnedSetterRecord isKindOfClass:[NSDictionary class]] &&
            [marker isEqualToDictionary:returnedSetterRecord]) {
            continue;
        }

        CCNMBootRelation relation = CCNMMarkerBootRelation(marker);
        if (relation == CCNMBootRelationUnknown) {
            if (detail) {
                *detail = @"The boot session identity could not be compared, so an outstanding setter cannot be ruled out.";
            }
            return YES;
        }
        if (relation == CCNMBootRelationCurrentBoot) {
            if (detail) {
                *detail = [NSString stringWithFormat:@"%@ belongs to this boot session. Reboot the device first.", path.lastPathComponent];
            }
            return YES;
        }
    }
    return NO;
}

static BOOL CCNMValidateTargetDevice(NSMutableDictionary *result, NSString **failure) {
    NSString *deviceModel = CCNMSysctlString("hw.machine");
    NSString *systemBuild = CCNMSysctlString("kern.osversion");
    NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
    result[@"deviceModel"] = deviceModel ?: @"";
    result[@"systemBuild"] = systemBuild ?: @"";
    result[@"systemVersion"] = systemVersion ?: @"";

    BOOL valid = [deviceModel isEqualToString:@"iPhone14,3"] &&
                 [systemBuild isEqualToString:@"19B81"] &&
                 [systemVersion isEqualToString:@"15.1.1"];
    if (!valid && failure) {
        *failure = @"This write probe is locked to iPhone14,3 / iOS 15.1.1 / 19B81.";
    }
    return valid;
}

static NSTimeInterval CCNMMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (NSTimeInterval)now.tv_sec + ((NSTimeInterval)now.tv_nsec / (NSTimeInterval)NSEC_PER_SEC);
}

static BOOL CCNMBeginBandOperation(NSUInteger *operationGeneration,
                                   NSUInteger *manualRecoveryGeneration) {
    @synchronized([CCNMRootListController class]) {
        if (CCNMBandOperationInProgress ||
            CCNMRecoveryOperationInProgress ||
            CCNMManualRestoreInProgress ||
            CCNMSetterTimeoutUncertain) {
            return NO;
        }
        CCNMBandOperationInProgress = YES;
        CCNMCurrentBandOperationGeneration++;
        if (operationGeneration) {
            *operationGeneration = CCNMCurrentBandOperationGeneration;
        }
        if (manualRecoveryGeneration) {
            *manualRecoveryGeneration = CCNMManualRecoveryGeneration;
        }
        return YES;
    }
}

static BOOL CCNMBeginTestSetterOperation(NSUInteger operationGeneration,
                                         NSUInteger manualRecoveryGeneration,
                                         NSString **failure) {
    @synchronized([CCNMRootListController class]) {
        if (!CCNMBandOperationInProgress ||
            CCNMCurrentBandOperationGeneration != operationGeneration ||
            CCNMManualRecoveryGeneration != manualRecoveryGeneration ||
            CCNMRecoveryOperationInProgress ||
            CCNMManualRestoreInProgress ||
            CCNMTestSetterInProgress ||
            CCNMSetterTimeoutUncertain) {
            if (failure) {
                *failure = @"A recovery, uncertain setter, or newer operation invalidated the write before the setter was called.";
            }
            return NO;
        }
        CCNMTestSetterInProgress = YES;
        CCNMTestSetterCallStarted = NO;
        CCNMTestSetterStartedMonotonic = 0;
        return YES;
    }
}

static BOOL CCNMMarkTestSetterCallStarted(NSUInteger operationGeneration) {
    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    @synchronized([CCNMRootListController class]) {
        if (startedMonotonic <= 0 ||
            !CCNMBandOperationInProgress ||
            !CCNMTestSetterInProgress ||
            CCNMSetterTimeoutUncertain ||
            CCNMCurrentBandOperationGeneration != operationGeneration) {
            return NO;
        }
        CCNMTestSetterStartedMonotonic = startedMonotonic;
        CCNMTestSetterCallStarted = YES;
        return YES;
    }
}

static BOOL CCNMMarkSetterTimeoutUncertain(NSUInteger operationGeneration) {
    NSTimeInterval observedMonotonic = CCNMMonotonicNow();
    @synchronized([CCNMRootListController class]) {
        BOOL deadlineReached = CCNMTestSetterStartedMonotonic <= 0 ||
                               observedMonotonic <= 0 ||
                               observedMonotonic - CCNMTestSetterStartedMonotonic >= CCNMSameValueWriteWatchdogSeconds;
        if (!deadlineReached ||
            !CCNMBandOperationInProgress ||
            !CCNMTestSetterInProgress ||
            !CCNMTestSetterCallStarted ||
            CCNMCurrentBandOperationGeneration != operationGeneration) {
            return NO;
        }
        CCNMSetterTimeoutUncertain = YES;
        return YES;
    }
}

static BOOL CCNMFinishTestSetterOperation(NSUInteger operationGeneration,
                                          BOOL setterReturnedNormally,
                                          NSTimeInterval finishedMonotonic,
                                          BOOL *deadlineExceeded) {
    @synchronized([CCNMRootListController class]) {
        BOOL callWasStarted = CCNMBandOperationInProgress &&
                              CCNMTestSetterInProgress &&
                              CCNMTestSetterCallStarted &&
                              CCNMCurrentBandOperationGeneration == operationGeneration;
        NSTimeInterval elapsed = callWasStarted &&
                                 CCNMTestSetterStartedMonotonic > 0 &&
                                 finishedMonotonic >= CCNMTestSetterStartedMonotonic
            ? finishedMonotonic - CCNMTestSetterStartedMonotonic
            : 0;
        BOOL invalidClock = callWasStarted &&
                            (CCNMTestSetterStartedMonotonic <= 0 ||
                             finishedMonotonic <= 0 ||
                             finishedMonotonic < CCNMTestSetterStartedMonotonic);
        BOOL exceededDeadline = callWasStarted &&
                                (invalidClock || elapsed >= CCNMSameValueWriteWatchdogSeconds);
        if (deadlineExceeded) {
            *deadlineExceeded = exceededDeadline;
        }
        if (callWasStarted && (!setterReturnedNormally || exceededDeadline)) {
            CCNMSetterTimeoutUncertain = YES;
        }
        BOOL uncertain = CCNMSetterTimeoutUncertain;
        CCNMTestSetterInProgress = NO;
        CCNMTestSetterCallStarted = NO;
        CCNMTestSetterStartedMonotonic = 0;
        if (callWasStarted && setterReturnedNormally && !uncertain) {
            CCNMTestSetterReturnedGeneration = operationGeneration;
        }
        return uncertain;
    }
}

// The only in-process proof that this generation's test setter is finished. A caller
// may exempt its own durable setter marker from the outstanding check only while
// this holds.
static BOOL CCNMTestSetterProvablyReturned(NSUInteger operationGeneration) {
    @synchronized([CCNMRootListController class]) {
        return operationGeneration > 0 &&
               !CCNMSetterTimeoutUncertain &&
               !CCNMTestSetterCallStarted &&
               !CCNMTestSetterInProgress &&
               CCNMTestSetterReturnedGeneration == operationGeneration;
    }
}

static BOOL CCNMBeginAutomaticRestoreOperation(NSUInteger operationGeneration) {
    @synchronized([CCNMRootListController class]) {
        if (!CCNMBandOperationInProgress ||
            CCNMCurrentBandOperationGeneration != operationGeneration ||
            CCNMRecoveryOperationInProgress ||
            CCNMManualRestoreInProgress ||
            CCNMTestSetterInProgress ||
            CCNMSetterTimeoutUncertain) {
            return NO;
        }
        CCNMRecoveryOperationInProgress = YES;
        return YES;
    }
}

static BOOL CCNMBeginManualRestoreOperation(NSUInteger *manualRestoreGeneration) {
    @synchronized([CCNMRootListController class]) {
        if (CCNMManualRestoreInProgress ||
            CCNMBandOperationInProgress ||
            CCNMRecoveryOperationInProgress ||
            CCNMTestSetterInProgress ||
            CCNMSetterTimeoutUncertain) {
            return NO;
        }
        CCNMManualRecoveryGeneration++;
        CCNMManualRestoreInProgress = YES;
        if (manualRestoreGeneration) {
            *manualRestoreGeneration = CCNMManualRecoveryGeneration;
        }
        return YES;
    }
}
static void CCNMEndRecoveryOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMRecoveryOperationInProgress = NO;
        CCNMRestoreSetterCallStarted = NO;
        CCNMRestoreSetterGeneration = 0;
        CCNMActiveRestoreSetterAttemptToken = 0;
        CCNMRestoreSetterStartedMonotonic = 0;
    }
}

static void CCNMEndManualRestoreOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMManualRestoreInProgress = NO;
        CCNMRestoreSetterCallStarted = NO;
        CCNMRestoreSetterGeneration = 0;
        CCNMActiveRestoreSetterAttemptToken = 0;
        CCNMRestoreSetterStartedMonotonic = 0;
    }
}

static void CCNMEndBandOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMBandOperationInProgress = NO;
        CCNMTestSetterInProgress = NO;
        CCNMTestSetterCallStarted = NO;
        CCNMTestSetterStartedMonotonic = 0;
        CCNMRestoreSetterCallStarted = NO;
        CCNMRestoreSetterGeneration = 0;
        CCNMActiveRestoreSetterAttemptToken = 0;
        CCNMRestoreSetterStartedMonotonic = 0;
    }
}

static NSString *CCNMReadableObject(id object) {
    if (!object) {
        return @"(none)";
    }

    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
        if (data && !error) {
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }

    return [object description];
}

static BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil && [left isEqualToDictionary:right];
}

static NSDictionary *CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString **failure) {
    if (![dictionary isKindOfClass:[NSDictionary class]] || dictionary.count == 0) {
        if (failure) {
            *failure = @"The Band dictionary is missing or empty.";
        }
        return nil;
    }

    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The Band dictionary could not be serialized.";
        }
        return nil;
    }

    id copiedObject = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:&serializationError];
    if (![copiedObject isKindOfClass:[NSDictionary class]] || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The Band dictionary copy is invalid.";
        }
        return nil;
    }

    return copiedObject;
}

static BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString **failure) {
    if (![bands isKindOfClass:[NSDictionary class]] || bands.count == 0) {
        if (failure) {
            *failure = @"The active-band dictionary is missing or empty.";
        }
        return NO;
    }

    // A partial read must never be treated as a complete original, because it would
    // later be written back as the "restore" value and silently drop whole radio
    // technologies. On the locked target the key set is fixed, so require it exactly.
    if (![[NSSet setWithArray:bands.allKeys] isEqualToSet:CCNMRequiredRATKeys()]) {
        if (failure) {
            *failure = @"The active-band dictionary does not contain exactly the expected radio-technology keys for this device.";
        }
        return NO;
    }

    for (id key in bands) {
        id values = bands[key];
        if (![key isKindOfClass:[NSString class]] ||
            ![(NSString *)key hasPrefix:@"kCTRegistrationRadioAccessTechnology"] ||
            ![values isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"The active-band dictionary has an unexpected RAT key or value type.";
            }
            return NO;
        }

        NSMutableSet *seen = [NSMutableSet set];
        for (id band in (NSArray *)values) {
            if (![band isKindOfClass:[NSNumber class]] || [band longLongValue] <= 0 || [band longLongValue] > CCNMMaximumExpectedBandIdentifier || [seen containsObject:band]) {
                if (failure) {
                    *failure = @"The active-band dictionary contains an invalid or duplicate Band value.";
                }
                return NO;
            }
            [seen addObject:band];
        }
    }

    return YES;
}

// The removal experiment is restricted to LTE band 48 (US-only CBRS spectrum) and
// LTE band 46 (unlicensed LAA, deployed only as a secondary aggregation carrier).
// Those are the least likely LTE entries to be serving this subscription, but this
// probe never reads the serving band or registration state, so a temporary loss of
// cellular service cannot be ruled out. Every failure path therefore keeps the
// snapshot and tells the user how to restore it.
static NSString *const CCNMRemovalRATKey = @"kCTRegistrationRadioAccessTechnologyLTE";

static NSArray<NSNumber *> *CCNMColdRemovalCandidates(void) {
    return @[@48, @46];
}

static NSArray *CCNMArrayRemovingSingleOccurrence(NSArray *values, NSNumber *target, BOOL *removedExactlyOne) {
    NSMutableArray *reduced = [NSMutableArray arrayWithCapacity:values.count];
    NSUInteger removals = 0;
    for (id value in values) {
        if (removals == 0 && [value isKindOfClass:[NSNumber class]] && [value isEqualToNumber:target]) {
            removals++;
            continue;
        }
        [reduced addObject:value];
    }
    if (removedExactlyOne) {
        *removedExactlyOne = (removals == 1);
    }
    return reduced;
}

static BOOL CCNMValidateSingleBandRemoval(NSDictionary *originalBands,
                                          NSDictionary *modifiedBands,
                                          NSNumber *removedBand,
                                          NSString **failure) {
    if (![originalBands isKindOfClass:[NSDictionary class]] ||
        ![modifiedBands isKindOfClass:[NSDictionary class]] ||
        ![removedBand isKindOfClass:[NSNumber class]] ||
        ![CCNMColdRemovalCandidates() containsObject:removedBand]) {
        if (failure) {
            *failure = @"The single-band removal inputs are incomplete.";
        }
        return NO;
    }

    if (![[NSSet setWithArray:originalBands.allKeys] isEqualToSet:[NSSet setWithArray:modifiedBands.allKeys]]) {
        if (failure) {
            *failure = @"The removal payload changed the set of radio-access-technology keys.";
        }
        return NO;
    }

    for (NSString *key in originalBands) {
        NSArray *originalValues = originalBands[key];
        NSArray *modifiedValues = modifiedBands[key];
        if (![originalValues isKindOfClass:[NSArray class]] || ![modifiedValues isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"The removal payload has an unexpected band value type.";
            }
            return NO;
        }

        if (![key isEqualToString:CCNMRemovalRATKey]) {
            if (![modifiedValues isEqualToArray:originalValues]) {
                if (failure) {
                    *failure = [NSString stringWithFormat:@"The removal payload modified %@, which must stay byte-identical.", key];
                }
                return NO;
            }
            continue;
        }

        BOOL removedExactlyOne = NO;
        NSArray *expected = CCNMArrayRemovingSingleOccurrence(originalValues, removedBand, &removedExactlyOne);
        if (!removedExactlyOne || ![modifiedValues isEqualToArray:expected]) {
            if (failure) {
                *failure = @"The removal payload is not exactly the original LTE list minus one cold band.";
            }
            return NO;
        }
    }

    return YES;
}

static NSDictionary *CCNMBuildSingleRemovalBands(NSDictionary *originalBands,
                                                 NSDictionary *supportedBands,
                                                 NSNumber **removedBand,
                                                 NSString **failure) {
    if (!CCNMValidateBandDictionary(originalBands, failure) ||
        !CCNMValidateBandDictionary(supportedBands, failure)) {
        return nil;
    }

    NSArray *originalValues = originalBands[CCNMRemovalRATKey];
    NSArray *supportedValues = supportedBands[CCNMRemovalRATKey];
    if (![originalValues isKindOfClass:[NSArray class]] || originalValues.count < 2 ||
        ![supportedValues isKindOfClass:[NSArray class]]) {
        if (failure) {
            *failure = @"The live active/supported LTE band lists are invalid for a safe single-band removal.";
        }
        return nil;
    }

    NSNumber *target = nil;
    for (NSNumber *candidate in CCNMColdRemovalCandidates()) {
        if ([originalValues containsObject:candidate] && [supportedValues containsObject:candidate]) {
            target = candidate;
            break;
        }
    }
    if (!target) {
        if (failure) {
            *failure = @"None of the allowed cold LTE bands is present in both the live active and supported sets, so no removal is attempted.";
        }
        return nil;
    }

    BOOL removedExactlyOne = NO;
    NSArray *reduced = CCNMArrayRemovingSingleOccurrence(originalValues, target, &removedExactlyOne);
    if (!removedExactlyOne) {
        if (failure) {
            *failure = @"The cold LTE band could not be removed exactly once.";
        }
        return nil;
    }

    NSMutableDictionary *draft = [originalBands mutableCopy];
    draft[CCNMRemovalRATKey] = reduced;
    NSDictionary *modified = CCNMDeepCopyDictionary(draft, failure);
    if (!modified ||
        !CCNMValidateBandDictionary(modified, failure) ||
        !CCNMValidateSingleBandRemoval(originalBands, modified, target, failure)) {
        return nil;
    }

    if (removedBand) {
        *removedBand = target;
    }
    return modified;
}

static NSString *const CCNMNRRATKey = @"kCTRegistrationRadioAccessTechnologyNR";

static NSNumber *CCNMNR78Band(void) {
    return @78;
}

static BOOL CCNMValidateNR78OnlyBands(NSDictionary *originalBands,
                                      NSDictionary *modifiedBands,
                                      NSString **failure) {
    if (!CCNMValidateBandDictionary(originalBands, failure) ||
        !CCNMValidateBandDictionary(modifiedBands, failure)) {
        return NO;
    }

    if (![[NSSet setWithArray:originalBands.allKeys] isEqualToSet:[NSSet setWithArray:modifiedBands.allKeys]]) {
        if (failure) {
            *failure = @"The n78-only payload changed the set of radio-access-technology keys.";
        }
        return NO;
    }

    for (NSString *key in originalBands) {
        NSArray *originalValues = originalBands[key];
        NSArray *modifiedValues = modifiedBands[key];
        if (![originalValues isKindOfClass:[NSArray class]] ||
            ![modifiedValues isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"The n78-only payload has an unexpected band value type.";
            }
            return NO;
        }

        if ([key isEqualToString:CCNMNRRATKey]) {
            if (![modifiedValues isEqualToArray:@[CCNMNR78Band()]]) {
                if (failure) {
                    *failure = @"The NR payload must contain exactly band n78.";
                }
                return NO;
            }
        } else if (![modifiedValues isEqualToArray:originalValues]) {
            if (failure) {
                *failure = [NSString stringWithFormat:@"The n78-only payload modified %@, which must stay byte-identical.", key];
            }
            return NO;
        }
    }

    return YES;
}

static NSDictionary *CCNMBuildNR78OnlyBands(NSDictionary *originalBands,
                                             NSDictionary *supportedBands,
                                             NSString **failure) {
    if (!CCNMValidateBandDictionary(originalBands, failure) ||
        !CCNMValidateBandDictionary(supportedBands, failure)) {
        return nil;
    }

    NSArray *activeNR = originalBands[CCNMNRRATKey];
    NSArray *supportedNR = supportedBands[CCNMNRRATKey];
    if (![activeNR isKindOfClass:[NSArray class]] ||
        ![supportedNR isKindOfClass:[NSArray class]] ||
        ![activeNR containsObject:CCNMNR78Band()] ||
        ![supportedNR containsObject:CCNMNR78Band()]) {
        if (failure) {
            *failure = @"NR band n78 is not present in both the live active and supported NR sets.";
        }
        return nil;
    }
    if ([activeNR isEqualToArray:@[CCNMNR78Band()]]) {
        if (failure) {
            *failure = @"The live NR set is already exactly [78], so this would not be a changed-value probe.";
        }
        return nil;
    }

    NSMutableDictionary *draft = [originalBands mutableCopy];
    draft[CCNMNRRATKey] = @[CCNMNR78Band()];
    NSDictionary *modified = CCNMDeepCopyDictionary(draft, failure);
    if (!modified || !CCNMValidateNR78OnlyBands(originalBands, modified, failure)) {
        return nil;
    }
    return modified;
}

static NSDictionary *CCNMBandDictionaryDifference(NSDictionary *left, NSDictionary *right) {
    NSMutableDictionary *difference = [NSMutableDictionary dictionary];
    if (![left isKindOfClass:[NSDictionary class]] || ![right isKindOfClass:[NSDictionary class]]) {
        return difference;
    }

    NSMutableSet *keys = [NSMutableSet setWithArray:left.allKeys];
    [keys addObjectsFromArray:right.allKeys];
    for (NSString *key in keys) {
        NSArray *leftValues = [left[key] isKindOfClass:[NSArray class]] ? left[key] : @[];
        NSArray *rightValues = [right[key] isKindOfClass:[NSArray class]] ? right[key] : @[];
        if ([leftValues isEqualToArray:rightValues]) {
            continue;
        }
        NSMutableArray *onlyInLeft = [leftValues mutableCopy];
        [onlyInLeft removeObjectsInArray:rightValues];
        NSMutableArray *onlyInRight = [rightValues mutableCopy];
        [onlyInRight removeObjectsInArray:leftValues];
        difference[key] = @{
            @"onlyInFirst": onlyInLeft ?: @[],
            @"onlyInSecond": onlyInRight ?: @[]
        };
    }
    return difference;
}

static BOOL CCNMValidateSnapshot(NSDictionary *snapshot, NSDictionary **bands, NSString **failure) {
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"The saved slot-1 Band snapshot is missing or invalid.";
        }
        return NO;
    }

    NSDictionary *snapshotBands = [snapshot[@"activeBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"activeBands"] : nil;
    if (![snapshot[@"schemaVersion"] isEqual:@1] ||
        ![snapshot[@"createdAt"] isKindOfClass:[NSNumber class]] ||
        [snapshot[@"createdAt"] longLongValue] <= 0 ||
        ![snapshot[@"slotID"] isEqual:@1] ||
        !CCNMCanonicalUUIDString(snapshot[@"subscriptionUUID"]) ||
        !CCNMValidateBandDictionary(snapshotBands, failure)) {
        if (failure && !*failure) {
            *failure = @"The saved slot-1 Band snapshot is missing or invalid.";
        }
        return NO;
    }

    if (bands) {
        *bands = snapshotBands;
    }
    return YES;
}

static BOOL CCNMValidateWriteIntent(NSDictionary *intent, NSDictionary *snapshot, NSString **failure) {
    if (![intent isKindOfClass:[NSDictionary class]] || ![snapshot isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"No valid write-intent record exists for this recovery snapshot.";
        }
        return NO;
    }

    NSDictionary *snapshotBands = [snapshot[@"activeBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"activeBands"] : nil;
    NSDictionary *intentBands = [intent[@"snapshotActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"snapshotActiveBands"] : nil;
    NSArray *allowedOperations = @[@"same_value_write_intent", @"cold_band_removal_intent", @"nr78_only_intent"];
    BOOL valid = [intent[@"schemaVersion"] isEqual:@1] &&
                 [intent[@"operation"] isKindOfClass:[NSString class]] &&
                 [allowedOperations containsObject:intent[@"operation"]] &&
                 [intent[@"createdAt"] isKindOfClass:[NSNumber class]] &&
                 [intent[@"createdAt"] longLongValue] > 0 &&
                 [intent[@"slotID"] isEqual:@1] &&
                 [intent[@"operationGeneration"] isKindOfClass:[NSNumber class]] &&
                 [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
                 [CCNMCanonicalUUIDString(intent[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(snapshot[@"subscriptionUUID"])] &&
                 [intent[@"snapshotCreatedAt"] isKindOfClass:[NSNumber class]] &&
                 [intent[@"snapshotCreatedAt"] isEqual:snapshot[@"createdAt"]] &&
                 CCNMValidateBandDictionary(intentBands, failure) &&
                 CCNMDictionariesEqual(snapshotBands, intentBands);
    if (valid && [intent[@"operation"] isEqual:@"cold_band_removal_intent"]) {
        NSDictionary *snapshotSupportedBands = [snapshot[@"supportedBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"supportedBands"] : nil;
        NSDictionary *intentSupportedBands = [intent[@"snapshotSupportedBands"] isKindOfClass:[NSDictionary class]] ? intent[@"snapshotSupportedBands"] : nil;
        NSDictionary *requestedBands = [intent[@"requestedActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"requestedActiveBands"] : nil;
        NSNumber *expectedRemovedBand = nil;
        NSDictionary *expectedRequestedBands = CCNMBuildSingleRemovalBands(snapshotBands,
                                                                            snapshotSupportedBands,
                                                                            &expectedRemovedBand,
                                                                            failure);
        valid = [intent[@"removalRATKey"] isEqual:CCNMRemovalRATKey] &&
                [intent[@"removedBand"] isKindOfClass:[NSNumber class]] &&
                [CCNMColdRemovalCandidates() containsObject:intent[@"removedBand"]] &&
                CCNMValidateBandDictionary(intentSupportedBands, failure) &&
                CCNMDictionariesEqual(snapshotSupportedBands, intentSupportedBands) &&
                [expectedRemovedBand isEqual:intent[@"removedBand"]] &&
                CCNMDictionariesEqual(expectedRequestedBands, requestedBands) &&
                CCNMValidateSingleBandRemoval(snapshotBands, requestedBands, intent[@"removedBand"], failure);
    }
    if (valid && [intent[@"operation"] isEqual:@"nr78_only_intent"]) {
        NSDictionary *snapshotSupportedBands = [snapshot[@"supportedBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"supportedBands"] : nil;
        NSDictionary *intentSupportedBands = [intent[@"snapshotSupportedBands"] isKindOfClass:[NSDictionary class]] ? intent[@"snapshotSupportedBands"] : nil;
        NSDictionary *requestedBands = [intent[@"requestedActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"requestedActiveBands"] : nil;
        NSDictionary *expectedRequestedBands = CCNMBuildNR78OnlyBands(snapshotBands,
                                                                      snapshotSupportedBands,
                                                                      failure);
        valid = [intent[@"targetRATKey"] isEqual:CCNMNRRATKey] &&
                [intent[@"targetBand"] isEqual:CCNMNR78Band()] &&
                [intent[@"observationSeconds"] isKindOfClass:[NSNumber class]] &&
                [intent[@"observationSeconds"] doubleValue] == CCNMNR78ObservationSeconds &&
                CCNMValidateBandDictionary(intentSupportedBands, failure) &&
                CCNMDictionariesEqual(snapshotSupportedBands, intentSupportedBands) &&
                CCNMDictionariesEqual(expectedRequestedBands, requestedBands) &&
                CCNMValidateNR78OnlyBands(snapshotBands, requestedBands, failure);
    }
    if (!valid) {
        if (failure && !*failure) {
            *failure = @"The write-intent record does not match the unique recovery snapshot.";
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMSyncParentDirectory(NSString *path, NSString **failure) {
    NSString *directory = [path stringByDeletingLastPathComponent];
    int directoryDescriptor = open(directory.fileSystemRepresentation, O_RDONLY);
    if (directoryDescriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not open the recovery-record directory: %s", strerror(errno)];
        }
        return NO;
    }
    int syncResult = fsync(directoryDescriptor);
    int syncError = errno;
    close(directoryDescriptor);
    if (syncResult != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not sync the recovery-record directory: %s", strerror(syncError ?: EIO)];
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMFullSyncFileDescriptor(int fileDescriptor, NSString **failure) {
#ifdef F_FULLFSYNC
    if (fcntl(fileDescriptor, F_FULLFSYNC, 0) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not fully sync the recovery record: %s", strerror(errno ?: EIO)];
        }
        return NO;
    }
    return YES;
#else
    if (fsync(fileDescriptor) != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not sync the recovery record: %s", strerror(errno ?: EIO)];
        }
        return NO;
    }
    return YES;
#endif
}

static BOOL CCNMUnlinkIfPresent(NSString *path, BOOL *removed, NSString **failure) {
    const char *filePath = path.fileSystemRepresentation;
    if (unlink(filePath) != 0 && errno != ENOENT) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not remove %@: %s", path.lastPathComponent, strerror(errno)];
        }
        return NO;
    }
    if (removed) {
        *removed = YES;
    }
    return CCNMSyncParentDirectory(path, failure);
}

static BOOL CCNMCreateDurablePlistExclusively(NSDictionary *plist, NSString *path, NSString **failure) {
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The recovery record is not a valid property list.";
        }
        return NO;
    }

    const char *filePath = path.fileSystemRepresentation;
    int fileDescriptor = open(filePath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (fileDescriptor < 0) {
        if (failure) {
            *failure = errno == EEXIST ? [NSString stringWithFormat:@"%@ already exists; refusing to overwrite it.", path.lastPathComponent]
                                       : [NSString stringWithFormat:@"Could not create %@: %s", path.lastPathComponent, strerror(errno)];
        }
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL wroteAllBytes = YES;
    int savedError = 0;
    while (remaining > 0) {
        ssize_t written = write(fileDescriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            wroteAllBytes = NO;
            savedError = errno ?: EIO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    NSString *syncFailure = nil;
    if (wroteAllBytes && !CCNMFullSyncFileDescriptor(fileDescriptor, &syncFailure)) {
        wroteAllBytes = NO;
        savedError = EIO;
    }
    if (close(fileDescriptor) != 0 && wroteAllBytes) {
        wroteAllBytes = NO;
        savedError = errno ?: EIO;
    }
    if (!wroteAllBytes) {
        unlink(filePath);
        CCNMSyncParentDirectory(path, NULL);
        if (failure) {
            *failure = syncFailure ?: [NSString stringWithFormat:@"Could not durably save %@: %s", path.lastPathComponent, strerror(savedError ?: EIO)];
        }
        return NO;
    }

    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:plist]) {
        unlink(filePath);
        CCNMSyncParentDirectory(path, NULL);
        if (failure) {
            *failure = [NSString stringWithFormat:@"%@ failed read-back verification.", path.lastPathComponent];
        }
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    return YES;
}

// Replace a validated earlier-boot marker with the current attempt as one rename.
// A crash can leave either the old marker or the new marker, but never an empty
// recovery path between them.
static BOOL CCNMReplaceDurablePlistExact(NSDictionary *expectedRecord,
                                         NSDictionary *replacementRecord,
                                         NSString *path,
                                         NSString **failure) {
    NSDictionary *liveRecord = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![liveRecord isEqualToDictionary:expectedRecord]) {
        if (failure) {
            *failure = @"The prior recovery marker changed before atomic handoff; preserving it.";
        }
        return NO;
    }

    NSString *token = [NSUUID UUID].UUIDString;
    if (!token) {
        if (failure) {
            *failure = @"Could not allocate a unique recovery-marker handoff path.";
        }
        return NO;
    }
    NSString *temporaryPath = [NSString stringWithFormat:@"%@.handoff.%d.%@", path, getpid(), token];
    if (!CCNMCreateDurablePlistExclusively(replacementRecord, temporaryPath, failure)) {
        return NO;
    }

    liveRecord = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![liveRecord isEqualToDictionary:expectedRecord]) {
        CCNMUnlinkIfPresent(temporaryPath, NULL, NULL);
        if (failure) {
            *failure = @"The prior recovery marker changed during atomic handoff; preserving recovery evidence.";
        }
        return NO;
    }
    if (rename(temporaryPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        int renameError = errno;
        CCNMUnlinkIfPresent(temporaryPath, NULL, NULL);
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not atomically hand off the recovery marker: %s", strerror(renameError ?: EIO)];
        }
        return NO;
    }
    if (!CCNMSyncParentDirectory(path, failure)) {
        return NO;
    }
    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:replacementRecord]) {
        if (failure) {
            *failure = @"The new recovery marker failed post-rename verification; preserving it for recovery.";
        }
        return NO;
    }
    return YES;
}

static NSDictionary *CCNMBuildRestoreMarkerRecord(NSString *sourceOperation,
                                                 NSDictionary *snapshot,
                                                 NSUInteger operationGeneration,
                                                 NSString **failure) {
    if (operationGeneration == 0) {
        if (failure) {
            *failure = @"A recovery setter requires a nonzero operation generation.";
        }
        return nil;
    }
    NSString *bootSession = CCNMBootSessionIdentity();
    NSNumber *bootSeconds = CCNMBootTimeSeconds();
    if (!bootSession || !bootSeconds) {
        if (failure) {
            *failure = @"The current boot session identity could not be read, so no recovery write was attempted.";
        }
        return nil;
    }
    NSString *uuid = CCNMCanonicalUUIDString(snapshot[@"subscriptionUUID"]);
    NSNumber *snapshotCreatedAt = [snapshot[@"createdAt"] isKindOfClass:[NSNumber class]] ? snapshot[@"createdAt"] : nil;
    if (!uuid || !snapshotCreatedAt) {
        if (failure) {
            *failure = @"The recovery snapshot is missing its subscription identity.";
        }
        return nil;
    }
    return @{
        @"schemaVersion": @1,
        @"state": @"restore_setter_in_flight",
        @"operation": sourceOperation ?: @"unknown",
        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
        @"processID": @(getpid()),
        @"bootSessionUUID": bootSession,
        @"bootTimeSeconds": bootSeconds,
        @"operationGeneration": @(operationGeneration),
        @"slotID": @1,
        @"subscriptionUUID": uuid,
        @"snapshotCreatedAt": snapshotCreatedAt
    };
}

static BOOL CCNMValidateSetterInFlightRecord(NSDictionary *record,
                                             NSDictionary *snapshot,
                                             NSDictionary *writeIntent,
                                             NSString **failure) {
    NSString *intentOperation = [writeIntent[@"operation"] isKindOfClass:[NSString class]] ? writeIntent[@"operation"] : nil;
    NSString *expectedOperation = nil;
    if ([intentOperation isEqualToString:@"same_value_write_intent"]) {
        expectedOperation = @"same_value_write";
    } else if ([intentOperation isEqualToString:@"cold_band_removal_intent"]) {
        expectedOperation = @"cold_band_removal";
    } else if ([intentOperation isEqualToString:@"nr78_only_intent"]) {
        expectedOperation = @"nr78_only";
    }
    BOOL valid = CCNMValidateSetterInFlightMarkerHeader(record, failure) &&
                 expectedOperation &&
                 [record[@"operation"] isEqual:expectedOperation] &&
                 [CCNMCanonicalUUIDString(record[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(snapshot[@"subscriptionUUID"])] &&
                 [record[@"snapshotCreatedAt"] isEqual:snapshot[@"createdAt"]] &&
                 [record[@"writeIntentCreatedAt"] isEqual:writeIntent[@"createdAt"]] &&
                 [record[@"operationGeneration"] isEqual:writeIntent[@"operationGeneration"]];
    if (!valid && failure) {
        *failure = @"The setter-in-flight record does not match the recovery snapshot and write intent.";
    }
    return valid;
}

static BOOL CCNMValidateRestoreInFlightRecord(NSDictionary *record,
                                              NSDictionary *snapshot,
                                              NSString **failure) {
    NSString *headerFailure = nil;
    BOOL valid = CCNMValidateRestoreInFlightMarkerHeader(record, &headerFailure) &&
                 [snapshot isKindOfClass:[NSDictionary class]] &&
                 [CCNMCanonicalUUIDString(record[@"subscriptionUUID"]) isEqualToString:CCNMCanonicalUUIDString(snapshot[@"subscriptionUUID"])] &&
                 [record[@"snapshotCreatedAt"] isEqual:snapshot[@"createdAt"]];
    if (!valid && failure) {
        *failure = headerFailure ?: @"The restore-in-flight record does not match the recovery snapshot.";
    }
    return valid;
}

static int CCNMAcquireRecoveryFileLock(BOOL nonBlocking, NSString **failure) {
    int fileDescriptor = open(CCNMBandRecoveryLockPath().fileSystemRepresentation,
                              O_RDWR | O_CREAT,
                              S_IRUSR | S_IWUSR);
    if (fileDescriptor < 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not open the Band recovery lock: %s", strerror(errno)];
        }
        return -1;
    }

    int operation = LOCK_EX | (nonBlocking ? LOCK_NB : 0);
    while (flock(fileDescriptor, operation) != 0) {
        if (errno == EINTR) {
            continue;
        }
        if (failure) {
            *failure = (errno == EWOULDBLOCK || errno == EAGAIN)
                ? @"Another Preferences process still owns the Band setter/recovery lock."
                : [NSString stringWithFormat:@"Could not acquire the Band recovery lock: %s", strerror(errno)];
        }
        close(fileDescriptor);
        return -1;
    }
    return fileDescriptor;
}

static void CCNMReleaseRecoveryFileLock(int fileDescriptor) {
    if (fileDescriptor < 0) {
        return;
    }
    flock(fileDescriptor, LOCK_UN);
    close(fileDescriptor);
}

static BOOL CCNMRemoveSetterInFlightRecord(NSDictionary *expectedRecord, NSString **failure) {
    NSDictionary *liveRecord = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSetterInFlightPath()];
    if (![liveRecord isEqualToDictionary:expectedRecord]) {
        if (failure) {
            *failure = @"The setter-in-flight record changed unexpectedly; preserving it for recovery.";
        }
        return NO;
    }
    BOOL removed = NO;
    return CCNMUnlinkIfPresent(CCNMBandSetterInFlightPath(), &removed, failure) && removed;
}

static BOOL CCNMRemoveRestoreInFlightRecord(NSDictionary *expectedRecord, NSString **failure) {
    NSDictionary *liveRecord = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
    if (![liveRecord isEqualToDictionary:expectedRecord]) {
        if (failure) {
            *failure = @"The restore-in-flight record changed unexpectedly; preserving it for recovery.";
        }
        return NO;
    }
    BOOL removed = NO;
    return CCNMUnlinkIfPresent(CCNMBandRestoreInFlightPath(), &removed, failure) && removed;
}

static const char *CCNMSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL CCNMValidateSetterABI(id<CCNMCoreTelephonyClient> client, NSString **failure) {
    SEL selector = @selector(setActiveBandInfo:bands:error:);
    if (![client respondsToSelector:selector]) {
        if (failure) {
            *failure = @"CoreTelephonyClient does not expose setActiveBandInfo:bands:error:.";
        }
        return NO;
    }

    NSMethodSignature *signature = [(id)client methodSignatureForSelector:selector];
    if (!signature) {
        if (failure) {
            *failure = @"The runtime setter has no Objective-C method signature.";
        }
        return NO;
    }
    const char *returnType = CCNMSkipTypeQualifiers(signature.methodReturnType);
    const char *contextType = signature.numberOfArguments > 2 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    const char *bandsType = signature.numberOfArguments > 3 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:3]) : NULL;
    const char *errorType = signature.numberOfArguments > 4 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:4]) : NULL;
    BOOL valid = signature.numberOfArguments == 5 &&
                 returnType && strcmp(returnType, @encode(void)) == 0 &&
                 contextType && contextType[0] == '@' &&
                 bandsType && bandsType[0] == '@' &&
                 errorType && errorType[0] == '^' && errorType[1] == '@';
    if (!valid && failure) {
        *failure = @"The runtime setter ABI does not match void(context, CTBandInfo, NSError **).";
    }
    return valid;
}

static id<CCNMCoreTelephonyClient> CCNMCreateCoreTelephonyClient(NSString **failure) {
    static void *coreTelephonyHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
    });

    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (!coreTelephonyHandle || !clientClass) {
        if (failure) {
            *failure = @"CoreTelephonyClient is unavailable on this system.";
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
            *failure = [NSString stringWithFormat:@"CoreTelephonyClient initialization raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    if (![client respondsToSelector:@selector(getSubscriptionInfoWithError:)] ||
        ![client respondsToSelector:@selector(getBandInfo:error:)]) {
        if (failure) {
            *failure = @"The required iOS 15 band-query selectors are unavailable.";
        }
        return nil;
    }

    return client;
}

static id<CCNMSubscriptionContext> CCNMSafeSlotOneContext(id<CCNMCoreTelephonyClient> client,
                                                           NSMutableDictionary *result,
                                                           NSString *requiredUUID,
                                                           NSString **failure) {
    @try {
    NSError *subscriptionError = nil;
    id<CCNMSubscriptionInfo> subscriptionInfo = nil;
    @try {
        subscriptionInfo = [client getSubscriptionInfoWithError:&subscriptionError];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Subscription query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    NSArray *subscriptions = [subscriptionInfo respondsToSelector:@selector(subscriptions)] ? [subscriptionInfo subscriptions] : nil;
    if (subscriptionError || subscriptions.count == 0) {
        if (failure) {
            *failure = subscriptionError.localizedDescription ?: @"No cellular subscription context was returned.";
        }
        return nil;
    }

    NSMutableArray *contextReports = [NSMutableArray array];
    id<CCNMSubscriptionContext> targetContext = nil;
    NSUInteger presentContextCount = 0;
    for (id<CCNMSubscriptionContext> context in subscriptions) {
        BOOL hasSlot = [context respondsToSelector:@selector(slotID)];
        BOOL hasPresent = [context respondsToSelector:@selector(isSimPresent)];
        BOOL hasGood = [context respondsToSelector:@selector(isSimGood)];
        long long slotID = hasSlot ? [context slotID] : -1;
        BOOL isPresent = hasPresent && [context isSimPresent];
        BOOL isGood = hasGood && [context isSimGood];
        id rawUUID = [context respondsToSelector:@selector(uuid)] ? [context uuid] : nil;
        NSUUID *uuid = [rawUUID isKindOfClass:[NSUUID class]] ? rawUUID : nil;
        [contextReports addObject:@{
            @"slotID": @(slotID),
            @"isSimPresent": @(isPresent),
            @"isSimGood": @(isGood),
            @"uuid": uuid.UUIDString ?: @""
        }];

        if (isPresent) {
            presentContextCount++;
        }
        if (slotID == 1 && isPresent && isGood && uuid.UUIDString.length > 0) {
            targetContext = context;
        }
    }
    result[@"contexts"] = contextReports;

    if (presentContextCount != 1 || !targetContext) {
        if (failure) {
            *failure = @"Safety check failed: this probe requires exactly one present/good SIM with a stable UUID in slot 1.";
        }
        return nil;
    }

    id targetRawUUID = [targetContext respondsToSelector:@selector(uuid)] ? [targetContext uuid] : nil;
    NSUUID *targetUUIDObject = [targetRawUUID isKindOfClass:[NSUUID class]] ? targetRawUUID : nil;
    NSString *targetUUID = targetUUIDObject.UUIDString;
    NSString *canonicalRequiredUUID = requiredUUID.length > 0 ? CCNMCanonicalUUIDString(requiredUUID) : nil;
    if (targetUUID.length == 0 ||
        (requiredUUID.length > 0 &&
         (!canonicalRequiredUUID || ![canonicalRequiredUUID isEqualToString:targetUUID]))) {
        if (failure) {
            *failure = @"Safety check failed: the slot-1 subscription UUID changed after the snapshot was created.";
        }
        return nil;
    }
    result[@"targetSubscriptionUUID"] = targetUUID;
    return targetContext;
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Slot-1 context validation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
}

static NSDictionary *CCNMWaitForExpectedBandReadBack(id<CCNMCoreTelephonyClient> client,
                                                       id<CCNMSubscriptionContext> context,
                                                       NSDictionary *expectedBands,
                                                       NSMutableDictionary *telemetry,
                                                       NSString **failure) {
    if (!client || !context || !CCNMValidateBandDictionary(expectedBands, failure)) {
        if (failure && !*failure) {
            *failure = @"Read-back polling inputs are incomplete.";
        }
        return nil;
    }

    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    NSDictionary *lastBands = nil;
    NSString *lastReadError = nil;
    NSString *lastReadException = nil;
    BOOL matched = NO;
    NSUInteger attempts = 0;

    for (NSUInteger attempt = 1; attempt <= CCNMBandReadBackMaximumAttempts; attempt++) {
        attempts = attempt;
        NSError *readError = nil;
        id<CCNMBandInfo> readInfo = nil;
        @try {
            readInfo = [client getBandInfo:context error:&readError];
        } @catch (NSException *exception) {
            lastReadException = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }

        NSDictionary *readBands = [readInfo respondsToSelector:@selector(activeBands)] ? [readInfo activeBands] : nil;
        if (readError) {
            lastReadError = readError.localizedDescription ?: @"Band read-back failed.";
        } else if (readBands && CCNMValidateBandDictionary(readBands, NULL)) {
            NSString *copyFailure = nil;
            NSDictionary *copiedBands = CCNMDeepCopyDictionary(readBands, &copyFailure);
            if (copiedBands) {
                lastBands = copiedBands;
                lastReadError = nil;
                lastReadException = nil;
                if (CCNMDictionariesEqual(expectedBands, copiedBands)) {
                    matched = YES;
                    break;
                }
            } else {
                lastReadError = copyFailure ?: @"Band read-back could not be copied.";
            }
        } else if (!readError) {
            lastReadError = @"Band read-back returned an invalid active-band dictionary.";
        }

        if (attempt < CCNMBandReadBackMaximumAttempts) {
            usleep(CCNMBandReadBackPollIntervalMicroseconds);
        }
    }

    NSTimeInterval finishedMonotonic = CCNMMonotonicNow();
    NSTimeInterval elapsed = startedMonotonic > 0 && finishedMonotonic >= startedMonotonic
        ? finishedMonotonic - startedMonotonic
        : 0;
    if (telemetry) {
        telemetry[@"readBackPollAttempts"] = @(attempts);
        telemetry[@"readBackPollElapsedMilliseconds"] = @((long long)(elapsed * 1000.0));
        telemetry[@"readBackExpectedObserved"] = @(matched);
        telemetry[@"readBackTimedOut"] = @(!matched);
        telemetry[@"readBackError"] = lastReadError ?: @"";
        telemetry[@"readBackException"] = lastReadException ?: @"";
        if (lastBands) {
            telemetry[@"readBackActiveBands"] = lastBands;
        }
    }
    if (!matched && !lastBands && failure) {
        *failure = lastReadException ?: lastReadError ?: @"No valid Band read-back was returned.";
    }
    return lastBands;
}

static BOOL CCNMWaitForObservationInterval(NSTimeInterval seconds,
                                            NSMutableDictionary *phase,
                                            NSString **failure) {
    NSTimeInterval started = CCNMMonotonicNow();
    if (seconds <= 0 || started <= 0) {
        if (failure) {
            *failure = @"The monotonic observation timer could not be started.";
        }
        return NO;
    }

    phase[@"startedAt"] = @([[NSDate date] timeIntervalSince1970]);
    while (YES) {
        NSTimeInterval now = CCNMMonotonicNow();
        if (now <= 0 || now < started) {
            if (failure) {
                *failure = @"The monotonic observation timer became invalid.";
            }
            return NO;
        }
        NSTimeInterval elapsed = now - started;
        if (elapsed >= seconds) {
            phase[@"elapsedSeconds"] = @(elapsed);
            phase[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
            return YES;
        }

        NSTimeInterval remaining = seconds - elapsed;
        useconds_t sleepMicroseconds = (useconds_t)(MIN(remaining, 1.0) * 1000000.0);
        usleep(MAX(sleepMicroseconds, (useconds_t)1));
    }
}

static BOOL CCNMMarkRestoreSetterCallStarted(NSUInteger operationGeneration,
                                               NSUInteger *restoreAttemptToken) {
    NSTimeInterval startedMonotonic = CCNMMonotonicNow();
    @synchronized([CCNMRootListController class]) {
        if (startedMonotonic <= 0 ||
            operationGeneration == 0 ||
            CCNMSetterTimeoutUncertain ||
            CCNMRestoreSetterCallStarted ||
            (!CCNMRecoveryOperationInProgress && !CCNMManualRestoreInProgress)) {
            return NO;
        }
        CCNMRestoreSetterAttemptSerial++;
        if (CCNMRestoreSetterAttemptSerial == 0) {
            CCNMRestoreSetterAttemptSerial++;
        }
        CCNMActiveRestoreSetterAttemptToken = CCNMRestoreSetterAttemptSerial;
        CCNMRestoreSetterStartedMonotonic = startedMonotonic;
        CCNMRestoreSetterCallStarted = YES;
        CCNMRestoreSetterGeneration = operationGeneration;
        if (restoreAttemptToken) {
            *restoreAttemptToken = CCNMActiveRestoreSetterAttemptToken;
        }
        return YES;
    }
}

static BOOL CCNMMarkRestoreTimeoutUncertain(NSUInteger operationGeneration,
                                             NSUInteger restoreAttemptToken) {
    NSTimeInterval observedMonotonic = CCNMMonotonicNow();
    @synchronized([CCNMRootListController class]) {
        BOOL deadlineReached = CCNMRestoreSetterStartedMonotonic <= 0 ||
                               observedMonotonic <= 0 ||
                               observedMonotonic - CCNMRestoreSetterStartedMonotonic >= CCNMSameValueWriteWatchdogSeconds;
        if (!deadlineReached ||
            !CCNMRestoreSetterCallStarted ||
            CCNMRestoreSetterGeneration != operationGeneration ||
            CCNMActiveRestoreSetterAttemptToken != restoreAttemptToken ||
            restoreAttemptToken == 0) {
            return NO;
        }
        CCNMSetterTimeoutUncertain = YES;
        return YES;
    }
}

static BOOL CCNMFinishRestoreSetterOperation(NSUInteger operationGeneration,
                                              NSUInteger restoreAttemptToken,
                                              BOOL setterReturnedNormally,
                                              NSTimeInterval finishedMonotonic,
                                              BOOL *deadlineExceeded) {
    @synchronized([CCNMRootListController class]) {
        BOOL callMatches = CCNMRestoreSetterCallStarted &&
                           CCNMRestoreSetterGeneration == operationGeneration &&
                           CCNMActiveRestoreSetterAttemptToken == restoreAttemptToken &&
                           restoreAttemptToken > 0;
        NSTimeInterval elapsed = callMatches &&
                                 CCNMRestoreSetterStartedMonotonic > 0 &&
                                 finishedMonotonic >= CCNMRestoreSetterStartedMonotonic
            ? finishedMonotonic - CCNMRestoreSetterStartedMonotonic
            : 0;
        BOOL invalidClock = callMatches &&
                            (CCNMRestoreSetterStartedMonotonic <= 0 ||
                             finishedMonotonic <= 0 ||
                             finishedMonotonic < CCNMRestoreSetterStartedMonotonic);
        BOOL exceededDeadline = callMatches &&
                                (invalidClock || elapsed >= CCNMSameValueWriteWatchdogSeconds);
        if (deadlineExceeded) {
            *deadlineExceeded = exceededDeadline;
        }
        if (!callMatches || !setterReturnedNormally || exceededDeadline) {
            CCNMSetterTimeoutUncertain = YES;
        }
        BOOL uncertain = CCNMSetterTimeoutUncertain;
        if (callMatches) {
            CCNMRestoreSetterCallStarted = NO;
            CCNMRestoreSetterGeneration = 0;
            CCNMActiveRestoreSetterAttemptToken = 0;
            CCNMRestoreSetterStartedMonotonic = 0;
        }
        return uncertain;
    }
}

static void CCNMWriteSetterTimeoutResult(NSUInteger operationGeneration, NSString *sourceOperation);
static void CCNMArmRestoreTimeoutWatchdog(NSUInteger operationGeneration,
                                          NSUInteger restoreAttemptToken);

static BOOL CCNMRestoreActiveBands(id<CCNMCoreTelephonyClient> client,
                                   id<CCNMSubscriptionContext> context,
                                   NSDictionary *snapshot,
                                   NSDictionary *snapshotBands,
                                   NSDictionary *restoreMarkerRecord,
                                   NSDictionary *returnedSetterRecord,
                                   NSUInteger operationGeneration,
                                   NSMutableDictionary *phase,
                                   NSString **failure) {
    NSUInteger restoreAttemptToken = 0;
    BOOL restoreSetterStarted = NO;
    BOOL restoreSetterFinished = NO;
    @try {
    phase[@"setterAttempted"] = @NO;
    if (!client || !context ||
        !CCNMValidateSnapshot(snapshot, NULL, failure) ||
        !CCNMValidateBandDictionary(snapshotBands, failure) ||
        !CCNMDictionariesEqual(snapshot[@"activeBands"], snapshotBands)) {
        if (failure && !*failure) {
            *failure = @"Restore inputs are incomplete or do not match the saved snapshot.";
        }
        return NO;
    }
    if (![restoreMarkerRecord isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"No durable restore marker was prepared, so the restore setter was not called.";
        }
        return NO;
    }
    NSString *restoreMarkerValidationFailure = nil;
    if (!CCNMValidateRestoreInFlightRecord(restoreMarkerRecord, snapshot, &restoreMarkerValidationFailure)) {
        if (failure) {
            *failure = restoreMarkerValidationFailure ?: @"The prepared restore marker is invalid, so the restore setter was not called.";
        }
        return NO;
    }

    Class bandInfoClass = NSClassFromString(@"CTBandInfo");
    if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
        if (failure) {
            *failure = @"CTBandInfo initWithActiveBands: is unavailable.";
        }
        return NO;
    }

    id<CCNMBandInfo> restoreInfo = nil;
    @try {
        restoreInfo = [[(id)bandInfoClass alloc] initWithActiveBands:[snapshotBands mutableCopy]];
    } @catch (NSException *exception) {
        phase[@"constructorException"] = exception.reason ?: exception.name;
        if (failure) {
            *failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
    NSDictionary *payloadBands = [restoreInfo respondsToSelector:@selector(activeBands)] ? [restoreInfo activeBands] : nil;
    BOOL payloadEqual = CCNMDictionariesEqual(snapshotBands, payloadBands);
    phase[@"payloadEqualBeforeWrite"] = @(payloadEqual);
    if (!payloadEqual) {
        if (failure) {
            *failure = @"CTBandInfo changed the snapshot before the restore write.";
        }
        return NO;
    }

    NSError *restoreError = nil;
    // A recovery setter can hang exactly like a test setter. Record it durably and
    // bind it to this boot session first, so a hung restore cannot be mistaken for
    // a finished one after the process is killed and relaunched.
    //
    // An automatic restore is recovering from a test setter that already returned in
    // this process, so its own marker must not block it. That exemption is allowed
    // only while the in-process state proves the call returned without a timeout.
    NSDictionary *exemptSetterRecord = nil;
    if ([returnedSetterRecord isKindOfClass:[NSDictionary class]]) {
        if (!CCNMTestSetterProvablyReturned(operationGeneration)) {
            if (failure) {
                *failure = @"The test setter has not provably returned, so no recovery write was authorized.";
            }
            return NO;
        }
        exemptSetterRecord = returnedSetterRecord;
        phase[@"exemptedOwnSetterMarker"] = @YES;
    }
    NSString *outstandingDetail = nil;
    if (CCNMCurrentBootSetterMayBeOutstanding(exemptSetterRecord, &outstandingDetail)) {
        if (failure) {
            *failure = outstandingDetail ?: @"A setter from this boot session may still be outstanding. Reboot the device first.";
        }
        return NO;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()]) {
        // The outstanding-setter gate established that this marker is from an
        // earlier boot. Validate it against the full snapshot, then atomically
        // replace it with this boot's restore marker without an unmarked gap.
        NSDictionary *staleRestoreMarker = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
        NSString *staleValidationFailure = nil;
        if (!staleRestoreMarker ||
            !CCNMValidateRestoreInFlightRecord(staleRestoreMarker, snapshot, &staleValidationFailure) ||
            CCNMMarkerBootRelation(staleRestoreMarker) != CCNMBootRelationEarlierBoot) {
            if (failure) {
                *failure = staleValidationFailure ?: @"The previous restore marker is not a valid earlier-boot marker; recovery evidence was preserved.";
            }
            return NO;
        }
        if (!CCNMReplaceDurablePlistExact(staleRestoreMarker, restoreMarkerRecord,
                                          CCNMBandRestoreInFlightPath(), failure)) {
            return NO;
        }
        phase[@"previousBootRestoreMarkerReplaced"] = @YES;
    } else if (!CCNMCreateDurablePlistExclusively(restoreMarkerRecord, CCNMBandRestoreInFlightPath(), failure)) {
        if (failure && !*failure) {
            *failure = @"The restore-in-flight marker could not be created, so the restore setter was not called.";
        }
        return NO;
    }
    phase[@"restoreInFlightSaved"] = @YES;
    if (!CCNMMarkRestoreSetterCallStarted(operationGeneration, &restoreAttemptToken)) {
        if (failure) {
            *failure = @"An uncertain setter state invalidated the restore before the call.";
        }
        return NO;
    }
    restoreSetterStarted = YES;
    phase[@"setterAttempted"] = @YES;
    CCNMArmRestoreTimeoutWatchdog(operationGeneration, restoreAttemptToken);

    BOOL setterReturnedNormally = NO;
    NSException *setterException = nil;
    @try {
        [client setActiveBandInfo:context bands:restoreInfo error:&restoreError];
        setterReturnedNormally = YES;
    } @catch (NSException *exception) {
        setterException = exception;
        phase[@"setterException"] = exception.reason ?: exception.name;
    }
    BOOL restoreDeadlineExceeded = NO;
    BOOL restoreStateUncertain = CCNMFinishRestoreSetterOperation(operationGeneration,
                                                                   restoreAttemptToken,
                                                                   setterReturnedNormally,
                                                                   CCNMMonotonicNow(),
                                                                   &restoreDeadlineExceeded);
    restoreSetterFinished = YES;
    phase[@"restoreStateUncertain"] = @(restoreStateUncertain);
    phase[@"restoreDeadlineExceeded"] = @(restoreDeadlineExceeded);
    if (restoreDeadlineExceeded) {
        CCNMWriteSetterTimeoutResult(operationGeneration, @"restore_setter_finish");
    }
    if (restoreStateUncertain) {
        if (failure) {
            *failure = setterException
                ? [NSString stringWithFormat:@"Restore setter raised %@; the exception left its server-side outcome uncertain. Reboot the device, then run the saved-snapshot restore again.", setterException.name]
                : @"The restore setter exceeded 20 seconds. Its outcome is uncertain. Reboot the device, then run the saved-snapshot restore again.";
        }
        return NO;
    }
    phase[@"setterError"] = restoreError.localizedDescription ?: @"";
    if (restoreError) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Restore setter failed: %@", restoreError.localizedDescription];
        }
        return NO;
    }

    NSString *readBackFailure = nil;
    NSDictionary *restoredBands = CCNMWaitForExpectedBandReadBack(client,
                                                                   context,
                                                                   snapshotBands,
                                                                   phase,
                                                                   &readBackFailure);
    BOOL equal = CCNMDictionariesEqual(snapshotBands, restoredBands);
    phase[@"readBackEqual"] = @(equal);
    if (!equal) {
        if (failure) {
            *failure = readBackFailure ?: @"Restore read-back did not match the saved snapshot within two minutes.";
        }
        return NO;
    }

    // Only a verified restore may retire its own exact marker.
    NSString *markerRemovalFailure = nil;
    BOOL markerRemoved = CCNMRemoveRestoreInFlightRecord(restoreMarkerRecord, &markerRemovalFailure);
    phase[@"restoreInFlightRemoved"] = @(markerRemoved);
    if (!markerRemoved) {
        if (failure) {
            *failure = markerRemovalFailure ?: @"The restore-in-flight marker could not be cleared after a verified restore.";
        }
        return NO;
    }

    return YES;
    } @catch (NSException *exception) {
        if (restoreSetterStarted && !restoreSetterFinished) {
            CCNMFinishRestoreSetterOperation(operationGeneration,
                                             restoreAttemptToken,
                                             NO,
                                             CCNMMonotonicNow(),
                                             NULL);
            phase[@"restoreStateUncertain"] = @YES;
            if (failure) {
                *failure = [NSString stringWithFormat:@"Band restore raised %@ after the setter was armed; its server-side outcome is uncertain. Reboot the device, then run the saved-snapshot restore again.", exception.name];
            }
        } else {
            phase[@"unexpectedException"] = exception.reason ?: exception.name;
            if (failure) {
                *failure = [NSString stringWithFormat:@"Band restore raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
        }
        return NO;
    }
}

static void CCNMWriteSetterTimeoutResult(NSUInteger operationGeneration, NSString *sourceOperation) {
    NSDictionary *timeoutResult = @{
        @"schemaVersion": @1,
        @"operation": @"setter_timeout",
        @"sourceOperation": sourceOperation ?: @"unknown",
        @"operationGeneration": @(operationGeneration),
        @"triggeredAt": @([[NSDate date] timeIntervalSince1970]),
        @"bootTimeSeconds": CCNMBootTimeSeconds() ?: @0,
        @"setterStateUncertain": @YES,
        @"automaticRestoreAttempted": @NO,
        @"requiresDeviceReboot": @YES,
        @"error": @"The setter exceeded 20 seconds. No concurrent restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then run the saved-snapshot restore."
    };
    [timeoutResult writeToFile:CCNMBandWatchdogResultPath() atomically:YES];
}

static void CCNMArmSetterTimeoutWatchdog(NSUInteger operationGeneration, NSString *sourceOperation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCNMSameValueWriteWatchdogSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (CCNMMarkSetterTimeoutUncertain(operationGeneration)) {
            CCNMWriteSetterTimeoutResult(operationGeneration, sourceOperation);
        }
    });
}

// The recovery setter is synchronous too, so it gets the same treatment: observe
// the hang, latch uncertainty, report it, and never issue a second write.
static void CCNMArmRestoreTimeoutWatchdog(NSUInteger operationGeneration,
                                          NSUInteger restoreAttemptToken) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCNMSameValueWriteWatchdogSeconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (CCNMMarkRestoreTimeoutUncertain(operationGeneration, restoreAttemptToken)) {
            CCNMWriteSetterTimeoutResult(operationGeneration, @"restore_setter");
        }
    });
}

@implementation CCNMRootListController
- (void)showHelpAlert:(PSSpecifier *)specifier {
    // Usually 2g/3g GSM are enough. Enable their CDMA counterparts only if your carrier is Sprint or Verizon or if you don't get any signal when forcing 2G/3G
    NSString* explanation = @"You can enable every network you want to switch between in the control center.\n"
        "\n"
        "About the different variations\n (GSM/CDMA/NR...):\n"
        "It all depends on your country/carrier. \n"
        "For 2G/3G usually you should be using GSM, but some carriers (Sprint, Verizon) are using CDMA.\n"
        "For 5G, I unfortunately couldn't do extensive testing, so it's up to you to try out which works. Personally I'm using the 5G NR Non StandAlone.\n"
        "\n"
        "Of course, you can use any number of module you want. Eg only LTE (which will switch between LTE & auto), or LTE+5G NSA (my personal setup), or any other combination you want.";

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"What do I need to enable?" message:explanation preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *dismissAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
    }];
    
    [alertController addAction:dismissAction];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showBandProbe:(PSSpecifier *)specifier {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static void *coreTelephonyHandle = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            coreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
        });

        NSMutableArray *reports = [NSMutableArray array];
        NSString *failure = nil;
        Class clientClass = NSClassFromString(@"CoreTelephonyClient");
        SEL subscriptionsSelector = @selector(getSubscriptionInfoWithError:);
        SEL bandInfoSelector = @selector(getBandInfo:error:);

        @try {
        if (!coreTelephonyHandle || !clientClass) {
            failure = @"CoreTelephonyClient is unavailable on this system.";
        } else {
            id<CCNMCoreTelephonyClient> client = [(id)clientClass alloc];
            if (![client respondsToSelector:@selector(initWithQueue:)]) {
                failure = @"CoreTelephonyClient does not expose initWithQueue:.";
            } else {
                @try {
                    client = [client initWithQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)];
                } @catch (NSException *exception) {
                    failure = [NSString stringWithFormat:@"CoreTelephonyClient initialization raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                if (!failure && (![client respondsToSelector:subscriptionsSelector] || ![client respondsToSelector:bandInfoSelector])) {
                    failure = @"The required iOS 15 band-query selectors are unavailable.";
                }
                if (!failure) {
                    NSError *subscriptionError = nil;
                    id<CCNMSubscriptionInfo> subscriptionInfo = nil;
                    @try {
                        subscriptionInfo = [client getSubscriptionInfoWithError:&subscriptionError];
                    } @catch (NSException *exception) {
                        failure = [NSString stringWithFormat:@"Subscription query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                    }
                    NSArray *subscriptions = [subscriptionInfo respondsToSelector:@selector(subscriptions)] ? [subscriptionInfo subscriptions] : nil;

                    if (!failure && (subscriptionError || subscriptions.count == 0)) {
                        failure = subscriptionError.localizedDescription ?: @"No cellular subscription context was returned.";
                    }
                    if (!failure) {
                        [subscriptions enumerateObjectsUsingBlock:^(id<CCNMSubscriptionContext> context, NSUInteger index, BOOL *stop) {
                            NSError *bandError = nil;
                            id<CCNMBandInfo> bandInfo = nil;
                            NSString *bandExceptionMessage = nil;
                            @try {
                                bandInfo = [client getBandInfo:context error:&bandError];
                            } @catch (NSException *exception) {
                                bandExceptionMessage = [NSString stringWithFormat:@"Band query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                            }
                            NSMutableDictionary *report = [NSMutableDictionary dictionary];
                            long long slotID = [context respondsToSelector:@selector(slotID)] ? [context slotID] : (long long)index + 1;
                            report[@"slotID"] = @(slotID);
                            if ([context respondsToSelector:@selector(isSimPresent)]) {
                                report[@"isSimPresent"] = @([context isSimPresent]);
                            }
                            if ([context respondsToSelector:@selector(isSimGood)]) {
                                report[@"isSimGood"] = @([context isSimGood]);
                            }

                            if (bandExceptionMessage || bandError || !bandInfo) {
                                report[@"error"] = bandExceptionMessage ?: bandError.localizedDescription ?: @"No CTBandInfo object was returned.";
                            } else {
                                NSDictionary *activeBands = [bandInfo respondsToSelector:@selector(activeBands)] ? [bandInfo activeBands] : nil;
                                NSDictionary *supportedBands = [bandInfo respondsToSelector:@selector(supportedBands)] ? [bandInfo supportedBands] : nil;
                                report[@"activeBands"] = activeBands ?: @{};
                                report[@"supportedBands"] = supportedBands ?: @{};
                            }

                            [reports addObject:report];
                        }];
                    }
                }
            }
        }
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"Band query operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }

        NSDictionary *probeResult = @{
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"subscriptions": reports,
            @"error": failure ?: @""
        };
        [probeResult writeToFile:CCNMBandProbePath() atomically:YES];
        NSString *message = failure ?: CCNMReadableObject(reports);

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }

            NSString *title = failure ? @"Band probe failed" : @"Band probe result";
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
            if (!failure) {
                [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [UIPasteboard generalPasteboard].string = message;
                }]];
            }
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)confirmSameValueBandWrite:(PSSpecifier *)specifier {
    BOOL snapshotExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()];
    BOOL intentExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()];
    BOOL setterInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
    BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
    if (snapshotExists || intentExists || setterInFlightExists || restoreInFlightExists) {
        UIAlertController *existingSnapshotAlert = [UIAlertController alertControllerWithTitle:@"Saved probe state already exists"
            message:@"This build never overwrites recovery records. Restore the saved snapshot first, then use Clear Saved Probe State."
            preferredStyle:UIAlertControllerStyleAlert];
        [existingSnapshotAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existingSnapshotAlert animated:YES completion:nil];
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Run same-value Band write?"
        message:@"This sends one real CoreTelephony Band write to slot 1, but the payload is the exact active-band dictionary just read from the device. A full snapshot is saved first, then the value is verified and restored. Cellular service may briefly re-register. Do not run this while the phone is your only emergency-communication device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Run Test" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self runSameValueBandWrite];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)confirmRestoreBandSnapshot:(PSSpecifier *)specifier {
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
    NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
    NSDictionary *inFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSetterInFlightPath()];
    BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
    NSDictionary *restoreInFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
    NSString *snapshotFailure = nil;
    NSString *intentFailure = nil;
    NSString *inFlightFailure = nil;
    NSString *restoreInFlightFailure = nil;
    BOOL validSnapshot = CCNMValidateSnapshot(snapshot, NULL, &snapshotFailure);
    BOOL validIntent = validSnapshot && CCNMValidateWriteIntent(writeIntent, snapshot, &intentFailure);
    BOOL validInFlight = inFlight && validIntent && CCNMValidateSetterInFlightRecord(inFlight, snapshot, writeIntent, &inFlightFailure);
    BOOL validRestoreInFlight = !restoreInFlightExists ||
                                (restoreInFlight && validSnapshot && CCNMValidateRestoreInFlightRecord(restoreInFlight, snapshot, &restoreInFlightFailure));
    NSString *outstandingDetail = nil;
    BOOL outstanding = CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail);
    BOOL restoreAllowed = validIntent && validInFlight && validRestoreInFlight && !outstanding;
    NSString *message = nil;
    if (outstanding) {
        message = outstandingDetail ?: @"A setter from this boot session may still be outstanding. Reboot the device before restoring the saved snapshot.";
    } else if (restoreAllowed) {
        message = @"The matching setter-in-flight marker is from an earlier boot session. Restore slot 1 to the complete saved snapshot and verify exact read-back?";
    } else if (!inFlight) {
        message = @"No setter-in-flight marker exists, so there is no crash or timeout recovery write to perform. If live bands already match the snapshot, use Clear Saved Probe State.";
    } else {
        message = snapshotFailure ?: intentFailure ?: inFlightFailure ?: restoreInFlightFailure ?: @"The saved recovery records do not match. Restore is disabled.";
    }
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Restore saved Band snapshot" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (restoreAllowed) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self restoreSavedBandSnapshot];
        }]];
    }
    [self presentViewController:alertController animated:YES completion:nil];
}
- (void)confirmColdBandRemovalWrite:(PSSpecifier *)specifier {
    BOOL snapshotExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()];
    BOOL intentExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()];
    BOOL setterInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
    BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
    if (snapshotExists || intentExists || setterInFlightExists || restoreInFlightExists) {
        UIAlertController *existingSnapshotAlert = [UIAlertController alertControllerWithTitle:@"Saved probe state already exists"
            message:@"This build never overwrites recovery records. Restore the saved snapshot first, then use Clear Saved Probe State."
            preferredStyle:UIAlertControllerStyleAlert];
        [existingSnapshotAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existingSnapshotAlert animated:YES completion:nil];
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Remove one cold LTE band?"
        message:@"This is the first write that actually changes modem configuration. It removes exactly one cold LTE band (48 CBRS, else 46 LAA) from slot 1, reads the result back, then restores the full original set. Every other radio technology stays byte-identical.\n\nThis build does not read the serving band, so it cannot promise service stays up. You may temporarily lose cellular service. If the automatic restore does not verify, reboot the device, reopen Preferences, then run Restore Saved Band Snapshot. Do not run this while the phone is your only emergency-communication device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Run Experiment" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self runColdBandRemovalWrite];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)confirmNR78BandWrite:(PSSpecifier *)specifier {
    BOOL snapshotExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()];
    BOOL intentExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()];
    BOOL setterInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
    BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
    if (snapshotExists || intentExists || setterInFlightExists || restoreInFlightExists) {
        UIAlertController *existingSnapshotAlert = [UIAlertController alertControllerWithTitle:@"Saved probe state already exists"
            message:@"This build never overwrites recovery records. Restore the saved snapshot first, then use Clear Saved Probe State."
            preferredStyle:UIAlertControllerStyleAlert];
        [existingSnapshotAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existingSnapshotAlert animated:YES completion:nil];
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Temporarily allow only NR band n78?"
        message:@"This changes slot 1's NR allowed-band array to exactly [78] for 60 seconds. LTE, GSM, UTRAN, and every other RAT array remain byte-identical, so an NSA LTE anchor remains allowed. The phone may fall back to LTE or temporarily lose cellular service if n78 is unavailable. Keep Preferences open until the original complete Band snapshot is restored and verified. If automatic restore does not verify, reboot, reopen Preferences, then run Restore Saved Band Snapshot. Do not run this while the phone is your only emergency-communication device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Run 60-Second Experiment" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self runNR78BandWrite];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)confirmClearProbeState:(PSSpecifier *)specifier {
    BOOL snapshotExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()];
    BOOL intentExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()];
    BOOL setterInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
    BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
    if (!snapshotExists && !intentExists && !setterInFlightExists && !restoreInFlightExists) {
        UIAlertController *emptyAlert = [UIAlertController alertControllerWithTitle:@"No saved probe state" message:@"There is no recovery snapshot or write-intent record to clear." preferredStyle:UIAlertControllerStyleAlert];
        [emptyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:emptyAlert animated:YES completion:nil];
        return;
    }

    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
    NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
    NSDictionary *inFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSetterInFlightPath()];
    NSDictionary *restoreInFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
    NSString *validationFailure = nil;
    BOOL clearAllowed = CCNMValidateSnapshot(snapshot, NULL, &validationFailure) &&
                        CCNMValidateWriteIntent(writeIntent, snapshot, &validationFailure);
    if (clearAllowed && setterInFlightExists) {
        clearAllowed = inFlight && CCNMValidateSetterInFlightRecord(inFlight, snapshot, writeIntent, &validationFailure);
    }
    if (clearAllowed && restoreInFlightExists) {
        clearAllowed = restoreInFlight && CCNMValidateRestoreInFlightRecord(restoreInFlight, snapshot, &validationFailure);
    }
    NSString *outstandingDetail = nil;
    if (clearAllowed && CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)) {
        clearAllowed = NO;
        validationFailure = outstandingDetail ?: @"A setter from this boot session may still be outstanding. Reboot the device before clearing recovery evidence.";
    }

    NSString *message = clearAllowed
        ? @"This deletes the recovery snapshot, write-intent record, and verified prior-boot setter markers. It is refused unless live slot-1 active bands already match the snapshot exactly."
        : validationFailure ?: @"The saved recovery records are incomplete or invalid, so they cannot be cleared here.";
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Clear saved probe state?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (clearAllowed) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self clearSavedProbeState];
        }]];
    }
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)clearSavedProbeState {
    NSUInteger operationGeneration = 0;
    NSUInteger manualRecoveryGeneration = 0;
    if (!CCNMBeginBandOperation(&operationGeneration, &manualRecoveryGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Band operation already running" message:@"Wait for the current query, write, or restore operation to finish." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"clear_probe_state",
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"liveMatchedSnapshot": @NO,
            @"snapshotRemoved": @NO,
            @"writeIntentRemoved": @NO,
            @"restoreInFlightRemoved": @NO,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        int recoveryLockDescriptor = -1;
        @try {
        recoveryLockDescriptor = CCNMAcquireRecoveryFileLock(YES, &failure);
        NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
        NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
        BOOL inFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
        BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
        NSDictionary *inFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSetterInFlightPath()];
        NSDictionary *restoreInFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
        NSDictionary *snapshotBands = nil;
        if (!failure) {
            CCNMValidateSnapshot(snapshot, &snapshotBands, &failure);
        }
        if (!failure) {
            CCNMValidateWriteIntent(writeIntent, snapshot, &failure);
        }
        if (!failure && inFlightExists && !inFlight) {
            failure = @"The setter-in-flight record exists but is unreadable. Recovery evidence was preserved.";
        }
        if (!failure && inFlight) {
            CCNMValidateSetterInFlightRecord(inFlight, snapshot, writeIntent, &failure);
        }
        if (!failure && restoreInFlightExists && !restoreInFlight) {
            failure = @"The restore-in-flight record exists but is unreadable. Recovery evidence was preserved.";
        }
        if (!failure && restoreInFlight) {
            CCNMValidateRestoreInFlightRecord(restoreInFlight, snapshot, &failure);
        }
        if (!failure) {
            NSString *outstandingDetail = nil;
            if (CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)) {
                result[@"deviceRebootRequiredForInFlight"] = @YES;
                failure = outstandingDetail ?: @"A setter from this boot session may still be outstanding. Reboot the device before clearing recovery evidence.";
            }
        }

        id<CCNMCoreTelephonyClient> client = nil;
        id<CCNMSubscriptionContext> context = nil;
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            client = CCNMCreateCoreTelephonyClient(&failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSError *readError = nil;
            id<CCNMBandInfo> liveInfo = nil;
            @try {
                liveInfo = [client getBandInfo:context error:&readError];
            } @catch (NSException *exception) {
                result[@"readException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Live Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *liveBands = [liveInfo respondsToSelector:@selector(activeBands)] ? [liveInfo activeBands] : nil;
            result[@"readError"] = readError.localizedDescription ?: @"";
            BOOL matched = !readError && CCNMDictionariesEqual(snapshotBands, liveBands);
            result[@"liveMatchedSnapshot"] = @(matched);
            if (liveBands) {
                result[@"liveDifferenceFromSnapshot"] = CCNMBandDictionaryDifference(snapshotBands, liveBands);
            }
            if (!matched && !failure) {
                failure = readError.localizedDescription ?: @"The live active bands do not match the saved snapshot, so the recovery records are still needed. Restore first.";
            }
        }
        if (!failure) {
            BOOL snapshotRemoved = NO;
            BOOL intentRemoved = NO;
            BOOL restoreMarkerRemoved = !restoreInFlightExists;
            BOOL markerRemoved = !inFlightExists;
            NSString *snapshotRemovalFailure = nil;
            NSString *intentRemovalFailure = nil;
            NSString *restoreMarkerRemovalFailure = nil;
            NSString *markerRemovalFailure = nil;

            // Remove payload and intent before either marker. If cleanup stops, a
            // remaining marker still blocks a new write and preserves the evidence.
            CCNMUnlinkIfPresent(CCNMBandSnapshotPath(), &snapshotRemoved, &snapshotRemovalFailure);
            if (snapshotRemoved) {
                CCNMUnlinkIfPresent(CCNMBandWriteIntentPath(), &intentRemoved, &intentRemovalFailure);
            }
            if (snapshotRemoved && intentRemoved && restoreInFlight) {
                restoreMarkerRemoved = CCNMRemoveRestoreInFlightRecord(restoreInFlight, &restoreMarkerRemovalFailure);
            }
            if (snapshotRemoved && intentRemoved && restoreMarkerRemoved && inFlight) {
                markerRemoved = CCNMRemoveSetterInFlightRecord(inFlight, &markerRemovalFailure);
            }
            result[@"snapshotRemoved"] = @(snapshotRemoved);
            result[@"writeIntentRemoved"] = @(intentRemoved);
            result[@"restoreInFlightRemoved"] = @(restoreMarkerRemoved);
            result[@"setterInFlightRemoved"] = @(markerRemoved);
            if (snapshotRemovalFailure || intentRemovalFailure || restoreMarkerRemovalFailure || markerRemovalFailure ||
                !snapshotRemoved || !intentRemoved || !restoreMarkerRemoved || !markerRemoved) {
                failure = snapshotRemovalFailure ?: intentRemovalFailure ?: restoreMarkerRemovalFailure ?: markerRemovalFailure ?: @"The probe state files could not be fully removed.";
            }
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Clear probe state raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            CCNMReleaseRecoveryFileLock(recoveryLockDescriptor);
            CCNMEndBandOperation();
        }

        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        [result writeToFile:CCNMBandClearStateResultPath() atomically:YES];
        NSString *message = failure ?: @"The recovery snapshot, write-intent record, and verified recovery markers were removed. A new experiment can run.";
        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:failure ? @"Probe state not cleared" : @"Probe state cleared" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)runSameValueBandWrite {
    NSUInteger operationGeneration = 0;
    NSUInteger manualRecoveryGeneration = 0;
    if (!CCNMBeginBandOperation(&operationGeneration, &manualRecoveryGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Band operation already running" message:@"Wait for the current query, write, or restore operation to finish." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"same_value_write",
            @"operationGeneration": @(operationGeneration),
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"snapshotSaved": @NO,
            @"writeIntentSaved": @NO,
            @"setterInFlightSaved": @NO,
            @"setterAttempted": @NO,
            @"setterStateUncertain": @NO,
            @"writeReadBackEqual": @NO,
            @"restoreAttempted": @NO,
            @"restoreReadBackEqual": @NO,
            @"watchdogArmed": @NO,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        BOOL setterWasInvoked = NO;
        BOOL setterStateUncertain = NO;
        int recoveryLockDescriptor = -1;
        NSDictionary *setterInFlightRecord = nil;
        BOOL markerWasCreated = NO;
        BOOL automaticRestoreVerified = NO;
        @try {
        recoveryLockDescriptor = CCNMAcquireRecoveryFileLock(YES, &failure);
        result[@"recoveryLockAcquired"] = @(recoveryLockDescriptor >= 0);
        id<CCNMCoreTelephonyClient> client = nil;
        if (!failure) {
            client = CCNMCreateCoreTelephonyClient(&failure);
        }
        if (client) {
            CCNMValidateSetterABI(client, &failure);
        }

        id<CCNMSubscriptionContext> context = nil;
        NSDictionary *originalBands = nil;
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, nil, &failure);
        }
        if (!failure) {
            NSError *readError = nil;
            id<CCNMBandInfo> originalInfo = nil;
            @try {
                originalInfo = [client getBandInfo:context error:&readError];
            } @catch (NSException *exception) {
                result[@"initialReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Initial Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *readBands = [originalInfo respondsToSelector:@selector(activeBands)] ? [originalInfo activeBands] : nil;
            if (!failure) {
                originalBands = CCNMDeepCopyDictionary(readBands, &failure);
            }
            result[@"initialReadError"] = readError.localizedDescription ?: @"";
            if (!failure && (readError || !originalBands || !CCNMValidateBandDictionary(originalBands, &failure))) {
                failure = readError.localizedDescription ?: failure ?: @"The original active-band dictionary is invalid.";
            }
        }

        if (!failure && ([[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()])) {
            failure = @"Saved Band probe state already exists. Refusing to overwrite recovery records.";
        }

        NSDictionary *snapshot = nil;
        if (!failure) {
            snapshot = @{
                @"schemaVersion": @1,
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"slotID": @1,
                @"subscriptionUUID": result[@"targetSubscriptionUUID"],
                @"activeBands": originalBands
            };
            if (!CCNMCreateDurablePlistExclusively(snapshot, CCNMBandSnapshotPath(), &failure)) {
                result[@"snapshotSaved"] = @NO;
            } else {
                result[@"snapshotSaved"] = @YES;
                result[@"snapshotPath"] = CCNMBandSnapshotPath();
                result[@"originalActiveBands"] = originalBands;
            }
        }

        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSError *preWriteReadError = nil;
            id<CCNMBandInfo> preWriteInfo = nil;
            @try {
                preWriteInfo = [client getBandInfo:context error:&preWriteReadError];
            } @catch (NSException *exception) {
                result[@"preWriteReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Pre-write read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *preWriteBands = [preWriteInfo respondsToSelector:@selector(activeBands)] ? [preWriteInfo activeBands] : nil;
            BOOL preWriteEqual = !preWriteReadError && CCNMDictionariesEqual(originalBands, preWriteBands);
            result[@"preWriteReadError"] = preWriteReadError.localizedDescription ?: @"";
            result[@"preWriteActiveBandsEqual"] = @(preWriteEqual);
            if (!preWriteEqual && !failure) {
                failure = preWriteReadError.localizedDescription ?: @"The live active-band dictionary changed after the snapshot; setter was not called.";
            }
        }

        id<CCNMBandInfo> sameValueInfo = nil;
        NSDictionary *writeIntent = nil;
        if (!failure) {
            Class bandInfoClass = NSClassFromString(@"CTBandInfo");
            if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
                failure = @"CTBandInfo initWithActiveBands: is unavailable.";
            } else {
                @try {
                    sameValueInfo = [[(id)bandInfoClass alloc] initWithActiveBands:[originalBands mutableCopy]];
                } @catch (NSException *exception) {
                    result[@"constructorException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                NSDictionary *payloadBands = [sameValueInfo respondsToSelector:@selector(activeBands)] ? [sameValueInfo activeBands] : nil;
                BOOL payloadEqual = CCNMDictionariesEqual(originalBands, payloadBands);
                result[@"payloadEqualBeforeWrite"] = @(payloadEqual);
                if (!payloadEqual && !failure) {
                    failure = @"CTBandInfo changed the original dictionary before the write; setter was not called.";
                }
            }
        }

        if (!failure) {
            writeIntent = @{
                @"schemaVersion": @1,
                @"operation": @"same_value_write_intent",
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"operationGeneration": @(operationGeneration),
                @"slotID": @1,
                @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                @"snapshotCreatedAt": snapshot[@"createdAt"],
                @"snapshotActiveBands": snapshot[@"activeBands"]
            };
            if (!CCNMValidateWriteIntent(writeIntent, snapshot, &failure) ||
                !CCNMCreateDurablePlistExclusively(writeIntent, CCNMBandWriteIntentPath(), &failure)) {
                result[@"writeIntentSaved"] = @NO;
            } else {
                result[@"writeIntentSaved"] = @YES;
                result[@"writeIntentPath"] = CCNMBandWriteIntentPath();
            }
        }

        if (!failure) {
            NSString *outstandingDetail = nil;
            if (CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)) {
                failure = outstandingDetail ?: @"An outstanding setter cannot be ruled out, so the test setter was not called.";
            }
        }
        if (!failure) {
            CCNMBeginTestSetterOperation(operationGeneration, manualRecoveryGeneration, &failure);
        }
        if (!failure && recoveryLockDescriptor >= 0) {
            setterInFlightRecord = @{
                @"schemaVersion": @1,
                @"state": @"setter_in_flight",
                @"operation": @"same_value_write",
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"processID": @(getpid()),
                @"bootSessionUUID": CCNMBootSessionIdentity() ?: @"",
                @"bootTimeSeconds": CCNMBootTimeSeconds() ?: @0,
                @"operationGeneration": @(operationGeneration),
                @"slotID": @1,
                @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                @"snapshotCreatedAt": snapshot[@"createdAt"],
                @"writeIntentCreatedAt": writeIntent[@"createdAt"]
            };
            if (![setterInFlightRecord[@"bootSessionUUID"] length] ||
                ![setterInFlightRecord[@"bootTimeSeconds"] longLongValue] ||
                !CCNMCreateDurablePlistExclusively(setterInFlightRecord, CCNMBandSetterInFlightPath(), &failure)) {
                if (!failure) {
                    failure = @"The current boot identity could not be read; setter was not called.";
                }
                result[@"setterInFlightSaved"] = @NO;
                CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
            } else {
                markerWasCreated = YES;
                result[@"setterInFlightSaved"] = @YES;
                result[@"setterInFlightPath"] = CCNMBandSetterInFlightPath();
            }
        }

        if (!failure && recoveryLockDescriptor >= 0) {
            if (!CCNMMarkTestSetterCallStarted(operationGeneration)) {
                failure = @"The setter operation was invalidated immediately before the call.";
                CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
            } else {
                result[@"watchdogArmed"] = @YES;
                result[@"watchdogDelaySeconds"] = @(CCNMSameValueWriteWatchdogSeconds);
                CCNMArmSetterTimeoutWatchdog(operationGeneration, @"same_value_write");
                result[@"setterAttempted"] = @YES;
                result[@"setterStartedAt"] = @([[NSDate date] timeIntervalSince1970]);
                setterWasInvoked = YES;
                NSError *setterError = nil;
                BOOL setterReturnedNormally = NO;
                NSException *setterException = nil;
                @try {
                    [client setActiveBandInfo:context bands:sameValueInfo error:&setterError];
                    setterReturnedNormally = YES;
                } @catch (NSException *exception) {
                    setterException = exception;
                    result[@"setterException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"Same-value setter raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                BOOL setterDeadlineExceeded = NO;
                setterStateUncertain = CCNMFinishTestSetterOperation(operationGeneration,
                                                                       setterReturnedNormally,
                                                                       CCNMMonotonicNow(),
                                                                       &setterDeadlineExceeded);
                result[@"setterDeadlineExceeded"] = @(setterDeadlineExceeded);
                result[@"setterFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
                result[@"setterError"] = setterError.localizedDescription ?: @"";
                result[@"setterStateUncertain"] = @(setterStateUncertain);
                if (setterStateUncertain) {
                    failure = setterException
                        ? [NSString stringWithFormat:@"Same-value setter raised %@; the exception left its server-side outcome uncertain. Reboot the device, then run the saved-snapshot restore again.", setterException.name]
                        : @"The setter exceeded 20 seconds. Its outcome is uncertain; no restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then run the saved-snapshot restore.";
                } else if (setterError) {
                    failure = [NSString stringWithFormat:@"Same-value setter failed: %@", setterError.localizedDescription];
                }

            }
        }

        if (setterWasInvoked && markerWasCreated && !setterStateUncertain) {
            NSMutableDictionary *readBackPhase = [NSMutableDictionary dictionary];
            NSString *readBackFailure = nil;
            NSDictionary *readBackBands = CCNMWaitForExpectedBandReadBack(client,
                                                                           context,
                                                                           originalBands,
                                                                           readBackPhase,
                                                                           &readBackFailure);
            BOOL equal = CCNMDictionariesEqual(originalBands, readBackBands);
            result[@"writeReadBackEqual"] = @(equal);
            result[@"writeReadBackPhase"] = readBackPhase;
            if (readBackBands) {
                result[@"writeReadBackActiveBands"] = readBackBands;
            }
            if (!equal && !failure) {
                failure = readBackFailure ?: @"Same-value write read-back differed from the original snapshot for two minutes.";
            }

            if (CCNMBeginAutomaticRestoreOperation(operationGeneration)) {
                NSMutableDictionary *restorePhase = nil;
                NSString *restoreFailure = nil;
                BOOL restored = NO;
                @try {
                    restorePhase = [NSMutableDictionary dictionary];
                    if (recoveryLockDescriptor >= 0) {
                        id<CCNMSubscriptionContext> restoreContext = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &restoreFailure);
                        NSDictionary *restoreMarker = nil;
                        if (!restoreFailure) {
                            restoreMarker = CCNMBuildRestoreMarkerRecord(@"same_value_automatic_restore", snapshot, operationGeneration, &restoreFailure);
                        }
                        if (!restoreFailure) {
                            result[@"restoreAttempted"] = @YES;
                            restored = CCNMRestoreActiveBands(client, restoreContext, snapshot, originalBands, restoreMarker, setterInFlightRecord, operationGeneration, restorePhase, &restoreFailure);
                        }
                    } else {
                        restoreFailure = @"The automatic restore lost exclusive recovery ownership.";
                    }
                } @finally {
                    CCNMEndRecoveryOperation();
                }
                automaticRestoreVerified = restored;
                result[@"restoreReadBackEqual"] = @(restored);
                result[@"restorePhase"] = restorePhase;
                result[@"restoreError"] = restoreFailure ?: @"";
                if (restoreFailure && !failure) {
                    failure = restoreFailure;
                }
            } else if (!failure) {
                failure = @"The automatic restore could not obtain exclusive recovery ownership.";
            }

            if (automaticRestoreVerified) {
                NSString *markerRemovalFailure = nil;
                BOOL markerRemoved = CCNMRemoveSetterInFlightRecord(setterInFlightRecord, &markerRemovalFailure);
                result[@"setterInFlightRemoved"] = @(markerRemoved);
                result[@"setterInFlightPreserved"] = @(!markerRemoved);
                if (!markerRemoved && !failure) {
                    failure = markerRemovalFailure ?: @"Could not clear the setter-in-flight record after verified automatic recovery.";
                }
            } else {
                result[@"setterInFlightRemoved"] = @NO;
                result[@"setterInFlightPreserved"] = @YES;
                if (!failure) {
                    failure = @"The automatic restore was not verified, so the setter-in-flight record and recovery files were preserved.";
                }
            }
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Band operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            if (recoveryLockDescriptor >= 0) {
                CCNMReleaseRecoveryFileLock(recoveryLockDescriptor);
            }
            CCNMEndBandOperation();
        }

        BOOL requiredPhasesCompleted = [result[@"setterAttempted"] boolValue] &&
                                       ![result[@"setterStateUncertain"] boolValue] &&
                                       [result[@"writeReadBackEqual"] boolValue] &&
                                       [result[@"restoreAttempted"] boolValue] &&
                                       [result[@"restoreReadBackEqual"] boolValue];
        BOOL recoveryPending = [result[@"setterAttempted"] boolValue] &&
                               !([result[@"restoreAttempted"] boolValue] && [result[@"restoreReadBackEqual"] boolValue]);
        result[@"recoveryPending"] = @(recoveryPending);
        if (!failure && !requiredPhasesCompleted) {
            failure = @"The probe did not complete every required write, read-back, and restore phase.";
        }
        if (recoveryPending) {
            failure = [NSString stringWithFormat:@"%@\n\nThe write was issued and the original set was not verified as restored. Reboot the device, reopen Preferences, then run Restore Saved Band Snapshot. Recovery records were preserved.", failure ?: @"Recovery was not verified."];
        }
        result[@"passed"] = @(!failure && requiredPhasesCompleted);
        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        BOOL resultSaved = [result writeToFile:CCNMBandWriteResultPath() atomically:YES];
        BOOL passed = resultSaved && !failure && requiredPhasesCompleted;
        NSString *message = nil;
        if (!resultSaved) {
            message = @"The test finished, but its result plist could not be saved.";
        } else if ([result[@"setterStateUncertain"] boolValue]) {
            message = [NSString stringWithFormat:@"SETTER STATE UNCERTAIN\nNo concurrent restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then use Restore Saved Band Snapshot.\n\nSnapshot: %@\nResult: %@", CCNMBandSnapshotPath(), CCNMBandWriteResultPath()];
        } else if (!passed) {
            message = [NSString stringWithFormat:@"FAILED\n%@\n\nSnapshot: %@\nResult: %@", failure ?: @"Required phases did not all complete.", CCNMBandSnapshotPath(), CCNMBandWriteResultPath()];
        } else {
            message = [NSString stringWithFormat:@"PASSED\nSetter returned no error. Same-value read-back matched, and the final snapshot restore matched.\n\nResult: %@", CCNMBandWriteResultPath()];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:passed ? @"Band write probe passed" : @"Band write probe failed" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)runColdBandRemovalWrite {
    NSUInteger operationGeneration = 0;
    NSUInteger manualRecoveryGeneration = 0;
    if (!CCNMBeginBandOperation(&operationGeneration, &manualRecoveryGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Band operation already running" message:@"Wait for the current query, write, or restore operation to finish." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"cold_band_removal",
            @"operationGeneration": @(operationGeneration),
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"removalRATKey": CCNMRemovalRATKey,
            @"snapshotSaved": @NO,
            @"writeIntentSaved": @NO,
            @"setterInFlightSaved": @NO,
            @"setterAttempted": @NO,
            @"setterStateUncertain": @NO,
            @"readBackMatchedRequest": @NO,
            @"readBackMatchedOriginal": @NO,
            @"effectApplied": @NO,
            @"restoreAttempted": @NO,
            @"restoreReadBackEqual": @NO,
            @"watchdogArmed": @NO,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        int recoveryLockDescriptor = -1;
        @try {
        recoveryLockDescriptor = CCNMAcquireRecoveryFileLock(YES, &failure);
        result[@"recoveryLockAcquired"] = @(recoveryLockDescriptor >= 0);
        id<CCNMCoreTelephonyClient> client = nil;
        if (!failure) {
            client = CCNMCreateCoreTelephonyClient(&failure);
        }
        if (client) {
            CCNMValidateSetterABI(client, &failure);
        }

        id<CCNMSubscriptionContext> context = nil;
        NSDictionary *originalBands = nil;
        NSDictionary *supportedBands = nil;
        NSDictionary *removalBands = nil;
        NSNumber *removedBand = nil;
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, nil, &failure);
        }

        if (!failure) {
            NSError *readError = nil;
            id<CCNMBandInfo> originalInfo = nil;
            @try {
                originalInfo = [client getBandInfo:context error:&readError];
            } @catch (NSException *exception) {
                result[@"initialReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Initial Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *readBands = [originalInfo respondsToSelector:@selector(activeBands)] ? [originalInfo activeBands] : nil;
            NSDictionary *readSupportedBands = [originalInfo respondsToSelector:@selector(supportedBands)] ? [originalInfo supportedBands] : nil;
            if (!failure) {
                originalBands = CCNMDeepCopyDictionary(readBands, &failure);
            }
            if (!failure) {
                supportedBands = CCNMDeepCopyDictionary(readSupportedBands, &failure);
            }
            result[@"initialReadError"] = readError.localizedDescription ?: @"";
            if (!failure && (readError ||
                             !originalBands || !CCNMValidateBandDictionary(originalBands, &failure) ||
                             !supportedBands || !CCNMValidateBandDictionary(supportedBands, &failure))) {
                failure = readError.localizedDescription ?: failure ?: @"The original active/supported band dictionaries are invalid.";
            }
        }

        if (!failure) {
            removalBands = CCNMBuildSingleRemovalBands(originalBands, supportedBands, &removedBand, &failure);
            if (removalBands && removedBand) {
                result[@"removedBand"] = removedBand;
                result[@"requestedActiveBands"] = removalBands;
                result[@"supportedBandsAtSelection"] = supportedBands;
            }
        }

        if (!failure && ([[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()])) {
            failure = @"Saved Band probe state already exists. Refusing to overwrite recovery records.";
        }

        __block NSDictionary *snapshot = nil;
        if (!failure) {
            snapshot = @{
                @"schemaVersion": @1,
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"slotID": @1,
                @"subscriptionUUID": result[@"targetSubscriptionUUID"],
                @"activeBands": originalBands,
                @"supportedBands": supportedBands
            };
            if (!CCNMCreateDurablePlistExclusively(snapshot, CCNMBandSnapshotPath(), &failure)) {
                result[@"snapshotSaved"] = @NO;
            } else {
                result[@"snapshotSaved"] = @YES;
                result[@"snapshotPath"] = CCNMBandSnapshotPath();
                result[@"originalActiveBands"] = originalBands;
            }
        }

        BOOL setterWasInvoked = NO;
        BOOL setterStateUncertain = NO;
        BOOL markerWasCreated = NO;
        BOOL automaticRestoreVerified = NO;
        NSDictionary *setterInFlightRecord = nil;
        NSDictionary *writeIntent = nil;
        id<CCNMBandInfo> removalInfo = nil;
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSError *preWriteReadError = nil;
            id<CCNMBandInfo> preWriteInfo = nil;
            @try {
                preWriteInfo = [client getBandInfo:context error:&preWriteReadError];
            } @catch (NSException *exception) {
                result[@"preWriteReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Pre-write read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *preWriteBands = [preWriteInfo respondsToSelector:@selector(activeBands)] ? [preWriteInfo activeBands] : nil;
            NSDictionary *preWriteSupportedBands = [preWriteInfo respondsToSelector:@selector(supportedBands)] ? [preWriteInfo supportedBands] : nil;
            BOOL preWriteActiveEqual = !preWriteReadError && CCNMDictionariesEqual(originalBands, preWriteBands);
            BOOL preWriteSupportedEqual = !preWriteReadError && CCNMDictionariesEqual(supportedBands, preWriteSupportedBands);
            result[@"preWriteReadError"] = preWriteReadError.localizedDescription ?: @"";
            result[@"preWriteActiveBandsEqual"] = @(preWriteActiveEqual);
            result[@"preWriteSupportedBandsEqual"] = @(preWriteSupportedEqual);
            if ((!preWriteActiveEqual || !preWriteSupportedEqual) && !failure) {
                failure = preWriteReadError.localizedDescription ?: @"The live active/supported band dictionaries changed after the snapshot; setter was not called.";
            }
        }
        if (!failure) {
            Class bandInfoClass = NSClassFromString(@"CTBandInfo");
            if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
                failure = @"CTBandInfo initWithActiveBands: is unavailable.";
            } else {
                @try {
                    removalInfo = [[(id)bandInfoClass alloc] initWithActiveBands:[removalBands mutableCopy]];
                } @catch (NSException *exception) {
                    result[@"constructorException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                NSDictionary *payloadBands = [removalInfo respondsToSelector:@selector(activeBands)] ? [removalInfo activeBands] : nil;
                BOOL payloadEqual = CCNMDictionariesEqual(removalBands, payloadBands) &&
                                    CCNMValidateSingleBandRemoval(originalBands, payloadBands, removedBand, &failure);
                result[@"payloadEqualBeforeWrite"] = @(payloadEqual);
                if (!payloadEqual && !failure) {
                    failure = @"CTBandInfo changed the removal payload before the write; setter was not called.";
                }

                if (!failure) {
                    writeIntent = @{
                        @"schemaVersion": @1,
                        @"operation": @"cold_band_removal_intent",
                        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                        @"operationGeneration": @(operationGeneration),
                        @"slotID": @1,
                        @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                        @"snapshotCreatedAt": snapshot[@"createdAt"],
                        @"snapshotActiveBands": snapshot[@"activeBands"],
                        @"snapshotSupportedBands": snapshot[@"supportedBands"],
                        @"removalRATKey": CCNMRemovalRATKey,
                        @"removedBand": removedBand,
                        @"requestedActiveBands": removalBands
                    };
                    if (!CCNMValidateWriteIntent(writeIntent, snapshot, &failure) ||
                        !CCNMCreateDurablePlistExclusively(writeIntent, CCNMBandWriteIntentPath(), &failure)) {
                        result[@"writeIntentSaved"] = @NO;
                    } else {
                        result[@"writeIntentSaved"] = @YES;
                        result[@"writeIntentPath"] = CCNMBandWriteIntentPath();
                    }
                }

                if (!failure) {
                    NSString *outstandingDetail = nil;
                    if (CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)) {
                        failure = outstandingDetail ?: @"An outstanding setter cannot be ruled out, so the test setter was not called.";
                    }
                }
                if (!failure) {
                    CCNMBeginTestSetterOperation(operationGeneration, manualRecoveryGeneration, &failure);
                }
                if (!failure && recoveryLockDescriptor >= 0) {
                    setterInFlightRecord = @{
                        @"schemaVersion": @1,
                        @"state": @"setter_in_flight",
                        @"operation": @"cold_band_removal",
                        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                        @"processID": @(getpid()),
                        @"bootSessionUUID": CCNMBootSessionIdentity() ?: @"",
                        @"bootTimeSeconds": CCNMBootTimeSeconds() ?: @0,
                        @"operationGeneration": @(operationGeneration),
                        @"slotID": @1,
                        @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                        @"snapshotCreatedAt": snapshot[@"createdAt"],
                        @"writeIntentCreatedAt": writeIntent[@"createdAt"]
                    };
                    if (![setterInFlightRecord[@"bootSessionUUID"] length] ||
                        ![setterInFlightRecord[@"bootTimeSeconds"] longLongValue] ||
                        !CCNMCreateDurablePlistExclusively(setterInFlightRecord, CCNMBandSetterInFlightPath(), &failure)) {
                        if (!failure) {
                            failure = @"The current boot identity could not be read; setter was not called.";
                        }
                        result[@"setterInFlightSaved"] = @NO;
                        CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
                    } else {
                        markerWasCreated = YES;
                        result[@"setterInFlightSaved"] = @YES;
                        result[@"setterInFlightPath"] = CCNMBandSetterInFlightPath();
                    }
                }
                if (!failure && recoveryLockDescriptor >= 0) {
                    if (!CCNMMarkTestSetterCallStarted(operationGeneration)) {
                        failure = @"The setter operation was invalidated immediately before the call.";
                        CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
                    } else {
                        result[@"watchdogArmed"] = @YES;
                        result[@"watchdogDelaySeconds"] = @(CCNMSameValueWriteWatchdogSeconds);
                        CCNMArmSetterTimeoutWatchdog(operationGeneration, @"cold_band_removal");
                        result[@"setterAttempted"] = @YES;
                        result[@"setterStartedAt"] = @([[NSDate date] timeIntervalSince1970]);
                        setterWasInvoked = YES;
                        NSError *setterError = nil;
                        BOOL setterReturnedNormally = NO;
                        NSException *setterException = nil;
                        @try {
                            [client setActiveBandInfo:context bands:removalInfo error:&setterError];
                            setterReturnedNormally = YES;
                        } @catch (NSException *exception) {
                            setterException = exception;
                            result[@"setterException"] = exception.reason ?: exception.name;
                            failure = [NSString stringWithFormat:@"Removal setter raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                        }
                        BOOL setterDeadlineExceeded = NO;
                        setterStateUncertain = CCNMFinishTestSetterOperation(operationGeneration,
                                                                               setterReturnedNormally,
                                                                               CCNMMonotonicNow(),
                                                                               &setterDeadlineExceeded);
                        result[@"setterDeadlineExceeded"] = @(setterDeadlineExceeded);
                        result[@"setterFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
                        result[@"setterError"] = setterError.localizedDescription ?: @"";
                        result[@"setterStateUncertain"] = @(setterStateUncertain);
                        if (setterStateUncertain) {
                            failure = setterException
                                ? [NSString stringWithFormat:@"Removal setter raised %@; the exception left its server-side outcome uncertain. Reboot the device, then run the saved-snapshot restore again.", setterException.name]
                                : @"The setter exceeded 20 seconds. Its outcome is uncertain; no restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then run the saved-snapshot restore.";
                        } else if (setterError) {
                            failure = [NSString stringWithFormat:@"Removal setter failed: %@", setterError.localizedDescription];
                        }
                    }
                }
            if (setterWasInvoked && markerWasCreated && !setterStateUncertain) {
                NSMutableDictionary *readBackPhase = [NSMutableDictionary dictionary];
                NSString *readBackFailure = nil;
                // The unchanged original dictionary is a known stale state immediately
                // after this setter. Wait for the changed request before deciding that
                // the write was ignored; the last valid value after the full window is
                // still retained for that decision.
                NSDictionary *readBackBands = CCNMWaitForExpectedBandReadBack(client,
                                                                               context,
                                                                               removalBands,
                                                                               readBackPhase,
                                                                               &readBackFailure);
                result[@"readBackPhase"] = readBackPhase;
                if (readBackBands) {
                    result[@"readBackActiveBands"] = readBackBands;
                    result[@"readBackDifferenceFromOriginal"] = CCNMBandDictionaryDifference(originalBands, readBackBands);
                    result[@"readBackDifferenceFromRequest"] = CCNMBandDictionaryDifference(removalBands, readBackBands);
                }
                BOOL matchedRequest = CCNMDictionariesEqual(removalBands, readBackBands);
                BOOL matchedOriginal = CCNMDictionariesEqual(originalBands, readBackBands);
                result[@"readBackMatchedRequest"] = @(matchedRequest);
                result[@"readBackMatchedOriginal"] = @(matchedOriginal);
                result[@"effectApplied"] = @(matchedRequest);
                if (!failure && !matchedRequest && !matchedOriginal) {
                    failure = readBackFailure ?: @"Read-back matched neither the requested removal nor the original snapshot within two minutes.";
                }

                if (CCNMBeginAutomaticRestoreOperation(operationGeneration)) {
                    NSMutableDictionary *restorePhase = nil;
                    NSString *restoreFailure = nil;
                    BOOL restored = NO;
                    @try {
                        restorePhase = [NSMutableDictionary dictionary];
                        if (recoveryLockDescriptor >= 0) {
                            id<CCNMSubscriptionContext> restoreContext = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &restoreFailure);
                            NSDictionary *restoreMarker = nil;
                            if (!restoreFailure) {
                                restoreMarker = CCNMBuildRestoreMarkerRecord(@"cold_band_removal_automatic_restore", snapshot, operationGeneration, &restoreFailure);
                            }
                            if (!restoreFailure) {
                                result[@"restoreAttempted"] = @YES;
                                restored = CCNMRestoreActiveBands(client, restoreContext, snapshot, originalBands, restoreMarker, setterInFlightRecord, operationGeneration, restorePhase, &restoreFailure);
                            }
                        } else {
                            restoreFailure = @"The automatic restore lost exclusive recovery ownership.";
                        }
                    } @finally {
                        CCNMEndRecoveryOperation();
                    }
                    automaticRestoreVerified = restored;
                    result[@"restoreReadBackEqual"] = @(restored);
                    result[@"restorePhase"] = restorePhase;
                    result[@"restoreError"] = restoreFailure ?: @"";
                    if (restoreFailure && !failure) {
                        failure = restoreFailure;
                    }
                } else if (!failure) {
                    failure = @"The automatic restore could not obtain exclusive recovery ownership.";
                }

                if (automaticRestoreVerified) {
                    NSString *markerRemovalFailure = nil;
                    BOOL markerRemoved = CCNMRemoveSetterInFlightRecord(setterInFlightRecord, &markerRemovalFailure);
                    result[@"setterInFlightRemoved"] = @(markerRemoved);
                    result[@"setterInFlightPreserved"] = @(!markerRemoved);
                    if (!markerRemoved && !failure) {
                        failure = markerRemovalFailure ?: @"Could not clear the setter-in-flight record after verified automatic recovery.";
                    }
                } else {
                    result[@"setterInFlightRemoved"] = @NO;
                    result[@"setterInFlightPreserved"] = @YES;
                    if (!failure) {
                        failure = @"The automatic restore was not verified, so the setter-in-flight record and recovery files were preserved.";
                    }
                }
            }
        }
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Band removal operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            if (recoveryLockDescriptor >= 0) {
                CCNMReleaseRecoveryFileLock(recoveryLockDescriptor);
            }
            CCNMEndBandOperation();
        }

        BOOL determinate = [result[@"setterAttempted"] boolValue] &&
                           ![result[@"setterStateUncertain"] boolValue] &&
                           ([result[@"readBackMatchedRequest"] boolValue] || [result[@"readBackMatchedOriginal"] boolValue]);
        BOOL recovered = [result[@"restoreAttempted"] boolValue] && [result[@"restoreReadBackEqual"] boolValue];
        // Any outcome where the write was issued but recovery is unverified must say
        // so first, because the modem may still be holding the modified set.
        BOOL recoveryPending = [result[@"setterAttempted"] boolValue] && !recovered;
        result[@"recoveryPending"] = @(recoveryPending);
        if (!failure && !(determinate && recovered)) {
            failure = @"The removal experiment did not complete every required write, read-back, and restore phase.";
        }
        if (recoveryPending) {
            failure = [NSString stringWithFormat:@"%@\n\nThe removal write was issued and the original set was not verified as restored. Reboot the device, reopen Preferences, then run Restore Saved Band Snapshot. Recovery records were preserved.", failure ?: @"Recovery was not verified."];
        }
        result[@"passed"] = @(!failure && determinate && recovered);
        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        BOOL resultSaved = [result writeToFile:CCNMBandRemovalResultPath() atomically:YES];
        BOOL passed = resultSaved && !failure && determinate && recovered;
        BOOL effectApplied = [result[@"effectApplied"] boolValue];
        NSString *message = nil;
        if (!resultSaved) {
            message = @"The experiment finished, but its result plist could not be saved.";
        } else if ([result[@"setterStateUncertain"] boolValue]) {
            message = [NSString stringWithFormat:@"SETTER STATE UNCERTAIN\nNo concurrent restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then use Restore Saved Band Snapshot.\n\nSnapshot: %@\nResult: %@", CCNMBandSnapshotPath(), CCNMBandRemovalResultPath()];
        } else if (!passed) {
            message = [NSString stringWithFormat:@"FAILED\n%@\n\nSnapshot: %@\nResult: %@", failure ?: @"Required phases did not all complete.", CCNMBandSnapshotPath(), CCNMBandRemovalResultPath()];
        } else if (effectApplied) {
            message = [NSString stringWithFormat:@"WRITE TOOK EFFECT\nLTE band %@ was removed, read back as removed, and the original set was restored and verified.\n\nResult: %@", result[@"removedBand"], CCNMBandRemovalResultPath()];
        } else {
            message = [NSString stringWithFormat:@"WRITE IGNORED\nThe setter returned no error, but the read-back still equals the original set, so LTE band %@ was not actually removed.\n\nResult: %@", result[@"removedBand"], CCNMBandRemovalResultPath()];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            NSString *title = passed ? (effectApplied ? @"Band removal took effect" : @"Band removal was ignored") : @"Band removal experiment failed";
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)runNR78BandWrite {
    NSUInteger operationGeneration = 0;
    NSUInteger manualRecoveryGeneration = 0;
    if (!CCNMBeginBandOperation(&operationGeneration, &manualRecoveryGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Band operation already running" message:@"Wait for the current query, write, or restore operation to finish." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"nr78_only",
            @"operationGeneration": @(operationGeneration),
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"targetRATKey": CCNMNRRATKey,
            @"targetBand": CCNMNR78Band(),
            @"observationSeconds": @(CCNMNR78ObservationSeconds),
            @"snapshotSaved": @NO,
            @"writeIntentSaved": @NO,
            @"setterInFlightSaved": @NO,
            @"setterAttempted": @NO,
            @"setterStateUncertain": @NO,
            @"readBackMatchedRequest": @NO,
            @"readBackMatchedOriginal": @NO,
            @"effectApplied": @NO,
            @"observationStarted": @NO,
            @"observationCompleted": @NO,
            @"observationEndMatchedRequest": @NO,
            @"restoreAttempted": @NO,
            @"restoreReadBackEqual": @NO,
            @"watchdogArmed": @NO,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        int recoveryLockDescriptor = -1;
        @try {
        recoveryLockDescriptor = CCNMAcquireRecoveryFileLock(YES, &failure);
        result[@"recoveryLockAcquired"] = @(recoveryLockDescriptor >= 0);
        id<CCNMCoreTelephonyClient> client = nil;
        if (!failure) {
            client = CCNMCreateCoreTelephonyClient(&failure);
        }
        if (client) {
            CCNMValidateSetterABI(client, &failure);
        }

        id<CCNMSubscriptionContext> context = nil;
        NSDictionary *originalBands = nil;
        NSDictionary *supportedBands = nil;
        NSDictionary *nr78Bands = nil;
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, nil, &failure);
        }

        if (!failure) {
            NSError *readError = nil;
            id<CCNMBandInfo> originalInfo = nil;
            @try {
                originalInfo = [client getBandInfo:context error:&readError];
            } @catch (NSException *exception) {
                result[@"initialReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Initial Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *readBands = [originalInfo respondsToSelector:@selector(activeBands)] ? [originalInfo activeBands] : nil;
            NSDictionary *readSupportedBands = [originalInfo respondsToSelector:@selector(supportedBands)] ? [originalInfo supportedBands] : nil;
            if (!failure) {
                originalBands = CCNMDeepCopyDictionary(readBands, &failure);
            }
            if (!failure) {
                supportedBands = CCNMDeepCopyDictionary(readSupportedBands, &failure);
            }
            result[@"initialReadError"] = readError.localizedDescription ?: @"";
            if (!failure && (readError ||
                             !originalBands || !CCNMValidateBandDictionary(originalBands, &failure) ||
                             !supportedBands || !CCNMValidateBandDictionary(supportedBands, &failure))) {
                failure = readError.localizedDescription ?: failure ?: @"The original active/supported band dictionaries are invalid.";
            }
        }

        if (!failure) {
            nr78Bands = CCNMBuildNR78OnlyBands(originalBands, supportedBands, &failure);
            if (nr78Bands) {
                result[@"requestedActiveBands"] = nr78Bands;
                result[@"supportedBandsAtSelection"] = supportedBands;
            }
        }

        if (!failure && ([[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()])) {
            failure = @"Saved Band probe state already exists. Refusing to overwrite recovery records.";
        }

        __block NSDictionary *snapshot = nil;
        if (!failure) {
            snapshot = @{
                @"schemaVersion": @1,
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"slotID": @1,
                @"subscriptionUUID": result[@"targetSubscriptionUUID"],
                @"activeBands": originalBands,
                @"supportedBands": supportedBands
            };
            if (!CCNMCreateDurablePlistExclusively(snapshot, CCNMBandSnapshotPath(), &failure)) {
                result[@"snapshotSaved"] = @NO;
            } else {
                result[@"snapshotSaved"] = @YES;
                result[@"snapshotPath"] = CCNMBandSnapshotPath();
                result[@"originalActiveBands"] = originalBands;
            }
        }

        BOOL setterWasInvoked = NO;
        BOOL setterStateUncertain = NO;
        BOOL markerWasCreated = NO;
        BOOL automaticRestoreVerified = NO;
        NSDictionary *setterInFlightRecord = nil;
        NSDictionary *writeIntent = nil;
        id<CCNMBandInfo> nr78Info = nil;
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSError *preWriteReadError = nil;
            id<CCNMBandInfo> preWriteInfo = nil;
            @try {
                preWriteInfo = [client getBandInfo:context error:&preWriteReadError];
            } @catch (NSException *exception) {
                result[@"preWriteReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Pre-write read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *preWriteBands = [preWriteInfo respondsToSelector:@selector(activeBands)] ? [preWriteInfo activeBands] : nil;
            NSDictionary *preWriteSupportedBands = [preWriteInfo respondsToSelector:@selector(supportedBands)] ? [preWriteInfo supportedBands] : nil;
            BOOL preWriteActiveEqual = !preWriteReadError && CCNMDictionariesEqual(originalBands, preWriteBands);
            BOOL preWriteSupportedEqual = !preWriteReadError && CCNMDictionariesEqual(supportedBands, preWriteSupportedBands);
            result[@"preWriteReadError"] = preWriteReadError.localizedDescription ?: @"";
            result[@"preWriteActiveBandsEqual"] = @(preWriteActiveEqual);
            result[@"preWriteSupportedBandsEqual"] = @(preWriteSupportedEqual);
            if ((!preWriteActiveEqual || !preWriteSupportedEqual) && !failure) {
                failure = preWriteReadError.localizedDescription ?: @"The live active/supported band dictionaries changed after the snapshot; setter was not called.";
            }
        }
        if (!failure) {
            Class bandInfoClass = NSClassFromString(@"CTBandInfo");
            if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
                failure = @"CTBandInfo initWithActiveBands: is unavailable.";
            } else {
                @try {
                    nr78Info = [[(id)bandInfoClass alloc] initWithActiveBands:[nr78Bands mutableCopy]];
                } @catch (NSException *exception) {
                    result[@"constructorException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                NSDictionary *payloadBands = [nr78Info respondsToSelector:@selector(activeBands)] ? [nr78Info activeBands] : nil;
                BOOL payloadEqual = CCNMDictionariesEqual(nr78Bands, payloadBands) &&
                                    CCNMValidateNR78OnlyBands(originalBands, payloadBands, &failure);
                result[@"payloadEqualBeforeWrite"] = @(payloadEqual);
                if (!payloadEqual && !failure) {
                    failure = @"CTBandInfo changed the n78-only payload before the write; setter was not called.";
                }

                if (!failure) {
                    writeIntent = @{
                        @"schemaVersion": @1,
                        @"operation": @"nr78_only_intent",
                        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                        @"operationGeneration": @(operationGeneration),
                        @"slotID": @1,
                        @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                        @"snapshotCreatedAt": snapshot[@"createdAt"],
                        @"snapshotActiveBands": snapshot[@"activeBands"],
                        @"snapshotSupportedBands": snapshot[@"supportedBands"],
                        @"targetRATKey": CCNMNRRATKey,
                        @"targetBand": CCNMNR78Band(),
                        @"observationSeconds": @(CCNMNR78ObservationSeconds),
                        @"requestedActiveBands": nr78Bands
                    };
                    if (!CCNMValidateWriteIntent(writeIntent, snapshot, &failure) ||
                        !CCNMCreateDurablePlistExclusively(writeIntent, CCNMBandWriteIntentPath(), &failure)) {
                        result[@"writeIntentSaved"] = @NO;
                    } else {
                        result[@"writeIntentSaved"] = @YES;
                        result[@"writeIntentPath"] = CCNMBandWriteIntentPath();
                    }
                }

                if (!failure) {
                    NSString *outstandingDetail = nil;
                    if (CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail)) {
                        failure = outstandingDetail ?: @"An outstanding setter cannot be ruled out, so the test setter was not called.";
                    }
                }
                if (!failure) {
                    CCNMBeginTestSetterOperation(operationGeneration, manualRecoveryGeneration, &failure);
                }
                if (!failure && recoveryLockDescriptor >= 0) {
                    setterInFlightRecord = @{
                        @"schemaVersion": @1,
                        @"state": @"setter_in_flight",
                        @"operation": @"nr78_only",
                        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                        @"processID": @(getpid()),
                        @"bootSessionUUID": CCNMBootSessionIdentity() ?: @"",
                        @"bootTimeSeconds": CCNMBootTimeSeconds() ?: @0,
                        @"operationGeneration": @(operationGeneration),
                        @"slotID": @1,
                        @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                        @"snapshotCreatedAt": snapshot[@"createdAt"],
                        @"writeIntentCreatedAt": writeIntent[@"createdAt"]
                    };
                    if (![setterInFlightRecord[@"bootSessionUUID"] length] ||
                        ![setterInFlightRecord[@"bootTimeSeconds"] longLongValue] ||
                        !CCNMCreateDurablePlistExclusively(setterInFlightRecord, CCNMBandSetterInFlightPath(), &failure)) {
                        if (!failure) {
                            failure = @"The current boot identity could not be read; setter was not called.";
                        }
                        result[@"setterInFlightSaved"] = @NO;
                        CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
                    } else {
                        markerWasCreated = YES;
                        result[@"setterInFlightSaved"] = @YES;
                        result[@"setterInFlightPath"] = CCNMBandSetterInFlightPath();
                    }
                }
                if (!failure && recoveryLockDescriptor >= 0) {
                    if (!CCNMMarkTestSetterCallStarted(operationGeneration)) {
                        failure = @"The setter operation was invalidated immediately before the call.";
                        CCNMFinishTestSetterOperation(operationGeneration, NO, CCNMMonotonicNow(), NULL);
                    } else {
                        result[@"watchdogArmed"] = @YES;
                        result[@"watchdogDelaySeconds"] = @(CCNMSameValueWriteWatchdogSeconds);
                        CCNMArmSetterTimeoutWatchdog(operationGeneration, @"nr78_only");
                        result[@"setterAttempted"] = @YES;
                        result[@"setterStartedAt"] = @([[NSDate date] timeIntervalSince1970]);
                        setterWasInvoked = YES;
                        NSError *setterError = nil;
                        BOOL setterReturnedNormally = NO;
                        NSException *setterException = nil;
                        @try {
                            [client setActiveBandInfo:context bands:nr78Info error:&setterError];
                            setterReturnedNormally = YES;
                        } @catch (NSException *exception) {
                            setterException = exception;
                            result[@"setterException"] = exception.reason ?: exception.name;
                            failure = [NSString stringWithFormat:@"n78-only setter raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                        }
                        BOOL setterDeadlineExceeded = NO;
                        setterStateUncertain = CCNMFinishTestSetterOperation(operationGeneration,
                                                                               setterReturnedNormally,
                                                                               CCNMMonotonicNow(),
                                                                               &setterDeadlineExceeded);
                        result[@"setterDeadlineExceeded"] = @(setterDeadlineExceeded);
                        result[@"setterFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
                        result[@"setterError"] = setterError.localizedDescription ?: @"";
                        result[@"setterStateUncertain"] = @(setterStateUncertain);
                        if (setterStateUncertain) {
                            failure = setterException
                                ? [NSString stringWithFormat:@"n78-only setter raised %@; the exception left its server-side outcome uncertain. Reboot the device, then run the saved-snapshot restore again.", setterException.name]
                                : @"The setter exceeded 20 seconds. Its outcome is uncertain; no restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then run the saved-snapshot restore.";
                        } else if (setterError) {
                            failure = [NSString stringWithFormat:@"n78-only setter failed: %@", setterError.localizedDescription];
                        }
                    }
                }
            if (setterWasInvoked && markerWasCreated && !setterStateUncertain) {
                NSMutableDictionary *readBackPhase = [NSMutableDictionary dictionary];
                NSString *readBackFailure = nil;
                NSDictionary *readBackBands = CCNMWaitForExpectedBandReadBack(client,
                                                                               context,
                                                                               nr78Bands,
                                                                               readBackPhase,
                                                                               &readBackFailure);
                result[@"readBackPhase"] = readBackPhase;
                if (readBackBands) {
                    result[@"readBackActiveBands"] = readBackBands;
                    result[@"readBackDifferenceFromOriginal"] = CCNMBandDictionaryDifference(originalBands, readBackBands);
                    result[@"readBackDifferenceFromRequest"] = CCNMBandDictionaryDifference(nr78Bands, readBackBands);
                }
                BOOL matchedRequest = CCNMDictionariesEqual(nr78Bands, readBackBands);
                BOOL matchedOriginal = CCNMDictionariesEqual(originalBands, readBackBands);
                result[@"readBackMatchedRequest"] = @(matchedRequest);
                result[@"readBackMatchedOriginal"] = @(matchedOriginal);
                result[@"effectApplied"] = @(matchedRequest);
                if (!failure && !matchedRequest && !matchedOriginal) {
                    failure = readBackFailure ?: @"Read-back matched neither the requested n78-only set nor the original snapshot within two minutes.";
                }

                if (matchedRequest) {
                    NSMutableDictionary *observationPhase = [NSMutableDictionary dictionary];
                    NSString *observationFailure = nil;
                    result[@"observationStarted"] = @YES;
                    BOOL intervalCompleted = CCNMWaitForObservationInterval(CCNMNR78ObservationSeconds,
                                                                            observationPhase,
                                                                            &observationFailure);
                    if (intervalCompleted) {
                        NSError *observationReadError = nil;
                        id<CCNMBandInfo> observationInfo = nil;
                        @try {
                            observationInfo = [client getBandInfo:context error:&observationReadError];
                        } @catch (NSException *exception) {
                            observationPhase[@"readException"] = exception.reason ?: exception.name;
                            observationFailure = [NSString stringWithFormat:@"Observation-end Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                        }
                        NSDictionary *observationEndBands = [observationInfo respondsToSelector:@selector(activeBands)] ? [observationInfo activeBands] : nil;
                        observationPhase[@"readError"] = observationReadError.localizedDescription ?: @"";
                        if (!observationFailure && observationReadError) {
                            observationFailure = observationReadError.localizedDescription;
                        }
                        if (!observationFailure && !CCNMValidateBandDictionary(observationEndBands, &observationFailure)) {
                            observationEndBands = nil;
                        }
                        if (observationEndBands) {
                            observationPhase[@"activeBands"] = observationEndBands;
                            observationPhase[@"differenceFromRequest"] = CCNMBandDictionaryDifference(nr78Bands, observationEndBands);
                        }
                        BOOL observationEndMatchedRequest = CCNMDictionariesEqual(nr78Bands, observationEndBands);
                        result[@"observationEndMatchedRequest"] = @(observationEndMatchedRequest);
                        if (observationEndMatchedRequest) {
                            result[@"observationCompleted"] = @YES;
                        } else if (!observationFailure) {
                            observationFailure = @"The active bands no longer matched the n78-only request at the end of the 60-second observation.";
                        }
                    }
                    result[@"observationPhase"] = observationPhase;
                    result[@"observationError"] = observationFailure ?: @"";
                    if (observationFailure && !failure) {
                        failure = observationFailure;
                    }
                } else {
                    result[@"observationSkippedReason"] = matchedOriginal ? @"setter_not_applied" : @"indeterminate_readback";
                }

                if (CCNMBeginAutomaticRestoreOperation(operationGeneration)) {
                    NSMutableDictionary *restorePhase = nil;
                    NSString *restoreFailure = nil;
                    BOOL restored = NO;
                    @try {
                        restorePhase = [NSMutableDictionary dictionary];
                        if (recoveryLockDescriptor >= 0) {
                            id<CCNMSubscriptionContext> restoreContext = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &restoreFailure);
                            NSDictionary *restoreMarker = nil;
                            if (!restoreFailure) {
                                restoreMarker = CCNMBuildRestoreMarkerRecord(@"nr78_only_automatic_restore", snapshot, operationGeneration, &restoreFailure);
                            }
                            if (!restoreFailure) {
                                result[@"restoreAttempted"] = @YES;
                                restored = CCNMRestoreActiveBands(client, restoreContext, snapshot, originalBands, restoreMarker, setterInFlightRecord, operationGeneration, restorePhase, &restoreFailure);
                            }
                        } else {
                            restoreFailure = @"The automatic restore lost exclusive recovery ownership.";
                        }
                    } @finally {
                        CCNMEndRecoveryOperation();
                    }
                    automaticRestoreVerified = restored;
                    result[@"restoreReadBackEqual"] = @(restored);
                    result[@"restorePhase"] = restorePhase;
                    result[@"restoreError"] = restoreFailure ?: @"";
                    if (restoreFailure && !failure) {
                        failure = restoreFailure;
                    }
                } else if (!failure) {
                    failure = @"The automatic restore could not obtain exclusive recovery ownership.";
                }

                if (automaticRestoreVerified) {
                    NSString *markerRemovalFailure = nil;
                    BOOL markerRemoved = CCNMRemoveSetterInFlightRecord(setterInFlightRecord, &markerRemovalFailure);
                    result[@"setterInFlightRemoved"] = @(markerRemoved);
                    result[@"setterInFlightPreserved"] = @(!markerRemoved);
                    if (!markerRemoved && !failure) {
                        failure = markerRemovalFailure ?: @"Could not clear the setter-in-flight record after verified automatic recovery.";
                    }
                } else {
                    result[@"setterInFlightRemoved"] = @NO;
                    result[@"setterInFlightPreserved"] = @YES;
                    if (!failure) {
                        failure = @"The automatic restore was not verified, so the setter-in-flight record and recovery files were preserved.";
                    }
                }
            }
        }
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"n78-only Band operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            if (recoveryLockDescriptor >= 0) {
                CCNMReleaseRecoveryFileLock(recoveryLockDescriptor);
            }
            CCNMEndBandOperation();
        }

        BOOL determinate = [result[@"setterAttempted"] boolValue] &&
                           ![result[@"setterStateUncertain"] boolValue] &&
                           ([result[@"readBackMatchedRequest"] boolValue] || [result[@"readBackMatchedOriginal"] boolValue]);
        BOOL recovered = [result[@"restoreAttempted"] boolValue] && [result[@"restoreReadBackEqual"] boolValue];
        BOOL effectApplied = [result[@"effectApplied"] boolValue];
        BOOL observationSatisfied = !effectApplied || [result[@"observationCompleted"] boolValue];
        BOOL recoveryPending = [result[@"setterAttempted"] boolValue] && !recovered;
        result[@"recoveryPending"] = @(recoveryPending);
        if (!failure && !(determinate && observationSatisfied && recovered)) {
            failure = @"The n78-only experiment did not complete every required write, read-back, observation, and restore phase.";
        }
        if (recoveryPending) {
            failure = [NSString stringWithFormat:@"%@\n\nThe n78-only write was issued and the original set was not verified as restored. Reboot the device, reopen Preferences, then run Restore Saved Band Snapshot. Recovery records were preserved.", failure ?: @"Recovery was not verified."];
        }
        result[@"passed"] = @(!failure && determinate && observationSatisfied && recovered);
        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        BOOL resultSaved = [result writeToFile:CCNMBandNR78ResultPath() atomically:YES];
        BOOL passed = resultSaved && !failure && determinate && observationSatisfied && recovered;
        NSString *message = nil;
        if (!resultSaved) {
            message = @"The experiment finished, but its result plist could not be saved.";
        } else if ([result[@"setterStateUncertain"] boolValue]) {
            message = [NSString stringWithFormat:@"SETTER STATE UNCERTAIN\nNo concurrent restore was issued. Do not restore in this boot session. Reboot the device, reopen Preferences, then use Restore Saved Band Snapshot.\n\nSnapshot: %@\nResult: %@", CCNMBandSnapshotPath(), CCNMBandNR78ResultPath()];
        } else if (!passed) {
            message = [NSString stringWithFormat:@"FAILED\n%@\n\nSnapshot: %@\nResult: %@", failure ?: @"Required phases did not all complete.", CCNMBandSnapshotPath(), CCNMBandNR78ResultPath()];
        } else if (effectApplied) {
            message = [NSString stringWithFormat:@"WRITE TOOK EFFECT\nThe NR allowed-band array read back as exactly [78], matched the same complete request again after 60 seconds, and the complete original set was restored and verified.\n\nResult: %@", CCNMBandNR78ResultPath()];
        } else {
            message = [NSString stringWithFormat:@"WRITE IGNORED\nThe setter returned no error, but the read-back still equals the original complete set, so the NR array was not changed to [78]. The original set was restored and verified.\n\nResult: %@", CCNMBandNR78ResultPath()];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            NSString *title = passed ? (effectApplied ? @"NR n78-only write took effect" : @"NR n78-only write was ignored") : @"NR n78-only experiment failed";
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)restoreSavedBandSnapshot {
    NSUInteger manualRestoreGeneration = 0;
    if (!CCNMBeginManualRestoreOperation(&manualRestoreGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Restore unavailable right now" message:@"A write or restore operation is already running. If a setter timed out, reboot the device before recovery." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"manual_restore",
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"error": @"",
            @"deviceRebootRequiredForInFlight": @NO,
            @"setterInFlightValidated": @NO,
            @"restoreInFlightValidated": @NO,
            @"recoveryLockAcquired": @NO,
            @"restoreReadBackEqual": @NO,
            @"snapshotRemoved": @NO,
            @"writeIntentRemoved": @NO,
            @"restoreInFlightRemoved": @NO,
            @"setterInFlightRemoved": @NO
        } mutableCopy];
        NSString *failure = nil;
        int recoveryLockDescriptor = -1;
        @try {
            recoveryLockDescriptor = CCNMAcquireRecoveryFileLock(YES, &failure);
            result[@"recoveryLockAcquired"] = @(recoveryLockDescriptor >= 0);

            NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
            NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
            BOOL inFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSetterInFlightPath()];
            BOOL restoreInFlightExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
            NSDictionary *inFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSetterInFlightPath()];
            NSDictionary *restoreInFlight = [NSDictionary dictionaryWithContentsOfFile:CCNMBandRestoreInFlightPath()];
            NSDictionary *snapshotBands = nil;
            if (!failure) {
                CCNMValidateSnapshot(snapshot, &snapshotBands, &failure);
            }
            if (!failure) {
                result[@"writeIntentValidated"] = @(CCNMValidateWriteIntent(writeIntent, snapshot, &failure));
            } else {
                result[@"writeIntentValidated"] = @NO;
            }
            if (!failure && !inFlightExists) {
                failure = @"No setter-in-flight marker exists. A recovery setter is not authorized.";
            } else if (!failure && !inFlight) {
                failure = @"The setter-in-flight record exists but is unreadable; preserving all recovery records.";
            }
            if (!failure) {
                NSString *inFlightFailure = nil;
                BOOL markerValid = CCNMValidateSetterInFlightRecord(inFlight, snapshot, writeIntent, &inFlightFailure);
                result[@"setterInFlightValidated"] = @(markerValid);
                if (!markerValid) {
                    failure = inFlightFailure ?: @"The setter-in-flight record is invalid; preserving all recovery records.";
                }
            }
            if (!failure && restoreInFlightExists && !restoreInFlight) {
                failure = @"The restore-in-flight record exists but is unreadable; preserving all recovery records.";
            }
            if (!failure && restoreInFlight) {
                NSString *restoreInFlightFailure = nil;
                BOOL restoreMarkerValid = CCNMValidateRestoreInFlightRecord(restoreInFlight, snapshot, &restoreInFlightFailure);
                result[@"restoreInFlightValidated"] = @(restoreMarkerValid);
                if (!restoreMarkerValid) {
                    failure = restoreInFlightFailure ?: @"The restore-in-flight record is invalid; preserving all recovery records.";
                }
            }
            if (!failure) {
                NSString *outstandingDetail = nil;
                BOOL outstanding = CCNMCurrentBootSetterMayBeOutstanding(nil, &outstandingDetail);
                result[@"inFlightSameBoot"] = @(outstanding);
                if (outstanding) {
                    result[@"deviceRebootRequiredForInFlight"] = @YES;
                    failure = outstandingDetail ?: @"A setter from this boot session may still be outstanding. Do not restore yet. Reboot the device first, then retry.";
                }
            }

            id<CCNMCoreTelephonyClient> client = nil;
            id<CCNMSubscriptionContext> context = nil;
            if (!failure) {
                client = CCNMCreateCoreTelephonyClient(&failure);
            }
            if (!failure) {
                CCNMValidateTargetDevice(result, &failure);
            }
            if (!failure) {
                context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
            }
            BOOL restored = NO;
            if (!failure) {
                NSError *liveReadError = nil;
                id<CCNMBandInfo> liveInfo = nil;
                @try {
                    liveInfo = [client getBandInfo:context error:&liveReadError];
                } @catch (NSException *exception) {
                    result[@"liveReadException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"Pre-restore Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                NSDictionary *liveBands = [liveInfo respondsToSelector:@selector(activeBands)] ? [liveInfo activeBands] : nil;
                result[@"liveReadError"] = liveReadError.localizedDescription ?: @"";
                if (!failure && (liveReadError || !CCNMValidateBandDictionary(liveBands, &failure))) {
                    if (!failure) {
                        failure = liveReadError.localizedDescription ?: @"The live active-band dictionary is invalid; restore was not attempted.";
                    }
                }
                if (!failure) {
                    BOOL restoreWasNeeded = !CCNMDictionariesEqual(snapshotBands, liveBands);
                    result[@"restoreWasNeeded"] = @(restoreWasNeeded);
                    result[@"liveDifferenceFromSnapshot"] = CCNMBandDictionaryDifference(snapshotBands, liveBands);
                    if (!restoreWasNeeded) {
                        restored = YES;
                        result[@"restorePhase"] = @{
                            @"setterAttempted": @NO,
                            @"readBackEqual": @YES,
                            @"liveAlreadyMatchedSnapshot": @YES
                        };
                    } else {
                        CCNMValidateSetterABI(client, &failure);
                        if (!failure) {
                            NSMutableDictionary *restorePhase = [NSMutableDictionary dictionary];
                            NSDictionary *restoreMarker = CCNMBuildRestoreMarkerRecord(@"manual_restore", snapshot, manualRestoreGeneration, &failure);
                            if (!failure) {
                                restored = CCNMRestoreActiveBands(client, context, snapshot, snapshotBands, restoreMarker, nil, manualRestoreGeneration, restorePhase, &failure);
                            }
                            result[@"restorePhase"] = restorePhase;
                        }
                    }
                }
                result[@"restoreReadBackEqual"] = @(restored);
            }
            if (restored) {
                BOOL snapshotRemoved = NO;
                BOOL intentRemoved = NO;
                BOOL restoreMarkerRemoved = ![[NSFileManager defaultManager] fileExistsAtPath:CCNMBandRestoreInFlightPath()];
                BOOL markerRemoved = NO;
                NSString *snapshotRemovalFailure = nil;
                NSString *intentRemovalFailure = nil;
                NSString *restoreMarkerRemovalFailure = nil;
                NSString *markerRemovalFailure = nil;

                CCNMUnlinkIfPresent(CCNMBandSnapshotPath(), &snapshotRemoved, &snapshotRemovalFailure);
                if (snapshotRemoved) {
                    CCNMUnlinkIfPresent(CCNMBandWriteIntentPath(), &intentRemoved, &intentRemovalFailure);
                }
                if (snapshotRemoved && intentRemoved && !restoreMarkerRemoved) {
                    if (restoreInFlight) {
                        restoreMarkerRemoved = CCNMRemoveRestoreInFlightRecord(restoreInFlight, &restoreMarkerRemovalFailure);
                    } else {
                        restoreMarkerRemovalFailure = @"A restore-in-flight record appeared unexpectedly; preserving it for recovery.";
                    }
                }
                if (snapshotRemoved && intentRemoved && restoreMarkerRemoved) {
                    markerRemoved = CCNMRemoveSetterInFlightRecord(inFlight, &markerRemovalFailure);
                }
                result[@"snapshotRemoved"] = @(snapshotRemoved);
                result[@"writeIntentRemoved"] = @(intentRemoved);
                result[@"restoreInFlightRemoved"] = @(restoreMarkerRemoved);
                result[@"setterInFlightRemoved"] = @(markerRemoved);
                if (snapshotRemovalFailure || intentRemovalFailure || restoreMarkerRemovalFailure || markerRemovalFailure ||
                    !snapshotRemoved || !intentRemoved || !restoreMarkerRemoved || !markerRemoved) {
                    failure = snapshotRemovalFailure ?: intentRemovalFailure ?: restoreMarkerRemovalFailure ?: markerRemovalFailure ?: @"Restore matched, but recovery records could not be cleared completely.";
                }
            }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Manual restore raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            CCNMReleaseRecoveryFileLock(recoveryLockDescriptor);
            CCNMEndManualRestoreOperation();
        }

        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        [result writeToFile:CCNMBandManualRestoreResultPath() atomically:YES];
        NSString *message = failure ?: @"Saved slot-1 active bands were restored, read back exactly, and recovery records were cleared.";
        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:failure ? @"Band snapshot restore failed" : @"Band snapshot restored" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    self.navigationItem.rightBarButtonItem = applyButton;

    // As of the latest Dopamine version, an oldabi check should no longer be required as it's implemented into Dopamine now.
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}

	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {
	NSString *path = [NSString stringWithFormat:jbroot(@"/var/mobile/Library/Preferences/%@.plist"), specifier.properties[@"defaults"]];
	NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:path];
	return (settings[specifier.properties[@"key"]]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
	NSString *path = [NSString stringWithFormat:jbroot(@"/var/mobile/Library/Preferences/%@.plist"), specifier.properties[@"defaults"]];
	NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithContentsOfFile:path];
	[settings setObject:value forKey:specifier.properties[@"key"]];
	[settings writeToFile:path atomically:YES];
	CFStringRef notificationName = (__bridge CFStringRef)specifier.properties[@"PostNotification"];
	if (notificationName) {
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notificationName, NULL, NULL, YES);
	}
}

-(void)save {
	[self.view endEditing:YES];
}
@end

@implementation CCNMTelegramCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Telegram";
        self.detailTextLabel.text = @"@Nixuge";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *telegramLogo = [UIImage imageNamed:@"telegram" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:telegramLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openTelegram)];
    }

    return self;
}

-(void)openTelegram {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"tg:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"tg://resolve?domain=Nixuge"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://t.me/Nixuge"] options:@{} completionHandler:nil];
    }
}
@end

@implementation CCNMDiscordCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Discord";
        self.detailTextLabel.text = @"@Nixuge";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *discordLogo = [UIImage imageNamed:@"discord" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:discordLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openDiscord)];
    }

    return self;
}

-(void)openDiscord {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"discord:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"discord://discord.com/users/784062518901473351"] options:@{} completionHandler:nil];
    }
    // not opening in the browser as discord browser on mobile is horrendous
}
@end

@implementation CCNMTwitterCell

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Twitter";
        self.detailTextLabel.text = @"@JeanFilsYTB";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *twitterLogo = [UIImage imageNamed:@"twitter" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:twitterLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openTwitter)];
    }

    return self;
}

-(void)openTwitter {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"twitter:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"twitter://user?screen_name=JeanFilsYTB"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.twitter.com/JeanFilsYTB"] options:@{} completionHandler:nil];
    }
}

@end

@implementation CCNMRedditCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Reddit";
        self.detailTextLabel.text = @"/u/Nixugay";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *redditLogo = [UIImage imageNamed:@"reddit" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:redditLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openReddit)];
    }

    return self;
}

-(void)openReddit {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"reddit:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"reddit:///u/Nixugay"] options:@{} completionHandler:nil];
    } else if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"apollo:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"apollo://www.reddit.com/u/Nixugay"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.reddit.com/u/Nixugay"] options:@{} completionHandler:nil];
    }
}
@end

@implementation NetworkManagerLogo

- (id)initWithSpecifier:(PSSpecifier *)specifier
{
	self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Banner" specifier:specifier];
	if (self) {
		// CGFloat width = 320;
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
		CGFloat height = 70;

		CGRect backgroundFrame = CGRectMake(-50, -35, width, height);
		background = [[UILabel alloc] initWithFrame:backgroundFrame];
		[background layoutIfNeeded];
		background.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:0.0];
		background.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

		CGRect tweakNameFrame = CGRectMake(-50, -40, width, height);
		tweakName = [[UILabel alloc] initWithFrame:tweakNameFrame];
		[tweakName layoutIfNeeded];
		tweakName.numberOfLines = 1;
		tweakName.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
        [tweakName setFont:[UIFont systemFontOfSize:30]];
		tweakName.textColor = [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
		tweakName.text = @"NetworkManagerReborn";
		tweakName.textAlignment = NSTextAlignmentCenter;

		CGRect versionFrame = CGRectMake(-50, -5, width, height);
		version = [[UILabel alloc] initWithFrame:versionFrame];
		version.numberOfLines = 1;
		version.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
        [version setFont:[UIFont systemFontOfSize:15]];
		version.textColor = [UIColor colorWithRed:0.82 green:0.82 blue:0.84 alpha:1.0];

        // For future reference (not really important here), could use either:
        // - %s and NETWORK_MANAGER_VERSION (Cstring) -> no perf impact but cant handle eg unicode & crashes if undefined macro
        // - %@ and @NETWORK_MANAGER_VERSION (NSString) -> slight perf impact (new obj) but can handle unicode & empty string if undefined macro
		version.text = [NSString stringWithFormat:@"Version %@", @(NETWORK_MANAGER_VERSION)];

		version.backgroundColor = [UIColor clearColor];
		version.textAlignment = NSTextAlignmentCenter;

		[self addSubview:background];
		[self addSubview:tweakName];
		[self addSubview:version];
	}
    return self;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
	return 100.0f;
}
@end
