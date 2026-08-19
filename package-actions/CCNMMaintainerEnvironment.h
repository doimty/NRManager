#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCNMMaintenanceLaunchdLabel;

FOUNDATION_EXPORT NSString * _Nullable CCNMMaintainerJailbreakRoot(void);
FOUNDATION_EXPORT NSString * _Nullable CCNMMaintainerRootedPath(NSString *path);

// Rewrites the installed launchd template to the current physical jailbreak
// root and validates the executable, launchctl, and policy PathState paths.
FOUNDATION_EXPORT BOOL CCNMPrepareMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);

// Registration and stop are idempotent. Registration replaces any stale
// loaded definition and starts the job only when the durable baseline exists.
FOUNDATION_EXPORT BOOL CCNMRegisterMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL CCNMStopMaintenanceLaunchd(
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
