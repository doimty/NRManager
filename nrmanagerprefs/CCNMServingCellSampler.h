#import <Foundation/Foundation.h>
#import "CCNMServingCellProbeSupport.h"

FOUNDATION_EXPORT NSDictionary *CCNMServingCellSamplerEmptyReport(void);
FOUNDATION_EXPORT NSDictionary *CCNMRunServingCellRatSelectionAttempt(id client, id context);
FOUNDATION_EXPORT NSDictionary *CCNMRunAdaptiveServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
);
FOUNDATION_EXPORT NSDictionary *CCNMRunResponsiveServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
);
FOUNDATION_EXPORT NSDictionary *CCNMRunFullWindowServingCellSampler(
    id client,
    id context,
    void *coreTelephonyHandle
);
FOUNDATION_EXPORT BOOL CCNMServingCellSamplerHasUnsafeOutstandingAttempt(void);
FOUNDATION_EXPORT id CCNMServingCellTypedPropertyListEvidence(id object);
