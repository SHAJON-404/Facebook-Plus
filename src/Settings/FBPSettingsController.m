// Main settings screen. A branded header card (topbar) scrolls above grouped
// sections of icon rows — one card per category. Each row pairs a monochrome
// glyph with a title, an optional subtitle, and a trailing control (switch, value
// or chevron), vertically centred against the icon.
//
// The whole panel uses a fixed dark palette — pure-black background, dark-grey
// cards — pinned regardless of the host app's OLED / dark / light setting, so the
// screen always reads the same way. See FBPPanelColor / FBPCardColor below.

#import "FBPSettingsController.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"
#import "FBPAppIconController.h"
#import "FBPLanguageController.h"
#import "FBPWelcomeController.h"
#import "FBPUpdateChecker.h"

#import <objc/runtime.h>

// Row model keys.
static NSString *const kRowKey     = @"key";
static NSString *const kRowType    = @"type";
static NSString *const kRowTitle   = @"title";
static NSString *const kRowDesc    = @"desc";
static NSString *const kRowIcon    = @"icon";     // bundled glyph name, else SF Symbol
static NSString *const kRowColor   = @"color";    // icon tile colour
static NSString *const kRowNav     = @"nav";      // @YES -> disclosure chevron
static NSString *const kRowDanger  = @"danger";   // @YES -> destructive (red) title

static NSString *const kTypeSwitch = @"bool";
static NSString *const kTypeAction = @"action";

static NSString *const kActionClearCache  = @"clearCache";
static NSString *const kActionAppIcon     = @"appIcon";
static NSString *const kActionWelcome     = @"welcome";
static NSString *const kActionReset       = @"reset";
static NSString *const kActionLanguage    = @"language";
static NSString *const kActionCheckUpdate  = @"checkUpdate";

static NSString *const kCellIdentifier   = @"fbp.settings.row";

static NSString *const kTelegramURL = @"https://t.me/ReFacebookPlus";

static const CGFloat kCardInset    = 16.0;
static const CGFloat kContentInset = 16.0;
static const CGFloat kIconTile     = 29.0;   // icon slot width (keeps label alignment)
static const CGFloat kIconGlyph    = 22.0;   // monochrome glyph size within the slot

// The fixed dark palette (FBPPanelColor / FBPCardColor / FBPIconColor) lives in
// FBPResources so every tweak screen shares one source of truth.

#pragma mark - Card view

/// An FBP-prefixed plain view. The class prefix is load-bearing: the OLED sweep
/// blackens any dark -backgroundColor it sees except on FBP* views, so the branded
/// header card must be an FBP* view or it turns invisible in OLED mode.
@interface FBPCardView : UIView
@end
@implementation FBPCardView
@end

#pragma mark - Cell

@interface FBPSettingsCell : UITableViewCell
@property (nonatomic, strong) UIView *iconTile;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIStackView *labelStack;
@property (nonatomic, strong) UIView *accessoryContainer;
@end

@implementation FBPSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        // Painted card background (fixed dark grey) so the grouped cards read
        // clearly on the black panel.
        self.backgroundColor = FBPCardColor();

        // Invisible slot that keeps the glyph aligned and the label indent
        // consistent; it no longer carries a coloured tile.
        _iconTile = [[UIView alloc] init];
        _iconTile.backgroundColor = UIColor.clearColor;
        _iconTile.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconTile];

        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = FBPIconColor();
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [_iconTile addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = FBPFont(16, UIFontWeightRegular);
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.numberOfLines = 0;

        _descLabel = [[UILabel alloc] init];
        _descLabel.font = FBPFont(12.5, UIFontWeightRegular);
        _descLabel.textColor = UIColor.secondaryLabelColor;
        _descLabel.numberOfLines = 0;

        _labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _descLabel]];
        _labelStack.axis = UILayoutConstraintAxisVertical;
        _labelStack.alignment = UIStackViewAlignmentLeading;
        _labelStack.spacing = 2.0;
        _labelStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_labelStack];

        _accessoryContainer = [[UIView alloc] init];
        _accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_accessoryContainer];

        [_labelStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                     forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer setContentHuggingPriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer
            setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisHorizontal];

        NSLayoutConstraint *top =
            [_labelStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor
                                                               constant:10];
        NSLayoutConstraint *bot =
            [_labelStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor
                                                               constant:-10];

        [NSLayoutConstraint activateConstraints:@[
            [_iconTile.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:kContentInset],
            [_iconTile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconTile.widthAnchor constraintEqualToConstant:kIconTile],
            [_iconTile.heightAnchor constraintEqualToConstant:kIconTile],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:kIconGlyph],
            [_iconView.heightAnchor constraintEqualToConstant:kIconGlyph],

            [_labelStack.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:12],
            [_labelStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_labelStack.trailingAnchor constraintEqualToAnchor:_accessoryContainer.leadingAnchor
                                                       constant:-12],
            top, bot,

            [_accessoryContainer.trailingAnchor
                constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kContentInset],
            [_accessoryContainer.centerYAnchor
                constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:52],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    for (UIView *subview in self.accessoryContainer.subviews) [subview removeFromSuperview];
    self.titleLabel.text = nil;
    self.titleLabel.textColor = UIColor.labelColor;
    self.descLabel.text = nil;
    self.descLabel.hidden = YES;
    self.iconView.image = nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
}

@end

#pragma mark - Controller

@interface FBPSettingsController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation FBPSettingsController

+ (void)presentFromViewController:(UIViewController *)viewController {
    UIViewController *host = viewController ?: [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) return;

    FBPSettingsController *settings = [[FBPSettingsController alloc] init];
    settings.modalPresentationStyle = UIModalPresentationFullScreen;

    [host presentViewController:settings animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.sections = [self buildSections];

    // Pin the panel to a fixed dark appearance. Forcing the dark interface style
    // makes every dynamic system colour still in use (labels, separators,
    // destructive red) resolve to its dark variant permanently, so the host app's
    // OLED / dark / light state can never shift the look.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPPanelColor();
    self.view.tintColor = FBPTintColor();

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                              style:UITableViewStyleInsetGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.separatorInset = UIEdgeInsetsMake(0, kContentInset + kIconTile + 12, 0, 0);
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 56.0;
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [_tableView registerClass:FBPSettingsCell.class forCellReuseIdentifier:kCellIdentifier];
    _tableView.tableHeaderView = [self buildHeaderCard];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - Header card (its own card, scrolls with content)

- (UIView *)buildHeaderCard {
    UIView *container = [[UIView alloc]
        initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 98)];

    FBPCardView *card = [[FBPCardView alloc] init];
    card.backgroundColor = FBPCardColor();
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:card];

    UIImageView *logo = [[UIImageView alloc] initWithImage:
        [[UIImage imageNamed:@"logo"
                    inBundle:NSBundle.fbp_resourceBundle
compatibleWithTraitCollection:nil]
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.layer.cornerRadius = 9;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.clipsToBounds = YES;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:38].active = YES;
    [logo.heightAnchor constraintEqualToConstant:38].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Facebook Plus";
    title.font = FBPFont(22, UIFontWeightBold);
    title.textColor = UIColor.labelColor;

    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[logo, title]];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = 10;
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleRow];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = FBPL(@"settings.subtitle");
    subtitle.font = FBPFont(12.5, UIFontWeightRegular);
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitle];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage fbp_symbolNamed:@"xmark.circle.fill" size:26
                                     weight:UIImageSymbolWeightRegular]
           forState:UIControlStateNormal];
    close.tintColor = UIColor.tertiaryLabelColor;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(closeButtonTapped)
    forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
        [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kCardInset],
        [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-kCardInset],

        [titleRow.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [titleRow.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleRow.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8],

        [subtitle.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:2],

        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        // Span the whole title+subtitle block so the (centred) glyph sits at its
        // vertical middle, not level with the title alone.
        [close.topAnchor constraintEqualToAnchor:titleRow.topAnchor],
        [close.bottomAnchor constraintEqualToAnchor:subtitle.bottomAnchor],
    ]];
    return container;
}

- (void)closeButtonTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Model

- (NSArray<NSDictionary *> *)buildSections {
    return @[
        @{ @"header" : @"Feed", @"rows" : @[
            [self switchRow:FBPKeyNoAds title:FBPL(@"row.noads.title") desc:nil
                       icon:@"ads" color:UIColor.systemRedColor],
            [self switchRow:FBPKeyNoRecs title:FBPL(@"row.norecs.title")
                       desc:FBPL(@"row.norecs.desc")
                       icon:@"magic" color:UIColor.systemPurpleColor],
            [self switchRow:FBPKeyNoPYMK title:FBPL(@"row.nopymk.title") desc:nil
                       icon:@"people" color:UIColor.systemBlueColor],
            [self switchRow:FBPKeyNoReels title:FBPL(@"row.noreels.title") desc:nil
                       icon:@"reels" color:UIColor.systemPinkColor],
            [self switchRow:FBPKeyNoStories title:FBPL(@"row.nostories.title")
                       desc:FBPL(@"row.nostories.desc")
                       icon:@"circle.dashed" color:UIColor.systemPurpleColor],
            [self switchRow:FBPKeyNoThreads title:FBPL(@"row.nothreads.title")
                       desc:FBPL(@"row.nothreads.desc")
                       icon:@"at" color:UIColor.systemIndigoColor],
            [self switchRow:FBPKeyNoGroupSuggestions title:FBPL(@"row.nogroups.title")
                       desc:FBPL(@"row.nogroups.desc")
                       icon:@"group" color:UIColor.systemTealColor],
            [self switchRow:FBPKeyNoSuggestedPages title:FBPL(@"row.nosuggestedpages.title")
                       desc:FBPL(@"row.nosuggestedpages.desc")
                       icon:@"group" color:UIColor.systemOrangeColor],
            [self switchRow:FBPKeyFeedLike title:FBPL(@"row.feedlike.title")
                       desc:FBPL(@"row.feedlike.desc")
                       icon:@"alert" color:UIColor.systemGreenColor],
        ]},
        @{ @"header" : @"Downloads", @"rows" : @[
            [self switchRow:FBPKeyReelsDownloaderEnabled title:FBPL(@"row.downloadreels.title")
                       desc:FBPL(@"row.downloadreels.desc")
                       icon:@"download" color:UIColor.systemBlueColor],
            [self switchRow:FBPKeyStoryDownloaderEnabled title:FBPL(@"row.downloadstories.title")
                       desc:FBPL(@"row.downloadstories.desc")
                       icon:@"download" color:UIColor.systemPurpleColor],
        ]},
        @{ @"header" : @"Reels", @"rows" : @[
            [self switchRow:FBPKeyReelsLike title:FBPL(@"row.reelslike.title") desc:nil
                       icon:@"alert" color:UIColor.systemGreenColor],
            [self switchRow:FBPKeyReelsHideOverlay title:FBPL(@"row.hideoverlay.title")
                       desc:FBPL(@"row.hideoverlay.desc")
                       icon:@"eye" color:UIColor.systemIndigoColor],
        ]},
        @{ @"header" : @"Stories", @"rows" : @[
            [self switchRow:FBPKeyAnonymousStories title:FBPL(@"row.anonstories.title")
                       desc:FBPL(@"row.anonstories.desc")
                       icon:@"incognito" color:UIColor.systemPurpleColor],
            [self switchRow:FBPKeyNoAutoNext title:FBPL(@"row.noautonext.title") desc:nil
                       icon:@"forward.end.alt.fill" color:UIColor.systemOrangeColor],
            [self switchRow:FBPKeyNoStoryPYMK title:FBPL(@"row.nostorypymk.title")
                       desc:FBPL(@"row.nostorypymk.desc")
                       icon:@"people" color:UIColor.systemBlueColor],
        ]},
        @{ @"header" : @"Appearance", @"rows" : @[
            [self switchRow:FBPKeyOLED title:FBPL(@"row.oled.title")
                       desc:FBPL(@"row.oled.desc")
                       icon:@"moon.fill" color:UIColor.systemIndigoColor],
            @{ kRowKey : kActionAppIcon, kRowType : kTypeAction, kRowNav : @YES,
               kRowTitle : FBPL(@"row.appicon.title"), kRowDesc : FBPL(@"row.appicon.desc"),
               kRowIcon : @"app.badge.fill", kRowColor : UIColor.systemBlueColor },
        ]},
        @{ @"header" : @"General", @"rows" : @[
            [self switchRow:FBPKeyLinksInSafari title:FBPL(@"row.linksinsafari.title")
                       desc:FBPL(@"row.linksinsafari.desc")
                       icon:@"safari.fill" color:UIColor.systemBlueColor],
            @{ kRowKey : kActionLanguage, kRowType : kTypeAction, kRowNav : @YES,
               kRowTitle : FBPL(@"row.language.title"),
               kRowIcon : @"globe", kRowColor : UIColor.systemBlueColor },
            [self switchRow:FBPKeyAutoClearCache title:FBPL(@"row.autoclear.title") desc:nil
                       icon:@"arrow.triangle.2.circlepath" color:UIColor.systemTealColor],
            @{ kRowKey : kActionClearCache, kRowType : kTypeAction,
               kRowTitle : FBPL(@"row.clearcache.title"),
               kRowIcon : @"trash.fill", kRowColor : UIColor.systemRedColor },
            @{ kRowKey : kActionCheckUpdate, kRowType : kTypeAction,
               kRowTitle : FBPL(@"row.checkupdate.title"), kRowDesc : FBPL(@"row.checkupdate.desc"),
               kRowIcon : @"arrow.down.circle", kRowColor : UIColor.systemBlueColor },
            @{ kRowKey : kActionWelcome, kRowType : kTypeAction, kRowNav : @YES,
               kRowTitle : FBPL(@"row.welcome.title"),
               kRowIcon : @"hand.wave.fill", kRowColor : FBPTintColor() },
            @{ kRowKey : kActionReset, kRowType : kTypeAction, kRowDanger : @YES,
               kRowTitle : FBPL(@"row.reset.title"),
               kRowIcon : @"arrow.counterclockwise", kRowColor : UIColor.systemRedColor },
        ]},
    ];
}

- (NSDictionary *)switchRow:(NSString *)key title:(NSString *)title desc:(NSString *)desc
                       icon:(NSString *)icon color:(UIColor *)color {
    NSMutableDictionary *row = [@{
        kRowKey : key, kRowType : kTypeSwitch, kRowTitle : title,
        kRowIcon : icon, kRowColor : color,
    } mutableCopy];
    if (desc) row[kRowDesc] = desc;
    return row;
}

- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)section {
    return self.sections[section][@"rows"];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowsInSection:section].count;
}

// No section labels — an empty spacer sets the gap between cards. The sections'
// "header" strings in the model stay as in-code documentation of the grouping.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 18.0;
}

// Centred credit footer under the last section, with a tappable @SHAJON handle
// that opens Telegram.
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)self.sections.count - 1) return nil;

    UIView *footer = [[UIView alloc] init];

    UILabel *prefix = [[UILabel alloc] init];
    prefix.text = FBPL(@"footer.by");
    prefix.font = FBPFont(13, UIFontWeightRegular);
    prefix.textColor = UIColor.secondaryLabelColor;

    UIButton *handle = [UIButton buttonWithType:UIButtonTypeSystem];
    [handle setTitle:@"@SHAJON" forState:UIControlStateNormal];
    handle.titleLabel.font = FBPFont(13, UIFontWeightSemibold);
    [handle setTitleColor:FBPTintColor() forState:UIControlStateNormal];
    [handle addTarget:self action:@selector(openDeveloperTelegram)
    forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[prefix, handle]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:footer.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-14],
    ]];
    return footer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return (section == (NSInteger)self.sections.count - 1) ? 46.0 : CGFLOAT_MIN;
}

- (void)openDeveloperTelegram {
    NSURL *url = [NSURL URLWithString:kTelegramURL];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self rowsInSection:indexPath.section][indexPath.row];
    FBPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier
                                                            forIndexPath:indexPath];
    cell.titleLabel.text = row[kRowTitle];
    cell.titleLabel.textColor = [row[kRowDanger] boolValue] ? UIColor.systemRedColor
                                                            : UIColor.labelColor;
    NSString *desc = row[kRowDesc];
    cell.descLabel.text = desc;
    cell.descLabel.hidden = (desc == nil);

    // Direct monochrome glyph — no coloured tile. Prefer the bundled PNG; fall
    // back to a thin SF Symbol so the whole set reads as one line-icon family.
    UIImage *icon = [UIImage fbp_imageNamed:row[kRowIcon]];
    if (!icon) icon = [UIImage fbp_symbolNamed:row[kRowIcon] size:19
                                        weight:UIImageSymbolWeightRegular];
    cell.iconView.image = icon;

    if ([row[kRowType] isEqualToString:kTypeSwitch]) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = FBPTintColor();
        toggle.on = FBPEnabled(row[kRowKey]);
        objc_setAssociatedObject(toggle, @selector(tag), row[kRowKey],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(toggleSwitch:)
         forControlEvents:UIControlEventValueChanged];
        [self setAccessory:toggle inCell:cell];

    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;

        NSMutableArray<UIView *> *pieces = [NSMutableArray array];
        if ([row[kRowKey] isEqualToString:kActionClearCache]) {
            UILabel *value = [[UILabel alloc] init];
            value.font = FBPFont(15, UIFontWeightRegular);
            value.textColor = UIColor.secondaryLabelColor;
            [self cacheSizeWithCompletion:^(NSString *size) { value.text = size; }];
            [pieces addObject:value];
        }
        if ([row[kRowNav] boolValue]) {
            UIImageView *chevron = [[UIImageView alloc] initWithImage:
                [UIImage fbp_symbolNamed:@"chevron.right" size:13 weight:UIImageSymbolWeightSemibold]];
            chevron.tintColor = UIColor.tertiaryLabelColor;
            [pieces addObject:chevron];
        }
        if (pieces.count) {
            UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:pieces];
            stack.axis = UILayoutConstraintAxisHorizontal;
            stack.alignment = UIStackViewAlignmentCenter;
            stack.spacing = 7;
            [self setAccessory:stack inCell:cell];
        }
    }
    return cell;
}

/// Pins the accessory to the trailing/centre of its container at its natural
/// size — so a switch, a value or a chevron is never stretched.
- (void)setAccessory:(UIView *)view inCell:(FBPSettingsCell *)cell {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.accessoryContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:cell.accessoryContainer.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:cell.accessoryContainer.trailingAnchor],
        [view.centerYAnchor constraintEqualToAnchor:cell.accessoryContainer.centerYAnchor],
        [view.topAnchor constraintGreaterThanOrEqualToAnchor:cell.accessoryContainer.topAnchor],
    ]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *row = [self rowsInSection:indexPath.section][indexPath.row];
    if (![row[kRowType] isEqualToString:kTypeAction]) return;
    NSString *key = row[kRowKey];

    if ([key isEqualToString:kActionClearCache]) {
        [self clearCache];
    } else if ([key isEqualToString:kActionAppIcon]) {
        [self presentInNavigation:[[FBPAppIconController alloc] init]];
    } else if ([key isEqualToString:kActionWelcome]) {
        [self dismissViewControllerAnimated:YES completion:^{ [FBPWelcomeController present]; }];
    } else if ([key isEqualToString:kActionReset]) {
        [self confirmReset];
    } else if ([key isEqualToString:kActionLanguage]) {
        [self presentInNavigation:[[FBPLanguageController alloc] init]];
    } else if ([key isEqualToString:kActionCheckUpdate]) {
        [FBPUpdateChecker checkManuallyFromViewController:self];
    }
}

// Re-localize when returning from a pushed page (e.g. the language picker), so a
// language change made there is reflected here immediately.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.sections = [self buildSections];
    self.tableView.tableHeaderView = [self buildHeaderCard];
    [self.tableView reloadData];
}

- (void)presentInNavigation:(UIViewController *)controller {
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:navigation animated:YES completion:nil];
}

#pragma mark - Actions

- (void)toggleSwitch:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, @selector(tag));
    if (!key) return;
    [FBPPrefs.shared setBool:sender.isOn forKey:key];
    [FBPPrefs.shared commit];
}

- (void)confirmReset {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:FBPL(@"reset.title")
                                            message:FBPL(@"reset.message")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"reset.confirm")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [FBPPrefs.shared resetToDefaults];
        [self.tableView reloadData];
        [FBPToastManager.shared showMessage:FBPL(@"toast.settingsReset") success:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Cache

- (void)cacheSizeWithCompletion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cachePath = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        unsigned long long total = 0;
        NSArray<NSString *> *subpaths =
            [NSFileManager.defaultManager subpathsOfDirectoryAtPath:cachePath error:NULL];
        for (NSString *subpath in subpaths) {
            NSString *full = [cachePath stringByAppendingPathComponent:subpath];
            NSDictionary *attributes =
                [NSFileManager.defaultManager attributesOfItemAtPath:full error:NULL];
            total += attributes.fileSize;
        }
        NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
        formatter.countStyle = NSByteCountFormatterCountStyleFile;
        NSString *text = [formatter stringFromByteCount:(long long)total];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text); });
    });
}

- (void)clearCache {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cachePath = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSArray<NSString *> *contents =
            [NSFileManager.defaultManager contentsOfDirectoryAtPath:cachePath error:NULL];
        for (NSString *item in contents) {
            [NSFileManager.defaultManager
                removeItemAtPath:[cachePath stringByAppendingPathComponent:item] error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            [FBPToastManager.shared showMessage:FBPL(@"toast.cacheCleared") success:YES];
        });
    });
}

@end
