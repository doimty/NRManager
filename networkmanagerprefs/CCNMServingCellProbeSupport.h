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

static inline int CCNMProbeWaitCompleted(long waitResult) {
    return waitResult == 0;
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

static inline int CCNMCellMonitorRATIsNR(const char *rat) {
    return rat && strstr(rat, "RadioAccessTechnologyNR") != NULL;
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
