#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const CCNMPreferenceSubtitleKey;
FOUNDATION_EXPORT NSString * const CCNMPreferenceValueKey;
FOUNDATION_EXPORT NSString * const CCNMPreferenceURLKey;
/// Whether a band-selection row currently carries a checkmark. Held on the
/// specifier rather than in the cell so a recycled cell cannot inherit the
/// previous row's state.
FOUNDATION_EXPORT NSString * const CCNMPreferenceCheckedKey;

FOUNDATION_EXPORT NSString *CCNMPreferencesLocalizedString(NSString *key);

@interface CCNMHeaderCell : PSTableCell
@end

@interface CCNMStatusCell : PSTableCell
@end

@interface CCNMRepositoryLinkCell : PSTableCell
@end

/// One selectable NR band: number, a short description, and a checkmark.
///
/// The checkmark is drawn from the specifier's own property rather than from
/// PSTableCell's -setChecked:, which is wired to Preferences' single-selection
/// radio-group machinery. Band selection is multi-select, so it owns its state.
@interface CCNMBandSelectionCell : PSTableCell
@end

NS_ASSUME_NONNULL_END
