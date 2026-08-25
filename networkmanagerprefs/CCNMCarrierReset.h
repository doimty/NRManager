#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCNMCarrierResetSuccessKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetOperationKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetCommandKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetExecutableKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetFirstExitStatusKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetSecondExitStatusKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetFirstAttemptedKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetSecondAttemptedKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetElapsedMillisecondsKey;
FOUNDATION_EXPORT NSString *const CCNMCarrierResetErrorKey;

/// Runs the device-observed two-invocation carrier reload sequence.
///
/// The function is synchronous by design. Callers that own a UI must invoke it
/// from their worker queue. It never invokes CoreTelephony and never writes a
/// policy record; it only returns what happened to the two fixed commands.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMResetCarrierConfiguration(
    NSString *_Nullable *_Nullable failure);

NS_ASSUME_NONNULL_END
