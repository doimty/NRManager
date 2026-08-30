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
// What "unedited" means for this appearance: the stored selection narrowed to the
// bands the current domain still offers, which is exactly what workingSelection is
// seeded with.
//
// Comparing against the raw stored value instead reported an edit the user never
// made. A stored band that has dropped out of the domain can never be in
// workingSelection, so the two arrays differed on arrival and the save row enabled
// itself on a pane that had only been looked at. The domain is the live active list
// narrowed by supported, so it shrinks on its own when the modem's active set
// changes, which is why re-entering the pane could flip the row on with no input.
// The bands that dropped out are reported by droppedStoredBands; they are not kept
// here, because a save can only ever write a subset of the domain.
@property (nonatomic, copy) NSArray<NSNumber *> *baselineSelection;
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

- (void)applicationWillEnterForeground:(NSNotification *)notification;

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
    self.baselineSelection = [working.allObjects sortedArrayUsingSelector:@selector(compare:)];
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

// Both sides are canonical and both are confined to the current domain, so this
// answers only "did the user change something on this pane".
- (BOOL)workingSelectionDiffersFromBaseline {
    return ![[self canonicalWorkingSelection] isEqualToArray:self.baselineSelection];
}

- (NSString *)validationFailureForWorkingSelection {
    NSArray<NSNumber *> *selection = [self canonicalWorkingSelection];
    NSString *failure = nil;
    if (CCNMValidateNRBandSelectionAgainstDomain(selection, self.domain, &failure)) {
        return nil;
    }
    if (selection.count == 0) {
        return CCNMPreferencesLocalizedString(@"Choose at least one NR band.");
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
        return CCNMPreferencesLocalizedString(@"The selection includes a band this device does not currently allow.");
    }
    if ([selection isEqualToArray:canonicalDomain]) {
        return CCNMPreferencesLocalizedString(@"All currently available bands are selected. Turn the feature off instead.");
    }
    return CCNMPreferencesLocalizedString(@"This selection cannot be applied on this device.");
}

- (BOOL)canSave {
    return [self isEditable] && [self workingSelectionDiffersFromBaseline] &&
        [self validationFailureForWorkingSelection] == nil;
}

- (NSString *)unavailableExplanation {
    switch (self.availability) {
        case CCNMBandSelectionBlockedByEnabledPolicy:
            return CCNMPreferencesLocalizedString(@"The NR band restriction is currently enabled, so the bands reported by iOS are the applied result rather than the original configuration. Turn off the switch on the previous screen before changing the selection.");
        case CCNMBandSelectionBlockedByRecovery:
            return CCNMPreferencesLocalizedString(@"Saved policy evidence needs attention before the selection can change. Resolve the recovery state on the previous screen first.");
        case CCNMBandSelectionBlockedByMissingEvidence:
            return CCNMPreferencesLocalizedString(@"No usable NR band evidence has been read from this device yet. Return to the previous screen and refresh the serving status.");
        case CCNMBandSelectionAvailable:
            return @"";
    }
    return @"";
}

- (NSString *)statusText {
    if (![self isEditable]) {
        return CCNMPreferencesLocalizedString(@"Unavailable");
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
    NSString *formatKey = @"Saved: %@";
    if ([self workingSelectionDiffersFromBaseline]) {
        formatKey = @"Not saved yet: %@";
    } else if (!self.hasExplicitSavedSelection) {
        formatKey = @"Using the default: %@";
    }
    return [NSString stringWithFormat:CCNMPreferencesLocalizedString(formatKey), list];
}

- (NSString *)descriptionForBands:(NSArray<NSNumber *> *)bands {
    if (bands.count == 0) {
        return CCNMPreferencesLocalizedString(@"none");
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
            CCNMPreferencesLocalizedString(@"%@ · currently connected at %@"),
            range, [NSString stringWithFormat:@"%.3f MHz", self.servingFrequencyMHz.doubleValue]];
    }
    return [NSString stringWithFormat:
        CCNMPreferencesLocalizedString(@"%@ · currently connected"), range];
}

- (NSString *)rangeDescriptionForBand:(NSNumber *)band {
    switch (CCNMClassifyNRBandRange(band.longLongValue)) {
        case CCNMNRBandRangeSub6:
            return CCNMPreferencesLocalizedString(@"Sub-6 GHz");
        case CCNMNRBandRangeMillimeterWave:
            return CCNMPreferencesLocalizedString(@"mmWave");
        case CCNMNRBandRangeUnknown:
            return CCNMPreferencesLocalizedString(@"Unrecognised band number");
    }
    return CCNMPreferencesLocalizedString(@"Unrecognised band number");
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
        CCNMPreferencesLocalizedString(@"Selection")
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
        CCNMPreferencesLocalizedString(@"Save selection")
        target:self set:NULL get:NULL detail:Nil cell:PSButtonCell edit:Nil];
    CCNMSetSpecifierID(specifier, CCNMBandSaveSpecifierID);
    specifier->action = @selector(saveBandSelection:);
    [specifier setProperty:@([self canSave]) forKey:PSEnabledKey];
    self.currentSaveSpecifier = specifier;
    return specifier;
}

- (PSSpecifier *)unavailableSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:
        CCNMPreferencesLocalizedString(@"Unavailable")
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
                                          titleKey:@"Selectable Bands"
                                         footerKey:self.droppedStoredBands.count > 0
                                             ? nil : @"Only bands that are both enabled by iOS and reported as supported by this modem can be chosen. Selecting every band is the same as turning the feature off."];
    if (self.droppedStoredBands.count > 0) {
        [group setProperty:[NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"Only bands that are both enabled by iOS and reported as supported by this modem can be chosen. Your saved selection also contained %@, which this device does not currently offer; those bands are not shown and will not be saved again."),
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
                                       titleKey:@"Save"
                                      footerKey:@"Saving records your choice only. Nothing is written to the modem until you turn the switch on, and the selection is checked again against live band evidence at that moment."]];
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
    self.title = CCNMPreferencesLocalizedString(@"NR Bands");

    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(applicationWillEnterForeground:)
                                                name:UIApplicationWillEnterForegroundNotification
                                              object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                   name:UIApplicationWillEnterForegroundNotification
                                                 object:nil];
}

// Returning from the background produces no appearance callback for a pane that
// never left the screen, so -viewWillAppear: cannot notice that the world moved on.
// Everything shown here is derived state: the availability gate reads live policy,
// the selectable domain comes from the cached capability sample, and the warning
// about losing the current connection names the band the modem was measured on. All
// three can be minutes old after a foreground return, and the domain is what a save
// is checked against.
//
// Staleness is already handled correctly further in -- an expired sample drops the
// serving band rather than naming the wrong one -- so this is not a correctness fix
// but the difference between a pane that silently describes an old world and one that
// describes the current one. The rebuild is the same work every appearance already
// does: it reads a cached file and a small plist, never the modem.
- (void)applicationWillEnterForeground:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded || self.view.window == nil) {
        // Off screen: -viewWillAppear: rebuilds when this pane comes back.
        return;
    }
    [self rebuildFromWorld];
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
            failure = CCNMPreferencesLocalizedString(@"This selection cannot be applied on this device.");
        }
        [self presentAlertWithTitleKey:@"Selection Not Saved" message:failure];
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
        [warnings addObject:CCNMPreferencesLocalizedString(@"Every band in this selection is mmWave, which has very limited coverage. 5G will be unavailable almost everywhere. LTE is unaffected and will still be used.")];
    }
    // Only when an NR band was actually measured. On LTE there is no NR serving
    // band to lose, and inventing one would produce a warning about nothing.
    if (self.servingNRBand && ![selection containsObject:self.servingNRBand]) {
        [warnings addObject:[NSString stringWithFormat:
            CCNMPreferencesLocalizedString(@"This selection excludes %@, which is the band you are connected to right now. Applying it will drop that 5G connection; the device will use another selected band if one is available, or LTE."),
            [NSString stringWithFormat:@"n%@", self.servingNRBand]]];
    }
    return warnings;
}

- (void)confirmSelection:(NSArray<NSNumber *> *)selection
                warnings:(NSArray<NSString *> *)warnings {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:CCNMPreferencesLocalizedString(@"Save this selection?")
        message:[warnings componentsJoinedByString:@"\n\n"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"Cancel")
        style:UIAlertActionStyleCancel
        handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:CCNMPreferencesLocalizedString(@"Save selection")
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
            ? CCNMPreferencesLocalizedString(@"This selection cannot be applied on this device.")
            : [self unavailableExplanation];
        if (message.length > 0) {
            [self presentAlertWithTitleKey:@"Selection Not Saved" message:message];
        }
        return;
    }

    NSString *failure = nil;
    if (!CCNMWriteSelectedNRBands(selection, &failure)) {
        [self presentAlertWithTitleKey:@"Selection Not Saved"
                              message:CCNMPreferencesLocalizedString(@"This selection cannot be applied on this device.")];
        return;
    }
    NSArray<NSNumber *> *readBack = CCNMReadSelectedNRBands();
    if (![readBack isEqualToArray:selection]) {
        [self presentAlertWithTitleKey:@"Selection Not Saved"
                              message:CCNMPreferencesLocalizedString(@"This selection cannot be applied on this device.")];
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
        actionWithTitle:CCNMPreferencesLocalizedString(@"OK")
        style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
