#include "CCNMRootListController.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

@protocol CCNMCoreTelephonyClient <NSObject>
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (id)getSubscriptionInfoWithError:(NSError **)error;
- (id)getBandInfo:(id)context error:(NSError **)error;
- (void)setActiveBandInfo:(id)context bands:(id)bands error:(NSError **)error;
@end

@protocol CCNMSubscriptionInfo <NSObject>
- (NSArray *)subscriptions;
@end

@protocol CCNMSubscriptionContext <NSObject>
- (long long)slotID;
- (BOOL)isSimGood;
- (BOOL)isSimPresent;
- (NSUUID *)uuid;
@end

@protocol CCNMBandInfo <NSObject>
- (instancetype)initWithActiveBands:(NSDictionary *)bands;
- (NSDictionary *)activeBands;
- (NSDictionary *)supportedBands;
@end

static const NSTimeInterval CCNMSameValueWriteWatchdogSeconds = 20.0;
static const long long CCNMMaximumExpectedBandIdentifier = 1024;
static BOOL CCNMBandOperationInProgress = NO;
static BOOL CCNMRecoveryOperationInProgress = NO;
static BOOL CCNMManualRestoreInProgress = NO;
static BOOL CCNMTestSetterInProgress = NO;
static NSTimeInterval CCNMBandOperationStartedAt = 0;
static NSTimeInterval CCNMRecoveryOperationStartedAt = 0;
static NSTimeInterval CCNMTestSetterStartedAt = 0;
static NSUInteger CCNMCurrentBandOperationGeneration = 0;
static NSUInteger CCNMManualRecoveryGeneration = 0;

static NSTimeInterval CCNMMonotonicTime(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static NSString *CCNMBandProbePath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandprobe.plist");
}

static NSString *CCNMBandSnapshotPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.snapshot.plist");
}

static NSString *CCNMBandWriteIntentPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.intent.plist");
}

static NSString *CCNMBandWriteResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.result.plist");
}

static NSString *CCNMBandWatchdogResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.watchdog.plist");
}

static NSString *CCNMBandManualRestoreResultPath(void) {
    return jbroot(@"/var/mobile/Library/Preferences/me.nixuge.networkmanager.bandwrite.manual-restore.plist");
}

static NSString *CCNMSysctlString(const char *name) {
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

static BOOL CCNMValidateTargetDevice(NSMutableDictionary *result, NSString **failure) {
    NSString *deviceModel = CCNMSysctlString("hw.machine");
    NSString *systemBuild = CCNMSysctlString("kern.osversion");
    NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
    result[@"deviceModel"] = deviceModel ?: @"";
    result[@"systemBuild"] = systemBuild ?: @"";
    result[@"systemVersion"] = systemVersion ?: @"";

    BOOL valid = [deviceModel isEqualToString:@"iPhone14,3"] &&
                 [systemBuild isEqualToString:@"19B81"] &&
                 [systemVersion isEqualToString:@"15.1.1"];
    if (!valid && failure) {
        *failure = @"This write probe is locked to iPhone14,3 / iOS 15.1.1 / 19B81.";
    }
    return valid;
}

static BOOL CCNMBeginBandOperation(NSUInteger *operationGeneration,
                                   NSUInteger *manualRecoveryGeneration) {
    @synchronized([CCNMRootListController class]) {
        if (CCNMBandOperationInProgress || CCNMRecoveryOperationInProgress || CCNMManualRestoreInProgress) {
            return NO;
        }
        CCNMBandOperationInProgress = YES;
        CCNMBandOperationStartedAt = CCNMMonotonicTime();
        CCNMCurrentBandOperationGeneration++;
        if (operationGeneration) {
            *operationGeneration = CCNMCurrentBandOperationGeneration;
        }
        if (manualRecoveryGeneration) {
            *manualRecoveryGeneration = CCNMManualRecoveryGeneration;
        }
        return YES;
    }
}

static BOOL CCNMBeginTestSetterOperation(NSUInteger operationGeneration,
                                         NSUInteger manualRecoveryGeneration,
                                         NSString **failure) {
    @synchronized([CCNMRootListController class]) {
        if (CCNMCurrentBandOperationGeneration != operationGeneration ||
            CCNMManualRecoveryGeneration != manualRecoveryGeneration ||
            CCNMRecoveryOperationInProgress ||
            CCNMManualRestoreInProgress ||
            CCNMTestSetterInProgress) {
            if (failure) {
                *failure = @"A recovery or newer operation invalidated the write before the setter was called.";
            }
            return NO;
        }
        CCNMTestSetterInProgress = YES;
        CCNMTestSetterStartedAt = CCNMMonotonicTime();
        return YES;
    }
}

static void CCNMEndTestSetterOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMTestSetterInProgress = NO;
        CCNMTestSetterStartedAt = 0;
    }
}

static BOOL CCNMBeginManualRestoreOperation(void) {
    @synchronized([CCNMRootListController class]) {
        if (CCNMManualRestoreInProgress) {
            return NO;
        }
        NSTimeInterval now = CCNMMonotonicTime();
        if (CCNMRecoveryOperationInProgress &&
            (CCNMRecoveryOperationStartedAt <= 0 || now - CCNMRecoveryOperationStartedAt < CCNMSameValueWriteWatchdogSeconds)) {
            return NO;
        }
        if (CCNMBandOperationInProgress) {
            NSTimeInterval protectedOperationStartedAt = CCNMTestSetterInProgress ? CCNMTestSetterStartedAt : CCNMBandOperationStartedAt;
            if (protectedOperationStartedAt <= 0 || now - protectedOperationStartedAt < CCNMSameValueWriteWatchdogSeconds) {
                return NO;
            }
            CCNMManualRecoveryGeneration++;
        }
        CCNMManualRestoreInProgress = YES;
        return YES;
    }
}

static void CCNMEndRecoveryOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMRecoveryOperationInProgress = NO;
        CCNMRecoveryOperationStartedAt = 0;
    }
}

static void CCNMEndManualRestoreOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMManualRestoreInProgress = NO;
    }
}

static void CCNMEndBandOperation(void) {
    @synchronized([CCNMRootListController class]) {
        CCNMBandOperationInProgress = NO;
        CCNMTestSetterInProgress = NO;
        CCNMBandOperationStartedAt = 0;
        CCNMTestSetterStartedAt = 0;
    }
}

static NSString *CCNMReadableObject(id object) {
    if (!object) {
        return @"(none)";
    }

    if ([NSJSONSerialization isValidJSONObject:object]) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:&error];
        if (data && !error) {
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }

    return [object description];
}

static BOOL CCNMDictionariesEqual(NSDictionary *left, NSDictionary *right) {
    return left != nil && right != nil && [left isEqualToDictionary:right];
}

static NSDictionary *CCNMDeepCopyDictionary(NSDictionary *dictionary, NSString **failure) {
    if (![dictionary isKindOfClass:[NSDictionary class]] || dictionary.count == 0) {
        if (failure) {
            *failure = @"The Band dictionary is missing or empty.";
        }
        return nil;
    }

    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dictionary
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The Band dictionary could not be serialized.";
        }
        return nil;
    }

    id copiedObject = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:&serializationError];
    if (![copiedObject isKindOfClass:[NSDictionary class]] || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The Band dictionary copy is invalid.";
        }
        return nil;
    }

    return copiedObject;
}

static BOOL CCNMValidateBandDictionary(NSDictionary *bands, NSString **failure) {
    if (![bands isKindOfClass:[NSDictionary class]] || bands.count == 0) {
        if (failure) {
            *failure = @"The active-band dictionary is missing or empty.";
        }
        return NO;
    }

    for (id key in bands) {
        id values = bands[key];
        if (![key isKindOfClass:[NSString class]] ||
            ![(NSString *)key hasPrefix:@"kCTRegistrationRadioAccessTechnology"] ||
            ![values isKindOfClass:[NSArray class]]) {
            if (failure) {
                *failure = @"The active-band dictionary has an unexpected RAT key or value type.";
            }
            return NO;
        }

        NSMutableSet *seen = [NSMutableSet set];
        for (id band in (NSArray *)values) {
            if (![band isKindOfClass:[NSNumber class]] || [band longLongValue] <= 0 || [band longLongValue] > CCNMMaximumExpectedBandIdentifier || [seen containsObject:band]) {
                if (failure) {
                    *failure = @"The active-band dictionary contains an invalid or duplicate Band value.";
                }
                return NO;
            }
            [seen addObject:band];
        }
    }

    return YES;
}

static BOOL CCNMValidateSnapshot(NSDictionary *snapshot, NSDictionary **bands, NSString **failure) {
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"The saved slot-1 Band snapshot is missing or invalid.";
        }
        return NO;
    }

    NSDictionary *snapshotBands = [snapshot[@"activeBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"activeBands"] : nil;
    if (![snapshot[@"schemaVersion"] isEqual:@1] ||
        ![snapshot[@"slotID"] isEqual:@1] ||
        ![snapshot[@"subscriptionUUID"] isKindOfClass:[NSString class]] ||
        [snapshot[@"subscriptionUUID"] length] == 0 ||
        !CCNMValidateBandDictionary(snapshotBands, failure)) {
        if (failure && !*failure) {
            *failure = @"The saved slot-1 Band snapshot is missing or invalid.";
        }
        return NO;
    }

    if (bands) {
        *bands = snapshotBands;
    }
    return YES;
}

static BOOL CCNMValidateWriteIntent(NSDictionary *intent, NSDictionary *snapshot, NSString **failure) {
    if (![intent isKindOfClass:[NSDictionary class]] || ![snapshot isKindOfClass:[NSDictionary class]]) {
        if (failure) {
            *failure = @"No valid write-intent record exists for this recovery snapshot.";
        }
        return NO;
    }

    NSDictionary *snapshotBands = [snapshot[@"activeBands"] isKindOfClass:[NSDictionary class]] ? snapshot[@"activeBands"] : nil;
    NSDictionary *intentBands = [intent[@"snapshotActiveBands"] isKindOfClass:[NSDictionary class]] ? intent[@"snapshotActiveBands"] : nil;
    BOOL valid = [intent[@"schemaVersion"] isEqual:@1] &&
                 [intent[@"operation"] isEqual:@"same_value_write_intent"] &&
                 [intent[@"slotID"] isEqual:@1] &&
                 [intent[@"operationGeneration"] isKindOfClass:[NSNumber class]] &&
                 [intent[@"operationGeneration"] unsignedIntegerValue] > 0 &&
                 [intent[@"subscriptionUUID"] isKindOfClass:[NSString class]] &&
                 [intent[@"subscriptionUUID"] isEqual:snapshot[@"subscriptionUUID"]] &&
                 [intent[@"snapshotCreatedAt"] isKindOfClass:[NSNumber class]] &&
                 [intent[@"snapshotCreatedAt"] isEqual:snapshot[@"createdAt"]] &&
                 CCNMValidateBandDictionary(intentBands, failure) &&
                 CCNMDictionariesEqual(snapshotBands, intentBands);
    if (!valid) {
        if (failure && !*failure) {
            *failure = @"The write-intent record does not match the unique recovery snapshot.";
        }
        return NO;
    }
    return YES;
}

static BOOL CCNMCreateDurablePlistExclusively(NSDictionary *plist, NSString *path, NSString **failure) {
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:&serializationError];
    if (!data || serializationError) {
        if (failure) {
            *failure = serializationError.localizedDescription ?: @"The recovery snapshot is not a valid property list.";
        }
        return NO;
    }

    const char *filePath = path.fileSystemRepresentation;
    int fileDescriptor = open(filePath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (fileDescriptor < 0) {
        if (failure) {
            *failure = errno == EEXIST ? @"A recovery snapshot already exists; refusing to overwrite it."
                                       : [NSString stringWithFormat:@"Could not create the recovery snapshot: %s", strerror(errno)];
        }
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL wroteAllBytes = YES;
    while (remaining > 0) {
        ssize_t written = write(fileDescriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            wroteAllBytes = NO;
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    int syncResult = wroteAllBytes ? fsync(fileDescriptor) : -1;
    int closeResult = close(fileDescriptor);
    if (!wroteAllBytes || syncResult != 0 || closeResult != 0) {
        int savedError = errno;
        unlink(filePath);
        if (failure) {
            *failure = [NSString stringWithFormat:@"Could not durably save the recovery snapshot: %s", strerror(savedError)];
        }
        return NO;
    }

    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![readBack isEqualToDictionary:plist]) {
        unlink(filePath);
        if (failure) {
            *failure = @"The recovery snapshot failed read-back verification.";
        }
        return NO;
    }

    return YES;
}

static const char *CCNMSkipTypeQualifiers(const char *type) {
    while (type && strchr("rnNoORV", *type)) {
        type++;
    }
    return type;
}

static BOOL CCNMValidateSetterABI(id<CCNMCoreTelephonyClient> client, NSString **failure) {
    SEL selector = @selector(setActiveBandInfo:bands:error:);
    if (![client respondsToSelector:selector]) {
        if (failure) {
            *failure = @"CoreTelephonyClient does not expose setActiveBandInfo:bands:error:.";
        }
        return NO;
    }

    NSMethodSignature *signature = [(id)client methodSignatureForSelector:selector];
    if (!signature) {
        if (failure) {
            *failure = @"The runtime setter has no Objective-C method signature.";
        }
        return NO;
    }
    const char *returnType = CCNMSkipTypeQualifiers(signature.methodReturnType);
    const char *contextType = signature.numberOfArguments > 2 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:2]) : NULL;
    const char *bandsType = signature.numberOfArguments > 3 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:3]) : NULL;
    const char *errorType = signature.numberOfArguments > 4 ? CCNMSkipTypeQualifiers([signature getArgumentTypeAtIndex:4]) : NULL;
    BOOL valid = signature.numberOfArguments == 5 &&
                 returnType && strcmp(returnType, @encode(void)) == 0 &&
                 contextType && contextType[0] == '@' &&
                 bandsType && bandsType[0] == '@' &&
                 errorType && errorType[0] == '^' && errorType[1] == '@';
    if (!valid && failure) {
        *failure = @"The runtime setter ABI does not match void(context, CTBandInfo, NSError **).";
    }
    return valid;
}

static id<CCNMCoreTelephonyClient> CCNMCreateCoreTelephonyClient(NSString **failure) {
    static void *coreTelephonyHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
    });

    Class clientClass = NSClassFromString(@"CoreTelephonyClient");
    if (!coreTelephonyHandle || !clientClass) {
        if (failure) {
            *failure = @"CoreTelephonyClient is unavailable on this system.";
        }
        return nil;
    }

    id<CCNMCoreTelephonyClient> client = [(id)clientClass alloc];
    if (![client respondsToSelector:@selector(initWithQueue:)]) {
        if (failure) {
            *failure = @"CoreTelephonyClient does not expose initWithQueue:.";
        }
        return nil;
    }

    @try {
        client = [client initWithQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"CoreTelephonyClient initialization raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    if (![client respondsToSelector:@selector(getSubscriptionInfoWithError:)] ||
        ![client respondsToSelector:@selector(getBandInfo:error:)]) {
        if (failure) {
            *failure = @"The required iOS 15 band-query selectors are unavailable.";
        }
        return nil;
    }

    return client;
}

static id<CCNMSubscriptionContext> CCNMSafeSlotOneContext(id<CCNMCoreTelephonyClient> client,
                                                           NSMutableDictionary *result,
                                                           NSString *requiredUUID,
                                                           NSString **failure) {
    @try {
    NSError *subscriptionError = nil;
    id<CCNMSubscriptionInfo> subscriptionInfo = nil;
    @try {
        subscriptionInfo = [client getSubscriptionInfoWithError:&subscriptionError];
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Subscription query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
    NSArray *subscriptions = [subscriptionInfo respondsToSelector:@selector(subscriptions)] ? [subscriptionInfo subscriptions] : nil;
    if (subscriptionError || subscriptions.count == 0) {
        if (failure) {
            *failure = subscriptionError.localizedDescription ?: @"No cellular subscription context was returned.";
        }
        return nil;
    }

    NSMutableArray *contextReports = [NSMutableArray array];
    id<CCNMSubscriptionContext> targetContext = nil;
    NSUInteger presentContextCount = 0;
    for (id<CCNMSubscriptionContext> context in subscriptions) {
        BOOL hasSlot = [context respondsToSelector:@selector(slotID)];
        BOOL hasPresent = [context respondsToSelector:@selector(isSimPresent)];
        BOOL hasGood = [context respondsToSelector:@selector(isSimGood)];
        long long slotID = hasSlot ? [context slotID] : -1;
        BOOL isPresent = hasPresent && [context isSimPresent];
        BOOL isGood = hasGood && [context isSimGood];
        id rawUUID = [context respondsToSelector:@selector(uuid)] ? [context uuid] : nil;
        NSUUID *uuid = [rawUUID isKindOfClass:[NSUUID class]] ? rawUUID : nil;
        [contextReports addObject:@{
            @"slotID": @(slotID),
            @"isSimPresent": @(isPresent),
            @"isSimGood": @(isGood),
            @"uuid": uuid.UUIDString ?: @""
        }];

        if (isPresent) {
            presentContextCount++;
        }
        if (slotID == 1 && isPresent && isGood && uuid.UUIDString.length > 0) {
            targetContext = context;
        }
    }
    result[@"contexts"] = contextReports;

    if (presentContextCount != 1 || !targetContext) {
        if (failure) {
            *failure = @"Safety check failed: this probe requires exactly one present/good SIM with a stable UUID in slot 1.";
        }
        return nil;
    }

    id targetRawUUID = [targetContext respondsToSelector:@selector(uuid)] ? [targetContext uuid] : nil;
    NSUUID *targetUUIDObject = [targetRawUUID isKindOfClass:[NSUUID class]] ? targetRawUUID : nil;
    NSString *targetUUID = targetUUIDObject.UUIDString;
    if (targetUUID.length == 0 || (requiredUUID.length > 0 && ![requiredUUID isEqualToString:targetUUID])) {
        if (failure) {
            *failure = @"Safety check failed: the slot-1 subscription UUID changed after the snapshot was created.";
        }
        return nil;
    }
    result[@"targetSubscriptionUUID"] = targetUUID;
    return targetContext;
    } @catch (NSException *exception) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Slot-1 context validation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return nil;
    }
}

static BOOL CCNMRestoreActiveBands(id<CCNMCoreTelephonyClient> client,
                                   id<CCNMSubscriptionContext> context,
                                   NSDictionary *snapshotBands,
                                   NSMutableDictionary *phase,
                                   NSString **failure) {
    @try {
    phase[@"setterAttempted"] = @NO;
    if (!client || !context || !CCNMValidateBandDictionary(snapshotBands, failure)) {
        if (failure && !*failure) {
            *failure = @"Restore inputs are incomplete.";
        }
        return NO;
    }

    Class bandInfoClass = NSClassFromString(@"CTBandInfo");
    if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
        if (failure) {
            *failure = @"CTBandInfo initWithActiveBands: is unavailable.";
        }
        return NO;
    }

    id<CCNMBandInfo> restoreInfo = nil;
    @try {
        restoreInfo = [[(id)bandInfoClass alloc] initWithActiveBands:[snapshotBands mutableCopy]];
    } @catch (NSException *exception) {
        phase[@"constructorException"] = exception.reason ?: exception.name;
        if (failure) {
            *failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
    NSDictionary *payloadBands = [restoreInfo respondsToSelector:@selector(activeBands)] ? [restoreInfo activeBands] : nil;
    BOOL payloadEqual = CCNMDictionariesEqual(snapshotBands, payloadBands);
    phase[@"payloadEqualBeforeWrite"] = @(payloadEqual);
    if (!payloadEqual) {
        if (failure) {
            *failure = @"CTBandInfo changed the snapshot before the restore write.";
        }
        return NO;
    }

    NSError *restoreError = nil;
    phase[@"setterAttempted"] = @YES;
    @try {
        [client setActiveBandInfo:context bands:restoreInfo error:&restoreError];
    } @catch (NSException *exception) {
        phase[@"setterException"] = exception.reason ?: exception.name;
        if (failure) {
            *failure = [NSString stringWithFormat:@"Restore setter raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
    phase[@"setterError"] = restoreError.localizedDescription ?: @"";
    if (restoreError) {
        if (failure) {
            *failure = [NSString stringWithFormat:@"Restore setter failed: %@", restoreError.localizedDescription];
        }
        return NO;
    }

    NSError *readBackError = nil;
    id<CCNMBandInfo> restoredInfo = nil;
    @try {
        restoredInfo = [client getBandInfo:context error:&readBackError];
    } @catch (NSException *exception) {
        phase[@"readBackException"] = exception.reason ?: exception.name;
        if (failure) {
            *failure = [NSString stringWithFormat:@"Restore read-back raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
    NSDictionary *restoredBands = [restoredInfo respondsToSelector:@selector(activeBands)] ? [restoredInfo activeBands] : nil;
    BOOL equal = !readBackError && CCNMDictionariesEqual(snapshotBands, restoredBands);
    phase[@"readBackError"] = readBackError.localizedDescription ?: @"";
    phase[@"readBackEqual"] = @(equal);
    if (restoredBands) {
        phase[@"readBackActiveBands"] = restoredBands;
    }
    if (!equal) {
        if (failure) {
            *failure = readBackError.localizedDescription ?: @"Restore read-back did not exactly match the saved snapshot.";
        }
        return NO;
    }

    return YES;
    } @catch (NSException *exception) {
        phase[@"unexpectedException"] = exception.reason ?: exception.name;
        if (failure) {
            *failure = [NSString stringWithFormat:@"Band restore raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }
        return NO;
    }
}

static void CCNMRunWatchdogRestore(NSDictionary *snapshot) {
    NSMutableDictionary *result = [@{
        @"schemaVersion": @1,
        @"operation": @"watchdog_restore",
        @"startedAt": @([[NSDate date] timeIntervalSince1970]),
        @"slotID": @1,
        @"restoreReadBackEqual": @NO,
        @"error": @""
    } mutableCopy];
    NSString *failure = nil;
    @try {
    NSDictionary *snapshotBands = nil;
    CCNMValidateTargetDevice(result, &failure);
    if (!failure && !CCNMValidateSnapshot(snapshot, &snapshotBands, &failure)) {
        result[@"error"] = failure ?: @"Invalid watchdog snapshot.";
        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        [result writeToFile:CCNMBandWatchdogResultPath() atomically:YES];
        return;
    }

    id<CCNMCoreTelephonyClient> client = CCNMCreateCoreTelephonyClient(&failure);
    if (!failure) {
        CCNMValidateSetterABI(client, &failure);
    }
    id<CCNMSubscriptionContext> context = nil;
    if (!failure) {
        context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
    }
    if (!failure) {
        NSMutableDictionary *restorePhase = [NSMutableDictionary dictionary];
        BOOL restored = CCNMRestoreActiveBands(client, context, snapshotBands, restorePhase, &failure);
        result[@"restoreReadBackEqual"] = @(restored);
        result[@"restorePhase"] = restorePhase;
    }

    } @catch (NSException *exception) {
        result[@"operationException"] = exception.reason ?: exception.name;
        failure = [NSString stringWithFormat:@"Watchdog restore raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
    }
    result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
    result[@"error"] = failure ?: @"";
    [result writeToFile:CCNMBandWatchdogResultPath() atomically:YES];
}

@implementation CCNMRootListController
- (void)showHelpAlert:(PSSpecifier *)specifier {
    // Usually 2g/3g GSM are enough. Enable their CDMA counterparts only if your carrier is Sprint or Verizon or if you don't get any signal when forcing 2G/3G
    NSString* explanation = @"You can enable every network you want to switch between in the control center.\n"
        "\n"
        "About the different variations\n (GSM/CDMA/NR...):\n"
        "It all depends on your country/carrier. \n"
        "For 2G/3G usually you should be using GSM, but some carriers (Sprint, Verizon) are using CDMA.\n"
        "For 5G, I unfortunately couldn't do extensive testing, so it's up to you to try out which works. Personally I'm using the 5G NR Non StandAlone.\n"
        "\n"
        "Of course, you can use any number of module you want. Eg only LTE (which will switch between LTE & auto), or LTE+5G NSA (my personal setup), or any other combination you want.";

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"What do I need to enable?" message:explanation preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *dismissAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
    }];
    
    [alertController addAction:dismissAction];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showBandProbe:(PSSpecifier *)specifier {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static void *coreTelephonyHandle = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            coreTelephonyHandle = dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_LOCAL);
        });

        NSMutableArray *reports = [NSMutableArray array];
        NSString *failure = nil;
        Class clientClass = NSClassFromString(@"CoreTelephonyClient");
        SEL subscriptionsSelector = @selector(getSubscriptionInfoWithError:);
        SEL bandInfoSelector = @selector(getBandInfo:error:);

        @try {
        if (!coreTelephonyHandle || !clientClass) {
            failure = @"CoreTelephonyClient is unavailable on this system.";
        } else {
            id<CCNMCoreTelephonyClient> client = [(id)clientClass alloc];
            if (![client respondsToSelector:@selector(initWithQueue:)]) {
                failure = @"CoreTelephonyClient does not expose initWithQueue:.";
            } else {
                @try {
                    client = [client initWithQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)];
                } @catch (NSException *exception) {
                    failure = [NSString stringWithFormat:@"CoreTelephonyClient initialization raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                if (!failure && (![client respondsToSelector:subscriptionsSelector] || ![client respondsToSelector:bandInfoSelector])) {
                    failure = @"The required iOS 15 band-query selectors are unavailable.";
                }
                if (!failure) {
                    NSError *subscriptionError = nil;
                    id<CCNMSubscriptionInfo> subscriptionInfo = nil;
                    @try {
                        subscriptionInfo = [client getSubscriptionInfoWithError:&subscriptionError];
                    } @catch (NSException *exception) {
                        failure = [NSString stringWithFormat:@"Subscription query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                    }
                    NSArray *subscriptions = [subscriptionInfo respondsToSelector:@selector(subscriptions)] ? [subscriptionInfo subscriptions] : nil;

                    if (!failure && (subscriptionError || subscriptions.count == 0)) {
                        failure = subscriptionError.localizedDescription ?: @"No cellular subscription context was returned.";
                    }
                    if (!failure) {
                        [subscriptions enumerateObjectsUsingBlock:^(id<CCNMSubscriptionContext> context, NSUInteger index, BOOL *stop) {
                            NSError *bandError = nil;
                            id<CCNMBandInfo> bandInfo = nil;
                            NSString *bandExceptionMessage = nil;
                            @try {
                                bandInfo = [client getBandInfo:context error:&bandError];
                            } @catch (NSException *exception) {
                                bandExceptionMessage = [NSString stringWithFormat:@"Band query raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                            }
                            NSMutableDictionary *report = [NSMutableDictionary dictionary];
                            long long slotID = [context respondsToSelector:@selector(slotID)] ? [context slotID] : (long long)index + 1;
                            report[@"slotID"] = @(slotID);
                            if ([context respondsToSelector:@selector(isSimPresent)]) {
                                report[@"isSimPresent"] = @([context isSimPresent]);
                            }
                            if ([context respondsToSelector:@selector(isSimGood)]) {
                                report[@"isSimGood"] = @([context isSimGood]);
                            }

                            if (bandExceptionMessage || bandError || !bandInfo) {
                                report[@"error"] = bandExceptionMessage ?: bandError.localizedDescription ?: @"No CTBandInfo object was returned.";
                            } else {
                                NSDictionary *activeBands = [bandInfo respondsToSelector:@selector(activeBands)] ? [bandInfo activeBands] : nil;
                                NSDictionary *supportedBands = [bandInfo respondsToSelector:@selector(supportedBands)] ? [bandInfo supportedBands] : nil;
                                report[@"activeBands"] = activeBands ?: @{};
                                report[@"supportedBands"] = supportedBands ?: @{};
                            }

                            [reports addObject:report];
                        }];
                    }
                }
            }
        }
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"Band query operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        }

        NSDictionary *probeResult = @{
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"subscriptions": reports,
            @"error": failure ?: @""
        };
        [probeResult writeToFile:CCNMBandProbePath() atomically:YES];
        NSString *message = failure ?: CCNMReadableObject(reports);

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }

            NSString *title = failure ? @"Band probe failed" : @"Band probe result";
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
            if (!failure) {
                [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [UIPasteboard generalPasteboard].string = message;
                }]];
            }
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)confirmSameValueBandWrite:(PSSpecifier *)specifier {
    BOOL snapshotExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()];
    BOOL intentExists = [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()];
    if (snapshotExists || intentExists) {
        UIAlertController *existingSnapshotAlert = [UIAlertController alertControllerWithTitle:@"Saved probe state already exists"
            message:@"This build never overwrites its recovery snapshot or write-intent record. Use Restore Saved Band Snapshot first. Only after a verified restore, manually delete the snapshot and intent paths shown in the copied result; reinstalling alone does not remove them."
            preferredStyle:UIAlertControllerStyleAlert];
        [existingSnapshotAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existingSnapshotAlert animated:YES completion:nil];
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Run same-value Band write?"
        message:@"This sends one real CoreTelephony Band write to slot 1, but the payload is the exact active-band dictionary just read from the device. A full snapshot is saved first, then the value is verified and restored. Cellular service may briefly re-register. Do not run this while the phone is your only emergency-communication device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Run Test" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self runSameValueBandWrite];
    }]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)confirmRestoreBandSnapshot:(PSSpecifier *)specifier {
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
    NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
    NSString *snapshotFailure = nil;
    NSString *intentFailure = nil;
    BOOL validSnapshot = CCNMValidateSnapshot(snapshot, NULL, &snapshotFailure);
    BOOL validIntent = validSnapshot && CCNMValidateWriteIntent(writeIntent, snapshot, &intentFailure);
    NSString *message = validIntent ? @"Restore slot 1 to the complete active-band snapshot saved before the last write test?" : (snapshotFailure ?: intentFailure ?: @"No matching Band write intent was found. Restore is disabled because no setter call can be established.");
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Restore saved Band snapshot" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (validIntent) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self restoreSavedBandSnapshot];
        }]];
    }
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)runSameValueBandWrite {
    NSUInteger operationGeneration = 0;
    NSUInteger manualRecoveryGeneration = 0;
    if (!CCNMBeginBandOperation(&operationGeneration, &manualRecoveryGeneration)) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Band operation already running" message:@"Wait for the current query, write, or restore operation to finish." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"same_value_write",
            @"operationGeneration": @(operationGeneration),
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"writeIntentSaved": @NO,
            @"setterAttempted": @NO,
            @"writeReadBackEqual": @NO,
            @"restoreAttempted": @NO,
            @"restoreReadBackEqual": @NO,
            @"watchdogArmed": @NO,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        @try {
        id<CCNMCoreTelephonyClient> client = CCNMCreateCoreTelephonyClient(&failure);
        if (client) {
            CCNMValidateSetterABI(client, &failure);
        }

        id<CCNMSubscriptionContext> context = nil;
        NSDictionary *originalBands = nil;
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, nil, &failure);
        }

        if (!failure) {
            NSError *readError = nil;
            id<CCNMBandInfo> originalInfo = nil;
            @try {
                originalInfo = [client getBandInfo:context error:&readError];
            } @catch (NSException *exception) {
                result[@"initialReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Initial Band read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *readBands = [originalInfo respondsToSelector:@selector(activeBands)] ? [originalInfo activeBands] : nil;
            if (!failure) {
                originalBands = CCNMDeepCopyDictionary(readBands, &failure);
            }
            result[@"initialReadError"] = readError.localizedDescription ?: @"";
            if (!failure && (readError || !originalBands || !CCNMValidateBandDictionary(originalBands, &failure))) {
                failure = readError.localizedDescription ?: failure ?: @"The original active-band dictionary is invalid.";
            }
        }

        if (!failure && ([[NSFileManager defaultManager] fileExistsAtPath:CCNMBandSnapshotPath()] ||
                         [[NSFileManager defaultManager] fileExistsAtPath:CCNMBandWriteIntentPath()])) {
            failure = @"Saved Band probe state already exists. Refusing to overwrite the recovery snapshot or write-intent record.";
        }

        __block NSDictionary *snapshot = nil;
        if (!failure) {
            snapshot = @{
                @"schemaVersion": @1,
                @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                @"slotID": @1,
                @"subscriptionUUID": result[@"targetSubscriptionUUID"],
                @"activeBands": originalBands
            };
            if (!CCNMCreateDurablePlistExclusively(snapshot, CCNMBandSnapshotPath(), &failure)) {
                result[@"snapshotSaved"] = @NO;
            } else {
                result[@"snapshotSaved"] = @YES;
                result[@"snapshotPath"] = CCNMBandSnapshotPath();
                result[@"originalActiveBands"] = originalBands;
            }
        }

        __block BOOL operationFinished = NO;
        __block BOOL setterWasInvoked = NO;
        __block BOOL restoreStarted = NO;
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSError *preWriteReadError = nil;
            id<CCNMBandInfo> preWriteInfo = nil;
            @try {
                preWriteInfo = [client getBandInfo:context error:&preWriteReadError];
            } @catch (NSException *exception) {
                result[@"preWriteReadException"] = exception.reason ?: exception.name;
                failure = [NSString stringWithFormat:@"Pre-write read raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
            }
            NSDictionary *preWriteBands = [preWriteInfo respondsToSelector:@selector(activeBands)] ? [preWriteInfo activeBands] : nil;
            BOOL preWriteEqual = !preWriteReadError && CCNMDictionariesEqual(originalBands, preWriteBands);
            result[@"preWriteReadError"] = preWriteReadError.localizedDescription ?: @"";
            result[@"preWriteActiveBandsEqual"] = @(preWriteEqual);
            if (!preWriteEqual && !failure) {
                failure = preWriteReadError.localizedDescription ?: @"The live active-band dictionary changed after the snapshot; setter was not called.";
            }
        }
        if (!failure) {
            Class bandInfoClass = NSClassFromString(@"CTBandInfo");
            if (!bandInfoClass || ![bandInfoClass instancesRespondToSelector:@selector(initWithActiveBands:)]) {
                failure = @"CTBandInfo initWithActiveBands: is unavailable.";
            } else {
                id<CCNMBandInfo> sameValueInfo = nil;
                @try {
                    sameValueInfo = [[(id)bandInfoClass alloc] initWithActiveBands:[originalBands mutableCopy]];
                } @catch (NSException *exception) {
                    result[@"constructorException"] = exception.reason ?: exception.name;
                    failure = [NSString stringWithFormat:@"CTBandInfo construction raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                }
                NSDictionary *payloadBands = [sameValueInfo respondsToSelector:@selector(activeBands)] ? [sameValueInfo activeBands] : nil;
                BOOL payloadEqual = CCNMDictionariesEqual(originalBands, payloadBands);
                result[@"payloadEqualBeforeWrite"] = @(payloadEqual);
                if (!payloadEqual) {
                    failure = @"CTBandInfo changed the original dictionary before the write; setter was not called.";
                }

                if (!failure) {
                    NSDictionary *writeIntent = @{
                        @"schemaVersion": @1,
                        @"operation": @"same_value_write_intent",
                        @"createdAt": @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0)),
                        @"operationGeneration": @(operationGeneration),
                        @"slotID": @1,
                        @"subscriptionUUID": snapshot[@"subscriptionUUID"],
                        @"snapshotCreatedAt": snapshot[@"createdAt"],
                        @"snapshotActiveBands": snapshot[@"activeBands"]
                    };
                    if (!CCNMValidateWriteIntent(writeIntent, snapshot, &failure) ||
                        !CCNMCreateDurablePlistExclusively(writeIntent, CCNMBandWriteIntentPath(), &failure)) {
                        result[@"writeIntentSaved"] = @NO;
                    } else {
                        result[@"writeIntentSaved"] = @YES;
                        result[@"writeIntentPath"] = CCNMBandWriteIntentPath();
                    }
                }

                if (!failure && CCNMBeginTestSetterOperation(operationGeneration, manualRecoveryGeneration, &failure)) {
                    NSError *setterError = nil;
                    @try {
                        NSDictionary *watchdogSnapshot = snapshot;
                        result[@"watchdogArmed"] = @YES;
                        result[@"watchdogDelaySeconds"] = @(CCNMSameValueWriteWatchdogSeconds);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCNMSameValueWriteWatchdogSeconds * NSEC_PER_SEC)),
                                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            BOOL shouldRestore = NO;
                            @synchronized([CCNMRootListController class]) {
                                if (setterWasInvoked &&
                                    !operationFinished &&
                                    !restoreStarted &&
                                    !CCNMRecoveryOperationInProgress &&
                                    !CCNMManualRestoreInProgress &&
                                    CCNMCurrentBandOperationGeneration == operationGeneration) {
                                    restoreStarted = YES;
                                    CCNMRecoveryOperationInProgress = YES;
                                    CCNMRecoveryOperationStartedAt = CCNMMonotonicTime();
                                    shouldRestore = YES;
                                }
                            }
                            if (shouldRestore) {
                                @try {
                                    CCNMRunWatchdogRestore(watchdogSnapshot);
                                } @finally {
                                    CCNMEndRecoveryOperation();
                                }
                            }
                        });
                        result[@"setterAttempted"] = @YES;
                        result[@"setterStartedAt"] = @([[NSDate date] timeIntervalSince1970]);
                        @synchronized([CCNMRootListController class]) {
                            setterWasInvoked = YES;
                        }
                        @try {
                            [client setActiveBandInfo:context bands:sameValueInfo error:&setterError];
                        } @catch (NSException *exception) {
                            result[@"setterException"] = exception.reason ?: exception.name;
                            failure = [NSString stringWithFormat:@"Same-value setter raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                        }
                    } @finally {
                        CCNMEndTestSetterOperation();
                    }
                    if (setterWasInvoked) {
                    result[@"setterFinishedAt"] = @([[NSDate date] timeIntervalSince1970]);
                    result[@"setterError"] = setterError.localizedDescription ?: @"";
                    if (setterError) {
                        failure = [NSString stringWithFormat:@"Same-value setter failed: %@", setterError.localizedDescription];
                    } else if (!failure) {
                        NSError *readBackError = nil;
                        id<CCNMBandInfo> readBackInfo = nil;
                        @try {
                            readBackInfo = [client getBandInfo:context error:&readBackError];
                        } @catch (NSException *exception) {
                            result[@"writeReadBackException"] = exception.reason ?: exception.name;
                            failure = [NSString stringWithFormat:@"Same-value read-back raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
                        }
                        NSDictionary *readBackBands = [readBackInfo respondsToSelector:@selector(activeBands)] ? [readBackInfo activeBands] : nil;
                        BOOL equal = !readBackError && CCNMDictionariesEqual(originalBands, readBackBands);
                        result[@"writeReadBackError"] = readBackError.localizedDescription ?: @"";
                        result[@"writeReadBackEqual"] = @(equal);
                        if (readBackBands) {
                            result[@"writeReadBackActiveBands"] = readBackBands;
                        }
                        if (!equal) {
                            failure = readBackError.localizedDescription ?: @"Same-value write read-back differed from the original snapshot.";
                        }
                    }
                    }
                }
            }

            if (setterWasInvoked) {
                BOOL shouldRestore = NO;
                @synchronized([CCNMRootListController class]) {
                    if (!restoreStarted && !CCNMRecoveryOperationInProgress && !CCNMManualRestoreInProgress) {
                        restoreStarted = YES;
                        CCNMRecoveryOperationInProgress = YES;
                        CCNMRecoveryOperationStartedAt = CCNMMonotonicTime();
                        shouldRestore = YES;
                    }
                }
                if (shouldRestore) {
                    NSMutableDictionary *restorePhase = [NSMutableDictionary dictionary];
                    NSString *restoreFailure = nil;
                    BOOL restored = NO;
                    @try {
                        id<CCNMSubscriptionContext> restoreContext = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &restoreFailure);
                        if (!restoreFailure) {
                            result[@"restoreAttempted"] = @YES;
                            restored = CCNMRestoreActiveBands(client, restoreContext, originalBands, restorePhase, &restoreFailure);
                        }
                    } @finally {
                        CCNMEndRecoveryOperation();
                    }
                    result[@"restoreReadBackEqual"] = @(restored);
                    result[@"restorePhase"] = restorePhase;
                    if (restoreFailure) {
                        result[@"restoreError"] = restoreFailure;
                        if (!failure) {
                            failure = restoreFailure;
                        }
                    } else {
                        result[@"restoreError"] = @"";
                    }
                } else {
                    result[@"restoreDeferred"] = @YES;
                    if (!failure) {
                        failure = @"A separate recovery attempt already owns the snapshot restore; inspect the watchdog or restore result.";
                    }
                }
            }
            @synchronized([CCNMRootListController class]) {
                operationFinished = YES;
            }
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Band operation raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            CCNMEndBandOperation();
        }

        BOOL requiredPhasesCompleted = [result[@"setterAttempted"] boolValue] &&
                                       [result[@"writeReadBackEqual"] boolValue] &&
                                       [result[@"restoreAttempted"] boolValue] &&
                                       [result[@"restoreReadBackEqual"] boolValue];
        if (!failure && !requiredPhasesCompleted) {
            failure = @"The probe did not complete every required write, read-back, and restore phase.";
        }
        result[@"passed"] = @(!failure && requiredPhasesCompleted);
        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        BOOL resultSaved = [result writeToFile:CCNMBandWriteResultPath() atomically:YES];
        BOOL passed = resultSaved && !failure && requiredPhasesCompleted;
        NSString *message = nil;
        if (!resultSaved) {
            message = @"The test finished, but its result plist could not be saved.";
        } else if (!passed) {
            message = [NSString stringWithFormat:@"FAILED\n%@\n\nSnapshot: %@\nResult: %@", failure ?: @"Required phases did not all complete.", CCNMBandSnapshotPath(), CCNMBandWriteResultPath()];
        } else {
            message = [NSString stringWithFormat:@"PASSED\nSetter returned no error. Same-value read-back matched, and the final snapshot restore matched.\n\nResult: %@", CCNMBandWriteResultPath()];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:passed ? @"Band write probe passed" : @"Band write probe failed" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)restoreSavedBandSnapshot {
    if (!CCNMBeginManualRestoreOperation()) {
        UIAlertController *busyAlert = [UIAlertController alertControllerWithTitle:@"Restore unavailable right now" message:@"A restore is already running, or the write test is still within its 20-second safety window. Retry after it finishes or after the watchdog window." preferredStyle:UIAlertControllerStyleAlert];
        [busyAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:busyAlert animated:YES completion:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *result = [@{
            @"schemaVersion": @1,
            @"operation": @"manual_restore",
            @"startedAt": @([[NSDate date] timeIntervalSince1970]),
            @"slotID": @1,
            @"error": @""
        } mutableCopy];
        NSString *failure = nil;
        @try {
        NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:CCNMBandSnapshotPath()];
        NSDictionary *writeIntent = [NSDictionary dictionaryWithContentsOfFile:CCNMBandWriteIntentPath()];
        NSDictionary *snapshotBands = nil;
        CCNMValidateSnapshot(snapshot, &snapshotBands, &failure);
        if (!failure) {
            result[@"writeIntentValidated"] = @(CCNMValidateWriteIntent(writeIntent, snapshot, &failure));
        } else {
            result[@"writeIntentValidated"] = @NO;
        }

        id<CCNMCoreTelephonyClient> client = nil;
        id<CCNMSubscriptionContext> context = nil;
        if (!failure) {
            client = CCNMCreateCoreTelephonyClient(&failure);
        }
        if (!failure) {
            CCNMValidateSetterABI(client, &failure);
        }
        if (!failure) {
            CCNMValidateTargetDevice(result, &failure);
        }
        if (!failure) {
            context = CCNMSafeSlotOneContext(client, result, snapshot[@"subscriptionUUID"], &failure);
        }
        if (!failure) {
            NSMutableDictionary *restorePhase = [NSMutableDictionary dictionary];
            BOOL restored = CCNMRestoreActiveBands(client, context, snapshotBands, restorePhase, &failure);
            result[@"restoreReadBackEqual"] = @(restored);
            result[@"restorePhase"] = restorePhase;
        }
        } @catch (NSException *exception) {
            result[@"operationException"] = exception.reason ?: exception.name;
            failure = [NSString stringWithFormat:@"Manual restore raised %@: %@", exception.name, exception.reason ?: @"(no reason)"];
        } @finally {
            CCNMEndManualRestoreOperation();
        }

        result[@"completedAt"] = @([[NSDate date] timeIntervalSince1970]);
        result[@"error"] = failure ?: @"";
        [result writeToFile:CCNMBandManualRestoreResultPath() atomically:YES];
        NSString *message = failure ?: @"Saved slot-1 active bands were restored and read back exactly.";
        dispatch_async(dispatch_get_main_queue(), ^{
            CCNMRootListController *strongSelf = weakSelf;
            if (!strongSelf.view.window) {
                return;
            }
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:failure ? @"Band snapshot restore failed" : @"Band snapshot restored" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [UIPasteboard generalPasteboard].string = CCNMReadableObject(result);
            }]];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [strongSelf presentViewController:alertController animated:YES completion:nil];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIBarButtonItem *applyButton = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    self.navigationItem.rightBarButtonItem = applyButton;

    // As of the latest Dopamine version, an oldabi check should no longer be required as it's implemented into Dopamine now.
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}

	return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier*)specifier {
	NSString *path = [NSString stringWithFormat:jbroot(@"/var/mobile/Library/Preferences/%@.plist"), specifier.properties[@"defaults"]];
	NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:path];
	return (settings[specifier.properties[@"key"]]) ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier*)specifier {
	NSString *path = [NSString stringWithFormat:jbroot(@"/var/mobile/Library/Preferences/%@.plist"), specifier.properties[@"defaults"]];
	NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithContentsOfFile:path];
	[settings setObject:value forKey:specifier.properties[@"key"]];
	[settings writeToFile:path atomically:YES];
	CFStringRef notificationName = (__bridge CFStringRef)specifier.properties[@"PostNotification"];
	if (notificationName) {
		CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notificationName, NULL, NULL, YES);
	}
}

-(void)save {
	[self.view endEditing:YES];
}
@end

@implementation CCNMTelegramCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Telegram";
        self.detailTextLabel.text = @"@Nixuge";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *telegramLogo = [UIImage imageNamed:@"telegram" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:telegramLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openTelegram)];
    }

    return self;
}

-(void)openTelegram {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"tg:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"tg://resolve?domain=Nixuge"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://t.me/Nixuge"] options:@{} completionHandler:nil];
    }
}
@end

@implementation CCNMDiscordCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Discord";
        self.detailTextLabel.text = @"@Nixuge";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *discordLogo = [UIImage imageNamed:@"discord" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:discordLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openDiscord)];
    }

    return self;
}

-(void)openDiscord {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"discord:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"discord://discord.com/users/784062518901473351"] options:@{} completionHandler:nil];
    }
    // not opening in the browser as discord browser on mobile is horrendous
}
@end

@implementation CCNMTwitterCell

-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Twitter";
        self.detailTextLabel.text = @"@JeanFilsYTB";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *twitterLogo = [UIImage imageNamed:@"twitter" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:twitterLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openTwitter)];
    }

    return self;
}

-(void)openTwitter {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"twitter:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"twitter://user?screen_name=JeanFilsYTB"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.twitter.com/JeanFilsYTB"] options:@{} completionHandler:nil];
    }
}

@end

@implementation CCNMRedditCell
-(instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self) {
        _bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/NetworkManagerPrefs.bundle")];
        [_bundle load];

        // Labels
        self.textLabel.text = @"Reddit";
        self.detailTextLabel.text = @"/u/Nixugay";
        self.detailTextLabel.textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.60 alpha:1.0];

        // Right image
        UIImage *redditLogo = [UIImage imageNamed:@"reddit" inBundle:_bundle compatibleWithTraitCollection:nil];
        self.accessoryView = [[UIImageView alloc] initWithImage:redditLogo];

        [specifier setTarget:self];
        [specifier setButtonAction:@selector(openReddit)];
    }

    return self;
}

-(void)openReddit {
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"reddit:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"reddit:///u/Nixugay"] options:@{} completionHandler:nil];
    } else if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"apollo:"]]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"apollo://www.reddit.com/u/Nixugay"] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.reddit.com/u/Nixugay"] options:@{} completionHandler:nil];
    }
}
@end

@implementation NetworkManagerLogo

- (id)initWithSpecifier:(PSSpecifier *)specifier
{
	self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Banner" specifier:specifier];
	if (self) {
		// CGFloat width = 320;
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
		CGFloat height = 70;

		CGRect backgroundFrame = CGRectMake(-50, -35, width, height);
		background = [[UILabel alloc] initWithFrame:backgroundFrame];
		[background layoutIfNeeded];
		background.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:0.0];
		background.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

		CGRect tweakNameFrame = CGRectMake(-50, -40, width, height);
		tweakName = [[UILabel alloc] initWithFrame:tweakNameFrame];
		[tweakName layoutIfNeeded];
		tweakName.numberOfLines = 1;
		tweakName.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
        [tweakName setFont:[UIFont systemFontOfSize:30]];
		tweakName.textColor = [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
		tweakName.text = @"NetworkManagerReborn";
		tweakName.textAlignment = NSTextAlignmentCenter;

		CGRect versionFrame = CGRectMake(-50, -5, width, height);
		version = [[UILabel alloc] initWithFrame:versionFrame];
		version.numberOfLines = 1;
		version.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
        [version setFont:[UIFont systemFontOfSize:15]];
		version.textColor = [UIColor colorWithRed:0.82 green:0.82 blue:0.84 alpha:1.0];

        // For future reference (not really important here), could use either:
        // - %s and NETWORK_MANAGER_VERSION (Cstring) -> no perf impact but cant handle eg unicode & crashes if undefined macro
        // - %@ and @NETWORK_MANAGER_VERSION (NSString) -> slight perf impact (new obj) but can handle unicode & empty string if undefined macro
		version.text = [NSString stringWithFormat:@"Version %@", @(NETWORK_MANAGER_VERSION)];

		version.backgroundColor = [UIColor clearColor];
		version.textAlignment = NSTextAlignmentCenter;

		[self addSubview:background];
		[self addSubview:tweakName];
		[self addSubview:version];
	}
    return self;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
	return 100.0f;
}
@end
