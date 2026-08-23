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

static bool CCNMTargetSelectionIsUsable(const int *targetBands, size_t count) {
    if (targetBands == NULL || count == 0) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        if (targetBands[index] <= 0) {
            return false;
        }
    }
    return true;
}

/// Whether the sample is resting inside the pinned NR set.
///
/// Membership, not equality: with a chosen subset such as {41, 78} the device
/// serving on 41 is a success. Treating anything but one specific band as a
/// deviation would spend the boot's single correction attempt on a state that is
/// already correct.
static bool CCNMSampleIsTarget(CCNMAutomaticMaintenanceSample sample,
                               const int *targetBands,
                               size_t count) {
    if (sample.rat != CCNMAutomaticMaintenanceRATNR) {
        return false;
    }
    for (size_t index = 0; index < count; index++) {
        if (sample.band == targetBands[index]) {
            return true;
        }
    }
    return false;
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
    if (!input.capabilityCompatible ||
        !CCNMTargetSelectionIsUsable(input.targetBands, input.targetBandCount)) {
        return CCNMAutomaticMaintenanceStopIncompatible;
    }
    if (input.verificationPending) {
        return CCNMAutomaticMaintenanceVerificationPending;
    }
    if (!CCNMSamplesMatch(input.previous, input.current)) {
        return CCNMAutomaticMaintenanceAwaitEvidence;
    }
    if (CCNMSampleIsTarget(input.current, input.targetBands, input.targetBandCount)) {
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
