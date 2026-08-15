#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) (@path)
#endif

@interface CCNMRootListController : PSListController
- (void)showHelpAlert:(PSSpecifier *)specifier;
- (void)showBandProbe:(PSSpecifier *)specifier;
- (void)confirmSameValueBandWrite:(PSSpecifier *)specifier;
- (void)confirmRestoreBandSnapshot:(PSSpecifier *)specifier;
- (void)runSameValueBandWrite;
- (void)restoreSavedBandSnapshot;
@end

@interface CCNMTelegramCell : PSTableCell
@property (nonatomic, retain) NSBundle *bundle;
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
- (void)openTelegram;
@end

@interface CCNMDiscordCell : PSTableCell
@property (nonatomic, retain) NSBundle *bundle;
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
- (void)openDiscord;
@end

@interface CCNMTwitterCell : PSTableCell
@property (nonatomic, retain) NSBundle *bundle;
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
- (void)openTwitter;
@end

@interface CCNMRedditCell : PSTableCell
@property (nonatomic, retain) NSBundle *bundle;
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
- (void)openReddit;
@end

@interface NetworkManagerLogo : PSTableCell {
	UILabel *background;
	UILabel *tweakName;
	UILabel *version;
}
@end
