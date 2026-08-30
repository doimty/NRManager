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
static NSString * const CCNMRecoveryGroupSpecifierID = @"recoveryGroup";
static NSString * const CCNMRecoveryStateSpecifierID = @"recoveryState";
static NSString * const CCNMRebootRequirementSpecifierID = @"rebootRequirement";
static NSString * const CCNMRestoreConfigurationSpecifierID = @"restoreSavedConfiguration";
static NSString * const CCNMAboutGroupSpecifierID = @"aboutGroup";

@interface CCNMRootListController ()

@property (nonatomic, assign) BOOL n78PreferenceEnabled;
@property (nonatomic, assign) BOOL n78PreferenceControlAvailable;
@property (nonatomic, assign) BOOL recoverySectionVisible;
@property (nonatomic, assign) BOOL hasRecoverableBaseline;
@property (nonatomic, assign) BOOL cleanupCheckpointRecoverable;
@property (nonatomic, assign) BOOL requiresReboot;
@property (nonatomic, copy) NSArray<PSSpecifier *> *recoverySpecifiers;
@property (nonatomic, copy) NSDictionary<NSString *, id> *policySummary;
@property (nonatomic, copy) NSDictionary<NSString *, id> *servingSummary;
@property (nonatomic, assign) BOOL policyOperationInProgress;
@property (nonatomic, assign) BOOL servingRefreshInProgress;

- (void)configureProductionHandlers;
- (void)refreshPolicyState;
- (void)requestN78PreferenceEnabled:(BOOL)enabled;
- (void)beginPolicyRecovery;
- (void)applyPolicySummary:(NSDictionary<NSString *, id> *)summary;
- (void)beginServingRefresh;
- (void)applyServingSummary:(NSDictionary<NSString *, id> *)summary;
- (void)showPolicyFailureForSummary:(NSDictionary<NSString *, id> *)summary;
- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers;
- (NSArray<PSSpecifier *> *)recoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers;
- (PSSpecifier *)recoverySpecifierForID:(NSString *)identifier;
- (void)setDisplayValue:(NSString *)valueOrLocalizationKey forSpecifierID:(NSString *)identifier;
- (id)readN78PreferenceValue:(PSSpecifier *)specifier;
- (void)setN78PreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)refreshServingStatus:(PSSpecifier *)specifier;
- (void)restoreSavedConfiguration:(PSSpecifier *)specifier;
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
        self.recoverySpecifiers = [self recoverySpecifiersFromArray:loaded];
        [loaded removeObjectsInArray:self.recoverySpecifiers];
        _specifiers = loaded;
    }

    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CCNMPreferencesLocalizedString(@"NR Manager");
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
    self.restoreSavedConfigurationHandler = ^{
        [weakSelf beginPolicyRecovery];
    };
}

- (void)refreshPolicyState {
    [self applyPolicySummary:CCNMReadN78PolicyState()];
}

- (void)requestN78PreferenceEnabled:(BOOL)enabled {
    if (self.policyOperationInProgress) {
        return;
    }
    self.policyOperationInProgress = YES;
    [self rebuildRecoverySection];
    [self updateTransitionStateWithLocalizationKey:@"Applying"];
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
    [self updateTransitionStateWithLocalizationKey:@"Applying"];
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

- (NSString *)requestedPolicyDisplayValue:(NSDictionary *)summary {
    return [summary[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred]
        ? CCNMPreferencesLocalizedString(@"NR band management")
        : CCNMPreferencesLocalizedString(@"System default");
}

// A verified enabled state is rendered from the band set the policy recorded, not
// from a fixed string.
//
// 1.6.0 generalised the feature from a hardcoded n78 to any subset of the bands
// the system already allows, and the write, read-back and persistence paths all
// followed. This row did not: it mapped CCNMAppliedPolicyVerifiedN78Only straight
// onto a constant that says "NR allows only n78". A device with n1 selected read
// back correctly, applied correctly and served n1, while the row claimed n78 --
// which looks exactly like the modem ignoring the restriction, the most alarming
// failure this project can have. Reading the recorded target is what makes the
// row's claim checkable against the pane that produced it.
//
// CCNMCanonicalNRSelection is the same canonicaliser the write path and the band
// pane use, so the row cannot present an ordering or a duplicate the policy would
// not have stored. A missing or malformed target is reported as a verified
// restriction without naming bands: the applied policy is a fact here, and the
// band list is the part that is unavailable, so inventing one would be worse than
// saying less.
- (NSString *)displayNameForNRBands:(NSArray<NSNumber *> *)bands {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:bands.count];
    for (NSNumber *band in bands) {
        [names addObject:[NSString stringWithFormat:@"n%@", band]];
    }
    return [names componentsJoinedByString:@", "];
}

// The durable policy summary proves what a completed write once matched. Fresh
// capabilityActiveNRBands proves what the modem allows now. The row keeps those
// time domains separate: exact current match, observed drift, or last-verified
// history when current capability evidence is unavailable.
- (NSString *)appliedPolicyDisplayValue:(NSDictionary *)policySummary
                         servingSummary:(NSDictionary *)servingSummary {
    NSString *applied = policySummary[CCNMN78PolicySummaryAppliedPolicyKey];
    if ([applied isEqual:CCNMAppliedPolicyVerifiedN78Only]) {
        id rawTarget = policySummary[CCNMN78PolicySummaryTargetNRBandsKey];
        NSArray<NSNumber *> *target = [rawTarget isKindOfClass:NSArray.class]
            ? CCNMCanonicalNRSelection(rawTarget, NULL) : nil;
        if (target.count == 0) {
            return CCNMPreferencesLocalizedString(@"NR band restriction was verified; recorded bands unavailable");
        }
        NSString *targetName = [self displayNameForNRBands:target];
        NSString *policyUUID = [policySummary[@"subscriptionUUID"] isKindOfClass:NSString.class]
            ? policySummary[@"subscriptionUUID"] : @"";
        NSString *capabilityUUID =
            [servingSummary[CCNMServingSummarySubscriptionUUIDKey] isKindOfClass:NSString.class]
                ? servingSummary[CCNMServingSummarySubscriptionUUIDKey] : @"";
        long long capabilitySampledAt = [servingSummary[
            CCNMServingSummaryCapabilitySampledAtMillisecondsKey] longLongValue];
        long long capabilityAge = (long long)(NSDate.date.timeIntervalSince1970 * 1000.0) -
            capabilitySampledAt;
        BOOL sameSubscription = policyUUID.length > 0 && capabilityUUID.length > 0 &&
            [policyUUID caseInsensitiveCompare:capabilityUUID] == NSOrderedSame;
        BOOL capabilityAvailable = sameSubscription && capabilitySampledAt > 0 &&
            capabilityAge >= 0 && capabilityAge <= 30000 &&
            ![servingSummary[CCNMServingSummaryUnsafeOutstandingKey] boolValue] &&
            [servingSummary[CCNMServingSummaryCapabilityReadSuccessKey] boolValue];
        id rawActive = servingSummary[CCNMServingSummaryCapabilityActiveNRBandsKey];
        NSArray<NSNumber *> *active = capabilityAvailable &&
            [rawActive isKindOfClass:NSArray.class]
                ? CCNMCanonicalNRSelection(rawActive, NULL) : nil;
        if (active.count == 0) {
            return [NSString stringWithFormat:
                CCNMPreferencesLocalizedString(@"Last verified NR target %@; current modem bands unavailable"),
                targetName];
        }
        if ([active isEqualToArray:target]) {
            return [NSString stringWithFormat:
                CCNMPreferencesLocalizedString(@"Current NR allows only %@; LTE unchanged"),
                targetName];
        }
        return [NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"Current NR %@ differs from recorded target %@"),
            [self displayNameForNRBands:active], targetName];
    }
    NSDictionary *keys = @{
        CCNMAppliedPolicyUnknown: @"Unknown",
        CCNMAppliedPolicyApplying: @"Applying",
        CCNMAppliedPolicyVerifiedSystemDefault: @"System default verified",
        CCNMAppliedPolicyDiverged: @"Applied policy differs from the request",
        CCNMAppliedPolicyRecoveryRequired: @"Recovery required",
    };
    return CCNMPreferencesLocalizedString(keys[applied] ?: @"Unknown");
}

- (NSString *)recoveryDisplayValue:(NSDictionary *)summary {
    if ([summary[CCNMN78PolicySummaryCleanupCheckpointRecoverableKey] boolValue]) {
        return CCNMPreferencesLocalizedString(@"Modem restore verified; cleanup pending");
    }
    NSString *recovery = summary[CCNMN78PolicySummaryRecoveryStateKey];
    NSDictionary *keys = @{
        CCNMRecoveryStateClean: @"No recovery required",
        CCNMRecoveryStateEnablePending: @"Enable is pending",
        CCNMRecoveryStateEnabledWithBaseline: @"Original configuration is retained",
        CCNMRecoveryStateCarrierResetPending: @"An earlier carrier reload was left pending",
        CCNMRecoveryStateCarrierResetFailed: @"An earlier carrier reload was not confirmed",
        CCNMRecoveryStateRebootRequired: @"Restart required",
        CCNMRecoveryStateRecoveryFailed: @"Recovery failed",
    };
    return CCNMPreferencesLocalizedString(keys[recovery] ?: @"Recovery failed");
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

    NSString *transitionKey = @"Recovery required";
    if ([appliedPolicy isEqual:CCNMAppliedPolicyApplying]) {
        transitionKey = @"Applying";
    } else if ([recoveryState isEqual:CCNMRecoveryStateClean] ||
        [recoveryState isEqual:CCNMRecoveryStateEnabledWithBaseline]) {
        transitionKey = @"Verified";
    }
    [self updateTransitionStateWithLocalizationKey:transitionKey];

    [self setDisplayValue:[self requestedPolicyDisplayValue:summary]
           forSpecifierID:CCNMRequestedPolicySpecifierID];
    [self setDisplayValue:[self appliedPolicyDisplayValue:summary
                                               servingSummary:self.servingSummary]
           forSpecifierID:CCNMAppliedPolicySpecifierID];

    BOOL baselineValid = [summary[@"baselineValid"] boolValue];
    BOOL cleanupCheckpointRecoverable =
        [summary[CCNMN78PolicySummaryCleanupCheckpointRecoverableKey] boolValue];
    BOOL recoveryVisible = ![recoveryState isEqual:CCNMRecoveryStateClean] ||
        cleanupCheckpointRecoverable;
    [self updateRecoveryStateWithLocalizationKey:[self recoveryDisplayValue:summary]
                                         visible:recoveryVisible
                          hasRecoverableBaseline:baselineValid
                    cleanupCheckpointRecoverable:cleanupCheckpointRecoverable
                                  requiresReboot:[summary[CCNMN78PolicySummaryRequiresRebootKey] boolValue]];
}

- (NSString *)servingDisplayValue:(NSDictionary *)summary {
    if ([summary[CCNMServingSummaryUnsafeOutstandingKey] boolValue]) {
        return CCNMPreferencesLocalizedString(@"Unknown (restart Settings before another modem operation)");
    }
    if ([summary[CCNMServingSummaryStaleKey] boolValue] ||
        ![summary[CCNMServingSummarySuccessKey] boolValue]) {
        return CCNMPreferencesLocalizedString(@"Unknown (data is stale)");
    }
    NSString *state = summary[CCNMServingSummaryStateKey];
    NSNumber *band = [summary[CCNMServingSummaryBandKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummaryBandKey] : nil;
    NSNumber *frequency = [summary[CCNMServingSummaryFrequencyMHzKey] isKindOfClass:NSNumber.class]
        ? summary[CCNMServingSummaryFrequencyMHzKey] : nil;
    if ([state isEqual:CCNMServingStateNRN78]) {
        if (frequency) {
            NSString *machineFrequency = [NSString stringWithFormat:@"%.3f MHz", frequency.doubleValue];
            return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"NR n78 · %@"), machineFrequency];
        }
        return CCNMPreferencesLocalizedString(@"NR n78");
    }
    if ([state isEqual:CCNMServingStateNROther]) {
        NSString *machineBand = band ? [NSString stringWithFormat:@"n%@", band] : @"NR";
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"NR %@"), machineBand];
    }
    if ([state isEqual:CCNMServingStateLTE]) {
        NSString *machineBand = band ? [NSString stringWithFormat:@"B%@", band] : @"B?";
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"LTE %@ (NR is not currently serving)"), machineBand];
    }
    return CCNMPreferencesLocalizedString(@"Other serving network");
}

- (NSString *)freshnessDisplayValue:(NSDictionary *)summary {
    long long milliseconds = [summary[CCNMServingSummarySampledAtMillisecondsKey] longLongValue];
    if (milliseconds <= 0) {
        return CCNMPreferencesLocalizedString(@"Unknown");
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)milliseconds / 1000.0];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    NSString *timestamp = [formatter stringFromDate:date] ?: @"";
    NSString *formatKey = [summary[CCNMServingSummaryStaleKey] boolValue]
        ? @"Stale · %@" : @"Updated %@";
    return [NSString stringWithFormat:CCNMPreferencesLocalizedString(formatKey), timestamp];
}

// The read path supports any slot, so the row must report which subscription was
// actually sampled rather than assuming slot 1.
- (NSString *)dataLineDisplayValue:(NSDictionary *)summary {
    NSString *dataLine = [summary[CCNMServingSummaryDataLineKey] isKindOfClass:NSString.class]
        ? summary[CCNMServingSummaryDataLineKey] : @"";
    if ([dataLine isEqualToString:@"slot1"]) {
        return CCNMPreferencesLocalizedString(@"SIM 1");
    }
    if ([dataLine isEqualToString:@"slot2"]) {
        return CCNMPreferencesLocalizedString(@"SIM 2");
    }
    if ([dataLine hasPrefix:@"slot"] && dataLine.length > 4) {
        return [NSString stringWithFormat:CCNMPreferencesLocalizedString(@"Line %@"),
            [dataLine substringFromIndex:4]];
    }
    return CCNMPreferencesLocalizedString(@"Unknown");
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
    [self setDisplayValue:@"Refreshing…" forSpecifierID:CCNMFreshnessSpecifierID];
    [self updateCurrentStateWithRequestedValue:[self requestedPolicyDisplayValue:self.policySummary]
                                  appliedValue:[self appliedPolicyDisplayValue:self.policySummary
                                                               servingSummary:self.servingSummary]
                                  servingValue:[self servingDisplayValue:self.servingSummary]
                                 dataLineValue:[self dataLineDisplayValue:self.servingSummary]
                                freshnessValue:CCNMPreferencesLocalizedString(@"Refreshing…")
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
                                  appliedValue:[self appliedPolicyDisplayValue:self.policySummary
                                                               servingSummary:self.servingSummary]
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
        CCNMPreferencesLocalizedString(@"This device: %@ / iOS %@ (%@)"),
        model, version, build];
}

- (NSString *)policyFailureLocalizationKey:(NSString *)errorCode {
    if ([errorCode isEqual:CCNMN78PolicyErrorBusy]) return @"Another policy or serving-status operation is still running.";
    if ([errorCode isEqual:CCNMN78PolicyErrorUnsupportedTarget]) return @"This operation requires readable device identity and matching runtime capability evidence.";
    if ([errorCode isEqual:CCNMN78PolicyErrorUnsafeSubscription] ||
        [errorCode isEqual:CCNMN78PolicyErrorUUIDDrift]) return @"The data-line SIM layout or subscription identity is not safe for this operation.";
    // No caller produces baselineIncompatible any more: the restore-from-baseline
    // write path it guarded is gone. It stays mapped because 1.5.0 persisted it
    // into the state record's errorCode, and a device that upgrades from such a
    // state would otherwise see the generic string instead of the reason.
    if ([errorCode isEqual:CCNMN78PolicyErrorBaselineIncompatible]) return @"The retained policy baseline is incompatible with this device or its modem capability evidence.";
    if ([errorCode isEqual:CCNMN78PolicyErrorN78Unavailable]) return @"One or more selected NR bands are no longer present in both the active and supported band lists.";
    if ([errorCode isEqual:CCNMN78PolicyErrorSetterUncertain]) return @"The modem setter result is uncertain. Restart the device before making another change.";
    if ([errorCode isEqual:CCNMN78PolicyErrorCarrierResetFailed]) return @"An earlier carrier reload could not be confirmed. Restore the saved configuration from Recovery & Maintenance.";
    if ([errorCode isEqual:CCNMN78PolicyErrorRecoveryRequired] ||
        [errorCode isEqual:CCNMN78PolicyErrorInvalidRecords]) return @"Saved policy evidence must be recovered before another change.";
    return @"The policy could not be changed or verified. Review the recovery state before retrying.";
}

- (void)showPolicyFailureForSummary:(NSDictionary<NSString *, id> *)summary {
    NSString *errorCode = [summary[CCNMN78PolicySummaryErrorCodeKey] isKindOfClass:NSString.class]
        ? summary[CCNMN78PolicySummaryErrorCodeKey] : @"unknown";
    NSString *technicalError = [summary[CCNMN78PolicySummaryErrorKey] isKindOfClass:NSString.class]
        ? summary[CCNMN78PolicySummaryErrorKey] : @"";
    NSString *key = [self policyFailureLocalizationKey:errorCode];
    NSString *message = [NSString stringWithFormat:
        CCNMPreferencesLocalizedString(@"%@\n\nError code: %@\nDetails: %@"),
        CCNMPreferencesLocalizedString(key), errorCode,
        technicalError.length > 0 ? technicalError : CCNMPreferencesLocalizedString(@"Unknown")];
    // The target check reports what it measured, so say so. Stating only which
    // device is accepted leaves the user to look up their own model and build by
    // hand to find out why they were refused.
    NSString *measured = [self measuredDeviceDescription:summary];
    if (measured.length > 0) {
        message = [message stringByAppendingFormat:@"\n%@", measured];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"Unable to Change NR Band Management")
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"OK")
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

- (NSArray<PSSpecifier *> *)recoverySpecifiersFromArray:(NSArray<PSSpecifier *> *)specifiers {
    NSSet<NSString *> *recoveryIDs = [NSSet setWithArray:@[
        CCNMRecoveryGroupSpecifierID,
        CCNMRecoveryStateSpecifierID,
        CCNMRebootRequirementSpecifierID,
        CCNMRestoreConfigurationSpecifierID,
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
        : CCNMPreferencesLocalizedString(@"Unknown");
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

// Routes both recovery forms through the policy owner. A retained baseline needs
// the reverse setActiveBandInfo: write. A verified cleanup checkpoint has already
// matched that write and retired the baseline, so recovery only revalidates live
// complete BandInfo and finishes the durable clean-state rewrite. The latter must
// never claim that it will write a missing baseline or issue a second setter.
- (void)restoreSavedConfiguration:(PSSpecifier *)specifier {
    (void)specifier;
    if ((!self.hasRecoverableBaseline && !self.cleanupCheckpointRecoverable) ||
        self.requiresReboot || self.policyOperationInProgress ||
        self.servingRefreshInProgress || !self.restoreSavedConfigurationHandler) {
        return;
    }

    BOOL cleanupOnly = self.cleanupCheckpointRecoverable;
    NSString *titleKey = cleanupOnly ? @"Finish verified restore?" : @"Restore saved configuration?";
    NSString *messageKey = cleanupOnly ? @"The modem already matched the saved configuration. Settings will recheck the live complete band configuration and finish the durable policy cleanup. No modem write is issued." : @"The band configuration saved before the NR band restriction was applied is written back to the modem, which removes the restriction. The result is verified by reading the modem back.";
    NSString *buttonKey = cleanupOnly ? @"Finish verified restore" : @"Restore";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(titleKey)
        message:CCNMPreferencesLocalizedString(messageKey)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(buttonKey)
        style:cleanupOnly ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            CCNMSettingsActionHandler handler = weakSelf.restoreSavedConfigurationHandler;
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
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"Unable to Open Link")
        message:CCNMPreferencesLocalizedString(@"The repository link could not be opened.")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"OK")
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
                  cleanupCheckpointRecoverable:(BOOL)cleanupCheckpointRecoverable
                                requiresReboot:(BOOL)requiresReboot {
    (void)[self specifiers];
    self.recoverySectionVisible = visible;
    self.hasRecoverableBaseline = hasRecoverableBaseline;
    self.cleanupCheckpointRecoverable = cleanupCheckpointRecoverable;
    self.requiresReboot = requiresReboot;
    [self setDisplayValue:localizationKey forSpecifierID:CCNMRecoveryStateSpecifierID];
    [self rebuildRecoverySection];
}

- (void)rebuildRecoverySection {
    NSMutableArray<PSSpecifier *> *updatedSpecifiers = [_specifiers mutableCopy];
    [updatedSpecifiers removeObjectsInArray:self.recoverySpecifiers];
    NSMutableArray<PSSpecifier *> *visibleMaintenanceSpecifiers = [NSMutableArray array];

    if (self.recoverySectionVisible) {
        PSSpecifier *group = [self recoverySpecifierForID:CCNMRecoveryGroupSpecifierID];
        PSSpecifier *state = [self recoverySpecifierForID:CCNMRecoveryStateSpecifierID];
        PSSpecifier *reboot = [self recoverySpecifierForID:CCNMRebootRequirementSpecifierID];
        PSSpecifier *restore = [self recoverySpecifierForID:CCNMRestoreConfigurationSpecifierID];

        if (group) {
            [visibleMaintenanceSpecifiers addObject:group];
        }
        if (state) {
            [visibleMaintenanceSpecifiers addObject:state];
        }
        if (self.requiresReboot && reboot) {
            [visibleMaintenanceSpecifiers addObject:reboot];
        }
        if ((self.hasRecoverableBaseline || self.cleanupCheckpointRecoverable) && restore) {
            NSString *titleKey = self.cleanupCheckpointRecoverable
                ? @"Finish verified restore" : @"Restore saved configuration";
            NSString *title = CCNMPreferencesLocalizedString(titleKey);
            restore.name = title;
            [restore setProperty:title forKey:PSTitleKey];
            BOOL restoreEnabled = self.restoreSavedConfigurationHandler != nil &&
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
