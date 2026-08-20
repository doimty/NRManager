#ifndef CCNM_PLIST_WRITE_H
#define CCNM_PLIST_WRITE_H

#include <stddef.h>
#include <sys/types.h>

// Which route actually produced the new file contents.
typedef enum {
    CCNMFileWriteStageNone = 0,
    // Wrote a sibling in the same directory and renamed it onto the target.
    // Preferred: an interrupted run cannot leave a torn file behind.
    CCNMFileWriteStageSibling,
    // Rewrote the existing entry in place. Used only when the directory will
    // not accept a new entry. Needs permission on the file rather than on the
    // directory, and gives up atomicity to do it.
    CCNMFileWriteStageInPlace,
} CCNMFileWriteStage;

// Everything a caller needs to explain a failure without asking the user to run
// commands by hand. `failingStep` is a stable token, never a sentence, so the
// message wording stays with the caller.
typedef struct {
    int ok;
    CCNMFileWriteStage stage;
    // errno from the preferred sibling attempt. Nonzero with ok == 1 means the
    // fallback was used and this is why.
    int siblingErrno;
    int failureErrno;
    const char *failingStep;
    size_t bytesRemaining;
    size_t bytesTotal;
    unsigned resultMode;
    unsigned resultUid;
    unsigned resultGid;

    // State of the surroundings, collected only on failure. As root a
    // directory's own permission bits cannot explain a refusal to create a
    // file, so these fields are what separate "this mount forbids writes" from
    // "a policy hook refused this one" from "the path is not what we think".
    // Guessing between those has already cost several rounds.
    int directoryStatErrno;
    unsigned directoryMode;
    unsigned directoryUid;
    int targetStatErrno;
    unsigned targetMode;
    unsigned targetUid;
    // 1 read-only, 0 read-write, -1 unknown.
    int readOnlyMount;
    int mountStatErrno;
} CCNMFileWriteOutcome;

// Replace the contents of `path` with `length` bytes, ending as `owner`:`group`
// with permission bits `mode`. `path` must be absolute. The final state is
// asserted by fstat rather than inferred from syscall returns, because a file
// that a packager already unpacked with the right owner needs no chown and must
// not fail for skipping one.
void CCNMReplaceFileContents(const char *path,
                             const void *bytes,
                             size_t length,
                             uid_t owner,
                             gid_t group,
                             unsigned mode,
                             CCNMFileWriteOutcome *outcome);

#endif
