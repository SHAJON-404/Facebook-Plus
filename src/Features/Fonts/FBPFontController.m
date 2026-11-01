// Font picker: a text-size slider, then the original font plus each custom font
// bundled with the tweak, previewed in its own typeface at the chosen size.
// Mirrors the app-icon picker's look and flow.

#import "FBPFontController.h"
#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPToast.h"

// Font registry, implemented in FBPFontHooks.
extern NSArray<NSString *> *FBPRegisteredFontFamilies(void);  // available families
extern NSArray<NSString *> *FBPUserFontFamilies(void);        // the deletable (imported) subset
extern NSString *FBPUserFontsDirectoryPath(void);             // writable import folder
extern void FBPReloadFonts(void);                             // re-scan after an import
extern void FBPDeleteUserFont(NSString *family);              // remove an imported family

static NSString *const kFontCell = @"fbp.font.row";
static NSString *const kSizeCell = @"fbp.font.size";

// The slider's range for the custom-font size multiplier (100 %–300 %).
static const float kScaleMin = 1.0f;
static const float kScaleMax = 3.0f;

// A short sample shown under each font name, in that same font.
static NSString *FBPFontSampleText(void) { return @"Facebook Plus — AaBbGg 0123"; }

#pragma mark - Font row cell

/// FBP-prefixed so the OLED sweep leaves its card colour alone. Subtitle style:
/// the font's name on top, a sample line beneath, both drawn in that font.
@interface FBPFontCell : UITableViewCell
@end
@implementation FBPFontCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleSubtitle
                     reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = FBPCardColor();
        self.textLabel.textColor = UIColor.labelColor;
        self.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}
@end

#pragma mark - Size slider cell

/// A card row carrying an "A" / slider / "A" group with a live percentage. The
/// controller owns the value handling; the cell just lays the controls out.
@interface FBPFontSizeCell : UITableViewCell
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
@end
@implementation FBPFontSizeCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                     reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = FBPCardColor();
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *small = [[UILabel alloc] init];
        small.text = @"A";
        small.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        small.textColor = UIColor.secondaryLabelColor;

        UILabel *big = [[UILabel alloc] init];
        big.text = @"A";
        big.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
        big.textColor = UIColor.labelColor;

        _slider = [[UISlider alloc] init];
        _slider.minimumValue = kScaleMin;
        _slider.maximumValue = kScaleMax;
        _slider.minimumTrackTintColor = FBPTintColor();

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired
                                       forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ small, _slider, big, _valueLabel ]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 12;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:row];

        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
            [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
            [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [_valueLabel.widthAnchor constraintGreaterThanOrEqualToConstant:46],
        ]];
    }
    return self;
}
@end

#pragma mark - Controller

@interface FBPFontController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NSString *> *families;
@property (nonatomic, copy, nullable) NSString *selected;   // nil = original
@property (nonatomic, assign) CGFloat scale;                 // custom-font size multiplier
@end

@implementation FBPFontController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _families = FBPRegisteredFontFamilies();
        NSString *saved = [FBPPrefs.shared stringForKey:FBPKeyFont];
        _selected = saved.length ? saved : nil;
        NSString *rawScale = [FBPPrefs.shared stringForKey:FBPKeyFontScale];
        _scale = rawScale.length ? rawScale.doubleValue : 1.0;
        if (_scale < kScaleMin) _scale = kScaleMin;
        if (_scale > kScaleMax) _scale = kScaleMax;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FBPL(@"row.fonts.title");

    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.tintColor = FBPTintColor();
    self.tableView.backgroundColor = FBPPanelColor();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;

    [self.tableView registerClass:FBPFontCell.class forCellReuseIdentifier:kFontCell];
    [self.tableView registerClass:FBPFontSizeCell.class forCellReuseIdentifier:kSizeCell];

    // Import a font from the Files app (local storage, iCloud Drive, …).
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addFontTapped)];
    [self applyNavigationChrome];
}

#pragma mark - Import

- (void)addFontTapped {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[ @"public.font", @"public.truetype-ttf-font",
                                 @"public.opentype-font", @"com.apple.truetype-datafork-suitcase-font" ]
                       inMode:UIDocumentPickerModeImport];   // hands us a readable local copy
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *dest = FBPUserFontsDirectoryPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSInteger imported = 0;

    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *target = [dest stringByAppendingPathComponent:url.lastPathComponent];
        [fm removeItemAtPath:target error:NULL];   // replace an earlier copy of the same name
        NSError *error = nil;
        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&error]) {
            imported += 1;
        }
        if (scoped) [url stopAccessingSecurityScopedResource];
    }

    if (imported == 0) {
        [FBPToastManager.shared showMessage:FBPL(@"fonts.importFailed") success:NO];
        return;
    }

    FBPReloadFonts();
    self.families = FBPRegisteredFontFamilies();
    [self.tableView reloadData];
    [FBPToastManager.shared showMessage:FBPL(@"fonts.added") success:YES];
}

/// Matches the app-icon picker: a black opaque bar with a white rounded title.
- (void)applyNavigationChrome {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;
    self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.tintColor = FBPTintColor();
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = FBPPanelColor();
        appearance.shadowColor = UIColor.clearColor;
        appearance.titleTextAttributes = @{
            NSForegroundColorAttributeName : FBPIconColor(),
            NSFontAttributeName : FBPFont(17, UIFontWeightSemibold),
        };
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
    }
}

#pragma mark - Preview font

/// The face used to preview a row, at the chosen size scale. Built inside the
/// font scope so the replacement hooks do not redirect it — each row shows its
/// true typeface, and the "Default" row shows Facebook's original font.
- (UIFont *)previewFontForFamily:(nullable NSString *)family size:(CGFloat)size {
    FBPSetFontScopeActive(YES);
    UIFont *font = nil;
    CGFloat scaled = family.length ? size * self.scale : size;   // scale only custom faces
    if (family.length) {
        UIFontDescriptor *descriptor =
            [UIFontDescriptor fontDescriptorWithFontAttributes:@{ UIFontDescriptorFamilyAttribute : family }];
        font = [UIFont fontWithDescriptor:descriptor size:scaled];
    } else {
        font = [UIFont fontWithName:@"OptimisticVFApp-Regular-Lite" size:scaled];
    }
    FBPSetFontScopeActive(NO);
    return font ?: [UIFont systemFontOfSize:scaled];
}

#pragma mark - Sections
//
// 0        : the text-size slider
// 1        : the original font
// 2…n+1    : the bundled families

- (BOOL)isSizeSection:(NSInteger)section { return section == 0; }

/// The family for a font section (section >= 1); nil for the original.
- (nullable NSString *)familyForSection:(NSInteger)section {
    if (section == 1) return nil;
    return self.families[section - 2];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.families.count + 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 8.0;
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 ? 4.0 : CGFLOAT_MIN;
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isSizeSection:indexPath.section]) {
        FBPFontSizeCell *cell = [tableView dequeueReusableCellWithIdentifier:kSizeCell
                                                                forIndexPath:indexPath];
        cell.slider.value = (float)self.scale;
        [self updateScaleLabel:cell.valueLabel];
        [cell.slider removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.slider addTarget:self action:@selector(scaleChanged:)
              forControlEvents:UIControlEventValueChanged];
        [cell.slider addTarget:self action:@selector(scaleCommitted:)
              forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        return cell;
    }

    FBPFontCell *cell = [tableView dequeueReusableCellWithIdentifier:kFontCell
                                                       forIndexPath:indexPath];
    NSString *family = [self familyForSection:indexPath.section];

    cell.textLabel.text = family ?: FBPL(@"fonts.default");
    cell.textLabel.font = [self previewFontForFamily:family size:18.0];
    cell.detailTextLabel.text = FBPFontSampleText();
    cell.detailTextLabel.font = [self previewFontForFamily:family size:14.0];

    BOOL isSelected = (family == nil) ? (self.selected == nil)
                                      : [family isEqualToString:self.selected];
    cell.accessoryType = isSelected ? UITableViewCellAccessoryCheckmark
                                    : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isSizeSection:indexPath.section]) return;

    NSString *family = [self familyForSection:indexPath.section];   // nil = original
    BOOL same = (family == nil) ? (self.selected == nil)
                                : [family isEqualToString:self.selected];
    if (same) return;

    self.selected = family;
    [FBPPrefs.shared setString:family forKey:FBPKeyFont];   // nil clears → original
    [FBPPrefs.shared commit];
    [self.tableView reloadData];

    NSString *name = family ?: FBPL(@"fonts.default");
    [FBPToastManager.shared showMessage:[NSString stringWithFormat:FBPL(@"fonts.applied"), name]
                                success:YES];
}

#pragma mark - Delete imported fonts

/// YES when a family was imported by the user (and so may be removed). Bundled
/// fonts and the original are never deletable.
- (BOOL)isUserFamily:(nullable NSString *)family {
    return family.length && [FBPUserFontFamilies() containsObject:family];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isSizeSection:indexPath.section]) return NO;
    return [self isUserFamily:[self familyForSection:indexPath.section]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self deleteConfigForSection:indexPath.section];
}

// The user asked for either direction, so a leading swipe offers it too.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self deleteConfigForSection:indexPath.section];
}

- (nullable UISwipeActionsConfiguration *)deleteConfigForSection:(NSInteger)section {
    NSString *family = [self familyForSection:section];
    if (![self isUserFamily:family]) return nil;   // only imported fonts

    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:FBPL(@"fonts.delete.confirm")
                                              handler:^(UIContextualAction *action,
                                                        UIView *sourceView,
                                                        void (^completion)(BOOL)) {
        // Hand the swipe back first, then confirm — the font is only removed on OK.
        completion(NO);
        [weakSelf confirmDeleteFamily:family];
    }];
    remove.image = [UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *config =
        [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    config.performsFirstActionWithFullSwipe = NO;   // require a deliberate tap, not a flick
    return config;
}

- (void)confirmDeleteFamily:(NSString *)family {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:FBPL(@"fonts.delete.title")
                         message:[NSString stringWithFormat:FBPL(@"fonts.delete.message"), family]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"fonts.delete.confirm")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [self deleteFamily:family];
    }]];
    alert.view.tintColor = FBPTintColor();
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteFamily:(NSString *)family {
    // If the font being removed is the one in use, fall back to the original.
    if ([family isEqualToString:self.selected]) {
        self.selected = nil;
        [FBPPrefs.shared setString:nil forKey:FBPKeyFont];
        [FBPPrefs.shared commit];
    }
    FBPDeleteUserFont(family);
    self.families = FBPRegisteredFontFamilies();
    [self.tableView reloadData];
    [FBPToastManager.shared showMessage:FBPL(@"fonts.deleted") success:YES];
}

#pragma mark - Size slider

- (void)updateScaleLabel:(UILabel *)label {
    label.text = [NSString stringWithFormat:@"%.0f%%", self.scale * 100.0];
}

// Live while dragging: update the previews and the percentage, without writing
// the preference on every frame.
- (void)scaleChanged:(UISlider *)slider {
    self.scale = slider.value;
    NSArray<NSIndexPath *> *visible = self.tableView.indexPathsForVisibleRows;
    for (NSIndexPath *path in visible) {
        if ([self isSizeSection:path.section]) {
            FBPFontSizeCell *cell = (FBPFontSizeCell *)[self.tableView cellForRowAtIndexPath:path];
            if ([cell isKindOfClass:FBPFontSizeCell.class]) [self updateScaleLabel:cell.valueLabel];
        }
    }
    [self reloadFontSections];
}

// On release: persist the multiplier so the live app picks it up.
- (void)scaleCommitted:(UISlider *)slider {
    self.scale = slider.value;
    [FBPPrefs.shared setString:[NSString stringWithFormat:@"%.3f", self.scale]
                        forKey:FBPKeyFontScale];
    [FBPPrefs.shared commit];
}

- (void)reloadFontSections {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSInteger s = 1; s < [self numberOfSectionsInTableView:self.tableView]; s++) {
        [set addIndex:(NSUInteger)s];
    }
    [self.tableView reloadSections:set withRowAnimation:UITableViewRowAnimationNone];
}

@end
