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

// Rewrites the installed launchd template to the current physical jailbreak
// root and validates the executable and policy PathState paths. This does not
// need launchctl: it only has to leave a correct plist on disk, which is what
// makes the job loadable at the next boot.
FOUNDATION_EXPORT BOOL CCNMPrepareMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);

typedef NS_ENUM(NSInteger, CCNMMaintenanceRegistration) {
    // The plist could not be prepared, so the job will not load now or later.
    CCNMMaintenanceRegistrationFailed = 0,
    // Plist prepared and the job is loaded and running now.
    CCNMMaintenanceRegistrationActive,
    // Plist prepared, but launchctl could not be run, so the job stays unloaded
    // until launchd reads the jailbreak LaunchDaemons directory at next boot.
    CCNMMaintenanceRegistrationDeferred,
    // Plist prepared and launchctl ran, but launchd did not end up with the job
    // loaded. Distinct from Failed because the durable half of the work is
    // intact, and distinct from Deferred because launchd already declined once:
    // the next boot may pick it up, and promising that it will would be a claim
    // this code cannot support.
    CCNMMaintenanceRegistrationRejected,
};

// Registration and stop are idempotent. Registration replaces any stale
// loaded definition and starts the job only when the durable baseline exists.
FOUNDATION_EXPORT CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL CCNMStopMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
