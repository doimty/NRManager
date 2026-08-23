#import <Foundation/Foundation.h>
#import "CCNMN78PolicySupport.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^CCNMN78PolicyCompletion)(NSDictionary<NSString *, id> *summary);

FOUNDATION_EXPORT NSString *const CCNMN78PolicyDidChangeDarwinNotification;

FOUNDATION_EXPORT NSString *CCNMN78PolicyStatePath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyBaselinePath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyIntentPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyInFlightPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyLockPath(void);
FOUNDATION_EXPORT NSString *CCNMN78PolicyRemovalGuardPath(void);
FOUNDATION_EXPORT NSArray<NSString *> *CCNMN78PolicyPaths(void);

/// Where the pending NR band selection is stored. Not part of
/// CCNMN78PolicyPaths(): it is user preference data rather than policy evidence,
/// it is never crash-recovered, and it deliberately outlives the off state.
FOUNDATION_EXPORT NSString *CCNMN78SelectedBandsPath(void);

/// The NR bands to pin on the next enable, ascending. Never empty: an absent or
/// unusable stored selection yields the shipped default of band 78 alone, which
/// keeps an upgrade from 1.5.0 identical in behaviour for a user who never opens
/// the band pane. This is a statement of intent, not of what is applied; read
/// CCNMN78PolicySummaryTargetNRBandsKey for that.
FOUNDATION_EXPORT NSArray<NSNumber *> *CCNMReadSelectedNRBands(void);

/// Records a pending selection. Performs no modem write and does not consult
/// policy state, so it is safe to call while the feature is off; the selection is
/// revalidated against live band evidence when an enable actually runs.
FOUNDATION_EXPORT BOOL CCNMWriteSelectedNRBands(NSArray<NSNumber *> *selection,
                                                NSString *_Nullable *_Nullable failure);

FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMReadN78PolicyState(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMReadKnownOrphanedN78RecoveryEligibility(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMReadKnownOrphanedN78RemovalSafety(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMArmN78PolicyRemovalGuard(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMClearN78PolicyRemovalGuardIfSafe(void);
FOUNDATION_EXPORT BOOL CCNMN78PolicyHasOutstandingSetter(void);
FOUNDATION_EXPORT void CCNMEnableN78Preference(CCNMN78PolicyCompletion _Nullable completion);
FOUNDATION_EXPORT void CCNMDisableN78Preference(CCNMN78PolicyCompletion _Nullable completion);
FOUNDATION_EXPORT void CCNMRecoverN78Preference(CCNMN78PolicyCompletion _Nullable completion);
FOUNDATION_EXPORT void CCNMRecoverKnownOrphanedN78WithCompletion(CCNMN78PolicyCompletion _Nullable completion);

@interface CCNMN78PolicyController : NSObject

+ (instancetype)sharedController;
- (NSDictionary<NSString *, id> *)readState;
- (void)enableWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;
- (void)disableWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;
- (void)recoverWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;
- (void)recoverKnownOrphanedN78WithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;

@end

NS_ASSUME_NONNULL_END
