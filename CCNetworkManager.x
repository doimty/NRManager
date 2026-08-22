#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "CCNetworkManager.h"
#import "networkmanagerprefs/CCNMServingStatusProvider.h"

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

static UIImage *CCNMLiveGlyphImage(NSString *text) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.text = text.length > 0 ? text : @"...";
    label.textColor = UIColor.whiteColor;
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

// CGRectIntegral's semantics without linking CoreGraphics into the injected bundle.
static CGRect CCNMLiveIntegralRect(CGRect rect) {
    CGFloat minX = floor(rect.origin.x);
    CGFloat minY = floor(rect.origin.y);
    CGFloat maxX = ceil(rect.origin.x + rect.size.width);
    CGFloat maxY = ceil(rect.origin.y + rect.size.height);
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

static UIImage *CCNMLiveCenteredSymbolGlyphImage(UIImage *symbol) {
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
    UIImage *whiteSymbol = [symbol imageWithTintColor:UIColor.whiteColor
        renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsBeginImageContextWithOptions(canvasSize, NO, 0.0);
    [whiteSymbol drawInRect:CCNMLiveIntegralRect(drawRect)];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static UIImage *CCNMLiveSearchingGlyphImage(void) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:25.0
            weight:UIImageSymbolWeightMedium];
    UIImage *symbol = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
        withConfiguration:configuration];
    if (!symbol) {
        symbol = [UIImage systemImageNamed:@"magnifyingglass"
            withConfiguration:configuration];
    }
    return CCNMLiveCenteredSymbolGlyphImage(symbol) ?: CCNMLiveGlyphImage(@"...");
}

static NSString *const CCNMLiveSearchingGlyphKey = @"__searching__";

@class CCNetworkManagerViewController;

static void CCNMLiveServingStatusDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo);

@interface CCNetworkManagerViewController ()

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
@property (nonatomic, copy) NSString *drawnGlyphKey;

- (void)applyNewerCachedSummary;
- (void)applyCurrentSummary;
- (void)requestBoundedServingRefresh;
- (void)applySummary:(NSDictionary<NSString *, id> *)summary
    requireNewerTimestamp:(BOOL)requireNewerTimestamp;
- (void)applyGlyphText:(NSString *)text;

@end

@implementation CCNetworkManagerViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _appliedPublishedAtMilliseconds = -1;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Live Band";
    self.selected = NO;
    self.glyphColor = UIColor.whiteColor;
    self.selectedGlyphColor = UIColor.whiteColor;
    self.drawnGlyphKey = nil;
    [self applyGlyphText:nil];
    [self applyNewerCachedSummary];
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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
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
    if (self.visible) {
        return;
    }
    self.visible = YES;
    [self registerObserversIfNeeded];
    [self applyNewerCachedSummary];
    if (!self.refreshTimer) {
        __weak typeof(self) weakSelf = self;
        self.refreshTimer = [NSTimer timerWithTimeInterval:CCNMLiveRefreshInterval
            repeats:YES
            block:^(NSTimer *timer) {
                (void)timer;
                [weakSelf refreshTimerFired:timer];
            }];
        [NSRunLoop.currentRunLoop addTimer:self.refreshTimer
            forMode:NSRunLoopCommonModes];
    }
}

- (void)endVisibleSession {
    self.visible = NO;
    self.refreshPending = NO;
    self.awaitingCurrentRefresh = NO;
    if (self.refreshInProgress) {
        self.refreshInProgress = NO;
        self.refreshGeneration++;
    }
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
        self.ratDebounceTimer = [NSTimer timerWithTimeInterval:CCNMLiveRATDebounceSeconds
            repeats:NO
            block:^(NSTimer *timer) {
                (void)timer;
                [weakDebounceSelf ratDebounceTimerFired:timer];
            }];
        [NSRunLoop.currentRunLoop addTimer:self.ratDebounceTimer
            forMode:NSRunLoopCommonModes];
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
    [CCNMServingStatusProvider.sharedProvider
        refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }
            BOOL superseded = generation != self.refreshGeneration;
            BOOL shouldRefreshAgain = (self.refreshPending || superseded) && self.visible;
            self.refreshPending = NO;
            self.refreshInProgress = NO;
            if (!superseded) {
                self.awaitingCurrentRefresh = NO;
                [self applySummary:summary requireNewerTimestamp:NO];
            }
            if (shouldRefreshAgain) {
                self.hasFreshServingResult = NO;
                self.awaitingCurrentRefresh = YES;
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
        CCNMServingStatusProvider.sharedProvider.currentSummary;
    [self applySummary:summary requireNewerTimestamp:YES];
}

- (void)applyCurrentSummary {
    if (self.awaitingCurrentRefresh) {
        return;
    }
    NSDictionary<NSString *, id> *summary =
        CCNMServingStatusProvider.sharedProvider.currentSummary;
    [self applySummary:summary requireNewerTimestamp:NO];
}

- (void)applySummary:(NSDictionary<NSString *, id> *)summary
    requireNewerTimestamp:(BOOL)requireNewerTimestamp {
    long long publishedAt = [summary[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue];
    if (requireNewerTimestamp && publishedAt <= self.appliedPublishedAtMilliseconds) {
        return;
    }
    self.appliedPublishedAtMilliseconds = MAX(self.appliedPublishedAtMilliseconds, publishedAt);
    NSString *text = CCNMLiveTextForSummary(summary);
    self.hasFreshServingResult = text.length > 0;
    [self applyGlyphText:self.hasFreshServingResult ? text : nil];
}

- (void)applyGlyphText:(NSString *)text {
    NSString *key = text.length > 0 ? text : CCNMLiveSearchingGlyphKey;
    if ([key isEqualToString:self.drawnGlyphKey]) {
        return;
    }
    UIImage *glyph = text.length > 0 ? CCNMLiveGlyphImage(text) : CCNMLiveSearchingGlyphImage();
    self.glyphImage = glyph;
    self.selectedGlyphImage = glyph;
    self.drawnGlyphKey = key;
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
    CCNetworkManagerViewController *viewController =
        (__bridge CCNetworkManagerViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [viewController applyNewerCachedSummary];
    });
}

@implementation CCNetworkManager {
    CCNetworkManagerViewController *_servingTileViewController;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _servingTileViewController = [[CCNetworkManagerViewController alloc] init];
    }
    return self;
}

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    return _servingTileViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

@end
