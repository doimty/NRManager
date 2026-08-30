#ifndef CCNM_DAEMON_ROOT_H
#define CCNM_DAEMON_ROOT_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// The path this tool is installed at, relative to whatever prefix holds it.
extern const char *const CCNMDaemonInstalledRelativePath;

/// Length of the install prefix in `executablePath`, or -1 when the path cannot
/// identify one.
///
/// Pure string arithmetic on purpose: the prefix is derived from a path the
/// kernel has already exec'd, so there is nothing to check on the filesystem, and
/// keeping it free of Foundation is what lets it be tested directly.
///
/// A return of 0 is success and means the empty prefix, i.e. bare absolute paths
/// already resolve.
ssize_t CCNMDaemonPrefixLength(const char *executablePath);

#ifdef __OBJC__

/// The install prefix the maintenance daemon is running out of, or nil when it
/// could not be established.
///
/// An empty string is a valid, successful answer. nil means "do not guess", and
/// callers must treat it as fatal rather than falling back to a bare path.
///
/// Why this exists instead of jbroot()
/// -----------------------------------
/// libroothide's install name is @loader_path/.jbroot/usr/lib/libroothide.dylib,
/// which only resolves when a .jbroot symlink sits beside the loading binary or
/// when something already loaded the library into the process. Neither holds for
/// a launchd daemon: launchd applies no bootstrap injection, and dpkg does not
/// create a .jbroot beside an installed helper. The reporting device produced
///
///   dyld[2618]: Library not loaded: @loader_path/.jbroot/usr/lib/libroothide.dylib
///     Referenced from: <jbroot>/usr/libexec/nrmanager-maintenance
///     Reason: tried: '<jbroot>/usr/libexec/.jbroot/usr/lib/libroothide.dylib'
///       (no such file), '/usr/local/lib/...' (no such file), '/usr/lib/...'
///       (no such file)
///
/// with launchd recording runs = 108, successive crashes = 108, last exit reason
/// = OS_REASON_DYLD. The job had never started once. The Control Center bundle
/// links the same library and works only because SpringBoard is injected and
/// already has it loaded.
///
/// The install guards reached the same conclusion earlier by a different route;
/// see the comment in package-actions/Makefile. This is the daemon's equivalent.
NSString *CCNMDaemonInstallPrefix(void);

/// `path` prefixed with CCNMDaemonInstallPrefix().
///
/// When the prefix is unresolvable this deliberately returns a path that cannot
/// exist, so a read fails visibly instead of silently targeting the wrong root.
/// A policy read against the wrong root would report a clean state, and a clean
/// state is what authorises removing a package that still holds a forced band
/// configuration.
NSString *CCNMDaemonRootedPath(NSString *path);

#endif

#ifdef __cplusplus
}
#endif

#endif
