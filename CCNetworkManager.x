#import "CCNetworkManager.h"
#import "networkmanagerprefs/CCNMN78PolicyController.h"

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

@interface CCNetworkManager ()
@property (nonatomic, assign) BOOL policyOperationPending;
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
        [module reconfigureView];
    });
}

@implementation CCNetworkManager

- (instancetype)init {
    self = [super init];
    if (self) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self,
            CCNMPolicyDidChangeCallback,
            (__bridge CFStringRef)CCNMN78PolicyDidChangeDarwinNotification,
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
}

- (UIImage *)iconGlyph {
    NSDictionary *state = CCNMReadN78PolicyState();
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 70, 70)];
    label.textColor = UIColor.blackColor;
    label.backgroundColor = UIColor.clearColor;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];

    if (self.policyOperationPending || CCNMPolicyIsTransitioning(state)) {
        label.text = @"n78\n...";
    } else if (CCNMPolicyNeedsRecovery(state)) {
        label.text = @"n78\n!";
    } else {
        label.text = @"n78";
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
    if (self.policyOperationPending) {
        [super reconfigureView];
        return;
    }
    NSDictionary *state = CCNMReadN78PolicyState();
    BOOL currentlyRequested = CCNMPolicyIsRequested(state);
    BOOL mayWrite = [state[CCNMN78PolicySummaryMayWriteKey] boolValue];
    if (selected == currentlyRequested || !mayWrite) {
        [super reconfigureView];
        return;
    }

    self.policyOperationPending = YES;
    __weak typeof(self) weakSelf = self;
    CCNMN78PolicyCompletion completion = ^(NSDictionary<NSString *, id> *summary) {
        (void)summary;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.policyOperationPending = NO;
            [weakSelf reconfigureView];
        });
    };
    if (selected) {
        CCNMEnableN78Preference(completion);
    } else {
        CCNMDisableN78Preference(completion);
    }

    [super reconfigureView];
}

@end
