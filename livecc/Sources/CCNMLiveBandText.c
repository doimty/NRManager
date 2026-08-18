#include "CCNMLiveBandText.h"

#include <stdio.h>

bool CCNMLiveFormatBandText(
    char *buffer,
    size_t bufferSize,
    bool success,
    bool stale,
    CCNMLiveRadioKind radioKind,
    long long band) {
    if (!buffer || bufferSize == 0) {
        return false;
    }

    if (!success || stale || band <= 0 ||
        (radioKind != CCNMLiveRadioKindLTE && radioKind != CCNMLiveRadioKindNR)) {
        return snprintf(buffer, bufferSize, "?") > 0;
    }

    const char *prefix = radioKind == CCNMLiveRadioKindLTE ? "B" : "n";
    int written = snprintf(buffer, bufferSize, "%s%lld", prefix, band);
    if (written <= 0 || (size_t)written >= bufferSize) {
        snprintf(buffer, bufferSize, "?");
        return false;
    }
    return true;
}
