#import <CoreTelephony/CTTelephonyNetworkInfo.h>

#import "CCNetworkManager.h"
#import "networkmanagerprefs/CCNMN78PolicyController.h"
#import "networkmanagerprefs/CCNMServingStatusProvider.h"

// Auto-refresh cadence while Control Center is on screen. The tile used to
// refresh only when the framework happened to re-read its icon, which is why the
// displayed band could lag far behind reality. The prototype validated this
// interval on the target device.
static const NSTimeInterval CCNMServingVisibleRefreshInterval = 15.0;
// Radio-access-technology notifications arrive in bursts during a handover.
// Coalesce them instead of starting a sampler round per notification.
static const NSTimeInterval CCNMServingRATDebounceSeconds = 0.25;
// Floor between two sampler requests so a notification burst or repeated taps
// cannot hammer the read path.
static const NSTimeInterval CCNMServingRefreshMinimumInterval = 2.0;
// A sampler round that never reports back must not pin the tile on "...".
static const NSTimeInterval CCNMServingRefreshStallTimeout = 20.0;

static BOOL CCNMPolicyIsRequested(NSDictionary *state) {
    return [state[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred];
}

static BOOL CCNMPolicyIsTransitioning(NSDictionary *state) {
    return [state[CCNMN78PolicySummaryAppliedPolicyKey] isEqual:CCNMAppliedPolicyApplying];
}

static BOOL CCNMPolicyNeedsRecovery(NSDictionary *state) {
    NSString *recovery = state[CCNMN78PolicySummaryRecoveryStateKey];
    return ![recovery isEqual:CCNMRecoveryStateClean] &&
        ![recovery isEqual:CCNMRecoveryStateEnabledWithBaseline];
}

static NSString *CCNMServingGlyphText(NSDictionary *summary, BOOL refreshInProgress) {
    if (refreshInProgress) {
        return @"...";
    }
    if (![summary[CCNMServingSummarySuccessKey] boolValue] ||
        [summary[CCNMServingSummaryStaleKey] boolValue]) {
        return @"?";
    }
    NSNumber *band = summary[CCNMServingSummaryBandKey];
    if (![band isKindOfClass:NSNumber.class] || band.longLongValue <= 0) {
        return @"?";
    }
    NSString *state = summary[CCNMServingSummaryStateKey];
    if ([state isEqual:CCNMServingStateLTE]) {
        return [NSString stringWithFormat:@"B%@", band];
    }
    if ([state isEqual:CCNMServingStateNRN78] ||
        [state isEqual:CCNMServingStateNROther]) {
        return [NSString stringWithFormat:@"n%@", band];
    }
    return @"?";
}

static UIImage *CCNMServingGlyphImage(NSString *text, UIColor *textColor) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.textColor = textColor;
    label.backgroundColor = UIColor.clearColor;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.text = text;

    UIGraphicsBeginImageContextWithOptions(label.bounds.size, NO, 0.0);
    [label.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface CCNetworkManagerViewController ()
@property (nonatomic, assign) BOOL servingRefreshInProgress;
@property (nonatomic, assign) NSTimeInterval servingRefreshLastAttempt;
@property (nonatomic, assign) NSTimeInterval servingRefreshStartedAt;
@property (nonatomic, copy) NSDictionary<NSString *, id> *servingSummary;
@property (nonatomic, strong) NSTimer *visibleRefreshTimer;
@property (nonatomic, strong) NSTimer *ratDebounceTimer;
@property (nonatomic, assign) BOOL refreshPending;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL observersRegistered;
@property (nonatomic, assign) NSUInteger refreshGeneration;

- (void)requestServingRefreshIfNeeded;
- (void)invalidateServingStatus;
- (void)refreshModulePresentation;
- (void)adoptPublishedServingSummary;
@end

static void CCNMPolicyDidChangeCallback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    CCNetworkManagerViewController *module =
        (__bridge CCNetworkManagerViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [module invalidateServingStatus];
        [module refreshModulePresentation];
        [module requestServingRefreshIfNeeded];
    });
}

static void CCNMServingStatusDidChangeCallback(CFNotificationCenterRef center,
                                                void *observer,
                                                CFStringRef name,
                                                const void *object,
                                                CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    CCNetworkManagerViewController *module =
        (__bridge CCNetworkManagerViewController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [module adoptPublishedServingSummary];
    });
}

@implementation CCNetworkManagerViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _servingSummary = CCNMServingStatusEmptySummary();
    }
    return self;
}

- (void)dealloc {
    [self endVisibleSession];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.glyphColor = UIColor.whiteColor;
    self.selectedGlyphColor = UIColor.blackColor;
    [self refreshModulePresentation];
}

#pragma mark - Visible session

// Control Center delivers presentation either through the content-module
// callbacks or through normal view lifecycle depending on how the tile is
// hosted, so both entry points start the same session. beginVisibleSession is
// idempotent.
- (void)controlCenterWillPresent {
    [self beginVisibleSession];
}

- (void)controlCenterDidDismiss {
    [self endVisibleSession];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self beginVisibleSession];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self endVisibleSession];
}

- (void)beginVisibleSession {
    self.visible = YES;
    [self registerObserversIfNeeded];
    [self adoptPublishedServingSummary];
    if (!self.visibleRefreshTimer) {
        __weak typeof(self) weakSelf = self;
        self.visibleRefreshTimer =
            [NSTimer scheduledTimerWithTimeInterval:CCNMServingVisibleRefreshInterval
                repeats:YES
                block:^(NSTimer *timer) {
                    (void)timer;
                    [weakSelf visibleRefreshTimerFired];
                }];
    }
    [self requestServingRefreshIfNeeded];
}

- (void)endVisibleSession {
    self.visible = NO;
    self.refreshPending = NO;
    [self.visibleRefreshTimer invalidate];
    self.visibleRefreshTimer = nil;
    [self.ratDebounceTimer invalidate];
    self.ratDebounceTimer = nil;
    [self removeObserversIfNeeded];
}

- (void)registerObserversIfNeeded {
    if (self.observersRegistered) {
        return;
    }
    self.observersRegistered = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(radioAccessTechnologyDidChange:)
        name:CTServiceRadioAccessTechnologyDidChangeNotification
        object:nil];
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CCNMPolicyDidChangeCallback,
        (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        CCNMServingStatusDidChangeCallback,
        (__bridge CFStringRef)CCNMServingStatusDidChangeDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)removeObserversIfNeeded {
    if (!self.observersRegistered) {
        return;
    }
    self.observersRegistered = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self
        name:CTServiceRadioAccessTechnologyDidChangeNotification
        object:nil];
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
        NULL);
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        (__bridge CFStringRef)CCNMServingStatusDidChangeDarwinNotification,
        NULL);
}

#pragma mark - Refresh triggers

- (void)visibleRefreshTimerFired {
    [self adoptPublishedServingSummary];
    [self requestServingRefreshIfNeeded];
}

- (void)radioAccessTechnologyDidChange:(NSNotification *)notification {
    (void)notification;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.visible) {
            return;
        }
        [strongSelf.ratDebounceTimer invalidate];
        strongSelf.ratDebounceTimer =
            [NSTimer scheduledTimerWithTimeInterval:CCNMServingRATDebounceSeconds
                repeats:NO
                block:^(NSTimer *timer) {
                    (void)timer;
                    [weakSelf ratDebounceTimerFired];
                }];
    });
}

- (void)ratDebounceTimerFired {
    self.ratDebounceTimer = nil;
    if (self.servingRefreshInProgress) {
        self.refreshPending = YES;
        return;
    }
    // The technology changed, so the published band is known-stale even if its
    // own freshness window has not expired yet.
    self.servingRefreshLastAttempt = 0;
    [self requestServingRefreshIfNeeded];
}

// A tap only forces an immediate sample. It deliberately does not call super and
// does not write any policy: the settings page remains the sole writer.
- (void)buttonTapped:(id)button forEvent:(UIEvent *)event {
    (void)button;
    (void)event;
    [self.ratDebounceTimer invalidate];
    self.ratDebounceTimer = nil;
    if (self.servingRefreshInProgress) {
        self.refreshPending = YES;
        return;
    }
    self.servingRefreshLastAttempt = 0;
    [self requestServingRefreshIfNeeded];
}

#pragma mark - Refresh

- (void)invalidateServingStatus {
    self.servingSummary = CCNMServingStatusEmptySummary();
    self.servingRefreshLastAttempt = 0;
}

- (void)clearStalledRefreshIfNeeded {
    if (!self.servingRefreshInProgress) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.servingRefreshStartedAt > CCNMServingRefreshStallTimeout) {
        self.servingRefreshInProgress = NO;
        self.servingRefreshLastAttempt = now;
        self.refreshGeneration++;
    }
}

- (void)requestServingRefreshIfNeeded {
    [self clearStalledRefreshIfNeeded];
    if (!self.visible || self.servingRefreshInProgress) {
        return;
    }
    if (self.ratDebounceTimer) {
        self.refreshPending = YES;
        return;
    }
    // Never sample across a policy transition, a pending recovery, or an
    // outstanding setter. This guard predates the auto-refresh loop and is the
    // reason the tile can never contend with the modem write path.
    NSDictionary *policy = CCNMReadN78PolicyState();
    if (CCNMPolicyIsTransitioning(policy) || CCNMPolicyNeedsRecovery(policy) ||
        CCNMN78PolicyHasOutstandingSetter()) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.servingRefreshLastAttempt < CCNMServingRefreshMinimumInterval) {
        return;
    }
    self.refreshPending = NO;
    self.servingRefreshLastAttempt = now;
    self.servingRefreshStartedAt = now;
    self.servingRefreshInProgress = YES;
    NSUInteger generation = ++self.refreshGeneration;
    [self refreshModulePresentation];
    CCNMServingStatusProvider *provider = CCNMServingStatusProvider.sharedProvider;
    __weak typeof(self) weakSelf = self;
    [provider refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
        (void)summary;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            // A round that was superseded by a stall reset or a newer request
            // must not publish its result or clear the newer in-flight state.
            if (generation != strongSelf.refreshGeneration) {
                return;
            }
            strongSelf.servingRefreshInProgress = NO;
            strongSelf.servingSummary = provider.currentSummary;
            [strongSelf refreshModulePresentation];
            if (strongSelf.refreshPending && strongSelf.visible) {
                strongSelf.refreshPending = NO;
                [strongSelf requestServingRefreshIfNeeded];
            }
        });
    }];
}

- (void)adoptPublishedServingSummary {
    if (self.servingRefreshInProgress) {
        [self clearStalledRefreshIfNeeded];
        if (self.servingRefreshInProgress) {
            return;
        }
    }
    self.servingSummary = CCNMServingStatusProvider.sharedProvider.currentSummary;
    [self refreshModulePresentation];
}

#pragma mark - Presentation

- (void)refreshModulePresentation {
    NSDictionary *state = CCNMReadN78PolicyState();
    BOOL requested = CCNMPolicyIsRequested(state);
    NSString *text = nil;
    if (CCNMPolicyIsTransitioning(state)) {
        text = requested ? @"n78\n..." : @"Auto\n...";
    } else if (CCNMPolicyNeedsRecovery(state)) {
        text = requested ? @"n78\n!" : @"Auto\n!";
    } else {
        text = CCNMServingGlyphText(self.servingSummary, self.servingRefreshInProgress);
    }
    self.glyphImage = CCNMServingGlyphImage(text, UIColor.whiteColor);
    self.selectedGlyphImage = CCNMServingGlyphImage(text, UIColor.blackColor);
    // Selection mirrors policy truth. It is display only; the tile never writes.
    self.selected = requested;
}

@end

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
