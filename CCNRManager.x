// The formal bundle uses the same source as the verified standalone LiveCC
// module. Only the runtime class names and one linker-compatibility helper are
// adapted to the package's principal class; the serving state machine remains
// a single source of truth.
#import <UIKit/UIKit.h>

// The formal package has a device-verified no-CoreGraphics dependency baseline.
// Keep the standalone renderer's integral-rect behavior without importing the
// CoreGraphics symbol on this lane.
static CGRect CCNMLiveFormalIntegralRect(CGRect rect) {
    CGFloat minX = floor(rect.origin.x);
    CGFloat minY = floor(rect.origin.y);
    CGFloat maxX = ceil(rect.origin.x + rect.size.width);
    CGFloat maxY = ceil(rect.origin.y + rect.size.height);
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

#define CGRectIntegral CCNMLiveFormalIntegralRect
#define NRManagerLiveViewController CCNRManagerViewController
#define NRManagerLiveModule CCNRManager
#import "livecc/Sources/NRManagerLiveModule.m"
#undef NRManagerLiveModule
#undef NRManagerLiveViewController
#undef CGRectIntegral
