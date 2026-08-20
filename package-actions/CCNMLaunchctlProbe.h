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
//
// When `pathSourcedFrom` is non-NULL it receives the index at which PATH-derived
// candidates begin, so a caller running as root can hold those to a stricter
// trust standard than the known prefixes. It equals the return value when PATH
// contributed nothing.
size_t CCNMBuildLaunchctlProbeOrder(const char *jbroot,
                                    const char *envPath,
                                    char **out,
                                    size_t capacity,
                                    size_t *pathSourcedFrom);

// Answers only "is this candidate definitively not worth a spawn attempt".
//
// access(X_OK) must not be used for this. On the reported device the real
// launchctl binary returned EPERM from access(X_OK) while the file plainly
// existed, because the X_OK check is routed through an exec-authorization hook.
// So this deliberately does not judge executability: it reports true only for
// conditions where a spawn is guaranteed to be pointless (the path does not
// resolve, or resolves to something other than a regular file). Any other stat
// error is inconclusive and the candidate is still worth trying.
//
// `requireRootOwned` adds the check appropriate for PATH-derived candidates: a
// root process must not exec a binary that a non-root user could have replaced,
// so a non-root owner or group/world write permission rejects the candidate.
//
// Sets `*statErrno` to the errno that justified a rejection, otherwise 0.
int CCNMLaunchctlCandidateIsUnusable(const char *path,
                                     int requireRootOwned,
                                     int *statErrno);

#endif
