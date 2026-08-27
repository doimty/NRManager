#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <Foundation/Foundation.h>

#include <limits.h>
#include <stddef.h>

#import "../networkmanagerprefs/CCNMAutomaticMaintenanceDecision.h"
#import "../networkmanagerprefs/CCNMAutomaticMaintenanceRecord.h"
#import "../networkmanagerprefs/CCNMN78PolicyReader.h"
#import "../networkmanagerprefs/CCNMServingStatusProvider.h"

static const NSTimeInterval CCNMMaintenancePrototypeRefreshSeconds = 30.0;

/// Upper bound for a recorded NR selection. The selectable domain is bounded by
/// what one modem advertises; the reference device reported 46 active NR bands, so
/// this is generous. A larger array means the record is not one this daemon wrote.
///
/// Declared as an enumerator rather than `static const size_t` so it is an integer
/// constant expression: in Objective-C a const variable would make the buffer a
/// folded VLA, which -Werror rejects under -Wgnu-folding-constant.
enum { CCNMMaintenanceMaximumTargetBands = 128 };

static BOOL CCNMPolicySummaryIsStableEnabled(NSDictionary *summary) {
    return [summary[CCNMN78PolicySummarySuccessKey] boolValue] &&
        [summary[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred] &&
        [summary[CCNMN78PolicySummaryAppliedPolicyKey] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [summary[CCNMN78PolicySummaryRecoveryStateKey] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        [summary[@"baselinePresent"] boolValue] && [summary[@"baselineValid"] boolValue] &&
        ![summary[@"transitionPresent"] boolValue] &&
        ![summary[@"uncertain"] boolValue];
}

static BOOL CCNMMaintenancePolicyRecordContext(NSDictionary *policy,
                                                NSNumber **generation,
                                                NSNumber **baselineCreatedAt) {
    NSNumber *candidateGeneration = [policy[@"operationGeneration"] isKindOfClass:NSNumber.class]
        ? policy[@"operationGeneration"] : nil;
    NSString *baselinePath = [policy[@"baselinePath"] isKindOfClass:NSString.class]
        ? policy[@"baselinePath"] : nil;
    NSDictionary *baseline = baselinePath.length > 0
        ? [NSDictionary dictionaryWithContentsOfFile:baselinePath] : nil;
    NSNumber *candidateBaselineCreatedAt =
        [baseline[@"createdAt"] isKindOfClass:NSNumber.class] ? baseline[@"createdAt"] : nil;
    if (!CCNMPolicySummaryIsStableEnabled(policy) ||
        !CCNMNSNumberIsInteger(candidateGeneration) ||
        candidateGeneration.longLongValue < 0 ||
        !CCNMValidateBaselineRecord(baseline, NULL) ||
        !CCNMNSNumberIsInteger(candidateBaselineCreatedAt) ||
        candidateBaselineCreatedAt.longLongValue <= 0) {
        return NO;
    }
    if (generation) {
        *generation = candidateGeneration;
    }
    if (baselineCreatedAt) {
        *baselineCreatedAt = candidateBaselineCreatedAt;
    }
    return YES;
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

/// Whether the current active NR bands match the target the policy claims to have
/// applied. The target is the canonical selection from the enabled state proof,
/// or nil when the summary does not describe a stable enabled state. A nil target
/// is treated as a mismatch: the daemon that cannot confirm the target must not
/// act on the sample.
static BOOL CCNMActiveNRBandsMatchTarget(NSArray *activeNR,
                                          NSArray *targetNRBands) {
    if (![activeNR isKindOfClass:NSArray.class] ||
        ![targetNRBands isKindOfClass:NSArray.class] ||
        targetNRBands.count == 0) {
        return NO;
    }
    // Both arrays are ascending by construction: the policy summary publishes the
    // canonicalised selection, and the modem echoes back the exact array that was
    // written to it and then verified. So plain array equality is the right test,
    // and a mismatch means the live NR bands are no longer the ones this policy
    // put there.
    return [activeNR isEqualToArray:targetNRBands];
}

/// Whether the modem still declares support for every band in the applied target.
///
/// This replaces the single "is band 78 supported" gate. The generalisation is not
/// cosmetic: the daemon's automatic action exists to keep a chosen NR set in
/// force, and a target containing a band the modem no longer advertises is not
/// something it can safely maintain.
static BOOL CCNMMaintenanceTargetIsCurrentlySupported(NSArray *supportedNR,
                                                       NSArray *targetNRBands) {
    if (![supportedNR isKindOfClass:NSArray.class] ||
        ![targetNRBands isKindOfClass:NSArray.class] ||
        targetNRBands.count == 0) {
        return NO;
    }
    NSSet *supported = [NSSet setWithArray:supportedNR];
    for (NSNumber *band in targetNRBands) {
        if (![supported containsObject:band]) {
            return NO;
        }
    }
    return YES;
}

/// Copies the recorded NR selection into a C buffer for the pure decision module.
///
/// Returns the number of bands written, or 0 when the summary does not carry a
/// usable selection. A refusal here becomes StopIncompatible downstream, which is
/// the correct outcome: the daemon must not maintain a target it cannot read.
static size_t CCNMCopyTargetNRBands(NSArray *targetNRBands,
                                     int *buffer,
                                     size_t capacity) {
    if (![targetNRBands isKindOfClass:NSArray.class] || buffer == NULL ||
        targetNRBands.count == 0 || targetNRBands.count > capacity) {
        return 0;
    }
    size_t written = 0;
    for (id band in targetNRBands) {
        if (![band isKindOfClass:NSNumber.class]) {
            return 0;
        }
        long long value = [band longLongValue];
        if (value <= 0 || value > INT_MAX) {
            return 0;
        }
        buffer[written++] = (int)value;
    }
    return written;
}

static BOOL CCNMMaintenanceCapabilityCompatible(NSDictionary *policy,
                                                  NSDictionary *servingSummary,
                                                  NSDictionary *identity) {
    long long capabilitySampledAt = [servingSummary[
        CCNMServingSummaryCapabilitySampledAtMillisecondsKey] longLongValue];
    long long capabilityAge = CCNMUnixMilliseconds() - capabilitySampledAt;
    NSArray *targetNRBands = policy[CCNMN78PolicySummaryTargetNRBandsKey];
    if (capabilitySampledAt <= 0 || capabilityAge < 0 || capabilityAge > 30000 ||
        [servingSummary[CCNMServingSummaryStaleKey] boolValue] ||
        ![servingSummary[CCNMServingSummaryCapabilityReadSuccessKey] boolValue] ||
        !CCNMMaintenanceTargetIsCurrentlySupported(
            servingSummary[CCNMServingSummaryCapabilitySupportedNRBandsKey],
            targetNRBands) ||
        !CCNMActiveNRBandsMatchTarget(
            servingSummary[CCNMServingSummaryCapabilityActiveNRBandsKey],
            targetNRBands)) {
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
    // Cache the exact policy transaction identity used by both decision feedback
    // and the record written after that decision. Missing or malformed values make
    // the existing record ineligible rather than borrowing state from another
    // enable generation.
    NSNumber *policyGeneration = nil;
    NSNumber *baselineCreatedAt = nil;
    (void)CCNMMaintenancePolicyRecordContext(summary,
        &policyGeneration, &baselineCreatedAt);
    self.cachedPolicyGeneration = policyGeneration;
    self.cachedBaselineCreatedAt = baselineCreatedAt;
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

            NSNumber *latestPolicyGeneration = nil;
            NSNumber *latestBaselineCreatedAt = nil;
            (void)CCNMMaintenancePolicyRecordContext(latestPolicy,
                &latestPolicyGeneration, &latestBaselineCreatedAt);
            self.cachedPolicyGeneration = latestPolicyGeneration;
            self.cachedBaselineCreatedAt = latestBaselineCreatedAt;

            CCNMAutomaticMaintenanceInput input = {0};
            input.policyEnabled = YES;
            NSDictionary *identity = CCNMMaintenanceIdentityFromServingSummary(summary);
            input.capabilityCompatible = CCNMMaintenanceCapabilityCompatible(
                latestPolicy, summary, identity);
            input.operationInProgress = [latestPolicy[@"transitionPresent"] boolValue];
            input.unsafeOutstanding = sample.unsafeOutstanding;

            long long nowMilliseconds = CCNMUnixMilliseconds();
            input.nowMilliseconds = nowMilliseconds > 0 ? (uint64_t)nowMilliseconds : 0;
            NSDictionary *existingRecord = CCNMAReadRecord();
            BOOL recordMatchesContext = self.cachedPolicyGeneration &&
                self.cachedBaselineCreatedAt &&
                CCNMARecordMatchesCurrentContext(existingRecord, identity,
                    self.cachedPolicyGeneration.unsignedIntegerValue,
                    self.cachedBaselineCreatedAt);
            if (recordMatchesContext) {
                input.verificationPending =
                    [existingRecord[CCNMARecordVerificationPendingKey] boolValue];
                input.attemptUsedForDrop =
                    [existingRecord[CCNMARecordAttemptConsumedKey] boolValue];
                input.dropRecordedForCurrentSample =
                    [existingRecord[CCNMARecordDropGenerationKey] unsignedIntegerValue] > 0 &&
                    !input.verificationPending && !input.attemptUsedForDrop &&
                    [existingRecord[CCNMARecordDropRATKey] intValue] == sample.rat &&
                    [existingRecord[CCNMARecordDropBandKey] intValue] == sample.band;
                NSNumber *cooldownUntil = existingRecord[CCNMARecordCooldownUntilKey];
                input.cooldownUntilMilliseconds = [cooldownUntil isKindOfClass:NSNumber.class]
                    ? cooldownUntil.unsignedLongLongValue : 0;
            }
            // The maintained target is whatever selection the policy recorded, not
            // a fixed band. An unreadable or malformed selection yields a zero
            // count, which the decision module turns into a refusal.
            int targetBands[CCNMMaintenanceMaximumTargetBands] = {0};
            input.targetBandCount = CCNMCopyTargetNRBands(
                latestPolicy[CCNMN78PolicySummaryTargetNRBandsKey],
                targetBands, CCNMMaintenanceMaximumTargetBands);
            input.targetBands = input.targetBandCount > 0 ? targetBands : NULL;
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
    NSDictionary *policy = CCNMReadN78PolicyState();
    CCNMAutomaticMaintenanceSample previous = self.hasPreviousSample
        ? self.previousSample : (CCNMAutomaticMaintenanceSample){0};

    // A disabled pass has no chosen subscription, so there is no slot or UUID to
    // bind a record to, and the record builder correctly refuses to invent one.
    // Retire the record instead of leaving the old one on disk: its drop state
    // belongs to the enable generation that just ended, and keeping it would let
    // a later enable in the same boot inherit an attempt it never made. Status is
    // still published, because the observable state is "disabled", not "unknown".
    //
    // This is deliberately narrower than "the builder returned nil". During an
    // enabled pass a nil record means the identity could not be read, and there
    // the old record must survive so a consumed attempt stays consumed.
    if (decision == CCNMAutomaticMaintenanceDisabled ||
        !CCNMPolicySummaryIsStableEnabled(policy)) {
        (void)CCNMADeleteRecord();
        (void)CCNMAWriteStatus(CCNMABuildStatus(policy, servingSummary, nil, decision,
            previous, self.currentSample, NO));
        return;
    }

    NSNumber *currentPolicyGeneration = nil;
    NSNumber *currentBaselineCreatedAt = nil;
    if (!CCNMMaintenancePolicyRecordContext(policy,
            &currentPolicyGeneration, &currentBaselineCreatedAt) ||
        ![currentPolicyGeneration isEqual:self.cachedPolicyGeneration] ||
        ![currentBaselineCreatedAt isEqual:self.cachedBaselineCreatedAt]) {
        return;
    }
    NSDictionary *identity = CCNMMaintenanceIdentityFromServingSummary(servingSummary);

    // Read existing record to carry forward drop state.
    NSDictionary *existingRecord = CCNMAReadRecord();
    NSUInteger policyGeneration = currentPolicyGeneration.unsignedIntegerValue;

    NSDictionary *record = CCNMABuildRecord(
        policy,
        identity,
        previous,
        self.currentSample,
        policyGeneration,
        currentBaselineCreatedAt,
        decision,
        existingRecord);
    if (record) {
        (void)CCNMAWriteRecord(record);
    }

    NSDictionary *status = CCNMABuildStatus(
        policy,
        servingSummary,
        record ?: existingRecord,
        decision,
        previous,
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