#import "CCNMN78PolicyReader.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

#if defined(CCNM_MAINTENANCE_DAEMON)
#import "../maintenance-daemon/CCNMDaemonRoot.h"
// The daemon cannot use jbroot(). libroothide's install name is
// @loader_path/.jbroot/usr/lib/libroothide.dylib, and launchd applies no
// bootstrap injection, so dyld found nothing to load and the job crashed on every
// one of its 108 launches with OS_REASON_DYLD. The prefix is recovered from the
// daemon's own executable path instead; see CCNMDaemonRoot.h.
#define CCNMPolicyRoot(path) CCNMDaemonRootedPath(path)
#elif __has_include(<roothide.h>)
#import <roothide.h>
#define CCNMPolicyRoot(path) jbroot(path)
#else
#define CCNMPolicyRoot(path) (path)
#endif

// ---------------------------------------------------------------------------
// Mark: constants
// ---------------------------------------------------------------------------

static NSString *const CCNMPolicyOwner = @"me.nixuge.networkmanager.n78-policy";
static NSString *const CCNMNRKey = @"kCTRegistrationRadioAccessTechnologyNR";
static NSString *const CCNMKnownOrphanRecoverySource = @"known-device-orphaned-n78";
static NSString *const CCNMKnownOrphanEvidenceSHA256 =
    @"9e6230dfae679537b5b827518975e7675abf864cd403e96f97f11de63316ac76";
static NSString *const CCNMKnownOrphanSubscriptionUUID =
    @"00000000-0000-0000-0000-000000000001";
static const long long CCNMMaximumBandIdentifier = 1024;

// ---------------------------------------------------------------------------
// Mark: path functions
// ---------------------------------------------------------------------------

NSString *CCNMN78PolicyStatePath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.state.plist");
}

NSString *CCNMN78PolicyBaselinePath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.baseline.plist");
}

NSString *CCNMN78PolicyIntentPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.intent.plist");
}

NSString *CCNMN78PolicyInFlightPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.inflight.plist");
}

NSString *CCNMN78PolicyLockPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.lock");
}

NSString *CCNMN78PolicyRemovalGuardPath(void) {
    return CCNMPolicyRoot(@"/var/mobile/Library/Preferences/"
                           "me.nixuge.networkmanager.n78-policy.removal-guard.plist");
}

NSArray<NSString *> *CCNMN78PolicyPaths(void) {
    return @[
        CCNMN78PolicyStatePath(),
        CCNMN78PolicyBaselinePath(),
        CCNMN78PolicyIntentPath(),
        CCNMN78PolicyInFlightPath(),
        CCNMN78PolicyLockPath(),
        CCNMN78PolicyRemovalGuardPath()
    ];
}

// ---------------------------------------------------------------------------
// Mark: time and identity
// ---------------------------------------------------------------------------

long long CCNMUnixMilliseconds(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

NSTimeInterval CCNMMonotonicNow(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (NSTimeInterval)now.tv_sec +
        ((NSTimeInterval)now.tv_nsec / (NSTimeInterval)NSEC_PER_SEC);
}

NSString *CCNMSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) {
        return nil;
    }
    char *buffer = calloc(1, size);
    if (!buffer) {
        return nil;
    }
    NSString *value = nil;
    if (sysctlbyname(name, buffer, &size, NULL, 0) == 0) {
        value = [NSString stringWithUTF8String:buffer];
    }
    free(buffer);
    return value;
}

NSString *CCNMCanonicalUUIDString(id value) {
    NSString *string = nil;
    if ([value isKindOfClass:[NSUUID class]]) {
        string = [(NSUUID *)value UUIDString];
    } else if ([value isKindOfClass:[NSString class]]) {
        string = [(NSString *)value
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSUUID *uuid = string ? [[NSUUID alloc] initWithUUIDString:string] : nil;
    return uuid.UUIDString;
}

NSString *CCNMBootSessionIdentity(void) {
    return CCNMCanonicalUUIDString(CCNMSysctlString("kern.bootsessionuuid"));
}

typedef NS_ENUM(NSInteger, CCNMBootRelation) {
    CCNMBootRelationUnknown = 0,
    CCNMBootRelationCurrent,
    CCNMBootRelationEarlier
};

static CCNMBootRelation CCNMBootRelationForRecord(NSDictionary *record) {
    NSString *current = CCNMBootSessionIdentity();
    NSString *recorded = CCNMCanonicalUUIDString(record[@"bootSessionUUID"]);
    if (!current || !recorded) {
        return CCNMBootRelationUnknown;
    }
    return [current isEqualToString:recorded] ? CCNMBootRelationCurrent : CCNMBootRelationEarlier;
}

// ---------------------------------------------------------------------------
// Mark: file helpers
// ---------------------------------------------------------------------------

BOOL CCNMFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

NSDictionary *CCNMLoadRecord(NSString *path, BOOL *exists) {
    BOOL present = CCNMFileExists(path);
    if (exists) {
        *exists = present;
    }
    if (!present) {
        return nil;
    }
    id record = [NSDictionary dictionaryWithContentsOfFile:path];
    return [record isKindOfClass:[NSDictionary class]] ? record : nil;
}

// ---------------------------------------------------------------------------
// Mark: integer / set helpers
// ---------------------------------------------------------------------------

BOOL CCNMNSNumberIsInteger(id value) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    const char *type = [(NSNumber *)value objCType];
    return type && type[0] && type[1] == '\0' && strchr("cCsSiIlLqQ", type[0]) != NULL;
}

NSSet<NSString *> *CCNMRequiredRATKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid",
            @"kCTRegistrationRadioAccessTechnologyGSM",
            @"kCTRegistrationRadioAccessTechnologyLTE",
            @"kCTRegistrationRadioAccessTechnologyNR",
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA",
            @"kCTRegistrationRadioAccessTechnologyUTRAN"
        ]];
    });
    return keys;
}

// ---------------------------------------------------------------------------
// Mark: known orphan historical data
// ---------------------------------------------------------------------------

static NSDictionary *CCNMKnownOrphanHistoricalOriginalBands(void) {
    static NSDictionary *bands;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bands = @{
            @"kCTRegistrationRadioAccessTechnologyCDMAHybrid": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10,
                @11, @12, @13, @14, @15, @16, @17, @18, @19, @20
            ],
            @"kCTRegistrationRadioAccessTechnologyGSM": @[ @1, @2, @3, @4, @5, @6, @7, @8, @9 ],
            @"kCTRegistrationRadioAccessTechnologyLTE": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12, @13, @14,
                @17, @18, @19, @20, @21, @24, @25, @26, @27, @28, @29, @30,
                @33, @34, @35, @36, @37, @38, @39, @40, @41, @42, @43, @46,
                @48, @66, @71
            ],
            @"kCTRegistrationRadioAccessTechnologyNR": @[
                @1, @2, @3, @5, @7, @8, @12, @13, @14, @18, @20, @25, @26,
                @28, @30, @34, @38, @39, @40, @41, @48, @50, @51, @53, @65,
                @66, @70, @71, @74, @75, @76, @77, @78, @79, @80, @81, @82,
                @83, @84, @85, @86, @257, @258, @259, @260, @261
            ],
            @"kCTRegistrationRadioAccessTechnologyTDSCDMA": @[ @1, @2, @3, @4, @5, @6 ],
            @"kCTRegistrationRadioAccessTechnologyUTRAN": @[
                @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11
            ]
        };
    });
    return bands;
}

static BOOL CCNMKnownOrphanBaselineMatchesEvidence(NSDictionary *baseline) {
    return [baseline isKindOfClass:NSDictionary.class] &&
        [baseline[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource] &&
        [baseline[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256] &&
        [CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])
            isEqualToString:CCNMKnownOrphanSubscriptionUUID] &&
        CCNMDictionariesEqual(baseline[@"activeBands"],
            CCNMKnownOrphanHistoricalOriginalBands());
}

static BOOL CCNMStateHasVerifiedKnownOrphanRestore(NSDictionary *state) {
    if (![state isKindOfClass:NSDictionary.class] ||
        ![state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] ||
        ![state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] ||
        ![state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] ||
        ![CCNMCanonicalUUIDString(state[@"subscriptionUUID"])
            isEqualToString:CCNMKnownOrphanSubscriptionUUID] ||
        [state[@"uncertain"] boolValue] ||
        ![state[@"verifiedAt"] isKindOfClass:NSNumber.class] ||
        ![state[@"restoredBaselineCreatedAt"] isKindOfClass:NSNumber.class] ||
        !CCNMDictionariesEqual(state[@"verifiedActiveBands"],
            CCNMKnownOrphanHistoricalOriginalBands())) {
        return NO;
    }
    BOOL fixedProvenance = [state[@"recoverySource"] isEqual:CCNMKnownOrphanRecoverySource] &&
        [state[@"evidenceSHA256"] isEqual:CCNMKnownOrphanEvidenceSHA256];
    BOOL legacyVerifiedShape = !state[@"recoverySource"] && !state[@"evidenceSHA256"];
    return fixedProvenance || legacyVerifiedShape;
}

// ---------------------------------------------------------------------------
// Mark: dictionary validation
// ---------------------------------------------------------------------------

BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString **failure) {
    if (![bands isKindOfClass:[NSDictionary class]] ||
        ![[NSSet setWithArray:bands.allKeys] isEqualToSet:CCNMRequiredRATKeys()]) {
        if (failure) {
            *failure = @"BandInfo does not contain the exact complete RAT key set.";
        }
        return NO;
    }
    for (id key in bands) {
        id values = bands[key];
        if (![key isKindOfClass:[NSString class]] ||
            ![(NSString *)key hasPrefix:@"kCTRegistrationRadioAccessTechnology"] ||
            ![values isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"BandInfo contains an invalid RAT key or value type.";
            }
            return NO;
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (id band in (NSArray *)values) {
            if (!CCNMNSNumberIsInteger(band) || [band longLongValue] <= 0 ||
                [band longLongValue] > CCNMMaximumBandIdentifier || [seen containsObject:band]) {
                if (failure) {
                    *failure = @"BandInfo contains an invalid or duplicate band identifier.";
                }
                return NO;
            }
            [seen addObject:band];
        }
    }
    return YES;
}

BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil && [left isEqualToDictionary:right];
}

BOOL CCNMStringInDomain(id value, NSArray<NSString *> *domain) {
    return [value isKindOfClass:[NSString class]] && [domain containsObject:value];
}

NSDictionary *CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString **failure) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"A complete BandInfo dictionary is required.";
        }
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&error];
    id copy = data ? [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:&error] : nil;
    if (![copy isKindOfClass:[NSDictionary class]] || error) {
        if (failure) {
            *failure = error.localizedDescription ?: @"BandInfo could not be deep-copied.";
        }
        return nil;
    }
    return copy;
}

// ---------------------------------------------------------------------------
// Mark: record validation
// ---------------------------------------------------------------------------

BOOL CCNMValidateStateRecord(NSDictionary *state, NSString **failure) {
    BOOL valid = [state isKindOfClass:[NSDictionary class]] &&
        [state[@"schemaVersion"] isEqual:@1] &&
        [state[@"owner"] isEqual:CCNMPolicyOwner] &&
        [state[@"kind"] isEqual:@"state"] &&
        [state[@"updatedAt"] isKindOfClass:[NSNumber class]] &&
        [state[@"updatedAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(state[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(state[@"operationGeneration"]) &&
        [state[@"operationGeneration"] longLongValue] >= 0 &&
        CCNMStringInDomain(state[@"requestedMode"],
            @[CCNMRequestedModeSystemDefault, CCNMRequestedModeN78Preferred]) &&
        CCNMStringInDomain(state[@"appliedPolicy"], @[
            CCNMAppliedPolicyUnknown, CCNMAppliedPolicyApplying,
            CCNMAppliedPolicyVerifiedSystemDefault, CCNMAppliedPolicyVerifiedN78Only,
            CCNMAppliedPolicyDiverged, CCNMAppliedPolicyRecoveryRequired
        ]) &&
        CCNMStringInDomain(state[@"recoveryState"], @[
            CCNMRecoveryStateClean, CCNMRecoveryStateEnablePending,
            CCNMRecoveryStateEnabledWithBaseline, CCNMRecoveryStateRestorePending,
            CCNMRecoveryStateRebootRequired, CCNMRecoveryStateRecoveryFailed
        ]) &&
        [state[@"uncertain"] isKindOfClass:[NSNumber class]] &&
        [state[@"errorCode"] isKindOfClass:[NSString class]] &&
        [state[@"error"] isKindOfClass:[NSString class]];
    NSString *uuid = state[@"subscriptionUUID"];
    valid = valid && [uuid isKindOfClass:[NSString class]] &&
        ([(NSString *)uuid length] == 0 || CCNMCanonicalUUIDString(uuid) != nil);
    if (!valid && failure) {
        *failure = @"The durable n78 policy state record is malformed or foreign.";
    }
    return valid;
}

BOOL CCNMValidateRemovalGuardRecord(NSDictionary *guard, NSString **failure) {
    BOOL valid = [guard isKindOfClass:NSDictionary.class] &&
        [guard[@"schemaVersion"] isEqual:@1] &&
        [guard[@"owner"] isEqual:CCNMPolicyOwner] &&
        [guard[@"kind"] isEqual:@"removalGuard"] &&
        [guard[@"createdAt"] isKindOfClass:NSNumber.class] &&
        [guard[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(guard[@"bootSessionUUID"]) != nil &&
        CCNMCanonicalUUIDString(guard[@"nonce"]) != nil &&
        CCNMNSNumberIsInteger(guard[@"operationGeneration"]) &&
        [guard[@"operationGeneration"] longLongValue] >= 0 &&
        [guard[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [guard[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [guard[@"recoveryState"] isEqual:CCNMRecoveryStateClean];
    if (!valid && failure) {
        *failure = @"The durable package-removal guard is malformed or foreign.";
    }
    return valid;
}

BOOL CCNMValidateBaselineRecord(NSDictionary *baseline, NSString **failure) {
    NSDictionary *bands = [baseline[@"activeBands"] isKindOfClass:[NSDictionary class]]
        ? baseline[@"activeBands"] : nil;
    BOOL hasRecoverySource = baseline[@"recoverySource"] != nil;
    BOOL hasEvidenceDigest = baseline[@"evidenceSHA256"] != nil;
    BOOL provenanceValid = (!hasRecoverySource && !hasEvidenceDigest) ||
        CCNMKnownOrphanBaselineMatchesEvidence(baseline);
    BOOL hasCapabilitySnapshot = baseline[@"deviceModel"] != nil ||
        baseline[@"systemVersion"] != nil || baseline[@"systemBuild"] != nil ||
        baseline[@"supportedBands"] != nil || baseline[@"modifiedBandKeys"] != nil;
    BOOL capabilitySnapshotValid = !hasCapabilitySnapshot ||
        ([baseline[@"deviceModel"] isKindOfClass:NSString.class] &&
         [baseline[@"deviceModel"] length] > 0 &&
         [baseline[@"systemVersion"] isKindOfClass:NSString.class] &&
         [baseline[@"systemVersion"] length] > 0 &&
         [baseline[@"systemBuild"] isKindOfClass:NSString.class] &&
         [baseline[@"systemBuild"] length] > 0 &&
         CCNMValidateBandDictionary(baseline[@"supportedBands"], failure) &&
         [baseline[@"modifiedBandKeys"] isKindOfClass:NSArray.class] &&
         [baseline[@"modifiedBandKeys"] count] == 1 &&
         [baseline[@"modifiedBandKeys"][0] isEqual:CCNMNRKey]);
    BOOL valid = [baseline isKindOfClass:[NSDictionary class]] &&
        [baseline[@"schemaVersion"] isEqual:@1] &&
        [baseline[@"owner"] isEqual:CCNMPolicyOwner] &&
        [baseline[@"kind"] isEqual:@"baseline"] &&
        [baseline[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [baseline[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(baseline[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(baseline[@"operationGeneration"]) &&
        [baseline[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [baseline[@"slotID"] isEqual:@1] &&
        CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"]) != nil &&
        provenanceValid &&
        capabilitySnapshotValid &&
        CCNMValidateBandDictionary(bands, failure);
    if (!valid && failure && !*failure) {
        *failure = @"The durable policy baseline is malformed, foreign, or has invalid capability evidence.";
    }
    return valid;
}

// A restore replays exactly one array: CCNMBuildRestorePayload keeps the live
// values for every RAT except NR, where it writes the saved array. So the saved
// NR bands are the values that have to be declared by the modem about to receive
// them. This is the capability requirement the device allowlist used to imply,
// expressed against live evidence instead of a model name.
static BOOL CCNMBaselineNRBandsFitCurrentCapability(NSArray *savedNR,
                                                    NSArray *currentSupportedNR,
                                                    NSString *unsupportedFailure,
                                                    NSString **failure) {
    if (![savedNR isKindOfClass:NSArray.class] || ![currentSupportedNR isKindOfClass:NSArray.class]) {
        if (failure) {
            *failure = @"The retained baseline NR capability evidence is unavailable on this system.";
        }
        return NO;
    }
    for (NSNumber *band in savedNR) {
        if (![currentSupportedNR containsObject:band]) {
            if (failure) {
                *failure = unsupportedFailure;
            }
            return NO;
        }
    }
    return YES;
}

BOOL CCNMValidateBaselineCompatibility(NSDictionary *baseline,
                                        NSDictionary *currentSupportedBands,
                                        NSDictionary *identity,
                                        NSString **failure) {
    BOOL hasCapabilitySnapshot = baseline[@"deviceModel"] != nil ||
        baseline[@"systemVersion"] != nil || baseline[@"systemBuild"] != nil ||
        baseline[@"supportedBands"] != nil || baseline[@"modifiedBandKeys"] != nil;
    // Keyed subscripting a non-dictionary raises, and this bundle loads into
    // SpringBoard. CCNMValidateBaselineRecord runs first in the current callers,
    // but this function is exported and must not depend on that.
    NSDictionary *savedActive = [baseline[@"activeBands"] isKindOfClass:NSDictionary.class]
        ? baseline[@"activeBands"] : nil;
    NSDictionary *currentSupported = [currentSupportedBands isKindOfClass:NSDictionary.class]
        ? currentSupportedBands : nil;
    if (!savedActive || !currentSupported ||
        !CCNMValidateBandDictionary(savedActive, failure) ||
        !CCNMValidateBandDictionary(currentSupported, failure)) {
        if (failure && !*failure) {
            *failure = @"The retained baseline or current capability evidence is unavailable.";
        }
        return NO;
    }
    // Do not require saved active NR to be a subset of supported NR. The modem's
    // BandInfo contract permits an active list to contain values absent from its
    // supported list, and the reviewed historical baseline includes exactly that
    // shape with a verified restore read-back. The saved capability snapshot is
    // the evidence that can be compared across the restore boundary.
    if (!hasCapabilitySnapshot) {
        // Written before capability evidence existed. Refusing it is not an
        // option: a baseline is the only way back from an enable, so refusing one
        // for lacking a field that did not exist when it was written would strand
        // the device it was written to protect.
        return YES;
    }
    // Same hardware. System version and build stay recorded evidence rather than
    // a gate: an iOS update does not invalidate a rollback whose capability shape
    // and owned-band evidence still fit, and refusing on build alone would strand
    // every device that updates while the policy is enabled.
    BOOL sameDevice = [baseline[@"deviceModel"] isEqual:identity[@"deviceModel"]];
    NSDictionary *savedSupported = [baseline[@"supportedBands"] isKindOfClass:NSDictionary.class]
        ? baseline[@"supportedBands"] : nil;
    BOOL sameCapabilityShape = savedSupported &&
        [[NSSet setWithArray:savedSupported.allKeys] isEqualToSet:
            [NSSet setWithArray:currentSupported.allKeys]];
    NSArray *ownedKeys = baseline[@"modifiedBandKeys"];
    BOOL ownedFieldsValid = [ownedKeys isKindOfClass:NSArray.class] &&
        ownedKeys.count == 1 && [ownedKeys.firstObject isEqual:CCNMNRKey];
    if (!sameDevice || !sameCapabilityShape || !ownedFieldsValid) {
        if (failure) {
            *failure = @"The retained baseline belongs to a different device, capability shape, or owned-band set.";
        }
        return NO;
    }
    return CCNMBaselineNRBandsFitCurrentCapability(savedSupported[CCNMNRKey],
        currentSupported[CCNMNRKey],
        @"The retained baseline contains an owned band unsupported by the current system.", failure);
}

static BOOL CCNMValidateN78OnlyPayloadLocal(NSDictionary *original,
                                             NSDictionary *payload,
                                             NSString **failure);
static BOOL CCNMValidateRestorePayloadLocal(NSDictionary *live,
                                             NSDictionary *baseline,
                                             NSDictionary *payload,
                                             NSString **failure);

BOOL CCNMValidateIntentRecord(NSDictionary *intent,
                               NSDictionary *baseline,
                               NSString **failure) {
    NSString *operation = [intent[@"operation"] isKindOfClass:[NSString class]]
        ? intent[@"operation"] : nil;
    NSDictionary *active = [intent[@"preWriteActiveBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"preWriteActiveBands"] : nil;
    NSDictionary *supported = [intent[@"preWriteSupportedBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"preWriteSupportedBands"] : nil;
    NSDictionary *requested = [intent[@"requestedActiveBands"] isKindOfClass:[NSDictionary class]]
        ? intent[@"requestedActiveBands"] : nil;
    BOOL header = [intent isKindOfClass:[NSDictionary class]] &&
        [intent[@"schemaVersion"] isEqual:@1] &&
        [intent[@"owner"] isEqual:CCNMPolicyOwner] &&
        [intent[@"kind"] isEqual:@"intent"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"]
            containsObject:operation ?: @""] &&
        [intent[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [intent[@"createdAt"] longLongValue] > 0 &&
        CCNMCanonicalUUIDString(intent[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(intent[@"operationGeneration"]) &&
        [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [intent[@"slotID"] isEqual:@1] &&
        [CCNMCanonicalUUIDString(intent[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [intent[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]] &&
        [intent[@"baselineGeneration"] isEqual:baseline[@"operationGeneration"]] &&
        CCNMDictionariesEqual(intent[@"baselineActiveBands"], baseline[@"activeBands"]) &&
        CCNMValidateBandDictionary(active, failure) &&
        CCNMValidateBandDictionary(supported, failure);
    BOOL enable = [operation isEqual:@"enable"];
    BOOL payload = NO;
    if (header && enable) {
        payload = [active[CCNMNRKey] containsObject:@78] &&
            [supported[CCNMNRKey] containsObject:@78] &&
            CCNMValidateN78OnlyPayloadLocal(active, requested, failure);
    } else if (header) {
        payload = CCNMValidateRestorePayloadLocal(active, baseline[@"activeBands"],
            requested, failure);
    }
    if ((!header || !payload) && failure && !*failure) {
        *failure = @"The durable policy intent is malformed, foreign, or inconsistent with the baseline.";
    }
    return header && payload;
}

BOOL CCNMValidateInFlightRecord(NSDictionary *record,
                                 NSDictionary *baseline,
                                 NSDictionary *intent,
                                 BOOL requireIntentLink,
                                 NSString **failure) {
    BOOL valid = [record isKindOfClass:[NSDictionary class]] &&
        [record[@"schemaVersion"] isEqual:@1] &&
        [record[@"owner"] isEqual:CCNMPolicyOwner] &&
        [record[@"kind"] isEqual:@"inflight"] &&
        [record[@"state"] isEqual:@"setterInFlight"] &&
        [@[@"enable", @"disable", @"recover", @"knownOrphanRecovery"]
            containsObject:record[@"operation"] ?: @""] &&
        [record[@"createdAt"] isKindOfClass:[NSNumber class]] &&
        [record[@"createdAt"] longLongValue] > 0 &&
        [record[@"processID"] isKindOfClass:[NSNumber class]] &&
        [record[@"processID"] intValue] > 0 &&
        CCNMCanonicalUUIDString(record[@"bootSessionUUID"]) != nil &&
        CCNMNSNumberIsInteger(record[@"operationGeneration"]) &&
        [record[@"operationGeneration"] unsignedIntegerValue] > 0 &&
        [record[@"slotID"] isEqual:@1] &&
        [CCNMCanonicalUUIDString(record[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [record[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]];
    if (valid && requireIntentLink) {
        valid = intent &&
            [record[@"operation"] isEqual:intent[@"operation"]] &&
            [record[@"operationGeneration"] isEqual:intent[@"operationGeneration"]] &&
            [record[@"intentCreatedAt"] isEqual:intent[@"createdAt"]];
    }
    if (!valid && failure) {
        *failure = @"The setter in-flight record is malformed, foreign, or inconsistent.";
    }
    return valid;
}

// ---------------------------------------------------------------------------
// Mark: local payload validation (reader-only copies, no setter dependency)
// ---------------------------------------------------------------------------

static BOOL CCNMValidateN78OnlyPayloadLocal(NSDictionary *original,
                                             NSDictionary *payload,
                                             NSString **failure) {
    if (!CCNMValidateBandDictionary(original, failure) ||
        !CCNMValidateBandDictionary(payload, failure) ||
        ![[NSSet setWithArray:original.allKeys] isEqualToSet:
            [NSSet setWithArray:payload.allKeys]]) {
        return NO;
    }
    for (NSString *key in original) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? @[ @78 ] : original[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? @"The requested NR array is not exactly [78]."
                    : [NSString stringWithFormat:
                        @"The requested payload changed non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

static BOOL CCNMValidateRestorePayloadLocal(NSDictionary *live,
                                             NSDictionary *baseline,
                                             NSDictionary *payload,
                                             NSString **failure) {
    if (!CCNMValidateBandDictionary(live, failure) ||
        !CCNMValidateBandDictionary(baseline, failure) ||
        !CCNMValidateBandDictionary(payload, failure)) {
        return NO;
    }
    if (![[NSSet setWithArray:live.allKeys] isEqualToSet:[NSSet setWithArray:baseline.allKeys]] ||
        ![[NSSet setWithArray:live.allKeys] isEqualToSet:[NSSet setWithArray:payload.allKeys]]) {
        if (failure) {
            *failure = @"Restore dictionaries do not have identical complete RAT key sets.";
        }
        return NO;
    }
    for (NSString *key in live) {
        NSArray *expected = [key isEqualToString:CCNMNRKey] ? baseline[key] : live[key];
        if (![payload[key] isEqualToArray:expected]) {
            if (failure) {
                *failure = [key isEqualToString:CCNMNRKey]
                    ? @"The restore payload does not contain the exact saved NR array."
                    : [NSString stringWithFormat:
                        @"The restore payload changed current non-NR RAT %@.", key];
            }
            return NO;
        }
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Mark: default state / summary builder
// ---------------------------------------------------------------------------

NSDictionary *CCNMDefaultState(void) {
    return @{
        @"operationGeneration": @0,
        @"requestedMode": CCNMRequestedModeSystemDefault,
        @"appliedPolicy": CCNMAppliedPolicyVerifiedSystemDefault,
        @"recoveryState": CCNMRecoveryStateClean,
        @"subscriptionUUID": @"",
        @"uncertain": @NO,
        @"errorCode": CCNMN78PolicyErrorNone,
        @"error": @""
    };
}

static NSDictionary *CCNMSyntheticRecoveryState(NSDictionary *state,
                                                 CCNMRecoveryState recovery,
                                                 NSString *error) {
    NSDictionary *base = CCNMValidateStateRecord(state, NULL) ? state : CCNMDefaultState();
    NSMutableDictionary *synthetic = [base mutableCopy];
    synthetic[@"appliedPolicy"] = CCNMAppliedPolicyRecoveryRequired;
    synthetic[@"recoveryState"] = recovery;
    synthetic[@"uncertain"] = @YES;
    synthetic[@"errorCode"] = CCNMN78PolicyErrorInvalidRecords;
    synthetic[@"error"] = error ?: @"Durable policy evidence is inconsistent.";
    return synthetic;
}

static NSDictionary *CCNMSummaryFromState(NSDictionary *state,
                                           BOOL success,
                                           NSString *operation,
                                           CCNMN78PolicyErrorCode errorCode,
                                           NSString *error,
                                           NSDictionary *details) {
    NSDictionary *base = state ?: CCNMDefaultState();
    BOOL baselinePresent = CCNMFileExists(CCNMN78PolicyBaselinePath());
    NSDictionary *baselineRecord = baselinePresent
        ? [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyBaselinePath()] : nil;
    BOOL baselineValid = baselinePresent && CCNMValidateBaselineRecord(baselineRecord, NULL);
    BOOL transitionPresent = CCNMFileExists(CCNMN78PolicyIntentPath()) ||
        CCNMFileExists(CCNMN78PolicyInFlightPath());
    BOOL removalGuardPresent = CCNMFileExists(CCNMN78PolicyRemovalGuardPath());
    NSDictionary *removalGuard = removalGuardPresent
        ? [NSDictionary dictionaryWithContentsOfFile:CCNMN78PolicyRemovalGuardPath()] : nil;
    BOOL removalGuardValid = removalGuardPresent &&
        CCNMValidateRemovalGuardRecord(removalGuard, NULL);
    CCNMRecoveryState recovery = base[@"recoveryState"] ?: CCNMRecoveryStateRecoveryFailed;
    CCNMAppliedPolicy applied = base[@"appliedPolicy"] ?: CCNMAppliedPolicyUnknown;
    BOOL currentBootInFlight = NO;
    if (CCNMFileExists(CCNMN78PolicyInFlightPath())) {
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:
            CCNMN78PolicyInFlightPath()];
        currentBootInFlight = !record ||
            CCNMBootRelationForRecord(record) != CCNMBootRelationEarlier;
    }
    BOOL requiresReboot = [recovery isEqual:CCNMRecoveryStateRebootRequired] ||
        currentBootInFlight;
    BOOL normalEnabled = [recovery isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedN78Only] && baselinePresent &&
        !transitionPresent;
    BOOL normalDefault = [recovery isEqual:CCNMRecoveryStateClean] &&
        [applied isEqual:CCNMAppliedPolicyVerifiedSystemDefault] && !baselinePresent &&
        !transitionPresent;
    NSDictionary *typedState = @{
        CCNMN78PolicySummaryRequestedModeKey:
            base[@"requestedMode"] ?: CCNMRequestedModeSystemDefault,
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO
    };
    NSMutableDictionary *summary = [@{
        CCNMN78PolicySummarySuccessKey: @(success),
        CCNMN78PolicySummaryOperationKey: operation ?: @"read",
        CCNMN78PolicySummaryStateKey: typedState,
        CCNMN78PolicySummaryRequestedModeKey:
            typedState[CCNMN78PolicySummaryRequestedModeKey],
        CCNMN78PolicySummaryAppliedPolicyKey: applied,
        CCNMN78PolicySummaryRecoveryStateKey: recovery,
        CCNMN78PolicySummaryErrorCodeKey: errorCode ?:
            base[@"errorCode"] ?: CCNMN78PolicyErrorNone,
        CCNMN78PolicySummaryErrorKey: error ?: base[@"error"] ?: @"",
        CCNMN78PolicySummaryRequiresRebootKey: @(requiresReboot),
        CCNMN78PolicySummaryMayWriteKey: @((normalDefault || normalEnabled) &&
            !requiresReboot && !removalGuardPresent),
        CCNMN78PolicySummaryMayUninstallKey: @(normalDefault &&
            (!removalGuardPresent || removalGuardValid)),
        @"baselinePresent": @(baselinePresent),
        @"baselineValid": @(baselineValid),
        @"transitionPresent": @(transitionPresent),
        @"removalGuardPresent": @(removalGuardPresent),
        @"removalGuardValid": @(removalGuardValid),
        @"operationGeneration": base[@"operationGeneration"] ?: @0,
        @"subscriptionUUID": base[@"subscriptionUUID"] ?: @"",
        @"uncertain": base[@"uncertain"] ?: @NO,
        @"statePath": CCNMN78PolicyStatePath(),
        @"baselinePath": CCNMN78PolicyBaselinePath(),
        @"intentPath": CCNMN78PolicyIntentPath(),
        @"inFlightPath": CCNMN78PolicyInFlightPath(),
        @"lockPath": CCNMN78PolicyLockPath(),
        @"removalGuardPath": CCNMN78PolicyRemovalGuardPath(),
        @"verifiedKnownOrphanRestore": @(CCNMStateHasVerifiedKnownOrphanRestore(base))
    } mutableCopy];
    if (details) {
        [summary addEntriesFromDictionary:details];
    }
    return [summary copy];
}

// ---------------------------------------------------------------------------
// Mark: read policy state (main entry point)
// ---------------------------------------------------------------------------

static NSDictionary *CCNMReadPolicyStateInternal(void) {
    BOOL stateExists = NO, baselineExists = NO, intentExists = NO;
    BOOL inFlightExists = NO, removalGuardExists = NO;
    NSDictionary *state = CCNMLoadRecord(CCNMN78PolicyStatePath(), &stateExists);
    NSDictionary *baseline = CCNMLoadRecord(CCNMN78PolicyBaselinePath(), &baselineExists);
    NSDictionary *intent = CCNMLoadRecord(CCNMN78PolicyIntentPath(), &intentExists);
    NSDictionary *inFlight = CCNMLoadRecord(CCNMN78PolicyInFlightPath(), &inFlightExists);
    NSDictionary *removalGuard = CCNMLoadRecord(
        CCNMN78PolicyRemovalGuardPath(), &removalGuardExists);

    if (!stateExists && !baselineExists && !intentExists && !inFlightExists &&
        (!removalGuardExists || CCNMValidateRemovalGuardRecord(removalGuard, NULL))) {
        return CCNMSummaryFromState(CCNMDefaultState(), YES, @"read",
            CCNMN78PolicyErrorNone, @"", nil);
    }
    if ((stateExists && !CCNMValidateStateRecord(state, NULL)) ||
        (baselineExists && !CCNMValidateBaselineRecord(baseline, NULL)) ||
        (intentExists && (!baseline ||
            !CCNMValidateIntentRecord(intent, baseline, NULL))) ||
        (inFlightExists && (!baseline ||
            !CCNMValidateInFlightRecord(inFlight, baseline, intent, intentExists, NULL))) ||
        (removalGuardExists && !CCNMValidateRemovalGuardRecord(removalGuard, NULL))) {
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state,
            CCNMRecoveryStateRebootRequired,
            @"A durable policy record is malformed, foreign, or inconsistent.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorInvalidRecords, synthetic[@"error"], nil);
    }
    if (!stateExists) {
        BOOL evidenceMayBeCurrent =
            (inFlightExists &&
             CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists &&
             CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (baselineExists &&
             CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = evidenceMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(nil, recovery,
            @"Policy evidence exists without its state record.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorInvalidRecords, synthetic[@"error"], nil);
    }
    if (intentExists || inFlightExists) {
        if ([state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyDiverged] &&
            [state[@"recoveryState"] isEqual:CCNMRecoveryStateRecoveryFailed]) {
            return CCNMSummaryFromState(state, NO, @"read",
                CCNMN78PolicyErrorReadBackMismatch, state[@"error"], nil);
        }
        BOOL transitionMayBeCurrent =
            (inFlightExists &&
             CCNMBootRelationForRecord(inFlight) != CCNMBootRelationEarlier) ||
            (intentExists &&
             CCNMBootRelationForRecord(intent) != CCNMBootRelationEarlier) ||
            (![state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
             CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier);
        CCNMRecoveryState recovery = transitionMayBeCurrent
            ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed;
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state, recovery,
            @"A policy transition is incomplete and must be recovered before another write.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired, synthetic[@"error"], nil);
    }
    BOOL enabled = [state[@"requestedMode"] isEqual:CCNMRequestedModeN78Preferred] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedN78Only] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateEnabledWithBaseline] &&
        baselineExists && !removalGuardExists &&
        [CCNMCanonicalUUIDString(state[@"subscriptionUUID"])
            isEqualToString:CCNMCanonicalUUIDString(baseline[@"subscriptionUUID"])] &&
        [state[@"baselineCreatedAt"] isEqual:baseline[@"createdAt"]];
    BOOL systemDefault = [state[@"requestedMode"] isEqual:CCNMRequestedModeSystemDefault] &&
        [state[@"appliedPolicy"] isEqual:CCNMAppliedPolicyVerifiedSystemDefault] &&
        [state[@"recoveryState"] isEqual:CCNMRecoveryStateClean] && !baselineExists &&
        ![state[@"uncertain"] boolValue];
    if (!enabled && !systemDefault) {
        BOOL evidenceMayBeCurrent =
            CCNMBootRelationForRecord(state) != CCNMBootRelationEarlier ||
            (baselineExists &&
             CCNMBootRelationForRecord(baseline) != CCNMBootRelationEarlier);
        NSDictionary *synthetic = CCNMSyntheticRecoveryState(state,
            evidenceMayBeCurrent
                ? CCNMRecoveryStateRebootRequired : CCNMRecoveryStateRecoveryFailed,
            @"Policy state and retained baseline do not form a verified stable state.");
        return CCNMSummaryFromState(synthetic, NO, @"read",
            CCNMN78PolicyErrorRecoveryRequired, synthetic[@"error"], nil);
    }
    return CCNMSummaryFromState(state, YES, @"read",
        state[@"errorCode"], state[@"error"], nil);
}

NSDictionary *CCNMReadN78PolicyState(void) {
    return CCNMReadPolicyStateInternal();
}