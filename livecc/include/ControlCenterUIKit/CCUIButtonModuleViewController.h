#import <UIKit/UIKit.h>
#import "CCUIContentModuleContentViewController.h"

@interface CCUIButtonModuleViewController : UIViewController
    <CCUIContentModuleContentViewController>

@property (nonatomic, strong) UIImage *glyphImage;
@property (nonatomic, strong) UIColor *glyphColor;
@property (nonatomic, strong) UIImage *selectedGlyphImage;
@property (nonatomic, strong) UIColor *selectedGlyphColor;
@property (nonatomic, copy) NSString *glyphState;
@property (nonatomic, assign, getter=isSelected) BOOL selected;

- (void)buttonTapped:(id)button forEvent:(UIEvent *)event;

@end
