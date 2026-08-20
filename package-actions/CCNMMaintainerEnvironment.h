#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCNMMaintenanceLaunchdLabel;

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
};

// Registration and stop are idempotent. Registration replaces any stale
// loaded definition and starts the job only when the durable baseline exists.
FOUNDATION_EXPORT CCNMMaintenanceRegistration CCNMRegisterMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL CCNMStopMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
