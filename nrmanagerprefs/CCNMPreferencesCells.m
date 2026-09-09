#import "CCNMPreferencesCells.h"
#import <objc/message.h>

NSString * const CCNMPreferenceSubtitleKey = @"subtitle";
NSString * const CCNMPreferenceValueKey = @"value";
NSString * const CCNMPreferenceURLKey = @"url";
NSString * const CCNMPreferenceCheckedKey = @"checked";

static NSString * const CCNMPreferencesStringsTable = @"NRManagerPrefs";

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

static UIColor *CCNMDisabledTextColor(void) {
    return CCNMColorFromClassSelector(@selector(tertiaryLabelColor), UIColor.lightGrayColor);
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
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    _productIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _productIconView.translatesAutoresizingMaskIntoConstraints = NO;
    _productIconView.contentMode = UIViewContentModeScaleAspectFit;
    _productIconView.layer.cornerRadius = 18.0;
    _productIconView.clipsToBounds = YES;
    _productIconView.image = [UIImage imageNamed:@"icon"
                                       inBundle:[NSBundle bundleForClass:self.class]
                  compatibleWithTraitCollection:self.traitCollection];

    _productTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _productTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _productTitleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold]];
    _productTitleLabel.adjustsFontForContentSizeCategory = YES;
    _productTitleLabel.adjustsFontForContentSizeCategory = YES;
    _productTitleLabel.textColor = CCNMPrimaryTextColor();
    _productTitleLabel.textAlignment = NSTextAlignmentCenter;
    _productTitleLabel.numberOfLines = 1;

    _productSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _productSubtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _productSubtitleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]];
    _productSubtitleLabel.adjustsFontForContentSizeCategory = YES;
    _productSubtitleLabel.textColor = CCNMSecondaryTextColor();
    _productSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    _productSubtitleLabel.numberOfLines = 2;

    [self.contentView addSubview:_productIconView];
    [self.contentView addSubview:_productTitleLabel];
    [self.contentView addSubview:_productSubtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_productIconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_productIconView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16.0],
        [_productIconView.widthAnchor constraintEqualToConstant:56.0],
        [_productIconView.heightAnchor constraintEqualToConstant:56.0],
        [_productTitleLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_productTitleLabel.topAnchor constraintEqualToAnchor:_productIconView.bottomAnchor constant:10.0],
        [_productTitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:20.0],
        [_productTitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-20.0],
        [_productSubtitleLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [_productSubtitleLabel.topAnchor constraintEqualToAnchor:_productTitleLabel.bottomAnchor constant:4.0],
        [_productSubtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:24.0],
        [_productSubtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-24.0],
        [_productSubtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16.0]
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
    return 148.0;
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

@interface CCNMBandSelectionCell ()

@property (nonatomic, strong) UILabel *bandTitleLabel;
@property (nonatomic, strong) UILabel *bandDetailLabel;
@property (nonatomic, strong) UIImageView *checkmarkView;

@end

@implementation CCNMBandSelectionCell

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

    _bandTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bandTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bandTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _bandTitleLabel.adjustsFontForContentSizeCategory = YES;
    _bandTitleLabel.numberOfLines = 1;

    _bandDetailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bandDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _bandDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _bandDetailLabel.adjustsFontForContentSizeCategory = YES;
    _bandDetailLabel.numberOfLines = 2;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _bandTitleLabel,
        _bandDetailLabel,
    ]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentFill;
    textStack.spacing = 1.0;

    // A glyph rather than UITableViewCellAccessoryCheckmark, because the accessory
    // type is one of the attributes Preferences resets when it hands a recycled
    // cell back, and a checkmark that survives onto the wrong row is a false claim
    // about what will be written to the modem.
    _checkmarkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _checkmarkView.translatesAutoresizingMaskIntoConstraints = NO;
    _checkmarkView.contentMode = UIViewContentModeScaleAspectFit;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
        _checkmarkView.image = [UIImage performSelector:@selector(systemImageNamed:)
                                            withObject:@"checkmark"];
    }

    [self.contentView addSubview:textStack];
    [self.contentView addSubview:_checkmarkView];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [textStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_checkmarkView.leadingAnchor constant:-12.0],
        [textStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [textStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:6.0],
        [textStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-6.0],
        [_checkmarkView.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_checkmarkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_checkmarkView.widthAnchor constraintEqualToConstant:18.0],
        [_checkmarkView.heightAnchor constraintEqualToConstant:18.0],
    ]];

    [self refreshCellContentsWithSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    CCNMHideStandardCellContent(self);

    // Every visual attribute is assigned on every refresh, including its negative
    // case, because this cell is recycled across rows whose checked and enabled
    // states differ.
    BOOL checked = [[specifier propertyForKey:CCNMPreferenceCheckedKey] boolValue];
    id enabledProperty = [specifier propertyForKey:PSEnabledKey];
    BOOL enabled = enabledProperty == nil || [enabledProperty boolValue];
    NSString *detail = [specifier propertyForKey:CCNMPreferenceSubtitleKey];
    detail = [detail isKindOfClass:NSString.class] ? detail : @"";

    self.bandTitleLabel.text = specifier.name ?: [specifier propertyForKey:PSTitleKey];
    self.bandTitleLabel.textColor = enabled ? CCNMPrimaryTextColor() : CCNMDisabledTextColor();
    self.bandDetailLabel.textColor = enabled ? CCNMSecondaryTextColor() : CCNMDisabledTextColor();
    self.checkmarkView.tintColor = enabled ? CCNMLinkColor() : CCNMDisabledTextColor();
    self.checkmarkView.hidden = !checked;
    self.selectionStyle = enabled
        ? UITableViewCellSelectionStyleDefault
        : UITableViewCellSelectionStyleNone;

    // Without SF Symbols the glyph view is empty, so a checked row would look
    // identical to an unchecked one. Say it in text instead of silently losing it.
    if (checked && self.checkmarkView.image == nil) {
        self.checkmarkView.hidden = YES;
        NSString *mark = CCNMPreferencesLocalizedString(@"Selected");
        detail = detail.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", mark, detail]
            : mark;
    }
    self.bandDetailLabel.text = detail;

    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",
        self.bandTitleLabel.text ?: @"", detail];
    UIAccessibilityTraits traits = UIAccessibilityTraitButton;
    if (checked) {
        traits |= UIAccessibilityTraitSelected;
    }
    if (!enabled) {
        traits |= UIAccessibilityTraitNotEnabled;
    }
    self.accessibilityTraits = traits;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return CCNMUsesAccessibilityText(self.traitCollection) ? 76.0 : 60.0;
}

@end
