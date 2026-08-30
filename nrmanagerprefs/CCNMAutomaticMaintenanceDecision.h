#ifndef CCNM_AUTOMATIC_MAINTENANCE_DECISION_H
#define CCNM_AUTOMATIC_MAINTENANCE_DECISION_H

#include <stdbool.h>
#include <stddef.h>
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
    /// A read-only daemon already recorded this exact non-target RAT+band as a
    /// correction candidate. This is not a consumed attempt and not verification:
    /// no setter has run.
    bool dropRecordedForCurrentSample;
    bool unsafeOutstanding;
    /// The NR bands the policy pinned, as an ascending set. Any band in this set
    /// is a legitimate place for the device to rest: the policy narrowed the
    /// allowed list, it did not demand one specific serving band. A NULL pointer,
    /// a zero count, or any non-positive entry means there is no target the daemon
    /// can maintain, and it must refuse rather than guess.
    const int *targetBands;
    size_t targetBandCount;
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
    CCNMAutomaticMaintenanceDropRecorded,
    CCNMAutomaticMaintenanceCorrectOnce,
    CCNMAutomaticMaintenanceStopAttemptExhausted,
    CCNMAutomaticMaintenanceStopIncompatible,
    CCNMAutomaticMaintenanceStopUnsafe,
} CCNMAutomaticMaintenanceDecision;

CCNMAutomaticMaintenanceDecision CCNMEvaluateAutomaticMaintenance(
    CCNMAutomaticMaintenanceInput input);

#endif
