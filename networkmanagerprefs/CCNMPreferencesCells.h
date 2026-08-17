#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const CCNMPreferenceSubtitleKey;
FOUNDATION_EXPORT NSString * const CCNMPreferenceValueKey;
FOUNDATION_EXPORT NSString * const CCNMPreferenceURLKey;

FOUNDATION_EXPORT NSString *CCNMPreferencesLocalizedString(NSString *key);

@interface CCNMHeaderCell : PSTableCell
@end

@interface CCNMStatusCell : PSTableCell
@end

@interface CCNMRepositoryLinkCell : PSTableCell
@end

NS_ASSUME_NONNULL_END
