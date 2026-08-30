#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#endif

#import "NRManagerControlCenterUIKitPrivate.h"

// The serving-band tile refreshes itself while Control Center is visible. The
// module object only vends the view controller; the view controller owns the
// visibility-driven refresh loop.
@interface CCNRManagerViewController : CCUIButtonModuleViewController
@end

@interface CCNRManager : NSObject <CCUIContentModule>
@end
