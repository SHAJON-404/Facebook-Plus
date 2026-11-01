// Settings UI.
//
// A top-level menu of categories (each a row with a monochrome glyph, a title
// and a short summary) plus two info cards (app versions, developer / links).
// Tapping a category pushes a dedicated page holding just that category's
// switches. This mirrors the iOS Settings pattern — familiar, professional, and
// short per screen instead of one long mixed list.
//
// The whole panel uses a fixed dark palette (FBPPanelColor / FBPCardColor),
// pinned regardless of the host app's OLED / dark / light setting.

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

// The tweak's version is injected from the control file at build time
// (-DFBP_VERSION in the Makefile), so it is never hardcoded here.
#ifndef FBP_VERSION
#define FBP_VERSION @"—"
#endif

#pragma mark - Row / section model keys

static NSString *const kRowType    = @"type";
static NSString *const kRowKey     = @"key";     // pref key, action id, or link URL
static NSString *const kRowTitle   = @"title";
static NSString *const kRowDesc    = @"desc";
static NSString *const kRowIcon    = @"icon";
static NSString *const kRowValue   = @"value";   // trailing value text (info / action)
static NSString *const kRowLink    = @"link";    // tappable URL (info rows)
static NSString *const kRowDanger  = @"danger";
static NSString *const kRowCategory = @"category"; // detail sections for a menu row

static NSString *const kTypeSwitch   = @"switch";
static NSString *const kTypeAction   = @"action";
static NSString *const kTypeInfo     = @"info";
static NSString *const kTypeCategory = @"catnav";

static NSString *const kSecRows   = @"rows";
static NSString *const kSecFooter = @"footer";

static NSString *const kActionClearCache  = @"clearCache";
static NSString *const kActionAppIcon     = @"appIcon";
static NSString *const kActionWelcome     = @"welcome";
static NSString *const kActionReset       = @"reset";
static NSString *const kActionLanguage    = @"language";
static NSString *const kActionCheckUpdate = @"checkUpdate";

static NSString *const kCellIdentifier = @"fbp.settings.row";
static NSString *const kTelegramURL    = @"https://t.me/ReFacebookPlus";
static NSString *const kGitHubURL      = @"https://github.com/SHAJON-404/Facebook-Plus";

static const CGFloat kContentInset = 16.0;

#pragma mark - Icon loading

/// Monochrome bundled glyph by default; a few assets are solid brand / app logos
/// and are rendered in their own colours instead of flattened to white.
static UIImage *FBPSettingsIcon(NSString *name) {
    static NSSet *original;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ original = [NSSet setWithArray:@[@"facebook", @"logo", @"telegram"]]; });

    if ([original containsObject:name]) {
        UIImage *img = [UIImage imageNamed:name
                                  inBundle:NSBundle.fbp_resourceBundle
             compatibleWithTraitCollection:nil];
        return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    UIImage *img = [UIImage fbp_imageNamed:name];
    if (!img) img = [UIImage fbp_symbolNamed:name size:20 weight:UIImageSymbolWeightRegular];
    return img;
}

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
        self.backgroundColor = FBPCardColor();
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
        self.selectedBackgroundView = selected;

        // Invisible slot that keeps the glyph aligned and the label indent
        // consistent; the glyph is monochrome, with no coloured tile.
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
        _descLabel.font = FBPFont(12, UIFontWeightRegular);
        _descLabel.textColor = UIColor.secondaryLabelColor;
        _descLabel.numberOfLines = 0;

        _labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _descLabel]];
        _labelStack.axis = UILayoutConstraintAxisVertical;
        _labelStack.alignment = UIStackViewAlignmentLeading;
        _labelStack.spacing = 1.5;
        _labelStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_labelStack];

        _accessoryContainer = [[UIView alloc] init];
        _accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_accessoryContainer];

        [_labelStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                     forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer setContentHuggingPriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
        [_accessoryContainer setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                             forAxis:UILayoutConstraintAxisHorizontal];

        [NSLayoutConstraint activateConstraints:@[
            [_iconTile.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:kContentInset],
            [_iconTile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconTile.widthAnchor constraintEqualToConstant:29],
            [_iconTile.heightAnchor constraintEqualToConstant:29],

            [_iconView.centerXAnchor constraintEqualToAnchor:_iconTile.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:_iconTile.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:22],
            [_iconView.heightAnchor constraintEqualToConstant:22],

            [_labelStack.leadingAnchor constraintEqualToAnchor:_iconTile.trailingAnchor constant:12],
            [_labelStack.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_labelStack.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor
                                                               constant:9],
            [_labelStack.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryContainer.leadingAnchor
                                                                 constant:-10],

            [_accessoryContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                               constant:-kContentInset],
            [_accessoryContainer.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
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
    self.iconView.tintColor = FBPIconColor();
    self.selectionStyle = UITableViewCellSelectionStyleNone;
}

@end

#pragma mark - Base table controller

@interface FBPTableController : UITableViewController
@end

@implementation FBPTableController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Pin a fixed dark appearance so the host app's theme can never shift it.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = FBPPanelColor();
    self.view.tintColor = FBPTintColor();

    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorInset = UIEdgeInsetsZero;      // full-width hairlines
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:FBPSettingsCell.class forCellReuseIdentifier:kCellIdentifier];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = FBPPanelColor();
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : FBPFont(20, UIFontWeightSemibold),
    };
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
    self.navigationController.navigationBar.tintColor = FBPTintColor();
}

#pragma mark Spacing (tight, even gaps between cards)

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 4 : 12;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if ([self respondsToSelector:@selector(tableView:titleForFooterInSection:)]) {
        NSString *footer = [(id<UITableViewDataSource>)self tableView:tableView
                                             titleForFooterInSection:section];
        if (footer.length) return UITableViewAutomaticDimension;
    }
    return CGFLOAT_MIN;
}

#pragma mark Cell configuration (shared)

- (void)configureCell:(FBPSettingsCell *)cell withRow:(NSDictionary *)row {
    cell.titleLabel.text = row[kRowTitle];
    cell.titleLabel.textColor = [row[kRowDanger] boolValue] ? UIColor.systemRedColor
                                                            : UIColor.labelColor;
    NSString *desc = row[kRowDesc];
    cell.descLabel.text = desc;
    cell.descLabel.hidden = (desc.length == 0);

    UIImage *icon = FBPSettingsIcon(row[kRowIcon]);
    cell.iconView.image = icon;
    cell.iconView.tintColor = FBPIconColor();

    NSString *type = row[kRowType];

    if ([type isEqualToString:kTypeSwitch]) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.onTintColor = FBPTintColor();
        toggle.on = FBPEnabled(row[kRowKey]);
        objc_setAssociatedObject(toggle, @selector(tag), row[kRowKey],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self action:@selector(fbpToggleSwitch:)
         forControlEvents:UIControlEventValueChanged];
        [self setAccessory:toggle inCell:cell];

    } else if ([type isEqualToString:kTypeInfo]) {
        NSString *link = row[kRowLink];
        UILabel *value = [[UILabel alloc] init];
        value.text = row[kRowValue];
        value.font = FBPFont(15, link.length ? UIFontWeightMedium : UIFontWeightRegular);
        value.textColor = link.length ? FBPTintColor() : UIColor.labelColor;
        value.textAlignment = NSTextAlignmentRight;
        [self setAccessory:value inCell:cell];
        cell.selectionStyle = link.length ? UITableViewCellSelectionStyleDefault
                                          : UITableViewCellSelectionStyleNone;

    } else {   // action / category — value and/or chevron
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSMutableArray<UIView *> *pieces = [NSMutableArray array];
        NSString *value = row[kRowValue];
        if (value.length) {
            UILabel *valueLabel = [[UILabel alloc] init];
            valueLabel.font = FBPFont(15, UIFontWeightRegular);
            valueLabel.textColor = UIColor.secondaryLabelColor;
            valueLabel.text = value;
            [pieces addObject:valueLabel];
        }
        BOOL showChevron = [type isEqualToString:kTypeCategory] ||
                           row[kRowCategory] != nil ||
                           [row[kRowKey] isEqualToString:kActionAppIcon] ||
                           [row[kRowKey] isEqualToString:kActionLanguage] ||
                           [row[kRowKey] isEqualToString:kActionWelcome];
        if (showChevron) {
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
}

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

- (void)fbpToggleSwitch:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, @selector(tag));
    if (!key) return;
    [FBPPrefs.shared setBool:sender.isOn forKey:key];
    [FBPPrefs.shared commit];
}

@end

#pragma mark - Row builders (shared helpers)

static NSDictionary *FBPSwitchRow(NSString *key, NSString *title, NSString *desc, NSString *icon) {
    NSMutableDictionary *row = [@{ kRowType : kTypeSwitch, kRowKey : key,
                                   kRowTitle : title, kRowIcon : icon } mutableCopy];
    if (desc.length) row[kRowDesc] = desc;
    return row;
}
static NSDictionary *FBPActionRow(NSString *action, NSString *title, NSString *desc,
                                  NSString *icon, BOOL danger) {
    NSMutableDictionary *row = [@{ kRowType : kTypeAction, kRowKey : action,
                                   kRowTitle : title, kRowIcon : icon } mutableCopy];
    if (desc.length) row[kRowDesc] = desc;
    if (danger) row[kRowDanger] = @YES;
    return row;
}
static NSDictionary *FBPInfoRow(NSString *title, NSString *value, NSString *icon, NSString *link) {
    NSMutableDictionary *row = [@{ kRowType : kTypeInfo, kRowTitle : title,
                                   kRowValue : value, kRowIcon : icon } mutableCopy];
    if (link.length) row[kRowLink] = link;
    return row;
}
static NSDictionary *FBPSection(NSString *footer, NSArray *rows) {
    NSMutableDictionary *s = [@{ kSecRows : rows } mutableCopy];
    if (footer.length) s[kSecFooter] = footer;
    return s;
}

#pragma mark - Category definitions

/// The six categories; each has a title, summary, menu glyph, and the grouped
/// sections shown on its own page.
static NSArray<NSDictionary *> *FBPCategories(void) {
    return @[
        @{ kRowTitle : FBPL(@"cat.ads.title"), kRowDesc : FBPL(@"cat.ads.summary"),
           kRowIcon : @"ads", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyNoAds, FBPL(@"row.noads.title"), FBPL(@"row.noads.desc"), @"ads"),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyNoRecs, FBPL(@"row.norecs.title"), FBPL(@"row.norecs.desc"), @"magic"),
                FBPSwitchRow(FBPKeyNoReels, FBPL(@"row.noreels.title"), nil, @"reels"),
                FBPSwitchRow(FBPKeyNoStories, FBPL(@"row.nostories.title"), FBPL(@"row.nostories.desc"), @"incognito"),
                FBPSwitchRow(FBPKeyNoThreads, FBPL(@"row.nothreads.title"), FBPL(@"row.nothreads.desc"), @"at"),
            ]),
            FBPSection(FBPL(@"footer.feedClutter"), @[
                FBPSwitchRow(FBPKeyNoPYMK, FBPL(@"row.nopymk.title"), nil, @"people"),
                FBPSwitchRow(FBPKeyNoGroupSuggestions, FBPL(@"row.nogroups.title"), nil, @"group"),
                FBPSwitchRow(FBPKeyNoSuggestedPages, FBPL(@"row.nosuggestedpages.title"), nil, @"group"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.confirm.title"), kRowDesc : FBPL(@"cat.confirm.summary"),
           kRowIcon : @"alert", kRowCategory : @[
            FBPSection(FBPL(@"footer.confirm"), @[
                FBPSwitchRow(FBPKeyFeedLike, FBPL(@"row.feedlike.title"), FBPL(@"row.feedlike.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmComment, FBPL(@"row.confirmcomment.title"), FBPL(@"row.confirmcomment.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmShare, FBPL(@"row.confirmshare.title"), FBPL(@"row.confirmshare.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmPost, FBPL(@"row.confirmpost.title"), FBPL(@"row.confirmpost.desc"), @"alert"),
                FBPSwitchRow(FBPKeyConfirmFriend, FBPL(@"row.confirmfriend.title"), FBPL(@"row.confirmfriend.desc"), @"people"),
                FBPSwitchRow(FBPKeyConfirmFollow, FBPL(@"row.confirmfollow.title"), FBPL(@"row.confirmfollow.desc"), @"group"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.stories.title"), kRowDesc : FBPL(@"cat.stories.summary"),
           kRowIcon : @"incognito", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyAnonymousStories, FBPL(@"row.anonstories.title"), FBPL(@"row.anonstories.desc"), @"incognito"),
                FBPSwitchRow(FBPKeyNoAutoNext, FBPL(@"row.noautonext.title"), nil, @"reels"),
                FBPSwitchRow(FBPKeyNoStoryPYMK, FBPL(@"row.nostorypymk.title"), FBPL(@"row.nostorypymk.desc"), @"people"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.downloads.title"), kRowDesc : FBPL(@"cat.downloads.summary"),
           kRowIcon : @"download", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyReelsDownloaderEnabled, FBPL(@"row.downloadreels.title"), FBPL(@"row.downloadreels.desc"), @"download"),
                FBPSwitchRow(FBPKeyStoryDownloaderEnabled, FBPL(@"row.downloadstories.title"), FBPL(@"row.downloadstories.desc"), @"download"),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.appearance.title"), kRowDesc : FBPL(@"cat.appearance.summary"),
           kRowIcon : @"magic", kRowCategory : @[
            FBPSection(FBPL(@"row.oled.desc"), @[
                FBPSwitchRow(FBPKeyOLED, FBPL(@"row.oled.title"), nil, @"moon.fill"),
            ]),
            FBPSection(nil, @[
                FBPActionRow(kActionAppIcon, FBPL(@"row.appicon.title"), FBPL(@"row.appicon.desc"), @"app.badge.fill", NO),
            ]),
        ]},
        @{ kRowTitle : FBPL(@"cat.general.title"), kRowDesc : FBPL(@"cat.general.summary"),
           kRowIcon : @"setting", kRowCategory : @[
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyLinksInSafari, FBPL(@"row.linksinsafari.title"), FBPL(@"row.linksinsafari.desc"), @"safari.fill"),
                FBPActionRow(kActionLanguage, FBPL(@"row.language.title"), nil, @"globe", NO),
            ]),
            FBPSection(nil, @[
                FBPSwitchRow(FBPKeyAutoClearCache, FBPL(@"row.autoclear.title"), nil, @"arrow.triangle.2.circlepath"),
                FBPActionRow(kActionClearCache, FBPL(@"row.clearcache.title"), nil, @"trash.fill", NO),
                FBPActionRow(kActionCheckUpdate, FBPL(@"row.checkupdate.title"), FBPL(@"row.checkupdate.desc"), @"arrow.down.circle", NO),
            ]),
            FBPSection(nil, @[
                FBPActionRow(kActionWelcome, FBPL(@"row.welcome.title"), nil, @"hand.wave.fill", NO),
                FBPActionRow(kActionReset, FBPL(@"row.reset.title"), nil, @"arrow.counterclockwise", YES),
            ]),
        ]},
    ];
}

#pragma mark - Category detail page

@interface FBPSettingsDetailController : FBPTableController
- (instancetype)initWithCategory:(NSDictionary *)category;
@end

@implementation FBPSettingsDetailController {
    NSDictionary *_category;
    NSArray<NSDictionary *> *_sections;
}

- (instancetype)initWithCategory:(NSDictionary *)category {
    if ((self = [super init])) {
        _category = category;
        _sections = category[kRowCategory];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _category[kRowTitle];
}

- (NSArray<NSDictionary *> *)rowsInSection:(NSInteger)section {
    return _sections[section][kSecRows];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowsInSection:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _sections[section][kSecFooter];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier forIndexPath:indexPath];
    [self configureCell:cell withRow:[self rowsInSection:indexPath.section][indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self rowsInSection:indexPath.section][indexPath.row];
    if (![row[kRowType] isEqualToString:kTypeAction]) return;
    NSString *action = row[kRowKey];

    if ([action isEqualToString:kActionClearCache]) {
        [self clearCache];
    } else if ([action isEqualToString:kActionAppIcon]) {
        [self.navigationController pushViewController:[[FBPAppIconController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionLanguage]) {
        [self.navigationController pushViewController:[[FBPLanguageController alloc] init] animated:YES];
    } else if ([action isEqualToString:kActionCheckUpdate]) {
        [FBPUpdateChecker checkManuallyFromViewController:self];
    } else if ([action isEqualToString:kActionWelcome]) {
        [self dismissViewControllerAnimated:YES completion:^{ [FBPWelcomeController present]; }];
    } else if ([action isEqualToString:kActionReset]) {
        [self confirmReset];
    }
}

// Re-localize when returning from a pushed page (e.g. the language picker).
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *icon = _category[kRowIcon];
    for (NSDictionary *category in FBPCategories()) {
        if ([category[kRowIcon] isEqualToString:icon]) {
            _category = category;
            _sections = category[kRowCategory];
            break;
        }
    }
    self.title = _category[kRowTitle];
    [self.tableView reloadData];
}

#pragma mark Actions

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
    alert.view.tintColor = FBPTintColor();
    [self presentViewController:alert animated:YES completion:nil];
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
            [FBPToastManager.shared showMessage:FBPL(@"toast.cacheCleared") success:YES];
        });
    });
}

@end

#pragma mark - Top-level menu

@interface FBPSettingsMenuController : FBPTableController
@end

@implementation FBPSettingsMenuController {
    NSArray<NSDictionary *> *_categories;
    NSArray<NSArray<NSDictionary *> *> *_sections;  // menu sections of rows
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FBPL(@"nav.settings");
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(dismissSettings)];
    self.navigationItem.leftBarButtonItem.tintColor = FBPTintColor();
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
    [self.tableView reloadData];
}

- (void)rebuild {
    _categories = FBPCategories();

    NSMutableArray *categoryRows = [NSMutableArray array];
    for (NSDictionary *category in _categories) {
        [categoryRows addObject:@{
            kRowType : kTypeCategory,
            kRowTitle : category[kRowTitle],
            kRowDesc : category[kRowDesc],
            kRowIcon : category[kRowIcon],
            kRowCategory : category[kRowCategory],
        }];
    }

    // Both versions are auto-detected, never hardcoded: Facebook's from the host
    // app's Info.plist (its full FBAppVersion, falling back to the short version),
    // ours from the control file (via the FBP_VERSION macro).
    NSString *fbVersion =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"FBAppVersion"]
        ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
        ?: @"—";
    NSString *plusVersion = FBP_VERSION;

    _sections = @[
        categoryRows,
        @[
            FBPInfoRow(FBPL(@"info.fbVersion"), fbVersion, @"facebook", nil),
            FBPInfoRow(FBPL(@"info.fbPlusVersion"), plusVersion, @"logo", nil),
        ],
        @[
            FBPInfoRow(FBPL(@"info.developer"), @"S. SHAJON", @"people", nil),
            FBPInfoRow(FBPL(@"info.github"), @"SHAJON-404", @"github", kGitHubURL),
            FBPInfoRow(FBPL(@"info.telegram"), @"@ReFacebookPlus", @"telegram", kTelegramURL),
        ],
    ];
}

- (void)dismissSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return (NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_sections[section].count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier forIndexPath:indexPath];
    [self configureCell:cell withRow:_sections[indexPath.section][indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _sections[indexPath.section][indexPath.row];

    if ([row[kRowType] isEqualToString:kTypeCategory]) {
        [self.navigationController pushViewController:
            [[FBPSettingsDetailController alloc] initWithCategory:row] animated:YES];
        return;
    }
    NSString *link = row[kRowLink];
    if (link.length) {
        NSURL *url = [NSURL URLWithString:link];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

@end

#pragma mark - Public entry

@implementation FBPSettingsController

+ (void)presentFromViewController:(UIViewController *)viewController {
    UIViewController *host = viewController ?: [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) return;

    FBPSettingsMenuController *menu = [[FBPSettingsMenuController alloc] init];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:menu];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // Paint the container black up front so the panel slides in already-dark —
    // otherwise the cards appear a frame before the background fills in.
    navigation.view.backgroundColor = FBPPanelColor();
    [host presentViewController:navigation animated:YES completion:nil];
}

@end
