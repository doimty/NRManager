#import "CCNMAutomaticMaintenanceRecord.h"
#import "CCNMN78PolicyReader.h"

#if __has_include(<roothide.h>)
#import <roothide.h>
#define CCNMPolicyRoot(path) jbroot(path)
#else
#define CCNMPolicyRoot(path) (path)
#endif

// ---------------------------------------------------------------------------
// Mark: constants
// ---------------------------------------------------------------------------

static NSString *const CCNMAOwner = @"me.nixuge.networkmanager.automatic-maintenance";
static NSString *const CCNMAServingCapabilityReadSuccessKey = @"capabilityReadSuccess";
static NSString *const CCNMAServingCapabilityN78SupportedKey = @"capabilityN78Supported";
static NSString *const CCNMAServingCapabilityN78ActiveKey = @"capabilityN78Active";
static NSString *const CCNMAServingCapabilitySupportedNRBandsKey = @"capabilitySupportedNRBands";
static NSString *const CCNMAServingCapabilityActiveNRBandsKey = @"capabilityActiveNRBands";
static NSString *const CCNMAServingCapabilitySupportedRATKeysKey = @"capabilitySupportedRATKeys";
static NSString *const CCNMAServingStateKey = @"state";
static NSString *const CCNMAServingBandKey = @"band";
static NSString *const CCNMAServingFrequencyMHzKey = @"frequencyMHz";
static NSString *const CCNMAServingSampledAtMillisecondsKey = @"sampledAtMilliseconds";
static const long long CCNMASchemaVersion = 1;
static const long long CCNMAStatusSchemaVersion = 1;

NSString *CCNMAutomaticMaintenanceRecordPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.maintenance.record.plist");
}

NSString *CCNMAutomaticMaintenanceStatusPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.maintenance.status.plist");
}

// ---------------------------------------------------------------------------
// Mark: record keys
// ---------------------------------------------------------------------------

NSString *const CCNMARecordSchemaVersionKey = @"schemaVersion";
NSString *const CCNMARecordOwnerKey = @"owner";
NSString *const CCNMARecordUpdatedAtKey = @"updatedAt";
NSString *const CCNMARecordBootSessionUUIDKey = @"bootSessionUUID";
NSString *const CCNMARecordPolicyGenerationKey = @"policyGeneration";
NSString *const CCNMARecordBaselineCreatedAtKey = @"baselineCreatedAt";
NSString *const CCNMARecordDeviceModelKey = @"deviceModel";
NSString *const CCNMARecordSystemVersionKey = @"systemVersion";
NSString *const CCNMARecordSystemBuildKey = @"systemBuild";
NSString *const CCNMARecordSubscriptionUUIDKey = @"subscriptionUUID";
NSString *const CCNMARecordSlotIDKey = @"slotID";
NSString *const CCNMARecordCapabilityReadSuccessKey = @"capabilityReadSuccess";
NSString *const CCNMARecordCapabilityN78SupportedKey = @"capabilityN78Supported";
NSString *const CCNMARecordCapabilityN78ActiveKey = @"capabilityN78Active";
NSString *const CCNMARecordCapabilitySupportedNRBandsKey = @"capabilitySupportedNRBands";
NSString *const CCNMARecordCapabilityActiveNRBandsKey = @"capabilityActiveNRBands";
NSString *const CCNMARecordCapabilitySupportedRATKeysKey = @"capabilitySupportedRATKeys";
NSString *const CCNMARecordPreviousSampleKey = @"previousSample";
NSString *const CCNMARecordCurrentSampleKey = @"currentSample";
NSString *const CCNMARecordDropGenerationKey = @"dropGeneration";
NSString *const CCNMARecordDropRATKey = @"dropRAT";
NSString *const CCNMARecordDropBandKey = @"dropBand";
NSString *const CCNMARecordAttemptConsumedKey = @"attemptConsumed";
NSString *const CCNMARecordVerificationPendingKey = @"verificationPending";
NSString *const CCNMARecordCooldownUntilKey = @"cooldownUntil";
NSString *const CCNMARecordLastDecisionKey = @"lastDecision";
NSString *const CCNMARecordLastDecisionAtKey = @"lastDecisionAt";

NSString *const CCNMARecordSampleValidKey = @"valid";
NSString *const CCNMARecordSampleStaleKey = @"stale";
NSString *const CCNMARecordSampleRATKey = @"rat";
NSString *const CCNMARecordSampleBandKey = @"band";
NSString *const CCNMARecordSampleSampledAtKey = @"sampledAt";

// ---------------------------------------------------------------------------
// Mark: status keys
// ---------------------------------------------------------------------------

NSString *const CCNMAStatusSchemaVersionKey = @"schemaVersion";
NSString *const CCNMAStatusUpdatedAtKey = @"updatedAt";
NSString *const CCNMAStatusBootSessionUUIDKey = @"bootSessionUUID";
NSString *const CCNMAStatusPolicyEnabledKey = @"policyEnabled";
NSString *const CCNMAStatusPolicyGenerationKey = @"policyGeneration";
NSString *const CCNMAStatusRequestedModeKey = @"requestedMode";
NSString *const CCNMAStatusAppliedPolicyKey = @"appliedPolicy";
NSString *const CCNMAStatusRecoveryStateKey = @"recoveryState";
NSString *const CCNMAStatusServingStateKey = @"servingState";
NSString *const CCNMAStatusServingBandKey = @"servingBand";
NSString *const CCNMAStatusServingFrequencyMHzKey = @"servingFrequencyMHz";
NSString *const CCNMAStatusServingSampledAtKey = @"servingSampledAt";
NSString *const CCNMAStatusPreviousSampleValidKey = @"previousSampleValid";
NSString *const CCNMAStatusPreviousSampleRATKey = @"previousSampleRAT";
NSString *const CCNMAStatusPreviousSampleBandKey = @"previousSampleBand";
NSString *const CCNMAStatusCurrentSampleValidKey = @"currentSampleValid";
NSString *const CCNMAStatusCurrentSampleRATKey = @"currentSampleRAT";
NSString *const CCNMAStatusCurrentSampleBandKey = @"currentSampleBand";
NSString *const CCNMAStatusLastDecisionKey = @"lastDecision";
NSString *const CCNMAStatusLastDecisionAtKey = @"lastDecisionAt";
NSString *const CCNMAStatusDropGenerationKey = @"dropGeneration";
NSString *const CCNMAStatusAttemptConsumedKey = @"attemptConsumed";
NSString *const CCNMAStatusCooldownUntilKey = @"cooldownUntil";
NSString *const CCNMAStatusUnsafeLatchKey = @"unsafeLatch";
NSString *const CCNMAStatusCapabilityReadSuccessKey = @"capabilityReadSuccess";
NSString *const CCNMAStatusCapabilityN78SupportedKey = @"capabilityN78Supported";
NSString *const CCNMAStatusCapabilityN78ActiveKey = @"capabilityN78Active";
NSString *const CCNMAStatusCapabilitySupportedNRBandsKey = @"capabilitySupportedNRBands";
NSString *const CCNMAStatusCapabilityActiveNRBandsKey = @"capabilityActiveNRBands";
NSString *const CCNMAStatusCapabilitySupportedRATKeysKey = @"capabilitySupportedRATKeys";

// ---------------------------------------------------------------------------
// Mark: name helpers
// ---------------------------------------------------------------------------

NSString *CCNMADecisionName(CCNMAutomaticMaintenanceDecision decision) {
    switch (decision) {
        case CCNMAutomaticMaintenanceAwaitEvidence:
            return @"awaitEvidence";
        case CCNMAutomaticMaintenanceDisabled:
            return @"disabled";
        case CCNMAutomaticMaintenanceTargetStable:
            return @"targetStable";
        case CCNMAutomaticMaintenanceDeferBusy:
            return @"deferBusy";
        case CCNMAutomaticMaintenanceDeferCooldown:
            return @"deferCooldown";
        case CCNMAutomaticMaintenanceVerificationPending:
            return @"verificationPending";
        case CCNMAutomaticMaintenanceCorrectOnce:
            return @"correctOnce";
        case CCNMAutomaticMaintenanceStopAttemptExhausted:
            return @"stopAttemptExhausted";
        case CCNMAutomaticMaintenanceStopIncompatible:
            return @"stopIncompatible";
        case CCNMAutomaticMaintenanceStopUnsafe:
            return @"stopUnsafe";
    }
    return @"unknown";
}

NSString *CCNMARATName(CCNMAutomaticMaintenanceRAT rat) {
    switch (rat) {
        case CCNMAutomaticMaintenanceRATLTE:
            return @"lte";
        case CCNMAutomaticMaintenanceRATNR:
            return @"nr";
        default:
            return @"unknown";
    }
}

// ---------------------------------------------------------------------------
// Mark: sample dictionary helpers
// ---------------------------------------------------------------------------

static NSDictionary *CCNMASampleDictionary(CCNMAutomaticMaintenanceSample sample,
                                            long long sampledAt) {
    return @{
        CCNMARecordSampleValidKey: @(sample.valid),
        CCNMARecordSampleStaleKey: @(sample.stale),
        CCNMARecordSampleRATKey: @(sample.rat),
        CCNMARecordSampleBandKey: @(sample.band),
        CCNMARecordSampleSampledAtKey: @(sampledAt)
    };
}

// ---------------------------------------------------------------------------
// Mark: file write helpers
// ---------------------------------------------------------------------------

static BOOL CCNMAWritePlistAtomically(NSDictionary *dictionary, NSString *path) {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSString *tempPath = [path stringByAppendingString:@".part"];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data) {
        return NO;
    }
    if (![data writeToFile:tempPath options:NSDataWritingAtomic error:&error]) {
        return NO;
    }
    if (rename(tempPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        // Clean up the temp file on failure.
        (void)[[NSFileManager defaultManager] removeItemAtPath:tempPath error:NULL];
        return NO;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Mark: record creation
// ---------------------------------------------------------------------------

static BOOL CCNMAIdentitySnapshotMatchesRecord(NSDictionary *record,
                                                 NSDictionary *identity) {
    if (![record isKindOfClass:NSDictionary.class] ||
        ![identity isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    for (NSString *key in @[
        CCNMARecordDeviceModelKey,
        CCNMARecordSystemVersionKey,
        CCNMARecordSystemBuildKey,
        CCNMARecordSubscriptionUUIDKey
    ]) {
        NSString *saved = [record[key] isKindOfClass:NSString.class] ? record[key] : nil;
        NSString *current = [identity[key] isKindOfClass:NSString.class] ? identity[key] : nil;
        if (!saved || !current || ![saved isEqualToString:current]) {
            return NO;
        }
    }
    for (NSString *key in @[
        CCNMARecordCapabilityReadSuccessKey,
        CCNMARecordCapabilityN78SupportedKey,
        CCNMARecordCapabilityN78ActiveKey
    ]) {
        if (![record[key] isKindOfClass:NSNumber.class] ||
            ![identity[key] isKindOfClass:NSNumber.class] ||
            ![record[key] isEqual:identity[key]]) {
            return NO;
        }
    }
    for (NSString *key in @[
        CCNMARecordCapabilitySupportedNRBandsKey,
        CCNMARecordCapabilityActiveNRBandsKey,
        CCNMARecordCapabilitySupportedRATKeysKey
    ]) {
        if (![record[key] isKindOfClass:NSArray.class] ||
            ![identity[key] isKindOfClass:NSArray.class] ||
            ![record[key] isEqualToArray:identity[key]]) {
            return NO;
        }
    }
    return YES;
}

NSDictionary *CCNMABuildRecord(NSDictionary *policySummary,
                                NSDictionary *identity,
                                CCNMAutomaticMaintenanceSample previous,
                                CCNMAutomaticMaintenanceSample current,
                                NSUInteger policyGeneration,
                                NSNumber *baselineCreatedAt,
                                CCNMAutomaticMaintenanceDecision decision,
                                NSDictionary *existingRecord) {
    NSString *bootSession = CCNMBootSessionIdentity();
    if (!bootSession) {
        return nil;
    }
    NSString *deviceModel = [identity[@"deviceModel"] isKindOfClass:NSString.class]
        ? identity[@"deviceModel"] : nil;
    NSString *systemVersion = [identity[@"systemVersion"] isKindOfClass:NSString.class]
        ? identity[@"systemVersion"] : nil;
    NSString *systemBuild = [identity[@"systemBuild"] isKindOfClass:NSString.class]
        ? identity[@"systemBuild"] : nil;
    NSString *subscriptionUUID = [identity[@"subscriptionUUID"] isKindOfClass:NSString.class]
        ? identity[@"subscriptionUUID"] : nil;
    NSNumber *slotID = [identity[@"slotID"] isKindOfClass:NSNumber.class]
        ? identity[@"slotID"] : @1;
    if (!deviceModel.length || !systemVersion.length || !systemBuild.length) {
        return nil;
    }

    NSNumber *capabilityReadSuccess = [identity[CCNMARecordCapabilityReadSuccessKey] isKindOfClass:NSNumber.class]
        ? identity[CCNMARecordCapabilityReadSuccessKey] : @NO;
    NSNumber *capabilityN78Supported = [identity[CCNMARecordCapabilityN78SupportedKey] isKindOfClass:NSNumber.class]
        ? identity[CCNMARecordCapabilityN78SupportedKey] : @NO;
    NSNumber *capabilityN78Active = [identity[CCNMARecordCapabilityN78ActiveKey] isKindOfClass:NSNumber.class]
        ? identity[CCNMARecordCapabilityN78ActiveKey] : @NO;
    NSArray *supportedNRBands = [identity[CCNMARecordCapabilitySupportedNRBandsKey] isKindOfClass:NSArray.class]
        ? identity[CCNMARecordCapabilitySupportedNRBandsKey] : @[];
    NSArray *activeNRBands = [identity[CCNMARecordCapabilityActiveNRBandsKey] isKindOfClass:NSArray.class]
        ? identity[CCNMARecordCapabilityActiveNRBandsKey] : @[];
    NSArray *supportedRATKeys = [identity[CCNMARecordCapabilitySupportedRATKeysKey] isKindOfClass:NSArray.class]
        ? identity[CCNMARecordCapabilitySupportedRATKeysKey] : @[];

    // Carry forward drop state only when boot and the full identity/capability
    // snapshot are unchanged. A new SIM or capability shape starts clean.
    BOOL sameBoot = [existingRecord[CCNMARecordBootSessionUUIDKey] isEqual:bootSession];
    BOOL sameIdentity = sameBoot && CCNMAIdentitySnapshotMatchesRecord(existingRecord, identity);
    NSUInteger dropGeneration = sameIdentity
        ? [existingRecord[CCNMARecordDropGenerationKey] unsignedIntegerValue] : 0;
    NSNumber *dropRAT = sameIdentity ? existingRecord[CCNMARecordDropRATKey] : nil;
    NSNumber *dropBand = sameIdentity ? existingRecord[CCNMARecordDropBandKey] : nil;
    BOOL attemptConsumed = sameIdentity &&
        [existingRecord[CCNMARecordAttemptConsumedKey] boolValue];
    BOOL verificationPending = sameIdentity &&
        [existingRecord[CCNMARecordVerificationPendingKey] boolValue];
    NSNumber *cooldownUntil = sameIdentity
        ? existingRecord[CCNMARecordCooldownUntilKey] : nil;

    // When the decision is CorrectOnce, check if we need to record a new drop.
    // The decision module already verified two matching clean non-target samples.
    BOOL isCorrectOnce = (decision == CCNMAutomaticMaintenanceCorrectOnce);
    // If the identity changed, start a fresh generation. Otherwise a second
    // CorrectOnce after an unconsumed drop records the same boot-local drop.
    if (isCorrectOnce && (!sameIdentity || !attemptConsumed)) {
        dropGeneration = sameIdentity ? dropGeneration + 1 : 1;
        dropRAT = @(current.rat);
        dropBand = @(current.band);
        attemptConsumed = NO;
        verificationPending = YES;
        cooldownUntil = nil;
    }

    long long now = CCNMUnixMilliseconds();
    long long sampledAt = now;

    NSMutableDictionary *record = [@{
        CCNMARecordSchemaVersionKey: @(CCNMASchemaVersion),
        CCNMARecordOwnerKey: CCNMAOwner,
        CCNMARecordUpdatedAtKey: @(now),
        CCNMARecordBootSessionUUIDKey: bootSession,
        CCNMARecordPolicyGenerationKey: @(policyGeneration),
        CCNMARecordDeviceModelKey: deviceModel,
        CCNMARecordSystemVersionKey: systemVersion,
        CCNMARecordSystemBuildKey: systemBuild,
        CCNMARecordSubscriptionUUIDKey: subscriptionUUID ?: @"",
        CCNMARecordSlotIDKey: slotID,
        CCNMARecordCapabilityReadSuccessKey: capabilityReadSuccess,
        CCNMARecordCapabilityN78SupportedKey: capabilityN78Supported,
        CCNMARecordCapabilityN78ActiveKey: capabilityN78Active,
        CCNMARecordCapabilitySupportedNRBandsKey: supportedNRBands,
        CCNMARecordCapabilityActiveNRBandsKey: activeNRBands,
        CCNMARecordCapabilitySupportedRATKeysKey: supportedRATKeys,
        CCNMARecordPreviousSampleKey: CCNMASampleDictionary(previous, sampledAt),
        CCNMARecordCurrentSampleKey: CCNMASampleDictionary(current, sampledAt),
        CCNMARecordDropGenerationKey: @(dropGeneration),
        CCNMARecordAttemptConsumedKey: @(attemptConsumed),
        CCNMARecordVerificationPendingKey: @(verificationPending),
        CCNMARecordLastDecisionKey: CCNMADecisionName(decision),
        CCNMARecordLastDecisionAtKey: @(now)
    } mutableCopy];

    if (baselineCreatedAt) {
        record[CCNMARecordBaselineCreatedAtKey] = baselineCreatedAt;
    }
    if (dropRAT) {
        record[CCNMARecordDropRATKey] = dropRAT;
    }
    if (dropBand) {
        record[CCNMARecordDropBandKey] = dropBand;
    }
    if (cooldownUntil) {
        record[CCNMARecordCooldownUntilKey] = cooldownUntil;
    }

    return [record copy];
}

// ---------------------------------------------------------------------------
// Mark: record persistence
// ---------------------------------------------------------------------------

BOOL CCNMAWriteRecord(NSDictionary *record) {
    return CCNMAWritePlistAtomically(record, CCNMAutomaticMaintenanceRecordPath());
}

NSDictionary *CCNMAReadRecord(void) {
    BOOL exists = NO;
    NSDictionary *record = CCNMLoadRecord(CCNMAutomaticMaintenanceRecordPath(), &exists);
    if (!exists) {
        return nil;
    }
    if (!CCNMAValidateRecord(record)) {
        return nil;
    }
    return record;
}

BOOL CCNMADeleteRecord(void) {
    NSString *path = CCNMAutomaticMaintenanceRecordPath();
    if (!CCNMFileExists(path)) {
        return YES;
    }
    return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

// ---------------------------------------------------------------------------
// Mark: status persistence
// ---------------------------------------------------------------------------

BOOL CCNMAWriteStatus(NSDictionary *status) {
    return CCNMAWritePlistAtomically(status, CCNMAutomaticMaintenanceStatusPath());
}

NSDictionary *CCNMAReadStatus(void) {
    BOOL exists = NO;
    NSDictionary *status = CCNMLoadRecord(CCNMAutomaticMaintenanceStatusPath(), &exists);
    if (!exists) {
        return nil;
    }
    if (!CCNMAValidateStatus(status)) {
        return nil;
    }
    return status;
}

// ---------------------------------------------------------------------------
// Mark: status construction
// ---------------------------------------------------------------------------

NSDictionary *CCNMABuildStatus(NSDictionary *policySummary,
                                NSDictionary *servingSummary,
                                NSDictionary *record,
                                CCNMAutomaticMaintenanceDecision decision,
                                CCNMAutomaticMaintenanceSample previous,
                                CCNMAutomaticMaintenanceSample current,
                                BOOL unsafeLatch) {
    long long now = CCNMUnixMilliseconds();
    NSString *bootSession = CCNMBootSessionIdentity() ?: @"";

    // Policy fields
    NSString *requestedMode = policySummary[CCNMN78PolicySummaryRequestedModeKey] ?: @"";
    NSString *appliedPolicy = policySummary[CCNMN78PolicySummaryAppliedPolicyKey] ?: @"";
    NSString *recoveryState = policySummary[CCNMN78PolicySummaryRecoveryStateKey] ?: @"";
    BOOL policyEnabled = [requestedMode isEqual:CCNMRequestedModeN78Preferred] &&
        [appliedPolicy isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [recoveryState isEqual:CCNMRecoveryStateEnabledWithBaseline];

    // Serving fields
    NSString *servingState = [servingSummary[CCNMAServingStateKey] isKindOfClass:NSString.class]
        ? servingSummary[CCNMAServingStateKey] : @"";
    NSNumber *servingBand = [servingSummary[CCNMAServingBandKey] isKindOfClass:NSNumber.class]
        ? servingSummary[CCNMAServingBandKey] : @0;
    NSNumber *servingFrequency = [servingSummary[CCNMAServingFrequencyMHzKey] isKindOfClass:NSNumber.class]
        ? servingSummary[CCNMAServingFrequencyMHzKey] : nil;
    NSNumber *servingSampledAt = [servingSummary[CCNMAServingSampledAtMillisecondsKey] isKindOfClass:NSNumber.class]
        ? servingSummary[CCNMAServingSampledAtMillisecondsKey] : nil;

    // Record-derived fields
    NSUInteger dropGeneration = 0;
    BOOL attemptConsumed = NO;
    NSNumber *cooldownUntil = nil;
    if ([record isKindOfClass:NSDictionary.class]) {
        dropGeneration = [record[CCNMARecordDropGenerationKey] unsignedIntegerValue];
        attemptConsumed = [record[CCNMARecordAttemptConsumedKey] boolValue];
        cooldownUntil = record[CCNMARecordCooldownUntilKey];
    }

    NSMutableDictionary *status = [@{
        CCNMAStatusSchemaVersionKey: @(CCNMAStatusSchemaVersion),
        CCNMAStatusUpdatedAtKey: @(now),
        CCNMAStatusBootSessionUUIDKey: bootSession,
        CCNMAStatusPolicyEnabledKey: @(policyEnabled),
        CCNMAStatusPolicyGenerationKey: policySummary[@"operationGeneration"] ?: @0,
        CCNMAStatusRequestedModeKey: requestedMode,
        CCNMAStatusAppliedPolicyKey: appliedPolicy,
        CCNMAStatusRecoveryStateKey: recoveryState,
        CCNMAStatusServingStateKey: servingState,
        CCNMAStatusServingBandKey: servingBand,
        CCNMAStatusServingSampledAtKey: servingSampledAt ?: @(now),
        CCNMAStatusPreviousSampleValidKey: @(previous.valid),
        CCNMAStatusPreviousSampleRATKey: CCNMARATName(previous.rat),
        CCNMAStatusPreviousSampleBandKey: @(previous.band),
        CCNMAStatusCurrentSampleValidKey: @(current.valid),
        CCNMAStatusCurrentSampleRATKey: CCNMARATName(current.rat),
        CCNMAStatusCurrentSampleBandKey: @(current.band),
        CCNMAStatusCapabilityReadSuccessKey: servingSummary[CCNMAServingCapabilityReadSuccessKey] ?: @NO,
        CCNMAStatusCapabilityN78SupportedKey: servingSummary[CCNMAServingCapabilityN78SupportedKey] ?: @NO,
        CCNMAStatusCapabilityN78ActiveKey: servingSummary[CCNMAServingCapabilityN78ActiveKey] ?: @NO,
        CCNMAStatusCapabilitySupportedNRBandsKey: servingSummary[CCNMAServingCapabilitySupportedNRBandsKey] ?: @[],
        CCNMAStatusCapabilityActiveNRBandsKey: servingSummary[CCNMAServingCapabilityActiveNRBandsKey] ?: @[],
        CCNMAStatusCapabilitySupportedRATKeysKey: servingSummary[CCNMAServingCapabilitySupportedRATKeysKey] ?: @[],
        CCNMAStatusLastDecisionKey: CCNMADecisionName(decision),
        CCNMAStatusLastDecisionAtKey: @(now),
        CCNMAStatusDropGenerationKey: @(dropGeneration),
        CCNMAStatusAttemptConsumedKey: @(attemptConsumed),
        CCNMAStatusUnsafeLatchKey: @(unsafeLatch)
    } mutableCopy];

    if (servingFrequency) {
        status[CCNMAStatusServingFrequencyMHzKey] = servingFrequency;
    }
    if (cooldownUntil) {
        status[CCNMAStatusCooldownUntilKey] = cooldownUntil;
    }

    return [status copy];
}

// ---------------------------------------------------------------------------
// Mark: validation
// ---------------------------------------------------------------------------

BOOL CCNMAValidateRecord(NSDictionary *record) {
    if (![record isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    if (![record[CCNMARecordSchemaVersionKey] isEqual:@(CCNMASchemaVersion)]) {
        return NO;
    }
    if (![record[CCNMARecordOwnerKey] isEqual:CCNMAOwner]) {
        return NO;
    }
    if (![record[CCNMARecordUpdatedAtKey] isKindOfClass:NSNumber.class] ||
        [record[CCNMARecordUpdatedAtKey] longLongValue] <= 0) {
        return NO;
    }
    if (CCNMCanonicalUUIDString(record[CCNMARecordBootSessionUUIDKey]) == nil) {
        return NO;
    }
    if (![record[CCNMARecordPolicyGenerationKey] isKindOfClass:NSNumber.class]) {
        return NO;
    }
    if (![record[CCNMARecordDeviceModelKey] isKindOfClass:NSString.class] ||
        [record[CCNMARecordDeviceModelKey] length] == 0) {
        return NO;
    }
    if (![record[CCNMARecordSystemVersionKey] isKindOfClass:NSString.class] ||
        [record[CCNMARecordSystemVersionKey] length] == 0) {
        return NO;
    }
    if (![record[CCNMARecordSystemBuildKey] isKindOfClass:NSString.class] ||
        [record[CCNMARecordSystemBuildKey] length] == 0) {
        return NO;
    }
    if (record[CCNMARecordCapabilityReadSuccessKey] != nil &&
        (![record[CCNMARecordCapabilityReadSuccessKey] isKindOfClass:NSNumber.class] ||
         ![record[CCNMARecordCapabilityN78SupportedKey] isKindOfClass:NSNumber.class] ||
         ![record[CCNMARecordCapabilityN78ActiveKey] isKindOfClass:NSNumber.class] ||
         ![record[CCNMARecordCapabilitySupportedNRBandsKey] isKindOfClass:NSArray.class] ||
         ![record[CCNMARecordCapabilityActiveNRBandsKey] isKindOfClass:NSArray.class] ||
         ![record[CCNMARecordCapabilitySupportedRATKeysKey] isKindOfClass:NSArray.class])) {
        return NO;
    }
    // Samples are optional (may be absent on first boot).
    if (record[CCNMARecordPreviousSampleKey] != nil &&
        ![record[CCNMARecordPreviousSampleKey] isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    if (record[CCNMARecordCurrentSampleKey] != nil &&
        ![record[CCNMARecordCurrentSampleKey] isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    if (![record[CCNMARecordDropGenerationKey] isKindOfClass:NSNumber.class]) {
        return NO;
    }
    if (![record[CCNMARecordAttemptConsumedKey] isKindOfClass:NSNumber.class]) {
        return NO;
    }
    if (![record[CCNMARecordLastDecisionKey] isKindOfClass:NSString.class]) {
        return NO;
    }
    return YES;
}

BOOL CCNMAValidateStatus(NSDictionary *status) {
    if (![status isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    if (![status[CCNMAStatusSchemaVersionKey] isEqual:@(CCNMAStatusSchemaVersion)]) {
        return NO;
    }
    if (![status[CCNMAStatusUpdatedAtKey] isKindOfClass:NSNumber.class] ||
        [status[CCNMAStatusUpdatedAtKey] longLongValue] <= 0) {
        return NO;
    }
    if (![status[CCNMAStatusPolicyEnabledKey] isKindOfClass:NSNumber.class]) {
        return NO;
    }
    return YES;
}

BOOL CCNMARecordMatchesCurrentIdentity(NSDictionary *record,
                                        NSDictionary *identity) {
    if (![record isKindOfClass:NSDictionary.class] ||
        ![identity isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSString *recordDevice = record[CCNMARecordDeviceModelKey];
    NSString *currentDevice = identity[@"deviceModel"];
    if (![recordDevice isKindOfClass:NSString.class] ||
        ![currentDevice isKindOfClass:NSString.class] ||
        ![recordDevice isEqual:currentDevice]) {
        return NO;
    }
    NSString *recordVersion = record[CCNMARecordSystemVersionKey];
    NSString *currentVersion = identity[@"systemVersion"];
    if (![recordVersion isKindOfClass:NSString.class] ||
        ![currentVersion isKindOfClass:NSString.class] ||
        ![recordVersion isEqual:currentVersion]) {
        return NO;
    }
    NSString *recordBuild = record[CCNMARecordSystemBuildKey];
    NSString *currentBuild = identity[@"systemBuild"];
    if (![recordBuild isKindOfClass:NSString.class] ||
        ![currentBuild isKindOfClass:NSString.class] ||
        ![recordBuild isEqual:currentBuild]) {
        return NO;
    }
    NSString *recordUUID = record[CCNMARecordSubscriptionUUIDKey];
    id currentUUID = identity[@"subscriptionUUID"];
    if ([recordUUID isKindOfClass:NSString.class] && recordUUID.length > 0 &&
        (![currentUUID isKindOfClass:NSString.class] || ((NSString *)currentUUID).length == 0 ||
         ![recordUUID isEqual:currentUUID])) {
        return NO;
    }
    if (record[CCNMARecordCapabilityReadSuccessKey] == nil ||
        !CCNMAIdentitySnapshotMatchesRecord(record, identity)) {
        return NO;
    }
    return YES;
}