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

static inline int CCNMProbeWaitCompleted(long waitResult) {
    return waitResult == 0;
}

typedef enum {
    CCNMCellMonitorSamplingFailed = 0,
    CCNMCellMonitorSamplingPartial,
    CCNMCellMonitorSamplingComplete,
} CCNMCellMonitorSamplingStatus;

typedef enum {
    CCNMAdaptiveSamplerStopRunning = 0,
    CCNMAdaptiveSamplerStopExplicitNRConfirmed,
    CCNMAdaptiveSamplerStopStableServingConfirmed,
    CCNMAdaptiveSamplerStopWindowExhausted,
    CCNMAdaptiveSamplerStopTimedOut,
    CCNMAdaptiveSamplerStopInvocationException,
    CCNMAdaptiveSamplerStopInvalidConfiguration,
} CCNMAdaptiveSamplerStopReason;

typedef enum {
    CCNMAdaptiveSamplerPolicyEarlyNR = 0,
    CCNMAdaptiveSamplerPolicyFullWindow,
    CCNMAdaptiveSamplerPolicyStableServing,
} CCNMAdaptiveSamplerPolicy;

typedef struct {
    size_t maximumSampleCount;
    size_t requiredConsecutiveNRSampleCount;
    size_t consumedSampleCount;
    size_t consecutiveNRSampleCount;
    size_t explicitNRSampleCount;
    size_t consecutiveStableServingSampleCount;
    CCNMAdaptiveSamplerPolicy policy;
    CCNMAdaptiveSamplerStopReason stopReason;
} CCNMAdaptiveSamplerState;

static inline CCNMAdaptiveSamplerState CCNMAdaptiveSamplerStartWithPolicy(
    size_t maximumSampleCount,
    size_t requiredConsecutiveNRSampleCount,
    CCNMAdaptiveSamplerPolicy policy
) {
    CCNMAdaptiveSamplerState state = {
        .maximumSampleCount = maximumSampleCount,
        .requiredConsecutiveNRSampleCount = requiredConsecutiveNRSampleCount,
        .consumedSampleCount = 0,
        .consecutiveNRSampleCount = 0,
        .explicitNRSampleCount = 0,
        .consecutiveStableServingSampleCount = 0,
        .policy = policy,
        .stopReason = CCNMAdaptiveSamplerStopRunning,
    };
    if (maximumSampleCount == 0 || requiredConsecutiveNRSampleCount == 0 ||
        requiredConsecutiveNRSampleCount > maximumSampleCount ||
        (policy != CCNMAdaptiveSamplerPolicyEarlyNR &&
         policy != CCNMAdaptiveSamplerPolicyFullWindow &&
         policy != CCNMAdaptiveSamplerPolicyStableServing)) {
        state.stopReason = CCNMAdaptiveSamplerStopInvalidConfiguration;
    }
    return state;
}

static inline CCNMAdaptiveSamplerState CCNMAdaptiveSamplerStart(
    size_t maximumSampleCount,
    size_t requiredConsecutiveNRSampleCount
) {
    return CCNMAdaptiveSamplerStartWithPolicy(
        maximumSampleCount,
        requiredConsecutiveNRSampleCount,
        CCNMAdaptiveSamplerPolicyEarlyNR);
}

static inline int CCNMAdaptiveSamplerShouldContinue(const CCNMAdaptiveSamplerState *state) {
    return state && state->stopReason == CCNMAdaptiveSamplerStopRunning;
}

static inline int CCNMAdaptiveSamplerObserve(
    CCNMAdaptiveSamplerState *state,
    int parsedSample,
    int explicitNRServingCellObserved
) {
    if (!CCNMAdaptiveSamplerShouldContinue(state) ||
        state->policy == CCNMAdaptiveSamplerPolicyStableServing) return 0;

    state->consumedSampleCount++;
    if (parsedSample && explicitNRServingCellObserved) {
        state->consecutiveNRSampleCount++;
        state->explicitNRSampleCount++;
    } else {
        state->consecutiveNRSampleCount = 0;
    }

    if (state->policy == CCNMAdaptiveSamplerPolicyEarlyNR &&
        state->consecutiveNRSampleCount >= state->requiredConsecutiveNRSampleCount) {
        state->stopReason = CCNMAdaptiveSamplerStopExplicitNRConfirmed;
    } else if (state->consumedSampleCount >= state->maximumSampleCount) {
        state->stopReason = CCNMAdaptiveSamplerStopWindowExhausted;
    }
    return 1;
}

static inline int CCNMAdaptiveSamplerObserveServing(
    CCNMAdaptiveSamplerState *state,
    int parsedSample,
    int hasServingIdentity,
    int sameServingIdentityAsPrevious
) {
    if (!CCNMAdaptiveSamplerShouldContinue(state) ||
        state->policy != CCNMAdaptiveSamplerPolicyStableServing) return 0;

    state->consumedSampleCount++;
    if (parsedSample && hasServingIdentity) {
        state->consecutiveStableServingSampleCount =
            sameServingIdentityAsPrevious && state->consecutiveStableServingSampleCount > 0
                ? state->consecutiveStableServingSampleCount + 1
                : 1;
    } else {
        state->consecutiveStableServingSampleCount = 0;
    }

    if (state->consecutiveStableServingSampleCount >=
        state->requiredConsecutiveNRSampleCount) {
        state->stopReason = CCNMAdaptiveSamplerStopStableServingConfirmed;
    } else if (state->consumedSampleCount >= state->maximumSampleCount) {
        state->stopReason = CCNMAdaptiveSamplerStopWindowExhausted;
    }
    return 1;
}

static inline int CCNMAdaptiveSamplerAbort(
    CCNMAdaptiveSamplerState *state,
    int timedOut,
    int invocationException
) {
    if (!CCNMAdaptiveSamplerShouldContinue(state) || (!timedOut && !invocationException)) return 0;
    state->stopReason = timedOut
        ? CCNMAdaptiveSamplerStopTimedOut
        : CCNMAdaptiveSamplerStopInvocationException;
    return 1;
}

static inline int CCNMAdaptiveSamplerStoppedEarly(const CCNMAdaptiveSamplerState *state) {
    if (!state || state->consumedSampleCount >= state->maximumSampleCount) return 0;
    return state->stopReason == CCNMAdaptiveSamplerStopExplicitNRConfirmed ||
           state->stopReason == CCNMAdaptiveSamplerStopStableServingConfirmed ||
           state->stopReason == CCNMAdaptiveSamplerStopTimedOut ||
           state->stopReason == CCNMAdaptiveSamplerStopInvocationException;
}

static inline CCNMCellMonitorSamplingStatus CCNMClassifyAdaptiveCellMonitorSamplingStatus(
    size_t maximumSampleCount,
    size_t requiredConsecutiveNRSampleCount,
    size_t attemptedRefreshCount,
    size_t completedRefreshCount,
    size_t successfulRefreshCount,
    size_t attemptedCopyCount,
    size_t completedCopyCount,
    size_t successfulCopyCount,
    size_t parsedSampleCount,
    int explicitNRConfirmed,
    int windowExhausted
) {
    if (maximumSampleCount == 0) return CCNMCellMonitorSamplingFailed;

    if (explicitNRConfirmed && requiredConsecutiveNRSampleCount > 0 &&
        parsedSampleCount >= requiredConsecutiveNRSampleCount &&
        attemptedRefreshCount >= requiredConsecutiveNRSampleCount &&
        completedRefreshCount >= requiredConsecutiveNRSampleCount &&
        successfulRefreshCount >= requiredConsecutiveNRSampleCount &&
        attemptedCopyCount >= requiredConsecutiveNRSampleCount &&
        completedCopyCount >= requiredConsecutiveNRSampleCount &&
        successfulCopyCount >= requiredConsecutiveNRSampleCount) {
        return CCNMCellMonitorSamplingComplete;
    }

    if (windowExhausted &&
        attemptedRefreshCount == maximumSampleCount &&
        completedRefreshCount == maximumSampleCount &&
        successfulRefreshCount == maximumSampleCount &&
        attemptedCopyCount == maximumSampleCount &&
        completedCopyCount == maximumSampleCount &&
        successfulCopyCount == maximumSampleCount &&
        parsedSampleCount == maximumSampleCount) {
        return CCNMCellMonitorSamplingComplete;
    }

    return parsedSampleCount > 0
        ? CCNMCellMonitorSamplingPartial
        : CCNMCellMonitorSamplingFailed;
}

static inline CCNMCellMonitorSamplingStatus CCNMClassifyStableServingSamplingStatus(
    size_t requiredConsecutiveServingSampleCount,
    size_t attemptedRefreshCount,
    size_t completedRefreshCount,
    size_t successfulRefreshCount,
    size_t attemptedCopyCount,
    size_t completedCopyCount,
    size_t successfulCopyCount,
    size_t parsedSampleCount,
    int stableServingConfirmed
) {
    if (stableServingConfirmed && requiredConsecutiveServingSampleCount > 0 &&
        attemptedRefreshCount >= requiredConsecutiveServingSampleCount &&
        completedRefreshCount >= requiredConsecutiveServingSampleCount &&
        successfulRefreshCount >= requiredConsecutiveServingSampleCount &&
        attemptedCopyCount >= requiredConsecutiveServingSampleCount &&
        completedCopyCount >= requiredConsecutiveServingSampleCount &&
        successfulCopyCount >= requiredConsecutiveServingSampleCount &&
        parsedSampleCount >= requiredConsecutiveServingSampleCount) {
        return CCNMCellMonitorSamplingComplete;
    }
    return parsedSampleCount > 0
        ? CCNMCellMonitorSamplingPartial
        : CCNMCellMonitorSamplingFailed;
}

static inline int CCNMCellMonitorRATIsNR(const char *ratValue) {
    return ratValue &&
           (strcmp(ratValue, "kCTCellMonitorRadioAccessTechnologyNR") == 0 ||
            strcmp(ratValue, "kCTCellMonitorRadioAccessTechnologyNRNSA") == 0);
}

static inline int CCNMPrivateAsyncAttemptRequiresAbort(int timedOut, int invocationException) {
    return timedOut || invocationException;
}

static inline int CCNMCellMonitorClassificationSymbolsAvailable(
    int hasCellTypeKey,
    int hasServingValue,
    int hasRATKey
) {
    return hasCellTypeKey && hasServingValue && hasRATKey;
}

static inline int CCNMCellMonitorEntryIsStructurallyClassifiable(
    int isDictionary,
    int hasCellTypeValue
) {
    return isDictionary && hasCellTypeValue;
}

static inline int CCNMCellMonitorServingEntryHasClassifiableRAT(
    int isServingEntry,
    int hasRATValue
) {
    return !isServingEntry || hasRATValue;
}

typedef enum {
    CCNMNRObservationIndeterminatePartial = 0,
    CCNMNRObservationNotObservedComplete,
    CCNMNRObservationObserved,
} CCNMNRObservationStatus;

static inline CCNMNRObservationStatus CCNMClassifyNRObservationStatus(
    int nrServingCellObserved,
    CCNMCellMonitorSamplingStatus samplingStatus
) {
    if (nrServingCellObserved) return CCNMNRObservationObserved;
    return samplingStatus == CCNMCellMonitorSamplingComplete
        ? CCNMNRObservationNotObservedComplete
        : CCNMNRObservationIndeterminatePartial;
}

#endif
