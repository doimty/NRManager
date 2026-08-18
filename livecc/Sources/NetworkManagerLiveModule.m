#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "ControlCenterUIKit/CCUIButtonModuleViewController.h"
#import "ControlCenterUIKit/CCUIContentModule.h"
#import "CCNMLiveBandText.h"
#import "CCNMServingStatusProvider.h"

static const NSTimeInterval CCNMLiveRefreshInterval = 15.0;
static const NSTimeInterval CCNMLiveRATDebounceInterval = 2.0;

static NSString *CCNMLiveTextForSummary(NSDictionary<NSString *, id> *summary) {
    NSString *state = [summary[CCNMServingSummaryStateKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummaryStateKey] : CCNMServingStateUnknown;
    CCNMLiveRadioKind radioKind = CCNMLiveRadioKindUnknown;
    if ([state isEqual:CCNMServingStateLTE]) {
        radioKind = CCNMLiveRadioKindLTE;
    } else if ([state isEqual:CCNMServingStateNRN78] ||
               [state isEqual:CCNMServingStateNROther]) {
        radioKind = CCNMLiveRadioKindNR;
    }

    char text[32] = {0};
    CCNMLiveFormatBandText(
        text,
        sizeof(text),
        [summary[CCNMServingSummarySuccessKey] boolValue],
        [summary[CCNMServingSummaryStaleKey] boolValue],
        radioKind,
        [summary[CCNMServingSummaryBandKey] longLongValue]);
    return [NSString stringWithUTF8String:text] ?: @"?";
}

static UIImage *CCNMLiveGlyphImage(NSString *text) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.text = text.length > 0 ? text : @"?";
    label.textColor = UIColor.blackColor;
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

@class NetworkManagerLiveViewController;

static void CCNMLiveServingStatusDidChangeCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo);

@interface NetworkManagerLiveViewController : CCUIButtonModuleViewController

@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSTimer *ratDebounceTimer;
@property (nonatomic, assign) BOOL refreshInProgress;
@property (nonatomic, assign) BOOL observersRegistered;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) long long appliedSampledAtMilliseconds;

- (void)applyNewerCachedSummary;
- (void)applyCurrentSummary;

@end

@implementation NetworkManagerLiveViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _appliedSampledAtMilliseconds = -1;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Live Band";
    self.selected = NO;
    self.glyphImage = CCNMLiveGlyphImage(@"?");
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
        [self.ratDebounceTimer invalidate];
        __weak typeof(self) weakDebounceSelf = self;
        self.ratDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:CCNMLiveRATDebounceInterval
            repeats:NO
            block:^(NSTimer *timer) {
                [weakDebounceSelf ratDebounceTimerFired:timer];
            }];
    });
}

- (void)ratDebounceTimerFired:(NSTimer *)timer {
    (void)timer;
    self.ratDebounceTimer = nil;
    [self requestBoundedServingRefresh];
}

- (void)requestBoundedServingRefresh {
    if (!self.visible || self.refreshInProgress) {
        return;
    }
    self.refreshInProgress = YES;
    __weak typeof(self) weakSelf = self;
    [[CCNMServingStatusProvider sharedProvider]
        refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }
            self.refreshInProgress = NO;
            [self applySummary:summary requireNewerTimestamp:NO];
        }];
}

- (void)applyNewerCachedSummary {
    NSDictionary<NSString *, id> *summary =
        [[CCNMServingStatusProvider sharedProvider] currentSummary];
    [self applySummary:summary requireNewerTimestamp:YES];
}

- (void)applyCurrentSummary {
    NSDictionary<NSString *, id> *summary =
        [[CCNMServingStatusProvider sharedProvider] currentSummary];
    [self applySummary:summary requireNewerTimestamp:NO];
}

- (void)applySummary:(NSDictionary<NSString *, id> *)summary
    requireNewerTimestamp:(BOOL)requireNewerTimestamp {
    long long sampledAt = [summary[CCNMServingSummarySampledAtMillisecondsKey] longLongValue];
    if (requireNewerTimestamp && sampledAt <= self.appliedSampledAtMilliseconds) {
        return;
    }
    self.appliedSampledAtMilliseconds = MAX(self.appliedSampledAtMilliseconds, sampledAt);
    self.glyphImage = CCNMLiveGlyphImage(CCNMLiveTextForSummary(summary));
}

- (void)buttonTapped:(id)button forEvent:(UIEvent *)event {
    (void)button;
    (void)event;
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
    NetworkManagerLiveViewController *viewController =
        (__bridge NetworkManagerLiveViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [viewController applyNewerCachedSummary];
    });
}

@interface NetworkManagerLiveModule : NSObject <CCUIContentModule>

@property (nonatomic, strong, readonly)
    UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;

@end

@implementation NetworkManagerLiveModule

@synthesize backgroundViewController;

- (instancetype)init {
    self = [super init];
    if (self) {
        _contentViewController = [[NetworkManagerLiveViewController alloc] init];
    }
    return self;
}

@end
