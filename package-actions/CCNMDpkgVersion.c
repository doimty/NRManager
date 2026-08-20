#include "CCNMDpkgVersion.h"

#include <stddef.h>
#include <string.h>

// Length of the leading run of decimal digits at `text`.
static size_t CCNMDigitRunLength(const char *text) {
    size_t length = 0;
    while (text[length] >= '0' && text[length] <= '9') {
        length++;
    }
    return length;
}

// Compare one dotted component. Components are compared numerically, so "10"
// sorts above "9". Values are compared digit-wise after skipping leading zeros
// so that arbitrarily long components cannot overflow an integer type.
// Returns -1, 0 or 1, or -2 when the component is not purely numeric.
static int CCNMCompareNumericComponent(const char *left, size_t leftLength,
                                       const char *right, size_t rightLength) {
    if (leftLength == 0 || rightLength == 0) {
        return -2;
    }
    if (CCNMDigitRunLength(left) != leftLength ||
        CCNMDigitRunLength(right) != rightLength) {
        return -2;
    }
    while (leftLength > 1 && *left == '0') {
        left++;
        leftLength--;
    }
    while (rightLength > 1 && *right == '0') {
        right++;
        rightLength--;
    }
    if (leftLength != rightLength) {
        return leftLength > rightLength ? 1 : -1;
    }
    int order = memcmp(left, right, leftLength);
    if (order == 0) {
        return 0;
    }
    return order > 0 ? 1 : -1;
}

// Advance past one dotted component, reporting its length.
static const char *CCNMNextComponent(const char *cursor, const char *end,
                                     size_t *length) {
    const char *dot = memchr(cursor, '.', (size_t)(end - cursor));
    const char *stop = dot ? dot : end;
    *length = (size_t)(stop - cursor);
    return dot ? dot + 1 : end;
}

bool CCNMDpkgVersionIsAtLeast(const char *version, const char *floorVersion) {
    if (!version || !floorVersion || version[0] == '\0' || floorVersion[0] == '\0') {
        return false;
    }
    // An epoch changes ordering semantics entirely. Refuse to guess.
    if (strchr(version, ':') != NULL) {
        return false;
    }

    // Split off the upstream head: the Debian revision and any pre-release or
    // build suffix start at the first '-', '+' or '~'.
    size_t headLength = strcspn(version, "-+~");
    const char *versionEnd = version + headLength;
    const char *suffix = versionEnd;

    const char *floorEnd = floorVersion + strlen(floorVersion);

    const char *left = version;
    const char *right = floorVersion;
    while (left < versionEnd || right < floorEnd) {
        size_t leftLength = 0;
        size_t rightLength = 0;
        const char *nextLeft = left < versionEnd
            ? CCNMNextComponent(left, versionEnd, &leftLength) : versionEnd;
        const char *nextRight = right < floorEnd
            ? CCNMNextComponent(right, floorEnd, &rightLength) : floorEnd;

        // A shorter version is padded with an implicit zero component, so
        // "1.5" compares equal to the floor "1.5.0".
        static const char zero[] = "0";
        const char *leftText = left < versionEnd ? left : zero;
        size_t leftSize = left < versionEnd ? leftLength : 1;
        const char *rightText = right < floorEnd ? right : zero;
        size_t rightSize = right < floorEnd ? rightLength : 1;

        int order = CCNMCompareNumericComponent(leftText, leftSize,
                                                rightText, rightSize);
        if (order == -2) {
            return false;
        }
        if (order != 0) {
            return order > 0;
        }
        left = nextLeft;
        right = nextRight;
    }

    // Numerically equal upstream heads. A '~' suffix sorts *before* the plain
    // version, so a pre-release of the floor has not reached the floor.
    return suffix[0] != '~';
}
