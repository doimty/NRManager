#include "CCNMAutomaticMaintenanceDecision.h"

static bool CCNMSampleIsClean(CCNMAutomaticMaintenanceSample sample) {
    return sample.valid && !sample.stale && !sample.unsafeOutstanding &&
        sample.rat != CCNMAutomaticMaintenanceRATUnknown && sample.band > 0;
}

static bool CCNMSamplesMatch(CCNMAutomaticMaintenanceSample first,
                             CCNMAutomaticMaintenanceSample second) {
    return CCNMSampleIsClean(first) && CCNMSampleIsClean(second) &&
        first.rat == second.rat && first.band == second.band;
}

static bool CCNMSampleIsTarget(CCNMAutomaticMaintenanceSample sample,
                               int targetBand) {
    return sample.rat == CCNMAutomaticMaintenanceRATNR &&
        sample.band == targetBand;
}

CCNMAutomaticMaintenanceDecision CCNMEvaluateAutomaticMaintenance(
    CCNMAutomaticMaintenanceInput input) {
    if (input.unsafeOutstanding || input.previous.unsafeOutstanding ||
        input.current.unsafeOutstanding) {
        return CCNMAutomaticMaintenanceStopUnsafe;
    }
    if (!input.policyEnabled) {
        return CCNMAutomaticMaintenanceDisabled;
    }
    if (!input.capabilityCompatible || input.targetBand <= 0) {
        return CCNMAutomaticMaintenanceStopIncompatible;
    }
    if (input.verificationPending) {
        return CCNMAutomaticMaintenanceVerificationPending;
    }
    if (!CCNMSamplesMatch(input.previous, input.current)) {
        return CCNMAutomaticMaintenanceAwaitEvidence;
    }
    if (CCNMSampleIsTarget(input.current, input.targetBand)) {
        return CCNMAutomaticMaintenanceTargetStable;
    }
    if (input.attemptUsedForDrop) {
        return CCNMAutomaticMaintenanceStopAttemptExhausted;
    }
    if (input.cooldownUntilMilliseconds > input.nowMilliseconds) {
        return CCNMAutomaticMaintenanceDeferCooldown;
    }
    if (input.operationInProgress) {
        return CCNMAutomaticMaintenanceDeferBusy;
    }
    return CCNMAutomaticMaintenanceCorrectOnce;
}
