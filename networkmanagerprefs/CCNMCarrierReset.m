#import "CCNMCarrierReset.h"

#import <errno.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

NSString *const CCNMCarrierResetSuccessKey = @"success";
NSString *const CCNMCarrierResetOperationKey = @"carrierReset";
NSString *const CCNMCarrierResetCommandKey = @"command";
NSString *const CCNMCarrierResetExecutableKey = @"executable";
NSString *const CCNMCarrierResetFirstExitStatusKey = @"firstExitStatus";
NSString *const CCNMCarrierResetSecondExitStatusKey = @"secondExitStatus";
NSString *const CCNMCarrierResetFirstAttemptedKey = @"firstAttempted";
NSString *const CCNMCarrierResetSecondAttemptedKey = @"secondAttempted";
NSString *const CCNMCarrierResetElapsedMillisecondsKey = @"elapsedMilliseconds";
NSString *const CCNMCarrierResetErrorKey = @"error";

static const NSTimeInterval CCNMCarrierResetDeadlineSeconds = 20.0;
static const useconds_t CCNMCarrierResetInterInvocationMicroseconds = 250000;
static const useconds_t CCNMCarrierResetPollMicroseconds = 10000;

extern char **environ;

static NSTimeInterval CCNMCarrierResetMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (NSTimeInterval)now.tv_sec +
        ((NSTimeInterval)now.tv_nsec / (NSTimeInterval)NSEC_PER_SEC);
}

static void CCNMCarrierResetAddCandidate(NSMutableArray<NSString *> *paths, NSString *path) {
    if (path.length > 0 && ![paths containsObject:path]) {
        [paths addObject:path];
    }
}

static NSArray<NSString *> *CCNMCarrierResetCandidates(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
#if __has_include(<roothide.h>)
    CCNMCarrierResetAddCandidate(paths, jbroot(@"/usr/bin/killall"));
    CCNMCarrierResetAddCandidate(paths, jbroot(@"/bin/killall"));
    CCNMCarrierResetAddCandidate(paths, jbroot(@"/basebin/killall"));
#endif
    CCNMCarrierResetAddCandidate(paths, @"/var/jb/usr/bin/killall");
    CCNMCarrierResetAddCandidate(paths, @"/var/jb/bin/killall");
    CCNMCarrierResetAddCandidate(paths, @"/usr/bin/killall");
    CCNMCarrierResetAddCandidate(paths, @"/bin/killall");
    return [paths copy];
}

static BOOL CCNMCarrierResetPathMayExist(NSString *path) {
    struct stat info = {0};
    if (stat(path.fileSystemRepresentation, &info) == 0) {
        return S_ISREG(info.st_mode);
    }
    switch (errno) {
        case ENOENT:
        case ENOTDIR:
        case ENAMETOOLONG:
        case ELOOP:
            return NO;
        default:
            // stat(2) is not an execution-authorisation oracle on this platform.
            // Let posix_spawn provide the actual answer for inconclusive errors.
            return YES;
    }
}

static int CCNMCarrierResetRunOne(NSString *path,
                                  NSTimeInterval deadline,
                                  BOOL *started,
                                  NSString **failure) {
    char killall[] = "killall";
    char signal[] = "-9";
    char process[] = "CommCenter";
    char *arguments[] = { killall, signal, process, NULL };
    pid_t child = -1;
    int spawnError = posix_spawn(&child, path.fileSystemRepresentation,
        NULL, NULL, arguments, environ);
    if (spawnError != 0) {
        if (failure) {
            *failure = [NSString stringWithFormat:
                @"Could not start %@ (%s).", path, strerror(spawnError)];
        }
        return -1;
    }
    if (started) {
        *started = YES;
    }

    int status = 0;
    for (;;) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            if (WIFEXITED(status)) {
                return WEXITSTATUS(status);
            }
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"%@ terminated by signal %d.", path, WTERMSIG(status)];
            }
            return -2;
        }
        if (waited < 0 && errno != EINTR) {
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"Could not wait for %@ (%s).", path, strerror(errno)];
            }
            return -1;
        }
        NSTimeInterval now = CCNMCarrierResetMonotonicNow();
        if (deadline > 0 && now > 0 && now >= deadline) {
            (void)kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
            }
            if (failure) {
                *failure = [NSString stringWithFormat:
                    @"%@ did not finish within the carrier reset deadline.", path];
            }
            return -3;
        }
        usleep(CCNMCarrierResetPollMicroseconds);
    }
}

static NSString *CCNMCarrierResetFailureForStatus(int status, NSUInteger invocation) {
    if (status == 1) {
        return [NSString stringWithFormat:
            @"killall found no CommCenter process on invocation %lu.",
            (unsigned long)invocation];
    }
    if (status < 0) {
        return [NSString stringWithFormat:
            @"The killall invocation %lu could not complete (status %d).",
            (unsigned long)invocation, status];
    }
    return [NSString stringWithFormat:
        @"killall returned status %d on invocation %lu.",
        status, (unsigned long)invocation];
}

NSDictionary<NSString *, id> *CCNMResetCarrierConfiguration(NSString **failure) {
    NSTimeInterval startedAt = CCNMCarrierResetMonotonicNow();
    NSMutableDictionary *result = [@{
        CCNMCarrierResetSuccessKey: @NO,
        CCNMCarrierResetOperationKey: @"carrierReset",
        CCNMCarrierResetCommandKey: @"killall -9 CommCenter",
        CCNMCarrierResetFirstAttemptedKey: @NO,
        CCNMCarrierResetSecondAttemptedKey: @NO,
        CCNMCarrierResetFirstExitStatusKey: [NSNull null],
        CCNMCarrierResetSecondExitStatusKey: [NSNull null],
        CCNMCarrierResetErrorKey: @""
    } mutableCopy];

    NSString *path = nil;
    NSMutableArray<NSString *> *attemptedPaths = [NSMutableArray array];
    for (NSString *candidate in CCNMCarrierResetCandidates()) {
        if (!CCNMCarrierResetPathMayExist(candidate)) {
            continue;
        }
        [attemptedPaths addObject:candidate];
        path = candidate;
        break;
    }
    if (!path) {
        NSString *message = @"No usable killall executable was found.";
        result[CCNMCarrierResetErrorKey] = message;
        result[@"attemptedPaths"] = attemptedPaths;
        if (failure) {
            *failure = message;
        }
        return [result copy];
    }
    result[CCNMCarrierResetExecutableKey] = path;

    NSTimeInterval deadline = startedAt > 0
        ? startedAt + CCNMCarrierResetDeadlineSeconds : 0;
    BOOL firstStarted = NO;
    NSString *runFailure = nil;
    int firstStatus = CCNMCarrierResetRunOne(path, deadline, &firstStarted, &runFailure);
    result[CCNMCarrierResetFirstAttemptedKey] = @(firstStarted);
    result[CCNMCarrierResetFirstExitStatusKey] = @(firstStatus);
    if (!firstStarted || firstStatus != 0) {
        NSString *message = runFailure ?: CCNMCarrierResetFailureForStatus(firstStatus, 1);
        result[CCNMCarrierResetErrorKey] = message;
        if (failure) {
            *failure = message;
        }
        goto finish;
    }

    usleep(CCNMCarrierResetInterInvocationMicroseconds);

    BOOL secondStarted = NO;
    runFailure = nil;
    int secondStatus = CCNMCarrierResetRunOne(path, deadline, &secondStarted, &runFailure);
    result[CCNMCarrierResetSecondAttemptedKey] = @(secondStarted);
    result[CCNMCarrierResetSecondExitStatusKey] = @(secondStatus);
    if (!secondStarted || secondStatus != 0) {
        NSString *message = runFailure ?: CCNMCarrierResetFailureForStatus(secondStatus, 2);
        result[CCNMCarrierResetErrorKey] = message;
        if (failure) {
            *failure = message;
        }
        goto finish;
    }
    result[CCNMCarrierResetSuccessKey] = @YES;

finish: {
    NSTimeInterval finishedAt = CCNMCarrierResetMonotonicNow();
    long long elapsed = (startedAt > 0 && finishedAt >= startedAt)
        ? (long long)((finishedAt - startedAt) * 1000.0) : 0;
    result[CCNMCarrierResetElapsedMillisecondsKey] = @(elapsed);
}
    if (failure && [result[CCNMCarrierResetSuccessKey] boolValue]) {
        *failure = nil;
    }
    return [result copy];
}
