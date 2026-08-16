#ifndef CCNM_SERVING_CELL_PROBE_SUPPORT_H
#define CCNM_SERVING_CELL_PROBE_SUPPORT_H

typedef enum {
    CCNMPublicNRFrequencyRangeUnknown = 0,
    CCNMPublicNRFrequencyRangeSub6,
    CCNMPublicNRFrequencyRangeMmWave,
    CCNMPublicNRFrequencyRangeSub6AndMmWave,
} CCNMPublicNRFrequencyRange;

static inline int CCNMProbeWaitCompleted(long waitResult) {
    return waitResult == 0;
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
