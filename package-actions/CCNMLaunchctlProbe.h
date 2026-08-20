#ifndef CCNM_LAUNCHCTL_PROBE_H
#define CCNM_LAUNCHCTL_PROBE_H

#include <stddef.h>

// Builds the ordered list of launchctl paths a maintainer script should try.
//
// Two device rounds were lost to guessing this list, so the ordering is a
// separate, host-testable unit rather than an inline loop: the interesting
// variable is not which binaries exist but which filesystem *view* the script
// runs in. A roothide shell sees the jbroot as `/` with the real root at
// `/rootfs`; a process spawned by dpkg need not see the same thing.
//
// Order, highest preference first:
//   1. `jbroot` (a jbroot-aware wrapper translates jbroot paths; the real
//      system copy does not)
//   2. the current view of `/`
//   3. `/rootfs`  (the real root, as seen from inside a jbroot view)
//   4. `/var/jb`  (a rootless bootstrap)
//   5. each absolute `PATH` directory, since that is what resolves launchctl
//      interactively
//
// Within prefixes 1-4 the basename order is basebin, bin, sbin, usr/bin,
// usr/sbin. Duplicates are removed, keeping the first (highest-preference)
// occurrence.
//
// `jbroot` and `envPath` may be NULL or empty and are then skipped. Writes at
// most `capacity` pointers into `out`; each is a NUL-terminated string owned by
// the caller and released with free(). Returns the number written, or 0 on
// allocation failure.
size_t CCNMBuildLaunchctlProbeOrder(const char *jbroot,
                                    const char *envPath,
                                    char **out,
                                    size_t capacity);

#endif
