#import <UIKit/UIKit.h>
#import "CCUIContentModuleContentViewController.h"

@protocol CCUIContentModule <NSObject>

@property (nonatomic, strong, readonly)
    UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end
