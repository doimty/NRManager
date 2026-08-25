#import "CCNMN78PolicySupport.h"

CCNMRequestedMode const CCNMRequestedModeSystemDefault = @"systemDefault";
CCNMRequestedMode const CCNMRequestedModeN78Preferred = @"n78Preferred";

CCNMAppliedPolicy const CCNMAppliedPolicyUnknown = @"unknown";
CCNMAppliedPolicy const CCNMAppliedPolicyApplying = @"applying";
CCNMAppliedPolicy const CCNMAppliedPolicyVerifiedSystemDefault = @"verifiedSystemDefault";
CCNMAppliedPolicy const CCNMAppliedPolicyVerifiedN78Only = @"verifiedN78Only";
CCNMAppliedPolicy const CCNMAppliedPolicyDiverged = @"diverged";
CCNMAppliedPolicy const CCNMAppliedPolicyRecoveryRequired = @"recoveryRequired";

CCNMServingState const CCNMServingStateNRN78 = @"nrN78";
CCNMServingState const CCNMServingStateNROther = @"nrOther";
CCNMServingState const CCNMServingStateLTE = @"lteBand";
CCNMServingState const CCNMServingStateOther = @"other";
CCNMServingState const CCNMServingStateUnknown = @"unknown";

CCNMRecoveryState const CCNMRecoveryStateClean = @"clean";
CCNMRecoveryState const CCNMRecoveryStateEnablePending = @"enablePending";
CCNMRecoveryState const CCNMRecoveryStateEnabledWithBaseline = @"enabledWithBaseline";
CCNMRecoveryState const CCNMRecoveryStateRestorePending = @"restorePending";
CCNMRecoveryState const CCNMRecoveryStateCarrierResetPending = @"carrierResetPending";
CCNMRecoveryState const CCNMRecoveryStateCarrierResetFailed = @"carrierResetFailed";
CCNMRecoveryState const CCNMRecoveryStateRebootRequired = @"rebootRequired";
CCNMRecoveryState const CCNMRecoveryStateRecoveryFailed = @"recoveryFailed";

CCNMN78PolicyErrorCode const CCNMN78PolicyErrorNone = @"none";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorBusy = @"busy";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUnsupportedTarget = @"unsupportedTarget";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUnsafeSubscription = @"unsafeSubscription";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorInvalidBandInfo = @"invalidBandInfo";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorN78Unavailable = @"n78Unavailable";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorInvalidRecords = @"invalidRecords";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorUUIDDrift = @"uuidDrift";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorBaselineIncompatible = @"baselineIncompatible";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorPersistence = @"persistence";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorSetterFailed = @"setterFailed";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorSetterUncertain = @"setterUncertain";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorReadBackMismatch = @"readBackMismatch";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorRecoveryRequired = @"recoveryRequired";
CCNMN78PolicyErrorCode const CCNMN78PolicyErrorCarrierResetFailed = @"carrierResetFailed";

NSString *const CCNMN78PolicySummarySuccessKey = @"success";
NSString *const CCNMN78PolicySummaryOperationKey = @"operation";
NSString *const CCNMN78PolicySummaryStateKey = @"state";
NSString *const CCNMN78PolicySummaryRequestedModeKey = @"requestedMode";
NSString *const CCNMN78PolicySummaryAppliedPolicyKey = @"appliedPolicy";
NSString *const CCNMN78PolicySummaryRecoveryStateKey = @"recoveryState";
NSString *const CCNMN78PolicySummaryErrorCodeKey = @"errorCode";
NSString *const CCNMN78PolicySummaryErrorKey = @"error";
NSString *const CCNMN78PolicySummaryRequiresRebootKey = @"requiresReboot";
NSString *const CCNMN78PolicySummaryMayWriteKey = @"mayWrite";
NSString *const CCNMN78PolicySummaryMayUninstallKey = @"mayUninstall";
NSString *const CCNMN78PolicySummaryTargetNRBandsKey = @"targetNRBands";

NSString *const CCNMN78PolicyDidChangeDarwinNotification =
    @"me.nixuge.networkmanager/n78-policy-changed";
