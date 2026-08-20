// PATH_MAX, O_CLOEXEC, ftruncate, fchmod and fchown are POSIX.1-2008. glibc
// hides them unless a feature level is requested, and this file has to build on
// Linux for the host tests as well as in the iOS lane. Apple's headers expose
// them by default and get narrower under a strict _POSIX_C_SOURCE, so only ask
// on non-Apple platforms. Must precede every include.
#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "CCNMPlistWrite.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Read-only detection differs by platform and this file builds in both the iOS
// lane and the Linux host tests. Darwin's native statfs/MNT_RDONLY is in the
// iOS SDK; elsewhere use POSIX statvfs/ST_RDONLY.
#ifdef __APPLE__
#include <sys/mount.h>
#include <sys/param.h>
#else
#include <sys/statvfs.h>
#endif

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

static int CCNMMountIsReadOnly(const char *path, int *failure) {
    *failure = 0;
#ifdef __APPLE__
    struct statfs info;
    if (statfs(path, &info) != 0) {
        *failure = errno;
        return -1;
    }
    return (info.f_flags & MNT_RDONLY) ? 1 : 0;
#else
    struct statvfs info;
    if (statvfs(path, &info) != 0) {
        *failure = errno;
        return -1;
    }
    return (info.f_flag & ST_RDONLY) ? 1 : 0;
#endif
}

// Collected only when the write has already failed, so the cost never lands on
// the working path. errno is saved and restored because the caller's failure
// errno has to survive this.
static void CCNMDescribeSurroundings(const char *path,
                                     CCNMFileWriteOutcome *outcome) {
    int saved = errno;
    outcome->readOnlyMount = -1;

    char directory[PATH_MAX];
    size_t length = strlen(path);
    while (length > 1 && path[length - 1] != '/') {
        length--;
    }
    while (length > 1 && path[length - 1] == '/') {
        length--;
    }
    if (length == 0 || length >= sizeof(directory)) {
        directory[0] = '/';
        directory[1] = '\0';
    } else {
        memcpy(directory, path, length);
        directory[length] = '\0';
    }

    struct stat info;
    if (stat(directory, &info) == 0) {
        outcome->directoryMode = (unsigned)(info.st_mode & 07777);
        outcome->directoryUid = (unsigned)info.st_uid;
    } else {
        outcome->directoryStatErrno = errno;
    }
    if (stat(path, &info) == 0) {
        outcome->targetMode = (unsigned)(info.st_mode & 07777);
        outcome->targetUid = (unsigned)info.st_uid;
    } else {
        outcome->targetStatErrno = errno;
    }
    outcome->readOnlyMount =
        CCNMMountIsReadOnly(directory, &outcome->mountStatErrno);

    errno = saved;
}

static void CCNMFileWriteFail(CCNMFileWriteOutcome *outcome,
                              const char *step,
                              int failure) {
    outcome->ok = 0;
    outcome->failingStep = step;
    outcome->failureErrno = failure;
}
void CCNMReplaceFileContents(const char *path,
                             const void *bytes,
                             size_t length,
                             uid_t owner,
                             gid_t group,
                             unsigned mode,
                             CCNMFileWriteOutcome *outcome) {
    if (!outcome) {
        return;
    }
    memset(outcome, 0, sizeof(*outcome));
    outcome->bytesTotal = length;
    outcome->bytesRemaining = length;
    outcome->readOnlyMount = -1;
    if (!path || path[0] != '/' || (!bytes && length > 0)) {
        CCNMFileWriteFail(outcome, "arguments", EINVAL);
        return;
    }

    // The sibling name encodes our own pid, so a leftover with this exact name
    // cannot belong to a live writer: it is debris from a run that died before
    // cleanup. Removing it is safe, and refusing would strand every later
    // install on the same pid.
    char sibling[PATH_MAX];
    int printed = snprintf(sibling, sizeof(sibling), "%s.networkmanager.%d.part",
                           path, (int)getpid());
    int descriptor = -1;
    if (printed <= 0 || (size_t)printed >= sizeof(sibling)) {
        outcome->siblingErrno = ENAMETOOLONG;
    } else {
        descriptor = open(sibling, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode);
        if (descriptor < 0 && errno == EEXIST) {
            (void)unlink(sibling);
            descriptor = open(sibling, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                              mode);
        }
        if (descriptor < 0) {
            outcome->siblingErrno = errno;
        }
    }

    if (descriptor >= 0) {
        outcome->stage = CCNMFileWriteStageSibling;
    } else {
        // No O_TRUNC. The bytes are written first and the length is fixed
        // afterwards, so the file is never observably empty and a failed write
        // leaves stale content rather than nothing.
        descriptor = open(path, O_WRONLY | O_CLOEXEC);
        if (descriptor < 0) {
            CCNMFileWriteFail(outcome, "in-place-open", errno);
            CCNMDescribeSurroundings(path, outcome);
            return;
        }
        outcome->stage = CCNMFileWriteStageInPlace;
    }

    const unsigned char *cursor = (const unsigned char *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            outcome->bytesRemaining = remaining;
            CCNMFileWriteFail(outcome, "write", written < 0 ? errno : EIO);
            goto cleanup;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
    outcome->bytesRemaining = 0;

    if (ftruncate(descriptor, (off_t)length) != 0) {
        CCNMFileWriteFail(outcome, "truncate", errno);
        goto cleanup;
    }

    // Best effort on purpose. What matters is the state fstat reports next, not
    // whether these calls were necessary.
    (void)fchmod(descriptor, (mode_t)mode);
    (void)fchown(descriptor, owner, group);

    struct stat result;
    if (fstat(descriptor, &result) != 0) {
        CCNMFileWriteFail(outcome, "fstat", errno);
        goto cleanup;
    }
    outcome->resultMode = (unsigned)(result.st_mode & 07777);
    outcome->resultUid = (unsigned)result.st_uid;
    outcome->resultGid = (unsigned)result.st_gid;
    if (outcome->resultMode != (mode & 07777)) {
        CCNMFileWriteFail(outcome, "mode", 0);
        goto cleanup;
    }
    if (result.st_uid != owner || result.st_gid != group) {
        CCNMFileWriteFail(outcome, "ownership", 0);
        goto cleanup;
    }
    if (fsync(descriptor) != 0) {
        CCNMFileWriteFail(outcome, "fsync", errno);
        goto cleanup;
    }
    if (close(descriptor) != 0) {
        descriptor = -1;
        CCNMFileWriteFail(outcome, "close", errno);
        goto cleanup;
    }
    descriptor = -1;

    if (outcome->stage == CCNMFileWriteStageSibling &&
        rename(sibling, path) != 0) {
        CCNMFileWriteFail(outcome, "rename", errno);
        goto cleanup;
    }

    outcome->ok = 1;
    return;

cleanup:
    if (descriptor >= 0) {
        (void)close(descriptor);
    }
    if (outcome->stage == CCNMFileWriteStageSibling) {
        int saved = errno;
        (void)unlink(sibling);
        errno = saved;
    }
    CCNMDescribeSurroundings(path, outcome);
}
