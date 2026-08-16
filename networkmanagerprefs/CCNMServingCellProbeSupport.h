#ifndef CCNM_SERVING_CELL_PROBE_SUPPORT_H
#define CCNM_SERVING_CELL_PROBE_SUPPORT_H

#include <stddef.h>
#include <string.h>

typedef enum {
    CCNMPublicNRFrequencyRangeUnknown = 0,
    CCNMPublicNRFrequencyRangeSub6,
    CCNMPublicNRFrequencyRangeMmWave,
    CCNMPublicNRFrequencyRangeSub6AndMmWave,
} CCNMPublicNRFrequencyRange;

typedef enum {
    CCNMCellMonitorSamplingFailed = 0,
    CCNMCellMonitorSamplingPartial,
    CCNMCellMonitorSamplingComplete,
} CCNMCellMonitorSamplingStatus;

typedef enum {
    CCNMNRObservationIndeterminatePartial = 0,
    CCNMNRObservationNotObservedComplete,
    CCNMNRObservationObserved,
} CCNMNRObservationStatus;

typedef enum {
    CCNMCellMonitorRefreshOncePerPhase = 0,
    CCNMCellMonitorRefreshBeforeEachCopy,
} CCNMCellMonitorRefreshPolicy;

typedef enum {
    CCNMCellMonitorOrchestrationDone = 0,
    CCNMCellMonitorOrchestrationRefresh,
    CCNMCellMonitorOrchestrationCopy,
} CCNMCellMonitorOrchestrationOperation;

typedef enum {
    CCNMCellMonitorOrchestrationSucceeded = 0,
    CCNMCellMonitorOrchestrationRecoverableFailure,
    CCNMCellMonitorOrchestrationTimedOut,
    CCNMCellMonitorOrchestrationInvocationException,
} CCNMCellMonitorOrchestrationOutcome;

typedef struct {
    size_t samplesPerPhase;
    size_t phaseIndex;
    size_t sampleIndex;
    CCNMCellMonitorOrchestrationOperation nextOperation;
    int abortedAfterTimeout;
    int abortedAfterInvocationException;
} CCNMCellMonitorOrchestrationState;

static inline CCNMCellMonitorOrchestrationState CCNMCellMonitorOrchestrationStart(
    size_t samplesPerPhase) {
    CCNMCellMonitorOrchestrationState state = {
        samplesPerPhase,
        0,
        0,
        samplesPerPhase > 0 ? CCNMCellMonitorOrchestrationRefresh
                            : CCNMCellMonitorOrchestrationDone,
        0,
        0,
    };
    return state;
}

static inline int CCNMCellMonitorOrchestrationIsDone(
    const CCNMCellMonitorOrchestrationState *state) {
    return !state || state->nextOperation == CCNMCellMonitorOrchestrationDone;
}

static inline int CCNMCellMonitorOrchestrationMatches(
    const CCNMCellMonitorOrchestrationState *state,
    size_t phaseIndex,
    size_t sampleIndex,
    CCNMCellMonitorOrchestrationOperation operation) {
    return state &&
           state->phaseIndex == phaseIndex &&
           state->sampleIndex == sampleIndex &&
           state->nextOperation == operation;
}

static inline void CCNMCellMonitorOrchestrationAdvanceSample(
    CCNMCellMonitorOrchestrationState *state) {
    state->sampleIndex++;
    if (state->sampleIndex >= state->samplesPerPhase) {
        state->phaseIndex++;
        state->sampleIndex = 0;
    }
    if (state->phaseIndex >= 2) {
        state->nextOperation = CCNMCellMonitorOrchestrationDone;
    } else if (state->phaseIndex == 0) {
        state->nextOperation = CCNMCellMonitorOrchestrationCopy;
    } else {
        state->nextOperation = CCNMCellMonitorOrchestrationRefresh;
    }
}

static inline int CCNMCellMonitorOrchestrationAdvance(
    CCNMCellMonitorOrchestrationState *state,
    CCNMCellMonitorOrchestrationOutcome outcome) {
    if (!state || state->nextOperation == CCNMCellMonitorOrchestrationDone) {
        return 0;
    }
    if (outcome == CCNMCellMonitorOrchestrationTimedOut) {
        state->abortedAfterTimeout = 1;
        state->nextOperation = CCNMCellMonitorOrchestrationDone;
        return 1;
    }
    if (outcome == CCNMCellMonitorOrchestrationInvocationException) {
        state->abortedAfterInvocationException = 1;
        state->nextOperation = CCNMCellMonitorOrchestrationDone;
        return 1;
    }
    if (outcome != CCNMCellMonitorOrchestrationSucceeded &&
        outcome != CCNMCellMonitorOrchestrationRecoverableFailure) {
        return 0;
    }

    if (state->nextOperation == CCNMCellMonitorOrchestrationRefresh) {
        if (outcome == CCNMCellMonitorOrchestrationSucceeded) {
            state->nextOperation = CCNMCellMonitorOrchestrationCopy;
        } else if (state->phaseIndex == 0) {
            state->phaseIndex = 1;
            state->sampleIndex = 0;
            state->nextOperation = CCNMCellMonitorOrchestrationRefresh;
        } else {
            CCNMCellMonitorOrchestrationAdvanceSample(state);
        }
        return 1;
    }

    CCNMCellMonitorOrchestrationAdvanceSample(state);
    return 1;
}

static inline int CCNMProbeWaitCompleted(long waitResult) {
    return waitResult == 0;
}

static inline int CCNMPrivateAsyncAttemptRequiresAbort(int timedOut,
                                                        int invocationException) {
    return timedOut || invocationException;
}

static inline int CCNMCellMonitorClassificationSymbolsAvailable(int hasCellTypeKey,
                                                                 int hasServingTypeValue,
                                                                 int hasRATKey) {
    return hasCellTypeKey && hasServingTypeValue && hasRATKey;
}

static inline CCNMCellMonitorSamplingStatus CCNMClassifyCellMonitorSamplingStatus(size_t requested,
                                                                                  size_t completed,
                                                                                  size_t successful) {
    if (requested > 0 && completed == requested && successful == requested) {
        return CCNMCellMonitorSamplingComplete;
    }
    if (successful > 0) {
        return CCNMCellMonitorSamplingPartial;
    }
    return CCNMCellMonitorSamplingFailed;
}

static inline int CCNMCellMonitorShouldRefresh(CCNMCellMonitorRefreshPolicy policy,
                                                size_t sampleIndex) {
    switch (policy) {
        case CCNMCellMonitorRefreshOncePerPhase:
            return sampleIndex == 0;
        case CCNMCellMonitorRefreshBeforeEachCopy:
            return 1;
        default:
            return 0;
    }
}

static inline size_t CCNMCellMonitorRequiredRefreshCount(CCNMCellMonitorRefreshPolicy policy,
                                                         size_t sampleCount) {
    if (sampleCount == 0) {
        return 0;
    }
    switch (policy) {
        case CCNMCellMonitorRefreshOncePerPhase:
            return 1;
        case CCNMCellMonitorRefreshBeforeEachCopy:
            return sampleCount;
        default:
            return 0;
    }
}

static inline CCNMCellMonitorSamplingStatus CCNMClassifyCellMonitorABSamplingStatus(
    size_t requestedSamples,
    size_t attemptedSamples,
    size_t callbackCompletedSamples,
    size_t apiSucceededSamples,
    size_t parsedSamples,
    size_t requestedRefreshes,
    size_t attemptedRefreshes,
    size_t callbackCompletedRefreshes,
    size_t succeededRefreshes) {
    if (requestedSamples > 0 &&
        requestedRefreshes > 0 &&
        attemptedSamples == requestedSamples &&
        callbackCompletedSamples == requestedSamples &&
        apiSucceededSamples == requestedSamples &&
        parsedSamples == requestedSamples &&
        attemptedRefreshes == requestedRefreshes &&
        callbackCompletedRefreshes == requestedRefreshes &&
        succeededRefreshes == requestedRefreshes) {
        return CCNMCellMonitorSamplingComplete;
    }
    if (parsedSamples > 0) {
        return CCNMCellMonitorSamplingPartial;
    }
    return CCNMCellMonitorSamplingFailed;
}

static inline CCNMNRObservationStatus CCNMClassifyNRObservationStatus(
    int explicitNRServingCellObserved,
    CCNMCellMonitorSamplingStatus samplingStatus) {
    if (explicitNRServingCellObserved) {
        return CCNMNRObservationObserved;
    }
    if (samplingStatus == CCNMCellMonitorSamplingComplete) {
        return CCNMNRObservationNotObservedComplete;
    }
    return CCNMNRObservationIndeterminatePartial;
}

static inline int CCNMCellMonitorRATIsNR(const char *rat) {
    return rat &&
           (strcmp(rat, "kCTCellMonitorRadioAccessTechnologyNR") == 0 ||
            strcmp(rat, "kCTCellMonitorRadioAccessTechnologyNRNSA") == 0);
}

static inline CCNMPublicNRFrequencyRange CCNMClassifyPublicNRFrequencyRange(unsigned int rawValue) {
    switch (rawValue) {
        case 4:
            return CCNMPublicNRFrequencyRangeSub6;
        case 8:
            return CCNMPublicNRFrequencyRangeMmWave;
        case 12:
            return CCNMPublicNRFrequencyRangeSub6AndMmWave;
        default:
            return CCNMPublicNRFrequencyRangeUnknown;
    }
}

#endif
