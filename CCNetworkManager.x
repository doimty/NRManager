#import "CCNetworkManager.h"
#import "networkmanagerprefs/CCNMN78PolicyController.h"
#import "networkmanagerprefs/CCNMServingStatusProvider.h"

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

@protocol CCNMGlyphReconfiguring <NSObject>
- (void)reconfigureView;
@end

@interface CCNetworkManager ()
@property (nonatomic, assign) BOOL servingRefreshInProgress;
@property (nonatomic, assign) NSTimeInterval servingRefreshLastAttempt;
@property (nonatomic, assign) NSTimeInterval servingRefreshStartedAt;
@property (nonatomic, copy) NSDictionary<NSString *, id> *servingSummary;

- (void)requestServingRefreshIfNeeded;
- (void)invalidateServingStatus;
- (void)refreshModulePresentation;
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
    CCNetworkManager *module = (__bridge CCNetworkManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [module invalidateServingStatus];
        [module refreshModulePresentation];
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
    CCNetworkManager *module = (__bridge CCNetworkManager *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        module.servingSummary = CCNMServingStatusProvider.sharedProvider.currentSummary;
        module.servingRefreshInProgress = NO;
        [module refreshModulePresentation];
    });
}

@implementation CCNetworkManager

- (instancetype)init {
    self = [super init];
    if (self) {
        self.servingSummary = CCNMServingStatusEmptySummary();
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
    return self;
}

- (void)dealloc {
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

- (void)refreshModulePresentation {
    [self refreshState];
    id<CCNMGlyphReconfiguring> controller = (id)self.contentViewController;
    if ([controller respondsToSelector:@selector(reconfigureView)]) {
        [controller reconfigureView];
    }
}

- (void)invalidateServingStatus {
    self.servingSummary = CCNMServingStatusEmptySummary();
    self.servingRefreshLastAttempt = 0;
}

- (void)requestServingRefreshIfNeeded {
    if (self.servingRefreshInProgress) {
        return;
    }
    NSDictionary *policy = CCNMReadN78PolicyState();
    if (CCNMPolicyIsTransitioning(policy) || CCNMPolicyNeedsRecovery(policy) ||
        CCNMN78PolicyHasOutstandingSetter()) {
        return;
    }
    CCNMServingStatusProvider *provider = CCNMServingStatusProvider.sharedProvider;
    NSDictionary *current = provider.currentSummary;
    self.servingSummary = current;
    BOOL fresh = [current[CCNMServingSummarySuccessKey] boolValue] &&
        ![current[CCNMServingSummaryStaleKey] boolValue];
    if (fresh) {
        return;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.servingRefreshLastAttempt < 10.0) {
        return;
    }
    self.servingRefreshLastAttempt = now;
    self.servingRefreshStartedAt = now;
    self.servingRefreshInProgress = YES;
    __weak typeof(self) weakSelf = self;
    [provider refreshWithCompletion:^(NSDictionary<NSString *, id> *summary) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.servingSummary = provider.currentSummary;
        self.servingRefreshInProgress = NO;
        [self refreshModulePresentation];
    }];
}

- (UIImage *)iconGlyph {
    NSDictionary *state = CCNMReadN78PolicyState();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.servingRefreshInProgress &&
        now - self.servingRefreshStartedAt > 20.0) {
        self.servingRefreshInProgress = NO;
        self.servingRefreshLastAttempt = now;
    }
    [self requestServingRefreshIfNeeded];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.textColor = UIColor.blackColor;
    label.backgroundColor = UIColor.clearColor;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];

    BOOL requested = CCNMPolicyIsRequested(state);
    if (CCNMPolicyIsTransitioning(state)) {
        label.text = requested ? @"n78\n..." : @"Auto\n...";
    } else if (CCNMPolicyNeedsRecovery(state)) {
        label.text = requested ? @"n78\n!" : @"Auto\n!";
    } else {
        label.text = CCNMServingGlyphText(self.servingSummary, self.servingRefreshInProgress);
    }

    UIGraphicsBeginImageContextWithOptions(label.bounds.size, NO, 0.0);
    [label.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIColor *)selectedColor {
    return [UIColor colorWithRed:0.04 green:0.48 blue:1.0 alpha:1.0];
}

- (BOOL)isSelected {
    return CCNMPolicyIsRequested(CCNMReadN78PolicyState());
}

- (void)setSelected:(BOOL)selected {
    (void)selected;
    [self refreshModulePresentation];
}

@end
