#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

#import <ControlCenterUIKit/CCUIToggleModule.h>

@interface CCUIToggleModule (CCNMReconfigureView)
- (void)reconfigureView;
@end

@interface CCNetworkManager : CCUIToggleModule
@end
