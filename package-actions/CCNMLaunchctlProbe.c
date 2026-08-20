#include "CCNMLaunchctlProbe.h"

#include <stdlib.h>
#include <string.h>

static const char *const CCNMLaunchctlBasenames[] = {
    // roothide keeps its jbroot-aware launchctl in basebin, outside the usual
    // bin/sbin layout, so probe it before the bootstrap paths.
    "/basebin/launchctl",
    "/bin/launchctl",
    "/sbin/launchctl",
    "/usr/bin/launchctl",
    "/usr/sbin/launchctl",
};
static const size_t CCNMLaunchctlBasenameCount =
    sizeof(CCNMLaunchctlBasenames) / sizeof(CCNMLaunchctlBasenames[0]);

// Joins `prefix` and `suffix`, trimming any trailing slashes on the prefix so
// that a prefix of "/rootfs/" cannot produce "/rootfs//bin/launchctl" and
// defeat duplicate detection. `suffix` always starts with '/'.
static char *CCNMJoinPath(const char *prefix, size_t prefixLength,
                          const char *suffix) {
    while (prefixLength > 0 && prefix[prefixLength - 1] == '/') {
        prefixLength--;
    }
    size_t suffixLength = strlen(suffix);
    char *joined = malloc(prefixLength + suffixLength + 1);
    if (!joined) {
        return NULL;
    }
    if (prefixLength > 0) {
        memcpy(joined, prefix, prefixLength);
    }
    memcpy(joined + prefixLength, suffix, suffixLength + 1);
    return joined;
}

// Appends `candidate` unless an equal string was already recorded. Takes
// ownership of `candidate` in both cases.
static void CCNMAppendUnique(char *candidate, char **out, size_t *count,
                             size_t capacity) {
    if (!candidate) {
        return;
    }
    for (size_t index = 0; index < *count; index++) {
        if (strcmp(out[index], candidate) == 0) {
            free(candidate);
            return;
        }
    }
    if (*count >= capacity) {
        free(candidate);
        return;
    }
    out[*count] = candidate;
    (*count)++;
}

static void CCNMAppendPrefix(const char *prefix, size_t prefixLength,
                             char **out, size_t *count, size_t capacity) {
    for (size_t index = 0; index < CCNMLaunchctlBasenameCount; index++) {
        CCNMAppendUnique(
            CCNMJoinPath(prefix, prefixLength, CCNMLaunchctlBasenames[index]),
            out, count, capacity);
    }
}

size_t CCNMBuildLaunchctlProbeOrder(const char *jbroot,
                                    const char *envPath,
                                    char **out,
                                    size_t capacity) {
    if (!out || capacity == 0) {
        return 0;
    }
    size_t count = 0;

    if (jbroot && jbroot[0] != '\0') {
        CCNMAppendPrefix(jbroot, strlen(jbroot), out, &count, capacity);
    }
    // The current view of `/`.
    CCNMAppendPrefix("", 0, out, &count, capacity);
    CCNMAppendPrefix("/rootfs", strlen("/rootfs"), out, &count, capacity);
    CCNMAppendPrefix("/var/jb", strlen("/var/jb"), out, &count, capacity);

    if (envPath && envPath[0] != '\0') {
        const char *cursor = envPath;
        while (*cursor != '\0') {
            const char *separator = strchr(cursor, ':');
            size_t length = separator ? (size_t)(separator - cursor)
                                      : strlen(cursor);
            // Relative PATH entries are ambiguous inside dpkg; skip them.
            if (length > 0 && cursor[0] == '/') {
                CCNMAppendUnique(CCNMJoinPath(cursor, length, "/launchctl"),
                    out, &count, capacity);
            }
            if (!separator) {
                break;
            }
            cursor = separator + 1;
        }
    }
    return count;
}
