#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCNMMaintenanceLaunchdLabel;

// The prefix every installed path is built from, as handed over by the shell
// maintainer script through NETWORKMANAGER_INSTALL_PREFIX.
//
// nil          the prefix could not be determined; no installed path is usable
// @""          bare paths already resolve inside the jailbreak root (roothide)
// "/var/jb"    a real prefix that must be prepended (rootless)
//
// The empty case is why this is separate from CCNMMaintainerJailbreakRoot: an
// empty prefix is a valid, working answer, but it is not a root that can be
// prepended to anything.
FOUNDATION_EXPORT NSString * _Nullable CCNMMaintainerInstallPrefix(void);

// A real absolute jailbreak root, or nil when paths resolve bare.
FOUNDATION_EXPORT NSString * _Nullable CCNMMaintainerJailbreakRoot(void);
FOUNDATION_EXPORT NSString * _Nullable CCNMMaintainerRootedPath(NSString *path);

// The one machine-readable line a guard writes to stdout, and only after the
// installed plist has been checked against the reviewed contract. Everything
// else a guard says goes to stderr, so the shell can read stdout as a verdict
// rather than parse prose.
FOUNDATION_EXPORT NSString *const CCNMMaintenanceLaunchdVerifiedSentinel;

// Checks the installed launchd plist against the reviewed maintenance contract:
// the paths it names, the arguments, the KeepAlive PathState, and that the helper
// it points at is present and executable.
//
// Read-only, and deliberately so. Two separate device findings pin that:
//
//  - The plist ships complete. It used to be rewritten here from a @JBROOT@
//    placeholder, which on roothide produced a doubled program path, because
//    launchctl is itself redirected and prepends the jailbreak root on load.
//  - This process cannot write anyway. On the reporting device a maintainer-script
//    child ran as euid 0 with every read succeeding and every write returning
//    EPERM, because the bootstrap injection that grants the exemption is not
//    applied to it.
//
// launchctl is not consulted either, for the same reason in its exec form:
// posix_spawn returned EPERM for the real <jbroot>/usr/bin/launchctl. The shell
// maintainer scripts own every launchctl invocation now, and they refuse to load
// a plist this function has rejected. See package-actions/launchctl.sh.inc.
FOUNDATION_EXPORT BOOL CCNMVerifyMaintenanceLaunchdContract(
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
