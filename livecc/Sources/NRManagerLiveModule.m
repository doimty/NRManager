#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "ControlCenterUIKit/CCUIButtonModuleViewController.h"
#import "ControlCenterUIKit/CCUIContentModule.h"
#import "CCNMLiveBandText.h"
#import "CCNMServingStatusProvider.h"

#if CCNM_LIVE_MAIN_BUNDLE
FOUNDATION_EXPORT NSString *CCNMN78PolicyStatePath(void);
static NSString *const CCNMLivePolicyChangedNotification =
    @"com.doimty.nrmanager/n78-policy-changed";
static NSString *const CCNMLivePolicyRequestedModeKey = @"requestedMode";
static NSString *const CCNMLivePolicyN78Preferred = @"n78Preferred";
#endif

static const NSTimeInterval CCNMLiveRefreshInterval = 15.0;
static const NSTimeInterval CCNMLiveRATDebounceSeconds = 0.25;

static NSString *CCNMLiveTextForSummary(NSDictionary<NSString *, id> *summary) {
    BOOL success = [summary[CCNMServingSummarySuccessKey] boolValue];
    BOOL stale = [summary[CCNMServingSummaryStaleKey] boolValue];
    long long band = [summary[CCNMServingSummaryBandKey] longLongValue];
    if (!success || stale || band <= 0 || band > 1024) {
        return nil;
    }

    NSString *state = [summary[CCNMServingSummaryStateKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummaryStateKey] : CCNMServingStateUnknown;
    if ([state isEqual:CCNMServingStateLTE]) {
        return [NSString stringWithFormat:@"B%lld", band];
    }
    if ([state isEqual:CCNMServingStateNRN78] ||
        [state isEqual:CCNMServingStateNROther]) {
        return [NSString stringWithFormat:@"n%lld", band];
    }
    return nil;
}

#if CCNM_LIVE_MAIN_BUNDLE
static UIColor *CCNMLivePolicyAccentColor(void) {
    return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
}

static BOOL CCNMLivePolicyRequested(void) {
    NSDictionary *state =
        [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyStatePath()];
    return [state[CCNMLivePolicyRequestedModeKey]
        isEqual:CCNMLivePolicyN78Preferred];
}
#else
static UIColor *CCNMLivePolicyAccentColor(void) {
    return UIColor.whiteColor;
}

static BOOL CCNMLivePolicyRequested(void) {
    return NO;
}
#endif

static UIImage *CCNMLiveGlyphImageWithColor(NSString *text, UIColor *textColor) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.text = text.length > 0 ? text : @"...";
    label.textColor = textColor;
    label.backgroundColor = UIColor.clearColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.65;
    label.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    UIGraphicsBeginImageContextWithOptions(label.bounds.size, NO, 0.0);
    [label.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *CCNMLiveCenteredSymbolGlyphImage(UIImage *symbol, UIColor *tintColor) {
    if (!symbol) {
        return nil;
    }
    CGSize canvasSize = CGSizeMake(70.0, 70.0);
    CGFloat maxDimension = 30.0;
    CGFloat scale = MIN(maxDimension / MAX(symbol.size.width, 1.0),
        maxDimension / MAX(symbol.size.height, 1.0));
    CGSize drawSize = CGSizeMake(symbol.size.width * scale, symbol.size.height * scale);
    CGRect drawRect = CGRectMake(
        (canvasSize.width - drawSize.width) / 2.0,
        (canvasSize.height - drawSize.height) / 2.0,
        drawSize.width,
        drawSize.height);
    UIImage *tintedSymbol = [symbol imageWithTintColor:tintColor
        renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsBeginImageContextWithOptions(canvasSize, NO, 0.0);
    [tintedSymbol drawInRect:CGRectIntegral(drawRect)];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *CCNMLiveSearchingGlyphImageWithColor(UIColor *tintColor) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:25.0
            weight:UIImageSymbolWeightMedium];
    UIImage *symbol = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
        withConfiguration:configuration];
    if (!symbol) {
        symbol = [UIImage systemImageNamed:@"magnifyingglass"
            withConfiguration:configuration];
    }
    return CCNMLiveCenteredSymbolGlyphImage(symbol, tintColor) ?:
        CCNMLiveGlyphImageWithColor(@"...", tintColor);
}

@class NRManagerLiveViewController;

static void CCNMLiveServingStatusDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo);

#if CCNM_LIVE_MAIN_BUNDLE
static void CCNMLivePolicyDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo);
#endif

@interface NRManagerLiveViewController : CCUIButtonModuleViewController

@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSTimer *ratDebounceTimer;
@property (nonatomic, assign) BOOL refreshInProgress;
@property (nonatomic, assign) BOOL refreshPending;
@property (nonatomic, assign) BOOL awaitingCurrentRefresh;
@property (nonatomic, assign) BOOL hasFreshServingResult;
@property (nonatomic, assign) BOOL observersRegistered;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) NSUInteger refreshGeneration;
@property (nonatomic, assign) long long appliedPublishedAtMilliseconds;

- (void)applyNewerCachedSummary;
- (void)applyCurrentSummary;
- (void)applyGlyphText:(NSString *)text;
- (void)applyPolicyPresentation;

@end

@implementation NRManagerLiveViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _appliedPublishedAtMilliseconds = -1;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"NR Manager";
    self.glyphColor = UIColor.whiteColor;
    self.selectedGlyphColor = CCNMLivePolicyAccentColor();
    [self applyGlyphText:nil];
    [self applyNewerCachedSummary];
}

// The live band is already visible in the compact tile. A long press must not
// transition to an expanded copy of the same preview.
- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return NO;
}

- (void)controlCenterWillPresent {
    [self beginVisibleSession];
    [self requestBoundedServingRefresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self beginVisibleSession];
    [self requestBoundedServingRefresh];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self endVisibleSession];
}

- (void)controlCenterDidDismiss {
    [self endVisibleSession];
}

- (void)dealloc {
    [self endVisibleSession];
}

- (void)beginVisibleSession {
    self.visible = YES;
    [self registerObserversIfNeeded];
    [self applyNewerCachedSummary];
    if (!self.refreshTimer) {
        __weak typeof(self) weakSelf = self;
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:CCNMLiveRefreshInterval
            repeats:YES
            block:^(NSTimer *timer) {
                [weakSelf refreshTimerFired:timer];
            }];
    }
}

- (void)endVisibleSession {
    self.visible = NO;
    self.refreshPending = NO;
    self.awaitingCurrentRefresh = NO;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    [self.ratDebounceTimer invalidate];
    self.ratDebounceTimer = nil;
    [self removeObserversIfNeeded];
}

- (void)registerObserversIfNeeded {
    if (self.observersRegistered) {
        return;
    }
    self.observersRegistered = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(radioAccessTechnologyDidChange:)
        name:CTServiceRadioAccessTechnologyDidChangeNotification
        object:nil];
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CCNMLiveServingStatusDidChangeCallback,
        (__bridge CFStringRef)CCNMServingStatusDidChangeDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
#if CCNM_LIVE_MAIN_BUNDLE
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CCNMLivePolicyDidChangeCallback,
        (__bridge CFStringRef)CCNMLivePolicyChangedNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
#endif
}

- (void)removeObserversIfNeeded {
    if (!self.observersRegistered) {
        return;
    }
    self.observersRegistered = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:CTServiceRadioAccessTechnologyDidChangeNotification
        object:nil];
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        (__bridge CFStringRef)CCNMServingStatusDidChangeDarwinNotification,
        NULL);
#if CCNM_LIVE_MAIN_BUNDLE
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        (__bridge CFStringRef)CCNMLivePolicyChangedNotification,
        NULL);
#endif
}

- (void)refreshTimerFired:(NSTimer *)timer {
    (void)timer;
    [self applyCurrentSummary];
    [self requestBoundedServingRefresh];
}

- (void)radioAccessTechnologyDidChange:(NSNotification *)notification {
    (void)notification;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.visible) {
            return;
        }
        self.refreshGeneration++;
        self.awaitingCurrentRefresh = YES;
        self.hasFreshServingResult = NO;
        [self applyGlyphText:nil];
        [self.ratDebounceTimer invalidate];
        __weak typeof(self) weakDebounceSelf = self;
        self.ratDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:CCNMLiveRATDebounceSeconds
            repeats:NO
            block:^(NSTimer *timer) {
                [weakDebounceSelf ratDebounceTimerFired:timer];
            }];
    });
}

- (void)ratDebounceTimerFired:(NSTimer *)timer {
    (void)timer;
    self.ratDebounceTimer = nil;
    if (self.refreshInProgress) {
        self.refreshPending = YES;
        return;
    }
    self.refreshPending = NO;
    [self requestBoundedServingRefresh];
}

- (void)requestBoundedServingRefresh {
    if (!self.visible || self.refreshInProgress) {
        return;
    }
    if (self.ratDebounceTimer) {
        self.refreshPending = YES;
        return;
    }
    if (!self.hasFreshServingResult) {
        [self applyGlyphText:nil];
    }
    self.refreshPending = NO;
    self.refreshInProgress = YES;
    NSUInteger generation = self.refreshGeneration;
    __weak typeof(self) weakSelf = self;
    [[CCNMServingStatusProvider sharedProvider]
        refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }
            self.refreshInProgress = NO;
            BOOL superseded = generation != self.refreshGeneration;
            BOOL shouldRefreshAgain = (self.refreshPending || superseded) && self.visible;
            self.refreshPending = NO;
            if (!superseded) {
                self.awaitingCurrentRefresh = NO;
                [self applySummary:summary requireNewerTimestamp:NO];
            }
            if (shouldRefreshAgain) {
                self.hasFreshServingResult = NO;
                [self applyGlyphText:nil];
                if (self.ratDebounceTimer) {
                    self.refreshPending = YES;
                    return;
                }
                [self requestBoundedServingRefresh];
            }
        }];
}

- (void)applyNewerCachedSummary {
    if (self.awaitingCurrentRefresh) {
        return;
    }
    NSDictionary<NSString *, id> *summary =
        [[CCNMServingStatusProvider sharedProvider] currentSummary];
    [self applySummary:summary requireNewerTimestamp:YES];
}

- (void)applyCurrentSummary {
    if (self.awaitingCurrentRefresh) {
        return;
    }
    NSDictionary<NSString *, id> *summary =
        [[CCNMServingStatusProvider sharedProvider] currentSummary];
    [self applySummary:summary requireNewerTimestamp:NO];
}

- (void)applySummary:(NSDictionary<NSString *, id> *)summary
    requireNewerTimestamp:(BOOL)requireNewerTimestamp {
    long long publishedAt = [summary[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue];
    if (requireNewerTimestamp && publishedAt <= self.appliedPublishedAtMilliseconds) {
        return;
    }
    self.appliedPublishedAtMilliseconds =
        MAX(self.appliedPublishedAtMilliseconds, publishedAt);
    NSString *text = CCNMLiveTextForSummary(summary);
    self.hasFreshServingResult = text.length > 0;
    [self applyGlyphText:self.hasFreshServingResult ? text : nil];
}

- (void)applyGlyphText:(NSString *)text {
    BOOL requested = CCNMLivePolicyRequested();
    UIColor *normalColor = UIColor.whiteColor;
    UIColor *selectedColor = CCNMLivePolicyAccentColor();
    UIImage *glyph = text.length > 0
        ? CCNMLiveGlyphImageWithColor(text, normalColor)
        : CCNMLiveSearchingGlyphImageWithColor(normalColor);
    UIImage *selectedGlyph = text.length > 0
        ? CCNMLiveGlyphImageWithColor(text, selectedColor)
        : CCNMLiveSearchingGlyphImageWithColor(selectedColor);
    self.glyphColor = normalColor;
    self.selectedGlyphColor = selectedColor;
    self.glyphImage = glyph;
    self.selectedGlyphImage = selectedGlyph;
    self.selected = requested;
}

- (void)applyPolicyPresentation {
    NSDictionary<NSString *, id> *summary =
        [[CCNMServingStatusProvider sharedProvider] currentSummary];
    NSString *text = CCNMLiveTextForSummary(summary);
    [self applyGlyphText:text.length > 0 ? text : nil];
}

- (void)buttonTapped:(id)button forEvent:(UIEvent *)event {
    (void)button;
    (void)event;
    self.refreshGeneration++;
    self.awaitingCurrentRefresh = YES;
    self.hasFreshServingResult = NO;
    [self applyGlyphText:nil];
    [self.ratDebounceTimer invalidate];
    self.ratDebounceTimer = nil;
    if (self.refreshInProgress) {
        self.refreshPending = YES;
        return;
    }
    [self requestBoundedServingRefresh];
}

@end

static void CCNMLiveServingStatusDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    NRManagerLiveViewController *viewController =
        (__bridge NRManagerLiveViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [viewController applyNewerCachedSummary];
    });
}

#if CCNM_LIVE_MAIN_BUNDLE
static void CCNMLivePolicyDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    NRManagerLiveViewController *viewController =
        (__bridge NRManagerLiveViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [viewController applyPolicyPresentation];
    });
}
#endif

@interface NRManagerLiveModule : NSObject <CCUIContentModule>

@property (nonatomic, strong, readonly)
    UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end

@implementation NRManagerLiveModule

@synthesize backgroundViewController;

- (instancetype)init {
    self = [super init];
    if (self) {
        _contentViewController = [[NRManagerLiveViewController alloc] init];
    }
    return self;
}

@end
