#ifndef CCNM_LIVE_BAND_TEXT_H
#define CCNM_LIVE_BAND_TEXT_H

#include <stdbool.h>
#include <stddef.h>

typedef enum {
    CCNMLiveRadioKindUnknown = 0,
    CCNMLiveRadioKindLTE,
    CCNMLiveRadioKindNR,
} CCNMLiveRadioKind;

bool CCNMLiveFormatBandText(
    char *buffer,
    size_t bufferSize,
    bool success,
    bool stale,
    CCNMLiveRadioKind radioKind,
    long long band);

#endif
