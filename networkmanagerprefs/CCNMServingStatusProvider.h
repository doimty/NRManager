#import <Foundation/Foundation.h>
#import "CCNMN78PolicySupport.h"
#import "CCNMServingCellSampler.h"
#import "CCNMServingStatusSupport.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCNMServingSummaryStateKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryDataLineKey;
// What device the sample was taken on. Reported, never used as a gate: the read
// path runs on any model, and this is what lets the UI say which device it is
// looking at instead of only which device the write path accepts.
FOUNDATION_EXPORT NSString *const CCNMServingSummaryDeviceModelKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySystemBuildKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySystemVersionKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySampledAtMillisecondsKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryPublishedAtMillisecondsKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryStaleKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryRATKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryBandKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryFrequencyMHzKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryErrorKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySuccessKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySamplingStatusKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryUnsafeOutstandingKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummarySubscriptionUUIDKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilityReadSuccessKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilityN78SupportedKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilityN78ActiveKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilitySupportedNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilityActiveNRBandsKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilitySupportedRATKeysKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilitySampledAtMillisecondsKey;
FOUNDATION_EXPORT NSString *const CCNMServingSummaryCapabilityErrorKey;
FOUNDATION_EXPORT NSString *const CCNMServingStatusDidChangeDarwinNotification;

// The UI receives only this compact typed summary. Full sampler evidence stays
// behind supportEvidence for diagnostics/export and is never used as policy truth.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *CCNMServingStatusEmptySummary(void);

@interface CCNMServingStatusProvider : NSObject

+ (instancetype)sharedProvider;
- (NSDictionary<NSString *, id> *)currentSummary;
- (NSDictionary<NSString *, id> *)supportEvidence;
- (void)refreshWithCompletion:(void (^ _Nullable)(NSDictionary<NSString *, id> *summary))completion;

@end

NS_ASSUME_NONNULL_END
