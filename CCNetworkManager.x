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
// A sampler round that never reports back must not pin the tile forever. This
// budget has to clear the sampler's own worst case, not merely feel short. A
// full ten-round window costs, per round, up to 0.5 s of inter-sample delay,
// one Cell Monitor refresh wait bounded at 5 s, 0.5 s of settling, and one copy
// wait bounded at 5 s. That is about 110 s before a single round is genuinely
// hung. The previous 20 s budget sat far below it, so an ordinary slow round was
// declared stalled and its result discarded, which is a large part of why the
// tile sat on the searching glyph until the user tapped it. Sitting in flight is
// no longer expensive: the tile still adopts cross-process publishes while a
// round runs, and a dismissal clears the flag outright.
static const NSTimeInterval CCNMServingRefreshStallTimeout = 120.0;

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

// The glyph is white in every state, matching the split-out prototype and the
// stock tiles beside it.
//
// The amber accent of the original pre-n78 release was the toggle's
// -selectedColor, which fills the tile background while a toggle is on. It was
// never the glyph tint. CCUIButtonModuleViewController has no equivalent
// property, and moving the amber onto the glyph instead forced the selected
// state to find a second colour that could be told apart from it, which is where
// the dark text came from. Control Center draws its own selection treatment, so
// the glyph does not need to carry that distinction at all.
static UIColor *CCNMServingGlyphColor(void) {
    return UIColor.whiteColor;
}

// Returns nil when there is no serving band worth showing. The caller draws the
// searching antenna in that case instead of a bare question mark.
static NSString *CCNMServingGlyphText(NSDictionary *summary,
                                         BOOL awaitingCurrentRefresh) {
    if (awaitingCurrentRefresh ||
        ![summary[CCNMServingSummarySuccessKey] boolValue] ||
        [summary[CCNMServingSummaryStaleKey] boolValue]) {
        return nil;
    }
    NSNumber *band = summary[CCNMServingSummaryBandKey];
    if (![band isKindOfClass:NSNumber.class] || band.longLongValue <= 0) {
        return nil;
    }
    NSString *state = summary[CCNMServingSummaryStateKey];
    if ([state isEqual:CCNMServingStateLTE]) {
        return [NSString stringWithFormat:@"B%@", band];
    }
    if ([state isEqual:CCNMServingStateNRN78] ||
        [state isEqual:CCNMServingStateNROther]) {
        return [NSString stringWithFormat:@"n%@", band];
    }
    return nil;
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

// CGRectIntegral's semantics without CoreGraphics. CGRectMake and CGSizeMake are
// static inline in CGGeometry.h and cost nothing at link time, but CGRectIntegral
// is a real exported symbol, and calling it made this bundle link CoreGraphics.
// That is an unreviewed dependency for a binary loaded into SpringBoard, so the
// release gate rejected it. The rect this is applied to is always standardized by
// construction, so plain arithmetic on the fields is exact here.
static CGRect CCNMServingIntegralRect(CGRect rect) {
    CGFloat minX = floor(rect.origin.x);
    CGFloat minY = floor(rect.origin.y);
    CGFloat maxX = ceil(rect.origin.x + rect.size.width);
    CGFloat maxY = ceil(rect.origin.y + rect.size.height);
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

static UIImage *CCNMServingCenteredSymbolGlyphImage(UIImage *symbol, UIColor *tintColor) {
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
    UIImage *tinted = [symbol imageWithTintColor:tintColor
        renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsBeginImageContextWithOptions(canvasSize, NO, 0.0);
    [tinted drawInRect:CCNMServingIntegralRect(drawRect)];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// Cache key standing for the searching antenna. It is not a valid band string,
// so it cannot collide with one.
static NSString *const CCNMServingSearchingGlyphKey = @"__searching__";

// Shown whenever no serving band is available, including while a sample is in
// flight. This is the searching glyph the split-out prototype uses.
static UIImage *CCNMServingSearchingGlyphImage(UIColor *tintColor) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:25.0
            weight:UIImageSymbolWeightMedium];
    UIImage *symbol = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"
        withConfiguration:configuration];
    if (!symbol) {
        symbol = [UIImage systemImageNamed:@"magnifyingglass"
            withConfiguration:configuration];
    }
    return CCNMServingCenteredSymbolGlyphImage(symbol, tintColor)
        ?: CCNMServingGlyphImage(@"...", tintColor);
}

@interface CCNetworkManagerViewController ()
@property (nonatomic, assign) BOOL servingRefreshInProgress;
@property (nonatomic, assign) BOOL awaitingCurrentRefresh;
@property (nonatomic, assign) NSTimeInterval servingRefreshLastAttempt;
@property (nonatomic, assign) NSTimeInterval servingRefreshStartedAt;
@property (nonatomic, copy) NSDictionary<NSString *, id> *servingSummary;
@property (nonatomic, strong) NSTimer *visibleRefreshTimer;
@property (nonatomic, strong) NSTimer *ratDebounceTimer;
@property (nonatomic, assign) BOOL refreshPending;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) BOOL observersRegistered;
@property (nonatomic, assign) NSUInteger refreshGeneration;
// Published timestamp of the summary currently drawn, so a cross-process publish
// can be adopted exactly once and never regresses to an older sample.
@property (nonatomic, assign) long long appliedPublishedAtMilliseconds;
// Last policy state read from disk. The drawing path uses this instead of going
// back to the filesystem; see -refreshPolicySnapshot.
@property (nonatomic, copy) NSDictionary<NSString *, id> *policySnapshot;
// Glyph string the current images were rendered for, so an unchanged string does
// not pay for two fresh bitmaps.
@property (nonatomic, copy) NSString *drawnGlyphKey;

- (void)requestServingRefreshIfNeeded;
- (void)invalidateServingStatus;
- (void)refreshModulePresentation;
- (void)adoptPublishedServingSummary;
- (NSDictionary<NSString *, id> *)refreshPolicySnapshot;
- (void)applyPublishedSummary:(NSDictionary<NSString *, id> *)summary
        requireNewerTimestamp:(BOOL)requireNewerTimestamp;
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
        // The policy is what just changed, so the snapshot the drawing path reads
        // is stale by definition and has to be re-read here.
        [module refreshPolicySnapshot];
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
        _appliedPublishedAtMilliseconds = -1;
    }
    return self;
}

- (void)dealloc {
    [self endVisibleSession];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Both tints are deliberately the same colour. Whether the framework draws
    // the bitmap as supplied or re-tints it as a template, and whichever of the
    // two it picks for the current state, the glyph comes out white.
    self.glyphColor = CCNMServingGlyphColor();
    self.selectedGlyphColor = CCNMServingGlyphColor();
    // The glyph properties are passthroughs to a button view owned by the
    // framework, so a reloaded view starts with no glyph at all. Dropping the
    // render cache here is what guarantees the next presentation actually draws
    // instead of assuming the previous view's image is still installed.
    self.drawnGlyphKey = nil;
    // Draw the last published sample straight away so a freshly built tile shows
    // a band instead of the searching glyph while its first round runs.
    [self adoptPublishedServingSummary];
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

// Third begin trigger on purpose. Which of the three the framework actually
// delivers depends on how the tile is hosted, and beginVisibleSession is
// idempotent, so covering all three costs nothing and removes the single point of
// failure that leaves the tile with no refresh loop at all.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self beginVisibleSession];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self endVisibleSession];
}

- (void)beginVisibleSession {
    // All three presentation callbacks lead here because which one Control Center
    // delivers depends on how the tile is hosted. That redundancy must not turn
    // into three times the work: each pass costs a cross-process cache read, a
    // policy read and a presentation pass, and they land in the middle of the
    // open animation. Repeats after the first return immediately, and
    // -endVisibleSession clears the flag, so the next presentation runs in full.
    if (self.visible) {
        return;
    }
    self.visible = YES;
    [self registerObserversIfNeeded];
    [self adoptPublishedServingSummary];
    // A presentation is a user-initiated event just like a tap, so it is not
    // charged against the rate floor. Without this, opening Control Center
    // shortly after the previous round silently skipped the fresh sample and the
    // tile kept showing whatever the cache held.
    self.servingRefreshLastAttempt = 0;
    if (!self.visibleRefreshTimer) {
        __weak typeof(self) weakSelf = self;
        self.visibleRefreshTimer =
            [NSTimer timerWithTimeInterval:CCNMServingVisibleRefreshInterval
                repeats:YES
                block:^(NSTimer *timer) {
                    (void)timer;
                    [weakSelf visibleRefreshTimerFired];
                }];
        // Control Center is gesture driven, so its run loop spends real time in
        // tracking mode. A default-mode timer would simply not fire there, which
        // is why the tile appeared to refresh only when touched.
        [NSRunLoop.currentRunLoop addTimer:self.visibleRefreshTimer
            forMode:NSRunLoopCommonModes];
    }
    [self requestServingRefreshIfNeeded];
}

- (void)endVisibleSession {
    self.visible = NO;
    self.refreshPending = NO;
    // Abandon any in-flight round rather than carrying its flag into the next
    // presentation. A leaked flag used to block every trigger on reopen until the
    // stall budget expired, including a tap. The provider round itself keeps
    // running and still publishes; the generation bump only stops it from
    // reporting into this tile, and adoptPublishedServingSummary picks the result
    // up from the shared cache instead. A second round started before the first
    // one finishes cannot touch the modem: it fails to take the shared lock and
    // deliberately publishes nothing.
    if (self.servingRefreshInProgress) {
        self.servingRefreshInProgress = NO;
        self.refreshGeneration++;
    }
    self.awaitingCurrentRefresh = NO;
    [self.visibleRefreshTimer invalidate];
    self.visibleRefreshTimer = nil;
    [self.ratDebounceTimer invalidate];
    self.ratDebounceTimer = nil;
    // The policy can change while the tile is off screen, and the change
    // notification is not observed then, so the cached snapshot must not survive
    // a dismissal. Clearing it here rather than re-reading on the way back in
    // keeps the read lazy: whichever path draws or samples first pays for it once.
    self.policySnapshot = nil;
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
    // Independent off-screen check. The framework's dismissal callbacks are the
    // primary stop signal, but a view with no window is definitively not on
    // screen, so this bounds sampling even if a dismissal callback is missed. A
    // view that is on screen always has a window, so this cannot block the case
    // it is meant to serve.
    if (!self.view.window) {
        return;
    }
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
        // A RAT notification invalidates the displayed band immediately. Keep
        // the old summary for diagnostics/cache adoption, but do not present it
        // as the current serving result while the debounced sample is pending.
        strongSelf.awaitingCurrentRefresh = YES;
        [strongSelf refreshModulePresentation];
        [strongSelf.ratDebounceTimer invalidate];
        strongSelf.ratDebounceTimer =
            [NSTimer timerWithTimeInterval:CCNMServingRATDebounceSeconds
                repeats:NO
                block:^(NSTimer *timer) {
                    (void)timer;
                    [weakSelf ratDebounceTimerFired];
                }];
        [NSRunLoop.currentRunLoop addTimer:strongSelf.ratDebounceTimer
            forMode:NSRunLoopCommonModes];
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
    self.awaitingCurrentRefresh = YES;
    [self refreshModulePresentation];
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
    self.appliedPublishedAtMilliseconds = -1;
}

- (void)clearStalledRefreshIfNeeded {
    if (!self.servingRefreshInProgress) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.servingRefreshStartedAt > CCNMServingRefreshStallTimeout) {
        self.servingRefreshInProgress = NO;
        // Zero rather than now: the caller is about to re-evaluate the minimum
        // interval, and charging the abandoned round against that floor used to
        // swallow the immediate retry and leave the tile waiting a whole timer
        // period with nothing in flight.
        self.servingRefreshLastAttempt = 0;
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
    // Deliberately a fresh read rather than the cached snapshot. This is the
    // guard that keeps the tile off the modem while the settings page owns it,
    // and it must never act on a stale copy. It is also not on the drawing path:
    // it runs on a timer tick, a tap or a technology change, not on every
    // presentation pass.
    NSDictionary *policy = [self refreshPolicySnapshot];
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
            BOOL refreshAgain = strongSelf.refreshPending && strongSelf.visible;
            strongSelf.servingRefreshInProgress = NO;
            // Keep the searching state through a queued second round. The first
            // result may have started before the RAT transition that queued the
            // next round, so it is not yet authoritative for the current radio.
            strongSelf.awaitingCurrentRefresh = refreshAgain;
            // The provider already read and normalized the current published
            // summary before invoking this completion. Reusing it avoids a
            // second main-thread plist read on every refresh completion.
            [strongSelf applyPublishedSummary:summary requireNewerTimestamp:NO];
            if (refreshAgain) {
                strongSelf.refreshPending = NO;
                [strongSelf requestServingRefreshIfNeeded];
            }
        });
    }];
}

// Adopts whatever the shared provider last published. This must stay reachable
// while a round of this tile's own is in flight: the sampler publishes its result
// and posts the Darwin notification before this tile's completion block runs, and
// a round that is later declared stalled or superseded drops its result entirely.
// Refusing the publish while busy therefore threw away good samples, so the band
// only appeared once a tap forced a fresh round. The timestamp gate keeps a
// notification from redrawing the same sample twice or regressing to an older one.
- (void)adoptPublishedServingSummary {
    [self clearStalledRefreshIfNeeded];
    [self applyPublishedSummary:CCNMServingStatusProvider.sharedProvider.currentSummary
        requireNewerTimestamp:YES];
}

- (void)applyPublishedSummary:(NSDictionary<NSString *, id> *)summary
        requireNewerTimestamp:(BOOL)requireNewerTimestamp {
    if (![summary isKindOfClass:NSDictionary.class]) {
        return;
    }
    long long publishedAt =
        [summary[CCNMServingSummaryPublishedAtMillisecondsKey] longLongValue];
    if (requireNewerTimestamp && publishedAt <= self.appliedPublishedAtMilliseconds) {
        return;
    }
    self.appliedPublishedAtMilliseconds =
        MAX(self.appliedPublishedAtMilliseconds, publishedAt);
    self.servingSummary = summary;
    [self refreshModulePresentation];
}

#pragma mark - Presentation

// Re-reads the durable policy state and caches it for the drawing path. Every
// call is up to five plist loads off the filesystem, on the main thread, so the
// drawing path must not do it: presentation runs on adoption, on every timer
// tick, on every notification and on every completion, all of which can land
// during the open animation. It is re-read only where the value can actually
// have changed, which is a policy-change notification and the sampling guard,
// and the cache is dropped on dismissal because notifications are not observed
// off screen.
- (NSDictionary<NSString *, id> *)refreshPolicySnapshot {
    NSDictionary<NSString *, id> *state = CCNMReadN78PolicyState();
    self.policySnapshot = state;
    return state;
}

- (void)refreshModulePresentation {
    NSDictionary *state = self.policySnapshot ?: [self refreshPolicySnapshot];
    BOOL requested = CCNMPolicyIsRequested(state);
    NSString *text = nil;
    if (CCNMPolicyIsTransitioning(state)) {
        text = requested ? @"n78\n..." : @"Auto\n...";
    } else if (CCNMPolicyNeedsRecovery(state)) {
        text = requested ? @"n78\n!" : @"Auto\n!";
    } else {
        text = CCNMServingGlyphText(self.servingSummary, self.awaitingCurrentRefresh);
    }
    // No serving band to show, either because a sample is still in flight or
    // because the last one came back empty. Draw the searching antenna instead
    // of a bare question mark.
    NSString *glyphKey = text.length > 0 ? text : CCNMServingSearchingGlyphKey;
    // Rendering a glyph means an offscreen bitmap context and either a layer
    // render or a symbol draw. Presentation is called far more often than the
    // glyph actually changes, and redrawing the identical bitmap during the open
    // animation is pure jank. Both tints are the same colour now, so one image
    // serves both states.
    if (![glyphKey isEqualToString:self.drawnGlyphKey]) {
        UIImage *glyph = text.length > 0
            ? CCNMServingGlyphImage(text, CCNMServingGlyphColor())
            : CCNMServingSearchingGlyphImage(CCNMServingGlyphColor());
        self.glyphImage = glyph;
        self.selectedGlyphImage = glyph;
        self.drawnGlyphKey = glyphKey;
    }
    // Selection mirrors policy truth. It is display only; the tile never writes.
    // Assigned only on change: the framework reacts to this setter by running its
    // own state-change pass over the button view, and presentation is called far
    // more often than the policy changes.
    if (self.selected != requested) {
        self.selected = requested;
    }
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
