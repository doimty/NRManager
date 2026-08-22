#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <Foundation/Foundation.h>

#import "../networkmanagerprefs/CCNMAutomaticMaintenanceDecision.h"
#import "../networkmanagerprefs/CCNMAutomaticMaintenanceRecord.h"
#import "../networkmanagerprefs/CCNMN78PolicyReader.h"
#import "../networkmanagerprefs/CCNMServingStatusProvider.h"

static const NSTimeInterval CCNMMaintenancePrototypeRefreshSeconds = 30.0;

static BOOL CCNMPolicySummaryIsStableEnabled(NSDictionary *summary) {
    return [summary[CCNMN78PolicySummarySuccessKey] boolValue] &&
        [summary[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred] &&
        [summary[CCNMN78PolicySummaryAppliedPolicyKey] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [summary[CCNMN78PolicySummaryRecoveryStateKey] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        [summary[@"baselinePresent"] boolValue] && [summary[@"baselineValid"] boolValue] &&
        ![summary[@"transitionPresent"] boolValue] &&
        ![summary[@"removalGuardPresent"] boolValue] &&
        ![summary[@"uncertain"] boolValue];
}

static NSDictionary *CCNMMaintenanceIdentityFromServingSummary(NSDictionary *summary) {
    NSString *deviceModel = CCNMSysctlString("hw.machine") ?: @"";
    NSString *systemBuild = CCNMSysctlString("kern.osversion") ?: @"";
    NSString *systemVersion = CCNMSysctlString("kern.osproductversion") ?: @"";
    NSString *subscriptionUUID = [summary[CCNMServingSummarySubscriptionUUIDKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummarySubscriptionUUIDKey] : @"";
    NSNumber *slotID = [summary[CCNMServingSummarySlotIDKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummarySlotIDKey] : @0;
    return @{
        @"deviceModel": deviceModel,
        @"systemVersion": systemVersion,
        @"systemBuild": systemBuild,
        @"subscriptionUUID": subscriptionUUID,
        @"slotID": slotID,
        CCNMARecordCapabilityReadSuccessKey:
            summary[CCNMServingSummaryCapabilityReadSuccessKey] ?: @NO,
        CCNMARecordCapabilityN78SupportedKey:
            summary[CCNMServingSummaryCapabilityN78SupportedKey] ?: @NO,
        CCNMARecordCapabilityN78ActiveKey:
            summary[CCNMServingSummaryCapabilityN78ActiveKey] ?: @NO,
        CCNMARecordCapabilitySupportedNRBandsKey:
            summary[CCNMServingSummaryCapabilitySupportedNRBandsKey] ?: @[],
        CCNMARecordCapabilityActiveNRBandsKey:
            summary[CCNMServingSummaryCapabilityActiveNRBandsKey] ?: @[],
        CCNMARecordCapabilitySupportedRATKeysKey:
            summary[CCNMServingSummaryCapabilitySupportedRATKeysKey] ?: @[]
    };
}

static BOOL CCNMMaintenanceCapabilityCompatible(NSDictionary *policy,
                                                  NSDictionary *servingSummary,
                                                  NSDictionary *identity) {
    long long capabilitySampledAt = [servingSummary[
        CCNMServingSummaryCapabilitySampledAtMillisecondsKey] longLongValue];
    long long capabilityAge = CCNMUnixMilliseconds() - capabilitySampledAt;
    if (capabilitySampledAt <= 0 || capabilityAge < 0 || capabilityAge > 30000 ||
        [servingSummary[CCNMServingSummaryStaleKey] boolValue] ||
        ![servingSummary[CCNMServingSummaryCapabilityReadSuccessKey] boolValue] ||
        ![servingSummary[CCNMServingSummaryCapabilityN78SupportedKey] boolValue] ||
        ![servingSummary[CCNMServingSummaryCapabilityN78ActiveKey] boolValue] ||
        ![servingSummary[CCNMServingSummaryCapabilityActiveNRBandsKey]
            isEqualToArray:@[ @78 ]]) {
        return NO;
    }
    NSString *baselinePath = [policy[CCNMN78PolicySummaryStateKey] isKindOfClass:NSDictionary.class]
        ? policy[CCNMN78PolicySummaryStateKey][@"baselinePath"] : nil;
    baselinePath = [policy[@"baselinePath"] isKindOfClass:NSString.class]
        ? policy[@"baselinePath"] : baselinePath;
    NSDictionary *baseline = [baselinePath isKindOfClass:NSString.class]
        ? [NSDictionary dictionaryWithContentsOfFile:baselinePath] : nil;
    if (!CCNMValidateBaselineRecord(baseline, NULL) ||
        ![baseline[@"supportedBands"] isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    for (NSString *key in @[
        @"deviceModel", @"systemVersion", @"systemBuild"
    ]) {
        if (![baseline[key] isKindOfClass:NSString.class] ||
            ![identity[key] isKindOfClass:NSString.class] ||
            ![baseline[key] isEqual:identity[key]]) {
            return NO;
        }
    }
    NSString *baselineUUID = CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]);
    NSString *currentUUID = CCNMCanonicalUUIDString(identity[@"subscriptionUUID"]);
    if (!baselineUUID || !currentUUID || ![baselineUUID isEqualToString:currentUUID] ||
        ![baseline[@"slotID"] isEqual:identity[@"slotID"]] ||
        [identity[@"slotID"] longLongValue] <= 0) {
        return NO;
    }
    NSArray *savedKeys = [[baseline[@"supportedBands"] allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    NSArray *currentKeys = [servingSummary[CCNMServingSummaryCapabilitySupportedRATKeysKey]
        sortedArrayUsingSelector:@selector(compare:)];
    if (![savedKeys isEqualToArray:currentKeys]) {
        return NO;
    }
    NSArray *savedNR = baseline[@"supportedBands"][@"kCTRegistrationRadioAccessTechnologyNR"];
    NSArray *currentNR = servingSummary[CCNMServingSummaryCapabilitySupportedNRBandsKey];
    if (![savedNR isKindOfClass:NSArray.class] ||
        ![savedNR containsObject:@78] ||
        ![currentNR isKindOfClass:NSArray.class]) {
        return NO;
    }
    for (NSNumber *band in savedNR) {
        if (![currentNR containsObject:band]) {
            return NO;
        }
    }
    return YES;
}

static CCNMAutomaticMaintenanceSample CCNMSampleFromServingSummary(NSDictionary *summary) {
    CCNMAutomaticMaintenanceSample sample = {0};
    sample.stale = [summary[CCNMServingSummaryStaleKey] boolValue];
    sample.unsafeOutstanding = [summary[CCNMServingSummaryUnsafeOutstandingKey] boolValue];
    NSNumber *band = [summary[CCNMServingSummaryBandKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummaryBandKey] : nil;
    NSString *state = [summary[CCNMServingSummaryStateKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummaryStateKey] : nil;
    if ([state isEqual:CCNMServingStateLTE]) {
        sample.rat = CCNMAutomaticMaintenanceRATLTE;
    } else if ([state isEqual:CCNMServingStateNRN78] ||
               [state isEqual:CCNMServingStateNROther]) {
        sample.rat = CCNMAutomaticMaintenanceRATNR;
    }
    sample.band = band.intValue;
    sample.valid = [summary[CCNMServingSummarySuccessKey] boolValue] &&
        !sample.stale && sample.rat != CCNMAutomaticMaintenanceRATUnknown && sample.band > 0;
    return sample;
}

@class CCNMMaintenanceMonitor;

static void CCNMPolicyChanged(CFNotificationCenterRef center,
                              void *observer,
                              CFNotificationName name,
                              const void *object,
                              CFDictionaryRef userInfo);

@interface CCNMMaintenanceMonitor : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) CTTelephonyNetworkInfo *telephonyInfo;
@property (nonatomic, strong) id ratObserver;
@property (nonatomic, assign) BOOL refreshInProgress;
@property (nonatomic, assign) BOOL exitRequested;
@property (nonatomic, assign) BOOL hasPreviousSample;
@property (nonatomic, assign) BOOL hasCurrentSample;
@property (nonatomic, assign) CCNMAutomaticMaintenanceSample previousSample;
@property (nonatomic, assign) CCNMAutomaticMaintenanceSample currentSample;
@property (nonatomic, assign) CCNMAutomaticMaintenanceDecision lastDecision;
@property (nonatomic, strong) NSDictionary *cachedIdentity;
@property (nonatomic, strong) NSNumber *cachedPolicyGeneration;
@property (nonatomic, strong) NSNumber *cachedBaselineCreatedAt;
- (void)start;
- (void)policyMayHaveChanged;
@end

@implementation CCNMMaintenanceMonitor

- (void)start {
    self.telephonyInfo = [[CTTelephonyNetworkInfo alloc] init];
    __weak typeof(self) weakSelf = self;
    self.ratObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:CTServiceRadioAccessTechnologyDidChangeNotification
                    object:self.telephonyInfo
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    [weakSelf requestRefreshIfEligible];
                }];
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CCNMPolicyChanged,
        (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:CCNMMaintenancePrototypeRefreshSeconds
                                                  repeats:YES
                                                    block:^(__unused NSTimer *timer) {
        [weakSelf requestRefreshIfEligible];
    }];
    [self policyMayHaveChanged];
}

- (void)dealloc {
    if (self.ratObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.ratObserver];
    }
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
        NULL);
    [self.timer invalidate];
}

- (void)resetEvidence {
    self.hasPreviousSample = NO;
    self.hasCurrentSample = NO;
    self.previousSample = (CCNMAutomaticMaintenanceSample){0};
    self.currentSample = (CCNMAutomaticMaintenanceSample){0};
    self.lastDecision = CCNMAutomaticMaintenanceDisabled;
    self.cachedIdentity = nil;
    self.cachedPolicyGeneration = nil;
    self.cachedBaselineCreatedAt = nil;
}

- (void)exitAfterBaselineRetirement {
    if (self.exitRequested) {
        return;
    }
    self.exitRequested = YES;
    [self.timer invalidate];
    self.timer = nil;
    CFRunLoopStop(CFRunLoopGetMain());
}

- (void)policyMayHaveChanged {
    NSDictionary *summary = CCNMReadN78PolicyState();
    if (!CCNMPolicySummaryIsStableEnabled(summary)) {
        [self resetEvidence];
        // Write a status update even when disabled, so the plist reflects
        // the current (non-enabled) state.
        NSDictionary *emptyServing = CCNMServingStatusEmptySummary();
        [self persistWithDecision:CCNMAutomaticMaintenanceDisabled
                  servingSummary:emptyServing];
        if (![summary[@"baselinePresent"] boolValue]) {
            [self exitAfterBaselineRetirement];
        }
        return;
    }
    // Cache policy identity for the record.
    NSDictionary *state = summary[CCNMN78PolicySummaryStateKey];
    if ([state isKindOfClass:NSDictionary.class]) {
        self.cachedPolicyGeneration = state[@"operationGeneration"];
    }
    // Cache baseline creation timestamp (from the summary's baselinePath).
    if (summary[@"baselinePresent"]) {
        NSDictionary *baseline = [NSDictionary dictionaryWithContentsOfFile:
            summary[@"baselinePath"]];
        if ([baseline isKindOfClass:NSDictionary.class]) {
            self.cachedBaselineCreatedAt = baseline[@"createdAt"];
        }
    }
    [self requestRefreshIfEligible];
}

- (void)requestRefreshIfEligible {
    NSDictionary *policy = CCNMReadN78PolicyState();
    if (!CCNMPolicySummaryIsStableEnabled(policy)) {
        [self resetEvidence];
        NSDictionary *emptyServing = CCNMServingStatusEmptySummary();
        [self persistWithDecision:CCNMAutomaticMaintenanceDisabled
                  servingSummary:emptyServing];
        if (![policy[@"baselinePresent"] boolValue]) {
            [self exitAfterBaselineRetirement];
        }
        return;
    }
    if (self.refreshInProgress) {
        return;
    }
    self.refreshInProgress = YES;
    __weak typeof(self) weakSelf = self;
    [[CCNMServingStatusProvider sharedProvider]
        refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) {
                return;
            }
            self.refreshInProgress = NO;
            NSDictionary *latestPolicy = CCNMReadN78PolicyState();
            if (!CCNMPolicySummaryIsStableEnabled(latestPolicy)) {
                [self resetEvidence];
                [self persistWithDecision:CCNMAutomaticMaintenanceDisabled
                          servingSummary:summary];
                if (![latestPolicy[@"baselinePresent"] boolValue]) {
                    [self exitAfterBaselineRetirement];
                }
                return;
            }
            CCNMAutomaticMaintenanceSample sample = CCNMSampleFromServingSummary(summary);
            if (self.hasCurrentSample) {
                self.previousSample = self.currentSample;
                self.hasPreviousSample = YES;
            }
            self.currentSample = sample;
            self.hasCurrentSample = YES;

            CCNMAutomaticMaintenanceInput input = {0};
            input.policyEnabled = YES;
            NSDictionary *identity = CCNMMaintenanceIdentityFromServingSummary(summary);
            input.capabilityCompatible = CCNMMaintenanceCapabilityCompatible(
                latestPolicy, summary, identity);
            input.operationInProgress = [latestPolicy[@"transitionPresent"] boolValue];
            input.unsafeOutstanding = sample.unsafeOutstanding;
            input.targetBand = 78;
            input.previous = self.hasPreviousSample
                ? self.previousSample : (CCNMAutomaticMaintenanceSample){0};
            input.current = self.currentSample;
            self.lastDecision = CCNMEvaluateAutomaticMaintenance(input);

            [self persistWithDecision:self.lastDecision servingSummary:summary];
        });
    }];
}

- (void)persistWithDecision:(CCNMAutomaticMaintenanceDecision)decision
             servingSummary:(NSDictionary *)servingSummary {
    NSDictionary *identity = CCNMMaintenanceIdentityFromServingSummary(servingSummary);

    // Read existing record to carry forward drop state.
    NSDictionary *existingRecord = CCNMAReadRecord();
    NSUInteger policyGeneration = [self.cachedPolicyGeneration unsignedIntegerValue];

    NSDictionary *record = CCNMABuildRecord(
        CCNMReadN78PolicyState(),
        identity,
        self.hasPreviousSample ? self.previousSample : (CCNMAutomaticMaintenanceSample){0},
        self.currentSample,
        policyGeneration,
        self.cachedBaselineCreatedAt,
        decision,
        existingRecord);
    if (record) {
        (void)CCNMAWriteRecord(record);
    }

    NSDictionary *status = CCNMABuildStatus(
        CCNMReadN78PolicyState(),
        servingSummary,
        record ?: existingRecord,
        decision,
        self.hasPreviousSample ? self.previousSample : (CCNMAutomaticMaintenanceSample){0},
        self.currentSample,
        NO);
    (void)CCNMAWriteStatus(status);
}

@end

static void CCNMPolicyChanged(CFNotificationCenterRef center,
                              void *observer,
                              CFNotificationName name,
                              const void *object,
                              CFDictionaryRef userInfo) {
    CCNMMaintenanceMonitor *monitor = (__bridge CCNMMaintenanceMonitor *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [monitor policyMayHaveChanged];
    });
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (![arguments containsObject:@"--daemon"]) {
            return 64;
        }
        CCNMMaintenanceMonitor *monitor = [[CCNMMaintenanceMonitor alloc] init];
        [monitor start];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}