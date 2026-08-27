#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CCNMSettingsPreferenceRequestHandler)(BOOL enabled);
typedef void (^CCNMSettingsActionHandler)(void);

@interface CCNMRootListController : PSListController

// The policy owner supplies these handlers. Without them, all state-changing
// controls remain unavailable and this controller only renders placeholders.
@property (nonatomic, copy, nullable) CCNMSettingsPreferenceRequestHandler n78PreferenceRequestHandler;
@property (nonatomic, copy, nullable) CCNMSettingsActionHandler refreshServingStatusHandler;
@property (nonatomic, copy, nullable) CCNMSettingsActionHandler restoreSavedConfigurationHandler;

- (void)updateN78PreferenceEnabled:(BOOL)enabled controlAvailable:(BOOL)available;
- (void)updateTransitionStateWithLocalizationKey:(NSString *)localizationKey;
- (void)updateCurrentStateWithRequestedValue:(NSString *)requestedValue
                                appliedValue:(NSString *)appliedValue
                                servingValue:(NSString *)servingValue
                               dataLineValue:(NSString *)dataLineValue
                              freshnessValue:(NSString *)freshnessValue
                            refreshAvailable:(BOOL)refreshAvailable;
- (void)updateRecoveryStateWithLocalizationKey:(NSString *)localizationKey
                                       visible:(BOOL)visible
                        hasRecoverableBaseline:(BOOL)hasRecoverableBaseline
                  cleanupCheckpointRecoverable:(BOOL)cleanupCheckpointRecoverable
                                requiresReboot:(BOOL)requiresReboot;

@end

NS_ASSUME_NONNULL_END