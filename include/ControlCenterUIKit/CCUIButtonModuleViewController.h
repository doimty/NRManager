#import <UIKit/UIKit.h>

#import <ControlCenterUIKit/CCUIContentModuleContentViewController-Protocol.h>

// ControlCenterUIKit ships CCUIButtonModuleViewController in the private
// framework (confirmed present in the iPhoneOS16.5 SDK tbd objc-classes list),
// but the vendored headers in $(THEOS)/vendor/include do not declare it. This is
// the minimal declaration the Control Center bundle needs.
//
// Only the members this bundle actually uses are declared. glyphImage is
// writable, which is what allows a visible-session refresh loop to publish a new
// serving-band glyph directly instead of asking the framework to re-read a
// read-only property. buttonTapped:forEvent: is a real user-interaction
// callback: unlike CCUIToggleModule's setSelected:, the framework does not
// invoke it during module initialization or state synchronization.
API_AVAILABLE(ios(11.0))
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
