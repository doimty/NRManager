#ifndef CCNM_SERVING_STATUS_SUPPORT_H
#define CCNM_SERVING_STATUS_SUPPORT_H

#include <math.h>

static inline double CCNMNRARFCNToMHz(long long nrarfcn) {
    if (nrarfcn >= 0 && nrarfcn <= 599999) {
        return (double)nrarfcn * 0.005;
    }
    if (nrarfcn >= 600000 && nrarfcn <= 2016666) {
        return 3000.0 + ((double)nrarfcn - 600000.0) * 0.015;
    }
    if (nrarfcn >= 2016667 && nrarfcn <= 3279165) {
        return 24250.08 + ((double)nrarfcn - 2016667.0) * 0.06;
    }
    return -1.0;
}

static inline int CCNMServingFrequencyIsValid(double frequencyMHz) {
    return isfinite(frequencyMHz) && frequencyMHz >= 0.0;
}

#endif
