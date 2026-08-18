#import <UIKit/UIKit.h>

@protocol CCUIContentModuleContentViewController <NSObject>

@property (nonatomic, readonly) CGFloat preferredExpandedContentHeight;
@property (nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL providesOwnPlatter;

@optional
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;

@end
