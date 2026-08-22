#import "CCNMRootListController.h"
#import "CCNMN78PolicyController.h"
#import "CCNMPreferencesCells.h"
#import "CCNMServingStatusProvider.h"

static NSString * const CCNMN78PreferenceSpecifierID = @"n78Preference";
static NSString * const CCNMTransitionStateSpecifierID = @"transitionState";
static NSString * const CCNMRequestedPolicySpecifierID = @"requestedPolicy";
static NSString * const CCNMAppliedPolicySpecifierID = @"appliedPolicy";
static NSString * const CCNMServingStateSpecifierID = @"servingState";
static NSString * const CCNMDataLineSpecifierID = @"dataLine";
static NSString * const CCNMFreshnessSpecifierID = @"freshness";
static NSString * const CCNMRefreshSpecifierID = @"refreshServingStatus";
static NSString * const CCNMKnownOrphanRecoveryGroupSpecifierID = @"knownOrphanRecoveryGroup";
static NSString * const CCNMKnownOrphanRecoverySpecifierID = @"recoverKnownOrphanedN78";
static NSString * const CCNMRecoveryGroupSpecifierID = @"recoveryGroup";
static NSString * const CCNMRecoveryStateSpecifierID = @"recoveryState";
static NSString * const CCNMRebootRequirementSpecifierID = @"rebootRequirement";
static NSString * const CCNMRestoreSpecifierID = @"restoreOriginalBands";
static NSString * const CCNMAboutGroupSpecifierID = @"aboutGroup";

@interface CCNMRootListController ()

@property (nonatomic, assign) BOOL n78PreferenceEnabled;
@property (nonatomic, assign) BOOL n78PreferenceControlAvailable;
@property (nonatomic, assign) BOOL knownOrphanedN78RecoveryEligible;
@property (nonatomic, assign) NSUInteger knownOrphanRecoveryProbeGeneration;
@property (nonatomic, assign) BOOL recoverySectionVisible;
@property (nonatomic, assign) BOOL hasRecoverableBaseline;
@property (nonatomic, assign) BOOL requiresReboot;
@property (nonatomic, copy) NSArray<PSSpecifier *> *knownOrphanRecoverySpecifiers;
@property (nonatomic, copy) NSArray<PSSpecifier *> *recoverySpecifiers;
@property (nonatomic, copy) NSDictionary<NSString *, id> *policySummary;
@property (nonatomic, copy) NSDictionary<NSString *, id> *servingSummary;
@property (nonatomic, assign) BOOL policyOperationInProgress;
@property (nonatomic, assign) BOOL servingRefreshInProgress;

- (void)configureProductionHandlers;
- (void)refreshPolicyState;
- (void)refreshKnownOrphanedN78RecoveryEligibility;
- (void)requestN78PreferenceEnabled:(BOOL)enabled;
- (void)beginPolicyRecovery;
- (void)beginKnownOrphanedN78Recovery;
- (void)applyPolicySummary:(NSDictionary<NSString *, id> *)summary;
- (void)beginServingRefresh;
- (void)applyServingSummary:(NSDictionary<NSString *, id> *)summary;
- (void)showPolicyFailureForSummary:(NSDictionary<NSString *, id> *)summary;
- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers;
- (NSArray<PSSpecifier *> *)knownOrphanRecoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers;
- (NSArray<PSSpecifier *> *)recoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers;
- (PSSpecifier *)recoverySpecifierForID:(NSString *)identifier;
- (void)setDisplayValue:(NSString *)valueOrLocalizationKey forSpecifierID:(NSString *)identifier;
- (id)readN78PreferenceValue:(PSSpecifier *)specifier;
- (void)setN78PreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)refreshServingStatus:(PSSpecifier *)specifier;
- (void)restoreOriginalBandConfiguration:(PSSpecifier *)specifier;
- (void)confirmKnownOrphanedN78Recovery:(PSSpecifier *)specifier;
- (void)openRepository:(PSSpecifier *)specifier;
- (void)showLinkOpenFailure;
- (void)rebuildRecoverySection;

@end

@implementation CCNMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSBundle *bundle = [NSBundle bundleForClass:self.class];
        NSMutableArray<PSSpecifier *> *loaded = [[self loadSpecifiersFromPlistName:@"Root"
                                                                                target:self
                                                                                bundle:bundle] mutableCopy];
        [self localizeSpecifiers:loaded];

        self.knownOrphanRecoverySpecifiers = [self knownOrphanRecoverySpecifiersFromArray:loaded];
        self.recoverySpecifiers = [self recoverySpecifiersFromArray:loaded];
        [loaded removeObjectsInArray:self.knownOrphanRecoverySpecifiers];
        [loaded removeObjectsInArray:self.recoverySpecifiers];
        _specifiers = loaded;
    }

    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CCNMPreferencesLocalizedString(@"SETTINGS_TITLE");
    [self configureProductionHandlers];
    [self refreshPolicyState];

    self.servingSummary = [[CCNMServingStatusProvider sharedProvider] currentSummary];
    [self applyServingSummary:self.servingSummary];
    if ([self.servingSummary[CCNMServingSummaryStaleKey] boolValue]) {
        [self beginServingRefresh];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPolicyState];
    NSDictionary *current = [[CCNMServingStatusProvider sharedProvider] currentSummary];
    self.servingSummary = current;
    [self applyServingSummary:current];
    if ([current[CCNMServingSummaryStaleKey] boolValue] &&
        ![current[CCNMServingSummaryUnsafeOutstandingKey] boolValue]) {
        [self beginServingRefresh];
    }
}

- (void)configureProductionHandlers {
    __weak typeof(self) weakSelf = self;
    self.n78PreferenceRequestHandler = ^(BOOL enabled) {
        [weakSelf requestN78PreferenceEnabled:enabled];
    };
    self.refreshServingStatusHandler = ^{
        [weakSelf beginServingRefresh];
    };
    self.restoreOriginalBandConfigurationHandler = ^{
        [weakSelf beginPolicyRecovery];
    };
    self.recoverKnownOrphanedN78Handler = ^{
        [weakSelf beginKnownOrphanedN78Recovery];
    };
}

- (void)refreshPolicyState {
    [self applyPolicySummary:CCNMReadN78PolicyState()];
    [self refreshKnownOrphanedN78RecoveryEligibility];
}

- (void)refreshKnownOrphanedN78RecoveryEligibility {
    NSUInteger probeGeneration = ++self.knownOrphanRecoveryProbeGeneration;
    if (self.policyOperationInProgress) {
        self.knownOrphanedN78RecoveryEligible = NO;
        [self rebuildRecoverySection];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *eligibility = CCNMReadKnownOrphanedN78RecoveryEligibility();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.policyOperationInProgress ||
                probeGeneration != self.knownOrphanRecoveryProbeGeneration) {
                return;
            }
            self.knownOrphanedN78RecoveryEligible = [eligibility[@"eligible"] boolValue];
            [self rebuildRecoverySection];
        });
    });
}

- (void)requestN78PreferenceEnabled:(BOOL)enabled {
    if (self.policyOperationInProgress) {
        return;
    }
    self.policyOperationInProgress = YES;
    [self rebuildRecoverySection];
    [self updateTransitionStateWithLocalizationKey:@"TRANSITION_APPLYING"];
    [self updateN78PreferenceEnabled:[self.policySummary[CCNMN78PolicySummaryRequestedModeKey]
        isEqual:CCNMRequestedModeN78Preferred] controlAvailable:NO];
    [self applyServingSummary:self.servingSummary];

    __weak typeof(self) weakSelf = self;
    CCNMN78PolicyCompletion completion = ^(NSDictionary<NSString *, id> *summary) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.policyOperationInProgress = NO;
        [self applyPolicySummary:summary];
        if (![summary[CCNMN78PolicySummarySuccessKey] boolValue]) {
            [self showPolicyFailureForSummary:summary];
        } else {
            [self beginServingRefresh];
        }
    };
    if (enabled) {
        CCNMEnableN78Preference(completion);
    } else {
        CCNMDisableN78Preference(completion);
    }
}

- (void)beginPolicyRecovery {
    if (self.policyOperationInProgress) {
        return;
    }
    self.policyOperationInProgress = YES;
    [self rebuildRecoverySection];
    [self updateTransitionStateWithLocalizationKey:@"TRANSITION_APPLYING"];
    [self updateN78PreferenceEnabled:[self.policySummary[CCNMN78PolicySummaryRequestedModeKey]
        isEqual:CCNMRequestedModeN78Preferred] controlAvailable:NO];
    [self applyServingSummary:self.servingSummary];

    __weak typeof(self) weakSelf = self;
    CCNMRecoverN78Preference(^(NSDictionary<NSString *, id> *summary) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.policyOperationInProgress = NO;
        [self applyPolicySummary:summary];
        if (![summary[CCNMN78PolicySummarySuccessKey] boolValue]) {
            [self showPolicyFailureForSummary:summary];
        } else {
            [self beginServingRefresh];
        }
    });
}

- (void)beginKnownOrphanedN78Recovery {
    if (self.policyOperationInProgress || !self.knownOrphanedN78RecoveryEligible) {
        return;
    }
    self.policyOperationInProgress = YES;
    ++self.knownOrphanRecoveryProbeGeneration;
    self.knownOrphanedN78RecoveryEligible = NO;
    [self rebuildRecoverySection];
    [self updateTransitionStateWithLocalizationKey:@"TRANSITION_APPLYING"];
    [self updateN78PreferenceEnabled:NO controlAvailable:NO];
    [self applyServingSummary:self.servingSummary];

    __weak typeof(self) weakSelf = self;
    CCNMRecoverKnownOrphanedN78WithCompletion(^(NSDictionary<NSString *, id> *summary) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.policyOperationInProgress = NO;
        [self applyPolicySummary:summary];
        [self refreshKnownOrphanedN78RecoveryEligibility];
        if (![summary[CCNMN78PolicySummarySuccessKey] boolValue]) {
            [self showPolicyFailureForSummary:summary];
        } else {
            [self beginServingRefresh];
        }
    });
}

- (NSString *)requestedPolicyDisplayValue:(NSDictionary *)summary {
    return [summary[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred]
        ? CCNMPreferencesLocalizedString(@"REQUESTED_N78_PREFERENCE")
        : CCNMPreferencesLocalizedString(@"REQUESTED_SYSTEM_DEFAULT");
}

- (NSString *)appliedPolicyDisplayValue:(NSDictionary *)summary {
    NSString *applied = summary[CCNMN78PolicySummaryAppliedPolicyKey];
    NSDictionary *keys = @{
        CCNMAppliedPolicyUnknown: @"APPLIED_UNKNOWN",
        CCNMAppliedPolicyApplying: @"APPLIED_APPLYING",
        CCNMAppliedPolicyVerifiedSystemDefault: @"APPLIED_VERIFIED_SYSTEM_DEFAULT",
        CCNMAppliedPolicyVerifiedN78Only: @"APPLIED_VERIFIED_N78_ONLY",
        CCNMAppliedPolicyDiverged: @"APPLIED_DIVERGED",
        CCNMAppliedPolicyRecoveryRequired: @"APPLIED_RECOVERY_REQUIRED",
    };
    return CCNMPreferencesLocalizedString(keys[applied] ?: @"APPLIED_UNKNOWN");
}

- (NSString *)recoveryDisplayValue:(NSDictionary *)summary {
    NSString *recovery = summary[CCNMN78PolicySummaryRecoveryStateKey];
    NSDictionary *keys = @{
        CCNMRecoveryStateClean: @"RECOVERY_STATE_CLEAN",
        CCNMRecoveryStateEnablePending: @"RECOVERY_STATE_ENABLE_PENDING",
        CCNMRecoveryStateEnabledWithBaseline: @"RECOVERY_STATE_ENABLED_WITH_BASELINE",
        CCNMRecoveryStateRestorePending: @"RECOVERY_STATE_RESTORE_PENDING",
        CCNMRecoveryStateRebootRequired: @"RECOVERY_STATE_REBOOT_REQUIRED",
        CCNMRecoveryStateRecoveryFailed: @"RECOVERY_STATE_FAILED",
    };
    return CCNMPreferencesLocalizedString(keys[recovery] ?: @"RECOVERY_STATE_FAILED");
}

- (void)applyPolicySummary:(NSDictionary<NSString *, id> *)summary {
    self.policySummary = summary ?: @{};
    NSString *requestedMode = summary[CCNMN78PolicySummaryRequestedModeKey];
    NSString *appliedPolicy = summary[CCNMN78PolicySummaryAppliedPolicyKey];
    NSString *recoveryState = summary[CCNMN78PolicySummaryRecoveryStateKey];
    BOOL requested = [requestedMode isEqual:CCNMRequestedModeN78Preferred];
    BOOL mayWrite = [summary[CCNMN78PolicySummaryMayWriteKey] boolValue] &&
        !self.policyOperationInProgress && !self.servingRefreshInProgress &&
        ![self.servingSummary[CCNMServingSummaryUnsafeOutstandingKey] boolValue];
    [self updateN78PreferenceEnabled:requested controlAvailable:mayWrite];

    NSString *transitionKey = @"TRANSITION_RECOVERY_REQUIRED";
    if ([appliedPolicy isEqual:CCNMAppliedPolicyApplying]) {
        transitionKey = @"TRANSITION_APPLYING";
    } else if ([recoveryState isEqual:CCNMRecoveryStateClean] ||
        [recoveryState isEqual:CCNMRecoveryStateEnabledWithBaseline]) {
        transitionKey = @"TRANSITION_VERIFIED";
    }
    [self updateTransitionStateWithLocalizationKey:transitionKey];

    [self setDisplayValue:[self requestedPolicyDisplayValue:summary]
           forSpecifierID:CCNMRequestedPolicySpecifierID];
    [self setDisplayValue:[self appliedPolicyDisplayValue:summary]
           forSpecifierID:CCNMAppliedPolicySpecifierID];

    BOOL baselineValid = [summary[@"baselineValid"] boolValue];
    BOOL recoveryVisible = ![recoveryState isEqual:CCNMRecoveryStateClean];
    [self updateRecoveryStateWithLocalizationKey:[self recoveryDisplayValue:summary]
                                         visible:recoveryVisible
                          hasRecoverableBaseline:baselineValid
                                  requiresReboot:[summary[CCNMN78PolicySummaryRequiresRebootKey] boolValue]];
}

- (NSString *)servingDisplayValue:(NSDictionary *)summary {
    if ([summary[CCNMServingSummaryUnsafeOutstandingKey] boolValue]) {
        return CCNMPreferencesLocalizedString(@"SERVING_UNKNOWN_RESTART_SETTINGS");
    }
    if ([summary[CCNMServingSummaryStaleKey] boolValue] ||
        ![summary[CCNMServingSummarySuccessKey] boolValue]) {
        return CCNMPreferencesLocalizedString(@"SERVING_UNKNOWN_STALE");
    }
    NSString *state = summary[CCNMServingSummaryStateKey];
    NSNumber *band = [summary[CCNMServingSummaryBandKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummaryBandKey] : nil;
    NSNumber *frequency = [summary[CCNMServingSummaryFrequencyMHzKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummaryFrequencyMHzKey] : nil;
    if ([state isEqual:CCNMServingStateNRN78]) {
        if (frequency) {
            NSString *machineFrequency = [NSString stringWithFormat:@"%.3f MHz", frequency.doubleValue];
            return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"SERVING_NR_N78_FORMAT"), machineFrequency];
        }
        return CCNMPreferencesLocalizedString(@"SERVING_NR_N78");
    }
    if ([state isEqual:CCNMServingStateNROther]) {
        NSString *machineBand = band ? [NSString stringWithFormat:@"n%@", band] : @"NR";
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"SERVING_NR_OTHER_FORMAT"), machineBand];
    }
    if ([state isEqual:CCNMServingStateLTE]) {
        NSString *machineBand = band ? [NSString stringWithFormat:@"B%@", band] : @"B?";
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"SERVING_LTE_FORMAT"), machineBand];
    }
    return CCNMPreferencesLocalizedString(@"SERVING_OTHER");
}

- (NSString *)freshnessDisplayValue:(NSDictionary *)summary {
    long long milliseconds = [summary[CCNMServingSummarySampledAtMillisecondsKey] longLongValue];
    if (milliseconds <= 0) {
        return CCNMPreferencesLocalizedString(@"VALUE_UNKNOWN");
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)milliseconds / 1000.0];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    NSString *timestamp = [formatter stringFromDate:date] ?: @"";
    NSString *formatKey = [summary[CCNMServingSummaryStaleKey] boolValue]
        ? @"FRESHNESS_STALE_FORMAT" : @"FRESHNESS_UPDATED_FORMAT";
    return [NSString stringWithFormat:CCNMPreferencesLocalizedString(formatKey), timestamp];
}

// The read path supports any slot, so the row must report which subscription was
// actually sampled rather than assuming slot 1.
- (NSString *)dataLineDisplayValue:(NSDictionary *)summary {
    NSString *dataLine = [summary[CCNMServingSummaryDataLineKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummaryDataLineKey] : @"";
    if ([dataLine isEqualToString:@"slot1"]) {
        return CCNMPreferencesLocalizedString(@"DATA_LINE_SLOT_1");
    }
    if ([dataLine isEqualToString:@"slot2"]) {
        return CCNMPreferencesLocalizedString(@"DATA_LINE_SLOT_2");
    }
    if ([dataLine hasPrefix:@"slot"] && dataLine.length > 4) {
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"DATA_LINE_FORMAT"),
            [dataLine substringFromIndex:4]];
    }
    return CCNMPreferencesLocalizedString(@"VALUE_UNKNOWN");
}

- (void)beginServingRefresh {
    if (self.servingRefreshInProgress || self.policyOperationInProgress ||
        [self.servingSummary[CCNMServingSummaryUnsafeOutstandingKey] boolValue]) {
        return;
    }
    self.servingRefreshInProgress = YES;
    [self rebuildRecoverySection];
    [self updateN78PreferenceEnabled:[self.policySummary[CCNMN78PolicySummaryRequestedModeKey]
        isEqual:CCNMRequestedModeN78Preferred] controlAvailable:NO];
    [self setDisplayValue:@"FRESHNESS_REFRESHING" forSpecifierID:CCNMFreshnessSpecifierID];
    [self updateCurrentStateWithRequestedValue:[self requestedPolicyDisplayValue:self.policySummary]
                                  appliedValue:[self appliedPolicyDisplayValue:self.policySummary]
                                  servingValue:[self servingDisplayValue:self.servingSummary]
                                 dataLineValue:[self dataLineDisplayValue:self.servingSummary]
                                freshnessValue:CCNMPreferencesLocalizedString(@"FRESHNESS_REFRESHING")
                              refreshAvailable:NO];

    __weak typeof(self) weakSelf = self;
    [[CCNMServingStatusProvider sharedProvider] refreshWithCompletion:^(NSDictionary<NSString *,id> *summary) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.servingRefreshInProgress = NO;
        self.servingSummary = summary;
        [self refreshPolicyState];
        [self applyServingSummary:summary];
    }];
}

- (void)applyServingSummary:(NSDictionary<NSString *, id> *)summary {
    self.servingSummary = summary ?: CCNMServingStatusEmptySummary();
    [self updateCurrentStateWithRequestedValue:[self requestedPolicyDisplayValue:self.policySummary]
                                  appliedValue:[self appliedPolicyDisplayValue:self.policySummary]
                                  servingValue:[self servingDisplayValue:self.servingSummary]
                                 dataLineValue:[self dataLineDisplayValue:self.servingSummary]
                                freshnessValue:[self freshnessDisplayValue:self.servingSummary]
                              refreshAvailable:!self.servingRefreshInProgress && !self.policyOperationInProgress &&
                                  ![self.servingSummary[CCNMServingSummaryUnsafeOutstandingKey] boolValue]];
}

// The device the policy actually measured, when the failure carried it. Returns
// an empty string rather than a partial line, so a summary that never reached the
// target check does not invent identity values.
- (NSString *)measuredDeviceDescription:(NSDictionary<NSString *, id> *)summary {
    NSString *model = [summary[@"deviceModel"] isKindOfClass:NSString.class]
        ? summary[@"deviceModel"] : @"";
    NSString *version = [summary[@"systemVersion"] isKindOfClass:NSString.class]
        ? summary[@"systemVersion"] : @"";
    NSString *build = [summary[@"systemBuild"] isKindOfClass:NSString.class]
        ? summary[@"systemBuild"] : @"";
    if (model.length == 0 || version.length == 0 || build.length == 0) {
        return @"";
    }
    return [NSString stringWithFormat:
        CCNMPreferencesLocalizedString(@"POLICY_ERROR_MEASURED_DEVICE_FORMAT"),
        model, version, build];
}

- (NSString *)policyFailureLocalizationKey:(NSString *)errorCode {
    if ([errorCode isEqual:CCNMN78PolicyErrorBusy]) return @"POLICY_ERROR_BUSY";
    if ([errorCode isEqual:CCNMN78PolicyErrorUnsupportedTarget]) return @"POLICY_ERROR_UNSUPPORTED_TARGET";
    if ([errorCode isEqual:CCNMN78PolicyErrorUnsafeSubscription] ||
        [errorCode isEqual:CCNMN78PolicyErrorUUIDDrift]) return @"POLICY_ERROR_SUBSCRIPTION";
    if ([errorCode isEqual:CCNMN78PolicyErrorBaselineIncompatible]) return @"POLICY_ERROR_BASELINE_INCOMPATIBLE";
    if ([errorCode isEqual:CCNMN78PolicyErrorN78Unavailable]) return @"POLICY_ERROR_N78_UNAVAILABLE";
    if ([errorCode isEqual:CCNMN78PolicyErrorSetterUncertain]) return @"POLICY_ERROR_REBOOT_REQUIRED";
    if ([errorCode isEqual:CCNMN78PolicyErrorRecoveryRequired] ||
        [errorCode isEqual:CCNMN78PolicyErrorInvalidRecords]) return @"POLICY_ERROR_RECOVERY_REQUIRED";
    return @"POLICY_ERROR_GENERIC";
}

- (void)showPolicyFailureForSummary:(NSDictionary<NSString *, id> *)summary {
    NSString *errorCode = [summary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
        ? summary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
    NSString *technicalError = [summary[CCNMN78PolicySummaryErrorKey] isKindOfClass:NSString.class]
        ? summary[CCNMN78PolicySummaryErrorKey] : @"";
    NSString *key = [self policyFailureLocalizationKey:errorCode];
    NSString *message = [NSString stringWithFormat:
        CCNMPreferencesLocalizedString(@"POLICY_ERROR_DIAGNOSTIC_FORMAT"),
        CCNMPreferencesLocalizedString(key), errorCode,
        technicalError.length > 0 ? technicalError : CCNMPreferencesLocalizedString(@"VALUE_UNKNOWN")];
    // The target check reports what it measured, so say so. Stating only which
    // device is accepted leaves the user to look up their own model and build by
    // hand to find out why they were refused.
    NSString *measured = [self measuredDeviceDescription:summary];
    if (measured.length > 0) {
        message = [message stringByAppendingFormat:@"\n%@", measured];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"POLICY_ERROR_TITLE")
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_OK")
        style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers {
    NSArray<NSString *> *localizedPropertyKeys = @[
        PSTitleKey,
        PSFooterTextGroupKey,
        CCNMPreferenceSubtitleKey,
        CCNMPreferenceValueKey,
    ];

    for (PSSpecifier *specifier in specifiers) {
        for (NSString *propertyKey in localizedPropertyKeys) {
            NSString *localizationKey = [specifier propertyForKey:propertyKey];
            if (![localizationKey isKindOfClass:NSString.class] || localizationKey.length == 0) {
                continue;
            }

            NSString *localizedValue = CCNMPreferencesLocalizedString(localizationKey);
            [specifier setProperty:localizedValue forKey:propertyKey];
            if ([propertyKey isEqualToString:PSTitleKey]) {
                specifier.name = localizedValue;
            }
        }
    }
}

- (NSArray<PSSpecifier *> *)knownOrphanRecoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers {
    NSSet<NSString *> *knownOrphanIDs = [NSSet setWithArray:@[
        CCNMKnownOrphanRecoveryGroupSpecifierID,
        CCNMKnownOrphanRecoverySpecifierID,
    ]];
    NSMutableArray<PSSpecifier *> *result = [NSMutableArray array];
    for (PSSpecifier *specifier in specifiers) {
        if ([knownOrphanIDs containsObject:specifier.identifier]) {
            [result addObject:specifier];
        }
    }
    return result;
}

- (NSArray<PSSpecifier *> *)recoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers {
    NSSet<NSString *> *recoveryIDs = [NSSet setWithArray:@[
        CCNMRecoveryGroupSpecifierID,
        CCNMRecoveryStateSpecifierID,
        CCNMRebootRequirementSpecifierID,
        CCNMRestoreSpecifierID,
    ]];
    NSMutableArray<PSSpecifier *> *result = [NSMutableArray array];

    for (PSSpecifier *specifier in specifiers) {
        if ([recoveryIDs containsObject:specifier.identifier]) {
            [result addObject:specifier];
        }
    }
    return result;
}

- (PSSpecifier *)recoverySpecifierForID:(NSString *)identifier {
    for (PSSpecifier *specifier in self.recoverySpecifiers) {
        if ([specifier.identifier isEqualToString:identifier]) {
            return specifier;
        }
    }
    return nil;
}

- (void)setDisplayValue:(NSString *)valueOrLocalizationKey forSpecifierID:(NSString *)identifier {
    NSString *displayValue = valueOrLocalizationKey.length > 0
        ? CCNMPreferencesLocalizedString(valueOrLocalizationKey)
        : CCNMPreferencesLocalizedString(@"VALUE_UNKNOWN");
    PSSpecifier *specifier = [self specifierForID:identifier];
    if (!specifier) {
        specifier = [self recoverySpecifierForID:identifier];
    }
    if (!specifier) {
        return;
    }

    [specifier setProperty:displayValue forKey:CCNMPreferenceValueKey];
    if ([_specifiers containsObject:specifier] && self.isViewLoaded) {
        [self reloadSpecifier:specifier animated:NO];
    }
}

- (id)readN78PreferenceValue:(PSSpecifier *)specifier {
    (void)specifier;
    return @(self.n78PreferenceEnabled);
}

- (void)setN78PreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (self.n78PreferenceControlAvailable && self.n78PreferenceRequestHandler) {
        self.n78PreferenceRequestHandler([value boolValue]);
    }

    // The switch reflects verified requested state, not an optimistic tap.
    [self reloadSpecifier:specifier animated:YES];
}

- (void)refreshServingStatus:(PSSpecifier *)specifier {
    (void)specifier;
    if (self.refreshServingStatusHandler) {
        self.refreshServingStatusHandler();
    }
}

- (void)restoreOriginalBandConfiguration:(PSSpecifier *)specifier {
    (void)specifier;
    if (!self.hasRecoverableBaseline || self.requiresReboot || self.policyOperationInProgress ||
        self.servingRefreshInProgress || !self.restoreOriginalBandConfigurationHandler) {
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"RESTORE_ALERT_TITLE")
        message:CCNMPreferencesLocalizedString(@"RESTORE_ALERT_MESSAGE")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_CANCEL")
        style:UIAlertActionStyleCancel
        handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_RESTORE")
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            CCNMSettingsActionHandler handler = weakSelf.restoreOriginalBandConfigurationHandler;
            if (handler) {
                handler();
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmKnownOrphanedN78Recovery:(PSSpecifier *)specifier {
    (void)specifier;
    if (!self.knownOrphanedN78RecoveryEligible || self.policyOperationInProgress ||
        self.servingRefreshInProgress || !self.recoverKnownOrphanedN78Handler) {
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"KNOWN_ORPHAN_RECOVERY_ALERT_TITLE")
        message:CCNMPreferencesLocalizedString(@"KNOWN_ORPHAN_RECOVERY_ALERT_MESSAGE")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_CANCEL")
        style:UIAlertActionStyleCancel
        handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_RECOVER_KNOWN_ORPHAN")
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            CCNMSettingsActionHandler handler = weakSelf.recoverKnownOrphanedN78Handler;
            if (handler) {
                handler();
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openRepository:(PSSpecifier *)specifier {
    NSString *URLString = [specifier propertyForKey:CCNMPreferenceURLKey];
    NSURLComponents *components = [URLString isKindOfClass:NSString.class]
        ? [NSURLComponents componentsWithString:URLString]
        : nil;
    if (![components.scheme.lowercaseString isEqualToString:@"https"] ||
        ![components.host.lowercaseString isEqualToString:@"github.com"] ||
        components.URL == nil) {
        [self showLinkOpenFailure];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [UIApplication.sharedApplication openURL:components.URL
                                     options:@{}
                           completionHandler:^(BOOL success) {
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showLinkOpenFailure];
            });
        }
    }];
}

- (void)showLinkOpenFailure {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"LINK_OPEN_FAILED_TITLE")
        message:CCNMPreferencesLocalizedString(@"LINK_OPEN_FAILED_MESSAGE")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_OK")
        style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateN78PreferenceEnabled:(BOOL)enabled controlAvailable:(BOOL)available {
    (void)[self specifiers];
    self.n78PreferenceEnabled = enabled;
    self.n78PreferenceControlAvailable = available && self.n78PreferenceRequestHandler != nil;

    PSSpecifier *specifier = [self specifierForID:CCNMN78PreferenceSpecifierID];
    if (!specifier) {
        return;
    }
    [specifier setProperty:@(self.n78PreferenceControlAvailable) forKey:PSEnabledKey];
    if (self.isViewLoaded) {
        [self reloadSpecifier:specifier animated:NO];
    }
}

- (void)updateTransitionStateWithLocalizationKey:(NSString *)localizationKey {
    (void)[self specifiers];
    [self setDisplayValue:localizationKey forSpecifierID:CCNMTransitionStateSpecifierID];
}

- (void)updateCurrentStateWithRequestedValue:(NSString *)requestedValue
                                appliedValue:(NSString *)appliedValue
                                servingValue:(NSString *)servingValue
                               dataLineValue:(NSString *)dataLineValue
                              freshnessValue:(NSString *)freshnessValue
                            refreshAvailable:(BOOL)refreshAvailable {
    (void)[self specifiers];
    [self setDisplayValue:requestedValue forSpecifierID:CCNMRequestedPolicySpecifierID];
    [self setDisplayValue:appliedValue forSpecifierID:CCNMAppliedPolicySpecifierID];
    [self setDisplayValue:servingValue forSpecifierID:CCNMServingStateSpecifierID];
    [self setDisplayValue:dataLineValue forSpecifierID:CCNMDataLineSpecifierID];
    [self setDisplayValue:freshnessValue forSpecifierID:CCNMFreshnessSpecifierID];

    PSSpecifier *refreshSpecifier = [self specifierForID:CCNMRefreshSpecifierID];
    if (!refreshSpecifier) {
        return;
    }
    BOOL enabled = refreshAvailable && self.refreshServingStatusHandler != nil;
    [refreshSpecifier setProperty:@(enabled) forKey:PSEnabledKey];
    if (self.isViewLoaded) {
        [self reloadSpecifier:refreshSpecifier animated:NO];
    }
}

- (void)updateRecoveryStateWithLocalizationKey:(NSString *)localizationKey
                                       visible:(BOOL)visible
                        hasRecoverableBaseline:(BOOL)hasRecoverableBaseline
                                requiresReboot:(BOOL)requiresReboot {
    (void)[self specifiers];
    self.recoverySectionVisible = visible;
    self.hasRecoverableBaseline = hasRecoverableBaseline;
    self.requiresReboot = requiresReboot;
    [self setDisplayValue:localizationKey forSpecifierID:CCNMRecoveryStateSpecifierID];
    [self rebuildRecoverySection];
}

- (void)rebuildRecoverySection {
    NSMutableArray<PSSpecifier *> *updatedSpecifiers = [_specifiers mutableCopy];
    [updatedSpecifiers removeObjectsInArray:self.knownOrphanRecoverySpecifiers];
    [updatedSpecifiers removeObjectsInArray:self.recoverySpecifiers];
    NSMutableArray<PSSpecifier *> *visibleMaintenanceSpecifiers = [NSMutableArray array];

    if (self.knownOrphanedN78RecoveryEligible) {
        for (PSSpecifier *specifier in self.knownOrphanRecoverySpecifiers) {
            if ([specifier.identifier isEqualToString:CCNMKnownOrphanRecoverySpecifierID]) {
                BOOL enabled = self.recoverKnownOrphanedN78Handler != nil &&
                    !self.policyOperationInProgress && !self.servingRefreshInProgress;
                [specifier setProperty:@(enabled) forKey:PSEnabledKey];
            }
            [visibleMaintenanceSpecifiers addObject:specifier];
        }
    }

    if (self.recoverySectionVisible) {
        PSSpecifier *group = [self recoverySpecifierForID:CCNMRecoveryGroupSpecifierID];
        PSSpecifier *state = [self recoverySpecifierForID:CCNMRecoveryStateSpecifierID];
        PSSpecifier *reboot = [self recoverySpecifierForID:CCNMRebootRequirementSpecifierID];
        PSSpecifier *restore = [self recoverySpecifierForID:CCNMRestoreSpecifierID];

        if (group) {
            [visibleMaintenanceSpecifiers addObject:group];
        }
        if (state) {
            [visibleMaintenanceSpecifiers addObject:state];
        }
        if (self.requiresReboot && reboot) {
            [visibleMaintenanceSpecifiers addObject:reboot];
        }
        if (self.hasRecoverableBaseline && restore) {
            BOOL restoreEnabled = self.restoreOriginalBandConfigurationHandler != nil &&
                !self.requiresReboot && !self.policyOperationInProgress && !self.servingRefreshInProgress;
            [restore setProperty:@(restoreEnabled) forKey:PSEnabledKey];
            [visibleMaintenanceSpecifiers addObject:restore];
        }
    }

    if (visibleMaintenanceSpecifiers.count > 0) {
        PSSpecifier *aboutGroup = nil;
        for (PSSpecifier *specifier in updatedSpecifiers) {
            if ([specifier.identifier isEqualToString:CCNMAboutGroupSpecifierID]) {
                aboutGroup = specifier;
                break;
            }
        }
        NSUInteger insertionIndex = aboutGroup
            ? [updatedSpecifiers indexOfObjectIdenticalTo:aboutGroup]
            : updatedSpecifiers.count;
        NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:
            NSMakeRange(insertionIndex, visibleMaintenanceSpecifiers.count)];
        [updatedSpecifiers insertObjects:visibleMaintenanceSpecifiers atIndexes:indexes];
    }

    _specifiers = updatedSpecifiers;
    if (self.isViewLoaded) {
        [self.table reloadData];
    }
}

@end
