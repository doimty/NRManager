#ifndef CCNM_NR_BAND_SUPPORT_H
#define CCNM_NR_BAND_SUPPORT_H

// Static facts about NR band numbers, independent of any device.
//
// This is deliberately separate from CCNMServingStatusSupport.h: that header
// converts a *measured* NRARFCN into a frequency, which is only available for a
// cell the modem is actually reporting. Nothing here observes the device.
//
// Scope note, because the difference matters for what may be shown to a user:
// a band number alone does not determine a frequency. Expressing an arbitrary band
// in MHz requires the 3GPP band table (TS 38.101-1 Table 5.2-1 for FR1,
// Table 5.2-1 in TS 38.101-2 for FR2), which is not transcribed here. What *is*
// determined by the band number alone is which frequency range it belongs to,
// because 3GPP allocates the numbers themselves by range. That distinction is
// the one with a safety consequence: pinning NR to mmWave only would leave the
// user with essentially no 5G coverage, and a user reading a bare "n260" has no
// way to know that.

typedef enum {
    CCNMNRBandRangeUnknown = 0,
    // FR1, 410 MHz - 7125 MHz. Every currently allocated band below n257.
    CCNMNRBandRangeSub6,
    // FR2, 24250 MHz - 71000 MHz. n257 and above.
    CCNMNRBandRangeMillimeterWave,
} CCNMNRBandRange;

// The lowest band number 3GPP allocates to FR2. Bands below this are FR1.
#define CCNM_NR_FIRST_MILLIMETER_WAVE_BAND 257

// Matches the band-identifier ceiling the policy's own BandInfo validation
// enforces (CCNMMaximumBandIdentifier, mirrored in both policy translation
// units), so a band this classifier accepts is one the policy could hold. The
// two are pinned to each other by tests/test_nr_band_selection.py rather than
// shared through a header, because the policy constant is deliberately file-local
// in each mirror.
#define CCNM_NR_MAXIMUM_BAND_IDENTIFIER 1024

static inline CCNMNRBandRange CCNMClassifyNRBandRange(long long band) {
    if (band <= 0 || band > CCNM_NR_MAXIMUM_BAND_IDENTIFIER) {
        return CCNMNRBandRangeUnknown;
    }
    return band >= CCNM_NR_FIRST_MILLIMETER_WAVE_BAND
        ? CCNMNRBandRangeMillimeterWave
        : CCNMNRBandRangeSub6;
}

// Whether a selection would leave the user on mmWave only. Reported to the user
// as a warning rather than enforced as a refusal: it is a coverage judgement, and
// the policy's own safety argument is that LTE remains untouched either way.
static inline int CCNMNRSelectionIsMillimeterWaveOnly(const long long *bands, unsigned long count) {
    if (!bands || count == 0) {
        return 0;
    }
    for (unsigned long index = 0; index < count; index++) {
        if (CCNMClassifyNRBandRange(bands[index]) != CCNMNRBandRangeMillimeterWave) {
            return 0;
        }
    }
    return 1;
}

#endif
