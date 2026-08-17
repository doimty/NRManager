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

FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMReadN78PolicyState(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMArmN78PolicyRemovalGuard(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMClearN78PolicyRemovalGuardIfSafe(void);
FOUNDATION_EXPORT BOOL CCNMN78PolicyHasOutstandingSetter(void);
FOUNDATION_EXPORT void CCNMEnableN78Preference(CCNMN78PolicyCompletion _Nullable completion);
FOUNDATION_EXPORT void CCNMDisableN78Preference(CCNMN78PolicyCompletion _Nullable completion);
FOUNDATION_EXPORT void CCNMRecoverN78Preference(CCNMN78PolicyCompletion _Nullable completion);

@interface CCNMN78PolicyController : NSObject

+ (instancetype)sharedController;
- (NSDictionary<NSString *, id> *)readState;
- (void)enableWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;
- (void)disableWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;
- (void)recoverWithCompletion:(CCNMN78PolicyCompletion _Nullable)completion;

@end

NS_ASSUME_NONNULL_END
