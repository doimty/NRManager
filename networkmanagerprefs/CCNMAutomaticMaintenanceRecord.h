#import <Foundation/Foundation.h>
#import "CCNMAutomaticMaintenanceDecision.h"
#import "CCNMN78PolicySupport.h"

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Durability: the daemon persists a maintenance record to track serving
// evidence, drop state, cooldown, and attempt consumption across restarts
// and crashes.  A separate bounded status plist publishes the current state
// for external observation (e.g. Settings, diagnostic export).
// ---------------------------------------------------------------------------

// File path (within the jailbreak root, resolved via CCNMPolicyRoot).
FOUNDATION_EXPORT NSString *CCNMAutomaticMaintenanceRecordPath(void);
FOUNDATION_EXPORT NSString *CCNMAutomaticMaintenanceStatusPath(void);

// ---------------------------------------------------------------------------
// Record schema keys (used as dictionary keys for the plist)
// ---------------------------------------------------------------------------

FOUNDATION_EXPORT NSString *const CCNMARecordSchemaVersionKey;
FOUNDATION_EXPORT NSString *const CCNMARecordOwnerKey;
FOUNDATION_EXPORT NSString *const CCNMARecordUpdatedAtKey;
FOUNDATION_EXPORT NSString *const CCNMARecordBootSessionUUIDKey;
FOUNDATION_EXPORT NSString *const CCNMARecordPolicyGenerationKey;
FOUNDATION_EXPORT NSString *const CCNMARecordBaselineCreatedAtKey;
FOUNDATION_EXPORT NSString *const CCNMARecordDeviceModelKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSystemVersionKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSystemBuildKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSubscriptionUUIDKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSlotIDKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilityReadSuccessKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilityN78SupportedKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilityN78ActiveKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilitySupportedNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilityActiveNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCapabilitySupportedRATKeysKey;
FOUNDATION_EXPORT NSString *const CCNMARecordPreviousSampleKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCurrentSampleKey;
FOUNDATION_EXPORT NSString *const CCNMARecordDropGenerationKey;
FOUNDATION_EXPORT NSString *const CCNMARecordDropRATKey;
FOUNDATION_EXPORT NSString *const CCNMARecordDropBandKey;
FOUNDATION_EXPORT NSString *const CCNMARecordAttemptConsumedKey;
FOUNDATION_EXPORT NSString *const CCNMARecordVerificationPendingKey;
FOUNDATION_EXPORT NSString *const CCNMARecordCooldownUntilKey;
FOUNDATION_EXPORT NSString *const CCNMARecordLastDecisionKey;
FOUNDATION_EXPORT NSString *const CCNMARecordLastDecisionAtKey;

// Sample sub-dictionary keys
FOUNDATION_EXPORT NSString *const CCNMARecordSampleValidKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSampleStaleKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSampleRATKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSampleBandKey;
FOUNDATION_EXPORT NSString *const CCNMARecordSampleSampledAtKey;

// ---------------------------------------------------------------------------
// Status plist keys (published for external observation)
// ---------------------------------------------------------------------------

FOUNDATION_EXPORT NSString *const CCNMAStatusSchemaVersionKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusUpdatedAtKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusBootSessionUUIDKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusPolicyEnabledKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusPolicyGenerationKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusRequestedModeKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusAppliedPolicyKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusRecoveryStateKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusServingStateKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusServingBandKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusServingFrequencyMHzKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusServingSampledAtKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusPreviousSampleValidKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusPreviousSampleRATKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusPreviousSampleBandKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCurrentSampleValidKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCurrentSampleRATKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCurrentSampleBandKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusLastDecisionKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusLastDecisionAtKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusDropGenerationKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusAttemptConsumedKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCooldownUntilKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusUnsafeLatchKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilityReadSuccessKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilityN78SupportedKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilityN78ActiveKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilitySupportedNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilityActiveNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMAStatusCapabilitySupportedRATKeysKey;

// ---------------------------------------------------------------------------
// Decision name strings (for human-readable plist values)
// ---------------------------------------------------------------------------

FOUNDATION_EXPORT NSString *CCNMADecisionName(CCNMAutomaticMaintenanceDecision decision);
FOUNDATION_EXPORT NSString *CCNMARATName(CCNMAutomaticMaintenanceRAT rat);

// ---------------------------------------------------------------------------
// Record creation
// ---------------------------------------------------------------------------

// Build a new or updated record from the current daemon state.
// Returns nil if the input is invalid (no boot session, etc.).
FOUNDATION_EXPORT NSDictionary * _Nullable CCNMABuildRecord(NSDictionary *policySummary,
                                                             NSDictionary *identity,
                                                             CCNMAutomaticMaintenanceSample previous,
                                                             CCNMAutomaticMaintenanceSample current,
                                                             NSUInteger policyGeneration,
                                                             NSNumber *baselineCreatedAt,
                                                             CCNMAutomaticMaintenanceDecision decision,
                                                             NSDictionary * _Nullable existingRecord);

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

// Write the record plist atomically.  Returns YES on success.
FOUNDATION_EXPORT BOOL CCNMAWriteRecord(NSDictionary *record);
// Read the record plist.  Returns nil if absent or invalid.
FOUNDATION_EXPORT NSDictionary * _Nullable CCNMAReadRecord(void);
// Remove the record plist.  Returns YES if absent or successfully removed.
FOUNDATION_EXPORT BOOL CCNMADeleteRecord(void);

// Write the status plist atomically.  Returns YES on success.
FOUNDATION_EXPORT BOOL CCNMAWriteStatus(NSDictionary *status);
// Read the status plist.  Returns nil if absent or invalid.
FOUNDATION_EXPORT NSDictionary * _Nullable CCNMAReadStatus(void);

// ---------------------------------------------------------------------------
// Status construction
// ---------------------------------------------------------------------------

// Build a bounded status dictionary from the daemon's current state.
// Policy summary and serving summary are the dictionaries from the
// existing reader/provider.  Decision is the evaluation result.
FOUNDATION_EXPORT NSDictionary *CCNMABuildStatus(NSDictionary *policySummary,
                                                   NSDictionary *servingSummary,
                                                   NSDictionary * _Nullable record,
                                                   CCNMAutomaticMaintenanceDecision decision,
                                                   CCNMAutomaticMaintenanceSample previous,
                                                   CCNMAutomaticMaintenanceSample current,
                                                   BOOL unsafeLatch);

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

FOUNDATION_EXPORT BOOL CCNMAValidateRecord(NSDictionary *record);
FOUNDATION_EXPORT BOOL CCNMAValidateStatus(NSDictionary *status);

// Identity drift: returns YES if the record's identity snapshot matches the
// current device+SIM identity.
FOUNDATION_EXPORT BOOL CCNMARecordMatchesCurrentIdentity(NSDictionary *record,
                                                          NSDictionary *identity);

NS_ASSUME_NONNULL_END