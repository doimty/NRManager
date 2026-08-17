#import "CCNMPreferencesCells.h"
#import <objc/message.h>

NSString * const CCNMPreferenceSubtitleKey = @"subtitle";
NSString * const CCNMPreferenceValueKey = @"value";
NSString * const CCNMPreferenceURLKey = @"url";

static NSString * const CCNMPreferencesStringsTable = @"NetworkManagerPrefs";

static UIColor *CCNMColorFromClassSelector(SEL selector, UIColor *fallback) {
    if (![UIColor respondsToSelector:selector]) {
        return fallback;
    }
    UIColor *(*getter)(id, SEL) = (UIColor *(*)(id, SEL))objc_msgSend;
    id value = getter(UIColor.class, selector);
    return [value isKindOfClass:UIColor.class] ? value : fallback;
}

static UIColor *CCNMPrimaryTextColor(void) {
    return CCNMColorFromClassSelector(@selector(labelColor), UIColor.blackColor);
}

static UIColor *CCNMSecondaryTextColor(void) {
    return CCNMColorFromClassSelector(@selector(secondaryLabelColor), UIColor.grayColor);
}

static UIColor *CCNMLinkColor(void) {
    UIColor *fallback = [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0];
    return CCNMColorFromClassSelector(@selector(systemBlueColor), fallback);
}

static BOOL CCNMUsesAccessibilityText(UITraitCollection *traits) {
    return traits != nil && UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
}

NSString *CCNMPreferencesLocalizedString(NSString *key) {
    if (![key isKindOfClass:NSString.class] || key.length == 0) {
        return @"";
    }

    NSBundle *bundle = [NSBundle bundleForClass:CCNMHeaderCell.class];
    NSString *localized = [bundle localizedStringForKey:key
                                                   value:nil
                                                   table:CCNMPreferencesStringsTable];
    if (![localized isEqualToString:key]) {
        return localized;
    }

    NSString *englishPath = [bundle pathForResource:@"en" ofType:@"lproj"];
    NSBundle *englishBundle = englishPath.length > 0 ? [NSBundle bundleWithPath:englishPath] : nil;
    return englishBundle
        ? [englishBundle localizedStringForKey:key value:key table:CCNMPreferencesStringsTable]
        : key;
}

static void CCNMHideStandardCellContent(PSTableCell *cell) {
    cell.textLabel.hidden = YES;
    cell.detailTextLabel.hidden = YES;
    cell.imageView.hidden = YES;
}

@interface CCNMHeaderCell ()

@property (nonatomic, strong) UIImageView *productIconView;
@property (nonatomic, strong) UILabel *productTitleLabel;
@property (nonatomic, strong) UILabel *productSubtitleLabel;

@end

@implementation CCNMHeaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    (void)style;
    self = [super initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (!self) {
        return nil;
    }

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    CCNMHideStandardCellContent(self);

    _productIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _productIconView.translatesAutoresizingMaskIntoConstraints = NO;
    _productIconView.contentMode = UIViewContentModeScaleAspectFit;
    _productIconView.image = [UIImage imageNamed:@"icon"
                                       inBundle:[NSBundle bundleForClass:self.class]
                  compatibleWithTraitCollection:self.traitCollection];

    _productTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _productTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _productTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _productTitleLabel.adjustsFontForContentSizeCategory = YES;
    _productTitleLabel.textColor = CCNMPrimaryTextColor();
    _productTitleLabel.numberOfLines = 1;
    _productTitleLabel.adjustsFontSizeToFitWidth = YES;
    _productTitleLabel.minimumScaleFactor = 0.75;

    _productSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _productSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _productSubtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _productSubtitleLabel.adjustsFontForContentSizeCategory = YES;
    _productSubtitleLabel.textColor = CCNMSecondaryTextColor();
    _productSubtitleLabel.numberOfLines = 2;
    _productSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    _productSubtitleLabel.minimumScaleFactor = 0.75;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _productTitleLabel,
        _productSubtitleLabel,
    ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentFill;
    textStack.spacing = 2.0;

    [self.contentView addSubview:_productIconView];
    [self.contentView addSubview:textStack];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_productIconView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_productIconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_productIconView.widthAnchor constraintEqualToConstant:46.0],
        [_productIconView.heightAnchor constraintEqualToConstant:46.0],
        [textStack.leadingAnchor constraintEqualToAnchor:_productIconView.trailingAnchor constant:12.0],
        [textStack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [textStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8.0],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
    ]];

    [self refreshCellContentsWithSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    CCNMHideStandardCellContent(self);
    self.productTitleLabel.text = specifier.name ?: [specifier propertyForKey:PSTitleKey];
    self.productSubtitleLabel.text = [specifier propertyForKey:CCNMPreferenceSubtitleKey];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        self.productTitleLabel.text ?: @"",
        self.productSubtitleLabel.text ?: @""];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 88.0;
}

@end

@interface CCNMStatusCell ()

@property (nonatomic, strong) UILabel *statusTitleLabel;
@property (nonatomic, strong) UILabel *statusValueLabel;

@end

@implementation CCNMStatusCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    (void)style;
    self = [super initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (!self) {
        return nil;
    }

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    CCNMHideStandardCellContent(self);

    _statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _statusTitleLabel.adjustsFontForContentSizeCategory = YES;
    _statusTitleLabel.textColor = CCNMPrimaryTextColor();
    _statusTitleLabel.numberOfLines = 2;

    _statusValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusValueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _statusValueLabel.adjustsFontForContentSizeCategory = YES;
    _statusValueLabel.textColor = CCNMSecondaryTextColor();
    _statusValueLabel.numberOfLines = 2;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _statusTitleLabel,
        _statusValueLabel,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 1.0;

    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:6.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
    ]];

    [self refreshCellContentsWithSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    CCNMHideStandardCellContent(self);
    self.statusTitleLabel.text = specifier.name ?: [specifier propertyForKey:PSTitleKey];
    self.statusValueLabel.text = [specifier propertyForKey:CCNMPreferenceValueKey];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        self.statusTitleLabel.text ?: @"",
        self.statusValueLabel.text ?: @""];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return CCNMUsesAccessibilityText(self.traitCollection) ? 76.0 : 54.0;
}

@end

@interface CCNMRepositoryLinkCell ()

@property (nonatomic, strong) UILabel *linkTitleLabel;
@property (nonatomic, strong) UILabel *linkSubtitleLabel;
@property (nonatomic, strong) UIImageView *safariGlyphView;

@end

@implementation CCNMRepositoryLinkCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
               reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    (void)style;
    self = [super initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (!self) {
        return nil;
    }

    CCNMHideStandardCellContent(self);

    _linkTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _linkTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _linkTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _linkTitleLabel.adjustsFontForContentSizeCategory = YES;
    _linkTitleLabel.textColor = CCNMLinkColor();
    _linkTitleLabel.numberOfLines = 2;

    _linkSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _linkSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _linkSubtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _linkSubtitleLabel.adjustsFontForContentSizeCategory = YES;
    _linkSubtitleLabel.textColor = CCNMSecondaryTextColor();
    _linkSubtitleLabel.numberOfLines = 2;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _linkTitleLabel,
        _linkSubtitleLabel,
    ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentFill;
    textStack.spacing = 1.0;

    _safariGlyphView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _safariGlyphView.translatesAutoresizingMaskIntoConstraints = NO;
    _safariGlyphView.contentMode = UIViewContentModeScaleAspectFit;
    _safariGlyphView.tintColor = CCNMLinkColor();
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
        _safariGlyphView.image = [UIImage performSelector:@selector(systemImageNamed:) withObject:@"safari"];
    } else {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    [self.contentView addSubview:textStack];
    [self.contentView addSubview:_safariGlyphView];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_safariGlyphView.leadingAnchor constant:-12.0],
        [textStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:6.0],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
        [_safariGlyphView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_safariGlyphView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_safariGlyphView.widthAnchor constraintEqualToConstant:21.0],
        [_safariGlyphView.heightAnchor constraintEqualToConstant:21.0],
    ]];

    [self refreshCellContentsWithSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    CCNMHideStandardCellContent(self);
    self.linkTitleLabel.text = specifier.name ?: [specifier propertyForKey:PSTitleKey];
    self.linkSubtitleLabel.text = [specifier propertyForKey:CCNMPreferenceSubtitleKey];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        self.linkTitleLabel.text ?: @"",
        self.linkSubtitleLabel.text ?: @""];
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return CCNMUsesAccessibilityText(self.traitCollection) ? 76.0 : 60.0;
}

@end
