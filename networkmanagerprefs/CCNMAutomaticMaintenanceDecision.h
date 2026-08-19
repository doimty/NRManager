#ifndef CCNM_AUTOMATIC_MAINTENANCE_DECISION_H
#define CCNM_AUTOMATIC_MAINTENANCE_DECISION_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    CCNMAutomaticMaintenanceRATUnknown = 0,
    CCNMAutomaticMaintenanceRATLTE,
    CCNMAutomaticMaintenanceRATNR,
} CCNMAutomaticMaintenanceRAT;

typedef struct {
    bool valid;
    bool stale;
    bool unsafeOutstanding;
    CCNMAutomaticMaintenanceRAT rat;
    int band;
} CCNMAutomaticMaintenanceSample;

typedef struct {
    bool policyEnabled;
    bool capabilityCompatible;
    bool operationInProgress;
    bool verificationPending;
    bool attemptUsedForDrop;
    bool unsafeOutstanding;
    int targetBand;
    uint64_t nowMilliseconds;
    uint64_t cooldownUntilMilliseconds;
    CCNMAutomaticMaintenanceSample previous;
    CCNMAutomaticMaintenanceSample current;
} CCNMAutomaticMaintenanceInput;

typedef enum {
    CCNMAutomaticMaintenanceAwaitEvidence = 0,
    CCNMAutomaticMaintenanceDisabled,
    CCNMAutomaticMaintenanceTargetStable,
    CCNMAutomaticMaintenanceDeferBusy,
    CCNMAutomaticMaintenanceDeferCooldown,
    CCNMAutomaticMaintenanceVerificationPending,
    CCNMAutomaticMaintenanceCorrectOnce,
    CCNMAutomaticMaintenanceStopAttemptExhausted,
    CCNMAutomaticMaintenanceStopIncompatible,
    CCNMAutomaticMaintenanceStopUnsafe,
} CCNMAutomaticMaintenanceDecision;

CCNMAutomaticMaintenanceDecision CCNMEvaluateAutomaticMaintenance(
    CCNMAutomaticMaintenanceInput input);

#endif
