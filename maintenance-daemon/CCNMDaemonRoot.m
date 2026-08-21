#import "CCNMDaemonRoot.h"

#import <dispatch/dispatch.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <string.h>

// _NSGetExecutablePath returns the path launchd exec'd, which on roothide is the
// value its launchctl already rewrote to include the jailbreak root. That is
// normally enough. realpath is the fallback for the cases it is not: a
// non-canonical or symlinked spelling names the same file, and resolving it is
// what lets the suffix match. Both spellings are absolute and both are usable
// prefixes, so neither is preferred over the other.
static NSString *CCNMDaemonPrefixFromPath(const char *path) {
    ssize_t length = CCNMDaemonPrefixLength(path);
    if (length < 0) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:path
                                   length:(NSUInteger)length
                                 encoding:NSUTF8StringEncoding];
}

static NSString *CCNMDaemonExecutablePrefix(void) {
    char buffer[PATH_MAX * 2];
    uint32_t size = (uint32_t)sizeof(buffer);
    if (_NSGetExecutablePath(buffer, &size) != 0) {
        return nil;
    }
    buffer[sizeof(buffer) - 1] = '\0';
    NSString *prefix = CCNMDaemonPrefixFromPath(buffer);
    if (prefix) {
        return prefix;
    }
    char resolved[PATH_MAX];
    if (realpath(buffer, resolved) == NULL) {
        return nil;
    }
    return CCNMDaemonPrefixFromPath(resolved);
}

NSString *CCNMDaemonInstallPrefix(void) {
    // Resolved once. The answer is a property of how this process was exec'd and
    // cannot change while it runs, and every policy path goes through it.
    static NSString *prefix = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefix = CCNMDaemonExecutablePrefix();
    });
    return prefix;
}

NSString *CCNMDaemonRootedPath(NSString *path) {
    NSString *prefix = CCNMDaemonInstallPrefix();
    if (!prefix) {
        return [@"/.networkmanager-unresolved-install-prefix"
            stringByAppendingString:path];
    }
    // Plain concatenation, so an empty prefix yields the original path.
    return [prefix stringByAppendingString:path];
}
