#import <Foundation/Foundation.h>
#import "CCNMN78PolicySupport.h"

NS_ASSUME_NONNULL_BEGIN

// Read-only access to the durable n78 policy state.
// The daemon links against this module instead of the full policy controller
// so it can observe policy state, serving summaries, and automatic-maintenance
// decisions without importing any writer, setter, or recovery code.

FOUNDATION_EXPORT NSString *const CCNMN78PolicyDidChangeDarwinNotification;

FOUNDATION_EXPORT NSString *CCNMN78PolicyStatePath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyBaselinePath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyIntentPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyInFlightPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyLockPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyRemovalGuardPath(void);
FOUNDATION_EXPORT NSArray<NSString *> *CCNMN78PolicyPaths(void);

// Returns a complete policy summary dictionary. This is the same function
// exported by CCNMN78PolicyController.h, but implemented here without any
// writer code reachable in the same translation unit.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMReadN78PolicyState(void);

// Boot-identity and session helpers shared across the read-only path.
FOUNDATION_EXPORT long long CCNMUnixMilliseconds(void);
FOUNDATION_EXPORT NSTimeInterval CCNMMonotonicNow(void);
FOUNDATION_EXPORT NSString * _Nullable CCNMSysctlString(const char *name);
FOUNDATION_EXPORT NSString * _Nullable CCNMCanonicalUUIDString(id value);
FOUNDATION_EXPORT NSString * _Nullable CCNMBootSessionIdentity(void);
FOUNDATION_EXPORT BOOL CCNMFileExists(NSString *path);
FOUNDATION_EXPORT NSDictionary * _Nullable CCNMLoadRecord(NSString *path, BOOL *exists);

// Validation functions shared with the policy controller (no writer dependency).
FOUNDATION_EXPORT BOOL CCNMNSNumberIsInteger(id value);
FOUNDATION_EXPORT NSSet<NSString *> *CCNMRequiredRATKeys(void);
FOUNDATION_EXPORT BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right);
FOUNDATION_EXPORT BOOL CCNMStringInDomain(id value, NSArray<NSString *> *domain);
FOUNDATION_EXPORT NSDictionary * _Nullable CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString * _Nullable * _Nullable failure);

FOUNDATION_EXPORT BOOL CCNMValidateStateRecord(NSDictionary *state, NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMValidateBaselineRecord(NSDictionary *baseline, NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMValidateBaselineCompatibility(NSDictionary *baseline,
                                                          NSDictionary *currentSupportedBands,
                                                          NSDictionary *identity,
                                                          NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMValidateIntentRecord(NSDictionary *intent, NSDictionary *baseline,
                                                 NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMValidateInFlightRecord(NSDictionary *record, NSDictionary *baseline,
                                                   NSDictionary * _Nullable intent,
                                                   BOOL requireIntentLink,
                                                   NSString * _Nullable * _Nullable failure);
FOUNDATION_EXPORT BOOL CCNMValidateRemovalGuardRecord(NSDictionary *guard, NSString * _Nullable * _Nullable failure);

FOUNDATION_EXPORT NSDictionary *CCNMDefaultState(void);

NS_ASSUME_NONNULL_END