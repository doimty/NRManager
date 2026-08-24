#import "CCNMBandSelectionListController.h"
#import "CCNMN78PolicyController.h"
#import "CCNMNRBandSupport.h"
#import "CCNMPreferencesCells.h"
#import "CCNMServingStatusProvider.h"

static NSString * const CCNMBandRowSpecifierIDPrefix = @"nrBand.";
static NSString * const CCNMBandGroupSpecifierID = @"nrBandGroup";
static NSString * const CCNMBandUnavailableSpecifierID = @"nrBandUnavailable";
static NSString * const CCNMBandSaveGroupSpecifierID = @"nrBandSaveGroup";
static NSString * const CCNMBandSaveSpecifierID = @"saveBandSelection";
static NSString * const CCNMBandStatusSpecifierID = @"bandSelectionStatus";
static NSString * const CCNMBandNumberPropertyKey = @"ccnmBandNumber";
static const long long CCNMBandSelectionFreshnessLifetimeMilliseconds = 30000;

// PSCellClassKey must hold a Class, never its name.
//
// Root.plist may spell a cell class as a string because Preferences' own plist
// loader replaces it with NSClassFromString before the specifier exists. A
// specifier built in code skips that conversion, and +[PSTableCell
// cellClassForSpecifier:] returns the property verbatim; PSListController then
// sends the class method +isSubclassOfClass: to it. An NSString does not respond
// to that selector, so the row throws while the table is laying out and
// Preferences aborts. A Class here is the difference between the pane opening and
// Settings dying on entry.
static void CCNMSetCellClass(PSSpecifier *specifier, Class cellClass) {
    [specifier setProperty:cellClass forKey:PSCellClassKey];
}

// The identifier is a property, so write it as one.
//
// -[PSSpecifier identifier] reads propertyForKey:@"id" and falls back to @"label",
// then @"key", then -name, so a specifier that never has the property written
// answers with a localized display name rather than nothing, and -specifierForID:
// cannot match the ID the caller asked for.
//
// This is how Preferences itself builds a specifier in code:
// +[PSSpecifier deleteButtonSpecifierWithName:target:action:] sets the ID with
// setProperty:forKey:@"id" and never calls -setIdentifier:. PSSpecifier declares no
// identifier storage of its own, so the property is the whole mechanism.
static void CCNMSetSpecifierID(PSSpecifier *specifier, NSString *identifier) {
    [specifier setProperty:identifier forKey:PSIDKey];
}

static long long CCNMBandSelectionUnixMilliseconds(void) {
    return (long long)([NSDate date].timeIntervalSince1970 * 1000.0);
}

static BOOL CCNMBandSelectionTimestampIsFresh(id value, long long now) {
    if (![value isKindOfClass:NSNumber.class]) {
        return NO;
    }
    long long sampledAt = [value longLongValue];
    if (sampledAt <= 0 || sampledAt > now) {
        return NO;
    }
    return now - sampledAt <= CCNMBandSelectionFreshnessLifetimeMilliseconds;
}

// Why the domain may be unusable. Kept as an enum rather than a message so the
// pane decides once what state it is in, and every row derives its text from that
// one decision instead of each re-deriving it.
typedef NS_ENUM(NSInteger, CCNMBandSelectionAvailability) {
    CCNMBandSelectionAvailable = 0,
    // A baseline exists, so the live active list is the applied selection rather
    // than what the system originally allowed. Editing has to go through off.
    CCNMBandSelectionBlockedByEnabledPolicy,
    // Records need attention; the pane refuses rather than writing a preference
    // that a later enable could not honour anyway.
    CCNMBandSelectionBlockedByRecovery,
    // No usable capability evidence was cached by the parent pane.
    CCNMBandSelectionBlockedByMissingEvidence,
};

@interface CCNMBandSelectionListController ()

@property (nonatomic, assign) CCNMBandSelectionAvailability availability;
@property (nonatomic, copy) NSArray<NSNumber *> *domain;
@property (nonatomic, copy) NSSet<NSNumber *> *workingSelection;
@property (nonatomic, copy) NSArray<NSNumber *> *savedSelection;
@property (nonatomic, copy) NSArray<NSNumber *> *droppedStoredBands;
@property (nonatomic, assign) BOOL hasExplicitSavedSelection;
@property (nonatomic, copy) NSString *evidenceFailure;
// The NR band the modem was measured on, when the cached sample confirms one.
// nil for LTE, for any non-NR serving state, and for a stale or failed sample:
// this drives a warning about losing the current connection, so a guess would be
// worse than saying nothing.
@property (nonatomic, copy, nullable) NSNumber *servingNRBand;
@property (nonatomic, copy, nullable) NSNumber *servingFrequencyMHz;

// The two rows a band tap has to update, held directly rather than looked up by ID.
//
// -specifierForID: answers from _specifiersByID, which only PSListController's
// -prepareSpecifiersMetadata rebuilds. This pane replaces its whole specifier array
// on every appearance, so an ID lookup can hand back an object from an earlier
// build; -reloadSpecifier: then fails to find it, because it locates rows with
// -indexOfObject: and PSSpecifier does not override -isEqual:, making that a
// pointer comparison. Writing to an orphan and reloading nothing is a silent
// no-op, which is exactly how the save row stayed disabled after a valid change.
//
// Weak on purpose: when the array is replaced these must not resolve to an object
// the table no longer shows. A nil reference skips the refresh, which is a visible
// failure; a stale strong reference is an invisible one.
@property (nonatomic, weak, nullable) PSSpecifier *currentStatusSpecifier;
@property (nonatomic, weak, nullable) PSSpecifier *currentSaveSpecifier;

@end

@implementation CCNMBandSelectionListController

#pragma mark - Reading the world

// The pane never samples. Sampling is an async private-API call behind a
// cross-process lock with an unsafe-outstanding latch, and the parent pane already
// owns it and refreshes on appear. A second owner would buy nothing here and could
// leave the latch set, which blocks the write path the user is heading towards.
- (NSDictionary<NSString *, id> *)cachedServingSummary {
    return [[CCNMServingStatusProvider sharedProvider] currentSummary];
}

- (NSArray<NSNumber *> *)domainFromSummary:(NSDictionary<NSString *, id> *)summary
                                   failure:(NSString **)failure {
    long long now = CCNMBandSelectionUnixMilliseconds();
    // Capability evidence and serving-cell evidence are separate domains. A
    // failed serving sampler must not invalidate a successful, fresh BandInfo
    // read that still gives us the selectable active/supported intersection.
    BOOL freshCapability = CCNMBandSelectionTimestampIsFresh(
        summary[CCNMServingSummaryCapabilitySampledAtMillisecondsKey], now);
    if (![summary[CCNMServingSummaryCapabilityReadSuccessKey] boolValue] ||
        !freshCapability) {
        if (failure) {
            NSString *reported = [summary[CCNMServingSummaryCapabilityErrorKey] isKindOfClass:NSString.class]
                ? summary[CCNMServingSummaryCapabilityErrorKey] : @"";
            *failure = reported.length > 0 ? reported
                : @"No fresh BandInfo capability evidence is available.";
        }
        return nil;
    }
    id active = summary[CCNMServingSummaryCapabilityActiveNRBandsKey];
    id supported = summary[CCNMServingSummaryCapabilitySupportedNRBandsKey];
    return CCNMSelectableNRBandDomain(active, supported, failure);
}

- (CCNMBandSelectionAvailability)availabilityForPolicySummary:(NSDictionary<NSString *, id> *)policy {
    NSString *recoveryState = policy[CCNMN78PolicySummaryRecoveryStateKey];
    if ([recoveryState isEqual:CCNMRecoveryStateEnabledWithBaseline]) {
        return CCNMBandSelectionBlockedByEnabledPolicy;
    }
    if (![recoveryState isEqual:CCNMRecoveryStateClean]) {
        return CCNMBandSelectionBlockedByRecovery;
    }
    if ([policy[CCNMN78PolicySummaryRequestedModeKey] isEqual:CCNMRequestedModeN78Preferred]) {
        return CCNMBandSelectionBlockedByEnabledPolicy;
    }
    return CCNMBandSelectionAvailable;
}

// Everything the pane shows is decided here, in one pass, before any specifier
// exists. A row can then be pure rendering.
- (void)reloadModel {
    NSDictionary *policy = CCNMReadN78PolicyState();
    CCNMBandSelectionAvailability availability = [self availabilityForPolicySummary:policy];

    NSDictionary *serving = [self cachedServingSummary];
    NSString *evidenceFailure = nil;
    NSArray<NSNumber *> *domain = [self domainFromSummary:serving failure:&evidenceFailure];
    if (domain.count == 0) {
        domain = @[];
        // A policy problem is the more actionable statement, so it outranks missing
        // evidence; only report the evidence gap when nothing else is wrong.
        if (availability == CCNMBandSelectionAvailable) {
            availability = CCNMBandSelectionBlockedByMissingEvidence;
        }
    }

    id appliedValue = policy[CCNMN78PolicySummaryTargetNRBandsKey];
    NSString *appliedFailure = nil;
    NSArray<NSNumber *> *appliedSelection =
        [appliedValue isKindOfClass:NSArray.class]
            ? CCNMCanonicalNRSelection(appliedValue, &appliedFailure) : nil;
    BOOL showingAppliedSelection = availability == CCNMBandSelectionBlockedByEnabledPolicy;
    BOOL hidingSelectionForRecovery = availability == CCNMBandSelectionBlockedByRecovery;
    BOOL hasExplicitSavedSelection = !showingAppliedSelection && !hidingSelectionForRecovery &&
        CCNMHasStoredSelectedNRBands();
    NSArray<NSNumber *> *stored = showingAppliedSelection
        ? (appliedSelection ?: @[]) : hidingSelectionForRecovery ? @[] : CCNMReadSelectedNRBands();
    NSMutableArray<NSNumber *> *dropped = [NSMutableArray array];
    NSMutableSet<NSNumber *> *working = [NSMutableSet set];
    for (NSNumber *band in stored) {
        if ([domain containsObject:band]) {
            [working addObject:band];
        } else {
            [dropped addObject:band];
        }
    }

    self.availability = availability;
    self.domain = domain;
    self.savedSelection = stored;
    self.workingSelection = working;
    self.hasExplicitSavedSelection = hasExplicitSavedSelection;
    // Only worth reporting an explicit pending value. The shipped default is not a
    // user selection, and an applied target is already the live policy truth.
    self.droppedStoredBands = !showingAppliedSelection && hasExplicitSavedSelection &&
        domain.count > 0 ? dropped : @[];
    self.evidenceFailure = evidenceFailure ?: appliedFailure ?: @"";
    [self adoptServingCellFromSummary:serving];
}

- (void)adoptServingCellFromSummary:(NSDictionary<NSString *, id> *)summary {
    self.servingNRBand = nil;
    self.servingFrequencyMHz = nil;

    NSString *state = summary[CCNMServingSummaryStateKey];
    BOOL servingIsNR = [state isEqual:CCNMServingStateNRN78] || [state isEqual:CCNMServingStateNROther];
    if (![summary[CCNMServingSummarySuccessKey] boolValue] ||
        [summary[CCNMServingSummaryStaleKey] boolValue] || !servingIsNR) {
        return;
    }
    id band = summary[CCNMServingSummaryBandKey];
    if (![band isKindOfClass:NSNumber.class] || [band longLongValue] <= 0) {
        return;
    }
    self.servingNRBand = band;
    id frequency = summary[CCNMServingSummaryFrequencyMHzKey];
    if ([frequency isKindOfClass:NSNumber.class] && [frequency doubleValue] > 0.0) {
        self.servingFrequencyMHz = frequency;
    }
}

#pragma mark - Derived state

- (BOOL)isEditable {
    return self.availability == CCNMBandSelectionAvailable && self.domain.count > 0;
}

- (NSArray<NSNumber *> *)canonicalWorkingSelection {
    return [self.workingSelection.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

- (BOOL)workingSelectionDiffersFromSaved {
    return ![[self canonicalWorkingSelection] isEqualToArray:
        [self.savedSelection sortedArrayUsingSelector:@selector(compare:)]];
}

- (NSString *)validationFailureForWorkingSelection {
    NSArray<NSNumber *> *selection = [self canonicalWorkingSelection];
    NSString *failure = nil;
    if (CCNMValidateNRBandSelectionAgainstDomain(selection, self.domain, &failure)) {
        return nil;
    }
    if (selection.count == 0) {
        return CCNMPreferencesLocalizedString(@"BAND_SAVE_EMPTY");
    }
    NSArray *canonicalDomain = [self.domain sortedArrayUsingSelector:@selector(compare:)];
    BOOL containsOutsideBand = NO;
    for (NSNumber *band in selection) {
        if (![canonicalDomain containsObject:band]) {
            containsOutsideBand = YES;
            break;
        }
    }
    if (containsOutsideBand) {
        return CCNMPreferencesLocalizedString(@"BAND_SAVE_OUTSIDE_DOMAIN");
    }
    if ([selection isEqualToArray:canonicalDomain]) {
        return CCNMPreferencesLocalizedString(@"BAND_SAVE_WHOLE_DOMAIN");
    }
    return CCNMPreferencesLocalizedString(@"BAND_SAVE_INVALID_GENERIC");
}

- (BOOL)canSave {
    return [self isEditable] && [self workingSelectionDiffersFromSaved] &&
        [self validationFailureForWorkingSelection] == nil;
}

- (NSString *)unavailableExplanation {
    switch (self.availability) {
        case CCNMBandSelectionBlockedByEnabledPolicy:
            return CCNMPreferencesLocalizedString(@"BAND_UNAVAILABLE_ENABLED");
        case CCNMBandSelectionBlockedByRecovery:
            return CCNMPreferencesLocalizedString(@"BAND_UNAVAILABLE_RECOVERY");
        case CCNMBandSelectionBlockedByMissingEvidence:
            return CCNMPreferencesLocalizedString(@"BAND_UNAVAILABLE_NO_EVIDENCE");
        case CCNMBandSelectionAvailable:
            return @"";
    }
    return @"";
}

- (NSString *)statusText {
    if (![self isEditable]) {
        return CCNMPreferencesLocalizedString(@"ROW_BAND_UNAVAILABLE");
    }
    NSString *failure = [self validationFailureForWorkingSelection];
    if (failure) {
        return failure;
    }
    NSString *list = [self descriptionForBands:[self canonicalWorkingSelection]];
    // Three states, not two. A selection that has never been saved and has not been
    // touched is the factory default, and calling that "not saved yet" tells the
    // user to press a button which is correctly disabled, because there is nothing
    // to save. Only an actual edit is unsaved.
    NSString *formatKey = @"BAND_STATUS_SAVED_FORMAT";
    if ([self workingSelectionDiffersFromSaved]) {
        formatKey = @"BAND_STATUS_UNSAVED_FORMAT";
    } else if (!self.hasExplicitSavedSelection) {
        formatKey = @"BAND_STATUS_DEFAULT_FORMAT";
    }
    return [NSString stringWithFormat:CCNMPreferencesLocalizedString(formatKey), list];
}

- (NSString *)descriptionForBands:(NSArray<NSNumber *> *)bands {
    if (bands.count == 0) {
        return CCNMPreferencesLocalizedString(@"BAND_LIST_EMPTY");
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSNumber *band in bands) {
        [names addObject:[NSString stringWithFormat:@"n%@", band]];
    }
    return [names componentsJoinedByString:@", "];
}

// What a row says under the band number.
//
// Deliberately not a frequency in MHz for an arbitrary band. The plan assumed the
// sampler's NRARFCN/GSCN conversion could supply one, but that converts a
// *measured* channel number for a cell the modem is reporting; a band number alone
// does not determine a frequency without the 3GPP band table, which this project
// does not transcribe. What a band number does determine is its frequency range,
// and that is the part with a consequence the user cannot otherwise see. For the
// one band actually being served, the measured frequency is real, so it is shown.
- (NSString *)detailForBand:(NSNumber *)band {
    NSString *range = [self rangeDescriptionForBand:band];
    if (![band isEqualToNumber:self.servingNRBand ?: @(-1)]) {
        return range;
    }
    if (self.servingFrequencyMHz) {
        return [NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"BAND_DETAIL_SERVING_WITH_FREQUENCY_FORMAT"),
            range, [NSString stringWithFormat:@"%.3f MHz", self.servingFrequencyMHz.doubleValue]];
    }
    return [NSString stringWithFormat:
        CCNMPreferencesLocalizedString(@"BAND_DETAIL_SERVING_FORMAT"), range];
}

- (NSString *)rangeDescriptionForBand:(NSNumber *)band {
    switch (CCNMClassifyNRBandRange(band.longLongValue)) {
        case CCNMNRBandRangeSub6:
            return CCNMPreferencesLocalizedString(@"BAND_RANGE_SUB6");
        case CCNMNRBandRangeMillimeterWave:
            return CCNMPreferencesLocalizedString(@"BAND_RANGE_MMWAVE");
        case CCNMNRBandRangeUnknown:
            return CCNMPreferencesLocalizedString(@"BAND_RANGE_UNKNOWN");
    }
    return CCNMPreferencesLocalizedString(@"BAND_RANGE_UNKNOWN");
}

#pragma mark - Specifiers

- (PSSpecifier *)groupSpecifierWithID:(NSString *)identifier
                            titleKey:(NSString *)titleKey
                           footerKey:(NSString *_Nullable)footerKey {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithID:identifier];
    CCNMSetSpecifierID(group, identifier);
    group.name = CCNMPreferencesLocalizedString(titleKey);
    [group setProperty:CCNMPreferencesLocalizedString(titleKey) forKey:PSTitleKey];
    if (footerKey.length > 0) {
        [group setProperty:CCNMPreferencesLocalizedString(footerKey) forKey:PSFooterTextGroupKey];
    }
    return group;
}

- (PSSpecifier *)statusSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:
        CCNMPreferencesLocalizedString(@"ROW_BAND_SELECTION_STATUS")
        target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:Nil];
    CCNMSetSpecifierID(specifier, CCNMBandStatusSpecifierID);
    CCNMSetCellClass(specifier, CCNMStatusCell.class);
    [specifier setProperty:[self statusText] forKey:CCNMPreferenceValueKey];
    self.currentStatusSpecifier = specifier;
    return specifier;
}

- (PSSpecifier *)bandSpecifierForBand:(NSNumber *)band {
    // PSButtonCell so a tap dispatches through the specifier's action, which is
    // how every other action row in this bundle is wired. All rendering comes from
    // CCNMBandSelectionCell, so the button appearance never shows.
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:
        [NSString stringWithFormat:@"n%@", band]
        target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    CCNMSetSpecifierID(specifier, [CCNMBandRowSpecifierIDPrefix stringByAppendingFormat:@"%@", band]);
    specifier->action = @selector(toggleBandSelection:);
    CCNMSetCellClass(specifier, CCNMBandSelectionCell.class);
    [specifier setProperty:band forKey:CCNMBandNumberPropertyKey];
    [specifier setProperty:[self detailForBand:band] forKey:CCNMPreferenceSubtitleKey];
    [specifier setProperty:@([self.workingSelection containsObject:band]) forKey:CCNMPreferenceCheckedKey];
    [specifier setProperty:@([self isEditable]) forKey:PSEnabledKey];
    return specifier;
}

- (PSSpecifier *)saveSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:
        CCNMPreferencesLocalizedString(@"BAND_SAVE_SELECTION")
        target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    CCNMSetSpecifierID(specifier, CCNMBandSaveSpecifierID);
    specifier->action = @selector(saveBandSelection:);
    [specifier setProperty:@([self canSave]) forKey:PSEnabledKey];
    self.currentSaveSpecifier = specifier;
    return specifier;
}

- (PSSpecifier *)unavailableSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:
        CCNMPreferencesLocalizedString(@"ROW_BAND_UNAVAILABLE")
        target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:Nil];
    CCNMSetSpecifierID(specifier, CCNMBandUnavailableSpecifierID);
    CCNMSetCellClass(specifier, CCNMStatusCell.class);
    [specifier setProperty:[self unavailableExplanation] forKey:CCNMPreferenceValueKey];
    return specifier;
}

- (NSMutableArray<PSSpecifier *> *)buildSpecifiers {
    NSMutableArray<PSSpecifier *> *built = [NSMutableArray array];

    // The dropped-band footer is a format string, so it cannot be handed to the
    // generic group builder as a key; it is substituted here instead.
    PSSpecifier *group = [self groupSpecifierWithID:CCNMBandGroupSpecifierID
                                          titleKey:@"GROUP_BAND_SELECTION"
                                         footerKey:self.droppedStoredBands.count > 0
                                             ? nil : @"BAND_GROUP_FOOTER"];
    if (self.droppedStoredBands.count > 0) {
        [group setProperty:[NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"BAND_GROUP_FOOTER_DROPPED"),
            [self descriptionForBands:self.droppedStoredBands]] forKey:PSFooterTextGroupKey];
    }
    [built addObject:group];
    [built addObject:[self statusSpecifier]];

    if (![self isEditable]) {
        [built addObject:[self unavailableSpecifier]];
    }
    for (NSNumber *band in self.domain) {
        [built addObject:[self bandSpecifierForBand:band]];
    }

    [built addObject:[self groupSpecifierWithID:CCNMBandSaveGroupSpecifierID
                                       titleKey:@"GROUP_BAND_SAVE"
                                      footerKey:@"BAND_SAVE_FOOTER"]];
    [built addObject:[self saveSpecifier]];
    return built;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self reloadModel];
        // Assigned directly, not through -setSpecifiers:, because PSListController
        // calls this getter from inside its own -viewDidLoad and then runs
        // -prepareSpecifiersMetadata itself. Going through the setter here would
        // recurse into the getter before _specifiers is set.
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = CCNMPreferencesLocalizedString(@"BAND_SELECTION_TITLE");
}

// The parent pane can change policy state or refresh capability evidence while
// this pane sits on the navigation stack, so the whole model is rebuilt on every
// appearance rather than trusted from the first load. Unsaved checkmarks are
// intentionally discarded with it: keeping them would mean showing a selection
// checked against a domain that no longer exists.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuildFromWorld];
}

// Replacing the model after the first load must go through -setSpecifiers:.
//
// That setter is what rebuilds _specifiersByID and the group index array; a direct
// _specifiers assignment leaves both describing the previous build. The ID map
// going stale silently breaks -specifierForID:, and the group indices going stale
// is worse than silent, because PSListController computes row counts from them and
// this pane's row count changes with the capability evidence. The setter reloads the
// table itself, so no separate reload is needed after it.
- (void)commitRebuiltSpecifiers {
    NSMutableArray<PSSpecifier *> *rebuilt = [self buildSpecifiers];
    if (!self.isViewLoaded) {
        _specifiers = rebuilt;
        return;
    }
    [self setSpecifiers:rebuilt];
}

- (void)rebuildFromWorld {
    [self reloadModel];
    [self commitRebuiltSpecifiers];
}

#pragma mark - Actions

// Row taps only ever change in-memory state. No policy entry point is reachable
// from here; the preference write lives in -saveBandSelection: and the modem write
// stays behind the switch on the parent pane.
- (void)toggleBandSelection:(PSSpecifier *)specifier {
    NSNumber *band = [specifier propertyForKey:CCNMBandNumberPropertyKey];
    if (![band isKindOfClass:NSNumber.class] || ![self isEditable] ||
        ![self.domain containsObject:band]) {
        return;
    }

    NSMutableSet<NSNumber *> *updated = [self.workingSelection mutableCopy];
    if ([updated containsObject:band]) {
        [updated removeObject:band];
    } else {
        [updated addObject:band];
    }
    self.workingSelection = updated;

    [specifier setProperty:@([self.workingSelection containsObject:band]) forKey:CCNMPreferenceCheckedKey];
    [self reloadSpecifier:specifier animated:NO];
    [self refreshStatusAndSaveRows];
}

- (void)refreshStatusAndSaveRows {
    // Both rows are refreshed from the references captured while they were built,
    // never from -specifierForID:. See currentStatusSpecifier for why an ID lookup
    // cannot be trusted here.
    PSSpecifier *status = self.currentStatusSpecifier;
    if (status) {
        [status setProperty:[self statusText] forKey:CCNMPreferenceValueKey];
        [self reloadSpecifier:status animated:NO];
    }
    PSSpecifier *save = self.currentSaveSpecifier;
    if (save) {
        [save setProperty:@([self canSave]) forKey:PSEnabledKey];
        [self reloadSpecifier:save animated:NO];
    }
}

- (void)saveBandSelection:(PSSpecifier *)specifier {
    (void)specifier;
    // Re-checked rather than trusted from the row's enabled flag: this is the only
    // place a durable write happens, and the state it depends on can have changed
    // since the row was rendered.
    if (![self canSave]) {
        NSString *failure = ![self isEditable]
            ? [self unavailableExplanation] : [self validationFailureForWorkingSelection];
        if (failure.length == 0) {
            failure = CCNMPreferencesLocalizedString(@"BAND_SAVE_INVALID_GENERIC");
        }
        [self presentAlertWithTitleKey:@"BAND_SAVE_FAILED_TITLE" message:failure];
        return;
    }

    NSArray<NSNumber *> *selection = [self canonicalWorkingSelection];
    NSArray<NSString *> *warnings = [self warningsForSelection:selection];
    if (warnings.count > 0) {
        [self confirmSelection:selection warnings:warnings];
        return;
    }
    [self commitSelection:selection];
}

// Coverage consequences the user cannot read off the row list, gathered into one
// prompt rather than a chain of alerts. None of these is a safety refusal: LTE is
// untouched in every case, so the user is allowed to proceed once told.
- (NSArray<NSString *> *)warningsForSelection:(NSArray<NSNumber *> *)selection {
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    if ([self selectionIsMillimeterWaveOnly:selection]) {
        [warnings addObject:CCNMPreferencesLocalizedString(@"BAND_WARNING_MMWAVE_ONLY")];
    }
    // Only when an NR band was actually measured. On LTE there is no NR serving
    // band to lose, and inventing one would produce a warning about nothing.
    if (self.servingNRBand && ![selection containsObject:self.servingNRBand]) {
        [warnings addObject:[NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"BAND_WARNING_EXCLUDES_SERVING_FORMAT"),
            [NSString stringWithFormat:@"n%@", self.servingNRBand]]];
    }
    return warnings;
}

- (void)confirmSelection:(NSArray<NSNumber *> *)selection
                warnings:(NSArray<NSString *> *)warnings {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"BAND_WARNING_ALERT_TITLE")
        message:[warnings componentsJoinedByString:@"\n\n"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_CANCEL")
        style:UIAlertActionStyleCancel
        handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BAND_SAVE_SELECTION")
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            (void)action;
            [weakSelf commitSelection:selection];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)selectionIsMillimeterWaveOnly:(NSArray<NSNumber *> *)selection {
    if (selection.count == 0) {
        return NO;
    }
    long long *bands = calloc(selection.count, sizeof(long long));
    if (!bands) {
        return NO;
    }
    for (NSUInteger index = 0; index < selection.count; index++) {
        bands[index] = selection[index].longLongValue;
    }
    int result = CCNMNRSelectionIsMillimeterWaveOnly(bands, (unsigned long)selection.count);
    free(bands);
    return result != 0;
}

- (void)commitSelection:(NSArray<NSNumber *> *)selection {
    // The warning alert can sit above the pane while the parent changes policy
    // state. Re-check that state and the captured selection before the durable
    // preference write; the modem is still untouched here, but stale UI must not
    // silently overwrite a newer choice.
    NSDictionary *policy = CCNMReadN78PolicyState();
    CCNMBandSelectionAvailability latestAvailability =
        [self availabilityForPolicySummary:policy];
    BOOL selectionStillCurrent = [selection isEqualToArray:[self canonicalWorkingSelection]];
    if (latestAvailability != self.availability || latestAvailability != CCNMBandSelectionAvailable ||
        !selectionStillCurrent || ![self canSave]) {
        [self rebuildFromWorld];
        NSString *message = [self isEditable]
            ? CCNMPreferencesLocalizedString(@"BAND_SAVE_INVALID_GENERIC")
            : [self unavailableExplanation];
        if (message.length > 0) {
            [self presentAlertWithTitleKey:@"BAND_SAVE_FAILED_TITLE" message:message];
        }
        return;
    }

    NSString *failure = nil;
    if (!CCNMWriteSelectedNRBands(selection, &failure)) {
        [self presentAlertWithTitleKey:@"BAND_SAVE_FAILED_TITLE"
                              message:CCNMPreferencesLocalizedString(@"BAND_SAVE_INVALID_GENERIC")];
        return;
    }
    NSArray<NSNumber *> *readBack = CCNMReadSelectedNRBands();
    if (![readBack isEqualToArray:selection]) {
        [self presentAlertWithTitleKey:@"BAND_SAVE_FAILED_TITLE"
                              message:CCNMPreferencesLocalizedString(@"BAND_SAVE_INVALID_GENERIC")];
        return;
    }
    // Re-read the whole model after the write. This clears droppedStoredBands and
    // rebuilds the status/footer from the value that is actually on disk.
    [self reloadModel];
    [self commitRebuiltSpecifiers];
}

- (void)presentAlertWithTitleKey:(NSString *)titleKey message:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(titleKey)
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"BUTTON_OK")
        style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
