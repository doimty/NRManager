#include "CCNMDaemonRoot.h"

#include <string.h>

const char *const CCNMDaemonInstalledRelativePath =
    "/usr/libexec/networkmanager-maintenance";

// Recovering the prefix from our own path is the same idea as @loader_path,
// applied to something we know exactly: where this tool is installed. Whatever
// precedes that suffix is the prefix, which makes one mechanism cover every lane
// with no build-time switch:
//
//   <jbroot>/usr/libexec/networkmanager-maintenance -> <jbroot>
//   /var/jb/usr/libexec/networkmanager-maintenance  -> /var/jb
//   /usr/libexec/networkmanager-maintenance         -> "" (valid, bare paths)
//
// Suffix arithmetic, not a component search. A prefix that itself ended in
// "/usr/libexec/networkmanager-maintenance" would otherwise be cut at the first
// occurrence, and the result would be a real directory, so every later read would
// fail quietly rather than visibly.
ssize_t CCNMDaemonPrefixLength(const char *executablePath) {
    if (executablePath == NULL) {
        return -1;
    }
    size_t length = strlen(executablePath);
    // A relative path resolves against a working directory launchd does not
    // guarantee, so it cannot identify a root.
    if (length == 0 || executablePath[0] != '/') {
        return -1;
    }
    size_t suffix = strlen(CCNMDaemonInstalledRelativePath);
    if (length < suffix) {
        return -1;
    }
    if (strcmp(executablePath + (length - suffix),
               CCNMDaemonInstalledRelativePath) != 0) {
        return -1;
    }
    return (ssize_t)(length - suffix);
}
