// Private ControlCenterUIKit declarations used by this bundle.
//
// Do not replace these with angle-bracket imports of <ControlCenterUIKit/...>.
// The vendored ControlCenterUIKit headers form a Clang module with an umbrella
// header, and the CCSupport templates install a second, overlapping copy into
// $(THEOS)/include. Importing the framework by module makes the build depend on
// which copy is found first: on the pinned macOS runner it fails outright with
// duplicate protocol definitions, ambiguous protocol references, and incomplete
// umbrella errors, all promoted to errors by -Werror. A single self-contained
// header under a name that exists nowhere else resolves identically in every
// environment.
//
// CCUIButtonModuleViewController is exported by the private framework (it is
// present in the iPhoneOS SDK tbd objc-classes list) but is absent from the
// vendored headers. Only the members this bundle uses are declared.
//
// Two properties are the reason this bundle uses this class instead of
// CCUIToggleModule: glyphImage is writable, so the tile can publish a new glyph
// directly rather than asking the framework to re-read a readonly property, and
// buttonTapped:forEvent: is a real user-interaction callback that the framework
// does not invoke during module initialization or state synchronization.

#import <UIKit/UIKit.h>

@protocol CCUIContentModuleContentViewController <NSObject>

@property (nonatomic, readonly) CGFloat preferredExpandedContentHeight;
@property (nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property (nonatomic, readonly) BOOL providesOwnPlatter;

@optional
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;

@end

@protocol CCUIContentModule <NSObject>

@property (nonatomic, strong, readonly)
    UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end

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
