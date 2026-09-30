#import "OVPages.h"
#import "OVUI.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVRuntime.h"
#import "OVLocale.h"

static NSString *const kNoLoRA = @"__none__";

/// Model details are stored in English ("A · B"); translate each part for display.
/// Unknown text (e.g. user-provided) comes back unchanged from L().
static NSString *DetailsText(NSString *details) {
    if (!details.length) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [details componentsSeparatedByString:@" · "]) {
        if ([part hasPrefix:@"Languages: "])
            [parts addObject:[NSString stringWithFormat:L(@"Languages: %@"), [part substringFromIndex:@"Languages: ".length]]];
        else if ([part hasPrefix:@"Local folder: "])
            [parts addObject:[NSString stringWithFormat:L(@"Local folder: %@"), [part substringFromIndex:@"Local folder: ".length]]];
        else
            [parts addObject:L(part)];
    }
    return [parts componentsJoinedByString:@" · "];
}

static NSTextField *Badge(NSString *text, NSColor *color) {
    NSTextField *b = OVLabel([NSString stringWithFormat:@" %@ ", text], 10, NSFontWeightSemibold, color);
    b.wantsLayer = YES;
    b.layer.cornerRadius = 4;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [color colorWithAlphaComponent:0.5].CGColor;
    [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

/// Card row for one model; rebuilt in place on every models change.
@interface OVModelRow : NSStackView
@property (weak) id target;
@property NSString *repo;
@property NSButton *radio;
@property NSTextField *title, *details, *meta;
@property NSProgressIndicator *bar;
@property NSStackView *buttons;
@end

@implementation OVModelRow
+ (instancetype)rowFor:(OVModel *)m target:(id)t {
    OVModelRow *r = [OVModelRow new];
    r.target = t;
    r.repo = m ? m.repo : kNoLoRA;
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeTop;
    r.distribution = NSStackViewDistributionFill;
    r.spacing = 12;
    r.radio = [NSButton radioButtonWithTitle:@"" target:t action:@selector(useModel:)];
    r.radio.identifier = r.repo;
    r.radio.toolTip = L(@"Use");
    r.title = OVLabel(m ? m.title : L(@"No LoRA"), 14, NSFontWeightSemibold, nil);
    r.details = OVWrapLabel(m ? DetailsText(m.details) : L(@"The base model as is."), 12, nil);
    r.meta = OVLabel(@"", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    r.meta.lineBreakMode = NSLineBreakByTruncatingMiddle;
    r.bar = OVProgressBar();
    r.buttons = OVHStack(@[], 6);
    NSStackView *titleRow = OVHStack(@[r.title], 8);
    if (m.recommended) [titleRow addArrangedSubview:Badge(L(@"recommended"), OVAccent())];
    if (m.ukrainian && !m.recommended) [titleRow addArrangedSubview:Badge(@"UA", NSColor.systemYellowColor)];
    if (m.catalog && m.downloads)
        [titleRow addArrangedSubview:OVLabel([NSString stringWithFormat:@"↓ %ld", (long)m.downloads], 11, NSFontWeightRegular, NSColor.tertiaryLabelColor)];
    NSStackView *body = OVVStack(@[titleRow, r.details, r.meta, r.bar], 4);
    OVFillWidth(@[r.details, r.meta, r.bar], body);
    if (!m.catalog) [r addArrangedSubview:r.radio];
    [r addArrangedSubview:body];
    [r addArrangedSubview:r.buttons];
    [body setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.radio setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.buttons setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [body.widthAnchor constraintGreaterThanOrEqualToAnchor:r.widthAnchor multiplier:0.6].active = YES;
    [r update:m];
    return r;
}

- (NSButton *)btn:(NSString *)title sel:(SEL)sel {
    NSButton *b = OVButton(title, self.target, sel);
    b.controlSize = NSControlSizeRegular;
    b.identifier = self.repo;
    return b;
}

- (NSButton *)icon:(NSString *)symbol tip:(NSString *)tip sel:(SEL)sel {
    NSButton *b = OVIconButton(symbol, tip, self.target, sel);
    b.identifier = self.repo;
    return b;
}

- (void)update:(OVModel *)m {
    OVModels *mm = [OVModels shared];
    for (NSView *v in self.buttons.arrangedSubviews.copy) [v removeFromSuperview];
    if (!m) { // "no LoRA" row
        self.radio.state = mm.loraSelection ? NSControlStateValueOff : NSControlStateValueOn;
        self.meta.hidden = YES;
        self.bar.hidden = YES;
        return;
    }
    OVModel *selected = m.kind == OVModelTTS ? mm.ttsModel : m.kind == OVModelASR ? mm.asrModel : mm.loraSelection;
    self.radio.state = selected == m ? NSControlStateValueOn : NSControlStateValueOff;
    self.radio.enabled = m.installed || m.kind == OVModelLoRA; // a LoRA can be picked before it's downloaded
    long long size = m.total > 0 ? m.total : m.approxBytes;
    NSString *sizeText = size > 0 ? OVFormatBytes(size) : @"";
    NSString *where = [m.repo hasPrefix:@"/"] ? [m.repo stringByAbbreviatingWithTildeInPath] : m.repo;
    if (m.downloading) {
        self.meta.stringValue = [NSString stringWithFormat:L(@"%@ · %@ of %@ · %@"), where, OVFormatBytes(m.received), sizeText, m.downloadStatus ?: @""];
        self.meta.textColor = NSColor.secondaryLabelColor;
    } else if (m.installed) {
        self.meta.stringValue = [NSString stringWithFormat:L(@"✓ Installed · %@%@"), where, sizeText.length ? [@" · " stringByAppendingString:sizeText] : @""];
        self.meta.textColor = OVGreen();
    } else if (m.error) {
        self.meta.stringValue = [NSString stringWithFormat:L(@"%@ · Error: %@"), where, m.error];
        self.meta.textColor = NSColor.systemOrangeColor;
    } else {
        self.meta.stringValue = sizeText.length ? [NSString stringWithFormat:@"%@ · %@", where, sizeText] : where;
        self.meta.textColor = NSColor.tertiaryLabelColor;
    }
    self.bar.hidden = !m.downloading;
    self.bar.doubleValue = m.progress;

    NSMutableArray *bs = [NSMutableArray array];
    if (m.downloading) [bs addObject:[self btn:L(@"Pause") sel:@selector(cancelModel:)]];
    else if (m.catalog && m.kind == OVModelLoRA) [bs addObject:[self btn:L(@"Use") sel:@selector(useCatalogLoRA:)]];
    else if (!m.installed && ![m.repo hasPrefix:@"/"]) {
        NSButton *b = [self btn:m.error ? L(@"Continue") : L(@"Download") sel:@selector(downloadModel:)];
        b.bezelColor = OVAccent();
        [bs addObject:b];
    } else if (m.installed) {
        [bs addObject:[self icon:@"folder" tip:L(@"Show in Finder") sel:@selector(revealModel:)]];
        if (![m.repo hasPrefix:@"/"]) [bs addObject:[self icon:@"trash" tip:L(@"Delete from Hugging Face cache") sel:@selector(deleteModel:)]];
    }
    if (![m.repo hasPrefix:@"/"]) [bs addObject:[self icon:@"safari" tip:L(@"Open on Hugging Face") sel:@selector(openPage:)]];
    if (m.custom && !m.downloading) [bs addObject:[self icon:@"xmark.circle" tip:L(@"Remove from list") sel:@selector(forgetModel:)]];
    for (NSView *v in bs) {
        [v setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.buttons addArrangedSubview:v];
    }
}
@end

@interface OVModelsPage ()
@property NSStackView *ttsList, *loraList, *asrList, *catalogList;
@property NSMutableDictionary<NSString *, OVModelRow *> *rows;
@property NSSegmentedControl *catalogKind;
@property NSTextField *catalogStatus, *repoField, *addStatus, *endpointField, *cacheLabel;
@property NSPopUpButton *kindPopup;
@property NSSecureTextField *tokenField;
@property (copy) NSString *layoutSignature;
@end

@implementation OVModelsPage

- (void)loadView {
    self.rows = [NSMutableDictionary dictionary];
    NSStackView *page = OVVStack(@[], 14);
    page.edgeInsets = NSEdgeInsetsMake(30, 32, 30, 32);

    NSTextField *title = OVTitle(L(@"Models"));
    self.cacheLabel = OVWrapLabel(@"", 13, nil);
    self.ttsList = OVVStack(@[], 14);
    self.loraList = OVVStack(@[], 14);
    self.asrList = OVVStack(@[], 14);
    NSView *ttsCard = OVCard(self.ttsList, 18), *loraCard = OVCard(self.loraList, 18), *asrCard = OVCard(self.asrList, 18);
    NSTextField *loraHint = OVWrapLabel(L(@"Applied on top of the speech synthesis model. The selected adapter is downloaded automatically."), 12, nil);

    // catalog
    self.catalogKind = [NSSegmentedControl segmentedControlWithLabels:@[L(@"LoRA adapters"), L(@"Fine-tuned models")]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(catalogKindChanged:)];
    self.catalogKind.selectedSegment = 0;
    NSButton *refresh = OVIconButton(@"arrow.clockwise", L(@"Refresh catalog"), self, @selector(refreshCatalog:));
    self.catalogStatus = OVLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.catalogList = OVVStack(@[], 14);
    NSStackView *catBox = OVVStack(@[OVHStack(@[self.catalogKind, refresh, self.catalogStatus], 10), self.catalogList], 16);
    OVFillWidth(@[self.catalogList], catBox);
    NSView *catCard = OVCard(catBox, 18);

    // add custom
    self.repoField = OVField(L(@"author/model, huggingface.co/… link, or folder"));
    self.kindPopup = [NSPopUpButton new];
    [self.kindPopup addItemsWithTitles:@[L(@"LoRA adapter"), L(@"Speech synthesis model"), L(@"Speech recognition (Whisper)")]];
    NSButton *add = OVButton(L(@"Add"), self, @selector(addCustom:));
    NSButton *folder = OVButton(L(@"Folder…"), self, @selector(chooseFolder:));
    add.controlSize = folder.controlSize = NSControlSizeRegular;
    self.addStatus = OVWrapLabel(L(@"Your own LoRA (for example, one trained on a rented GPU) can be loaded straight from a folder "
                                 @"with adapter_config.json and adapter_model.safetensors."), 11.5, nil);
    NSStackView *addRow = OVHStack(@[self.repoField, self.kindPopup, folder, add], 8);
    NSStackView *addBox = OVVStack(@[OVSectionTitle(L(@"Add your own model or LoRA")), addRow, self.addStatus], 8);
    OVFillWidth(@[addRow, self.addStatus], addBox);
    NSView *addCard = OVCard(addBox, 18);

    // HF access
    self.tokenField = [NSSecureTextField new];
    self.tokenField.placeholderString = L(@"hf_… (only needed for gated models)");
    self.tokenField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"hfToken"] ?: @"";
    self.tokenField.target = self;
    self.tokenField.action = @selector(saveAccess:);
    self.endpointField = OVField(@"https://huggingface.co");
    self.endpointField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"] ?: @"";
    self.endpointField.target = self;
    self.endpointField.action = @selector(saveAccess:);
    NSButton *cacheBtn = OVButton(L(@"Choose folder…"), self, @selector(chooseCache:));
    NSButton *cacheReset = OVButton(L(@"Default"), self, @selector(resetCache:));
    cacheBtn.controlSize = cacheReset.controlSize = NSControlSizeRegular;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[OVLabel(L(@"Token"), 13, NSFontWeightMedium, nil), self.tokenField],
        @[OVLabel(L(@"Mirror"), 13, NSFontWeightMedium, nil), self.endpointField],
        @[OVLabel(L(@"Cache"), 13, NSFontWeightMedium, nil), OVHStack(@[cacheBtn, cacheReset], 8)],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    NSStackView *accessBox = OVVStack(@[OVSectionTitle(@"Hugging Face"), grid,
                                        OVWrapLabel(L(@"Press Return to save the token and mirror."), 11.5, nil)], 10);
    OVFillWidth(@[grid], accessBox);
    NSView *accessCard = OVCard(accessBox, 18);

    NSButton *rescan = OVButton(L(@"Rescan cache"), self, @selector(rescan:));
    NSButton *openCache = OVButton(L(@"Open cache in Finder"), self, @selector(openCache:));
    rescan.controlSize = openCache.controlSize = NSControlSizeRegular;

    NSTextField *loraTitle = OVSectionTitle(L(@"LoRA adapter"));
    NSArray *views = @[title, self.cacheLabel,
                       OVSectionTitle(L(@"Speech synthesis model")), ttsCard,
                       loraTitle, loraHint, loraCard,
                       OVSectionTitle(L(@"Speech recognition")), asrCard,
                       OVSectionTitle(L(@"Hugging Face catalog")), catCard,
                       addCard, accessCard, OVHStack(@[rescan, openCache], 8)];
    for (NSView *v in views) [page addArrangedSubview:v];
    [page setCustomSpacing:6 afterView:title];
    [page setCustomSpacing:4 afterView:loraTitle];
    for (NSView *c in @[self.cacheLabel, ttsCard, loraCard, asrCard, catCard]) [page setCustomSpacing:24 afterView:c];
    OVFillWidth(@[self.cacheLabel, ttsCard, loraHint, loraCard, asrCard, catCard, addCard, accessCard], page);
    self.view = OVScrollPage(page);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:OVModelsDidChangeNotification object:nil];
    [self refresh];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    OVModels *mm = [OVModels shared];
    if (![mm catalogOfKind:OVModelLoRA].count && !mm.catalogLoading) [mm refreshCatalog];
}

- (NSStackView *)listFor:(OVModel *)m {
    return m.kind == OVModelTTS ? self.ttsList : m.kind == OVModelLoRA ? self.loraList : self.asrList;
}

- (void)place:(OVModelRow *)row in:(NSStackView *)list {
    if (list.arrangedSubviews.count) {
        NSBox *sep = [NSBox new];
        sep.boxType = NSBoxSeparator;
        [list addArrangedSubview:sep];
        OVFillWidth(@[sep], list);
    }
    [list addArrangedSubview:row];
    OVFillWidth(@[row], list);
}

- (NSArray<OVModel *> *)visibleCatalog {
    OVModels *mm = [OVModels shared];
    return [[mm catalogOfKind:self.catalogKind.selectedSegment == 0 ? OVModelLoRA : OVModelTTS]
            sortedArrayUsingComparator:^NSComparisonResult(OVModel *a, OVModel *b) {
        if (a.ukrainian != b.ukrainian) return a.ukrainian ? NSOrderedAscending : NSOrderedDescending;
        return [@(b.downloads) compare:@(a.downloads)];
    }];
}

- (void)refresh {
    OVModels *mm = [OVModels shared];
    self.cacheLabel.stringValue = [NSString stringWithFormat:
        L(@"Models are stored in the Hugging Face cache — %@ — in the same format as VoiceStudio, "
          @"so anything downloaded by one app is visible to the other. Downloads can be stopped and resumed later."),
        [[OVModels hubCache] stringByAbbreviatingWithTildeInPath]];

    NSArray *catalog = [self visibleCatalog];
    // rebuild rows when the set of listed models changes (e.g. a catalog entry was added)
    NSMutableArray *sig = [NSMutableArray array];
    for (OVModel *m in mm.all) if (!m.hidden && !m.catalog) [sig addObject:[NSString stringWithFormat:@"%@:%ld", m.repo, (long)m.kind]];
    for (OVModel *m in catalog) [sig addObject:[@"cat:" stringByAppendingString:m.repo]];
    NSString *signature = [sig componentsJoinedByString:@"|"];
    if (![signature isEqualToString:self.layoutSignature]) {
        self.layoutSignature = signature;
        for (NSStackView *l in @[self.ttsList, self.loraList, self.asrList, self.catalogList])
            for (NSView *v in l.arrangedSubviews.copy) [v removeFromSuperview];
        [self.rows removeAllObjects];
        OVModelRow *none = [OVModelRow rowFor:nil target:self];
        self.rows[kNoLoRA] = none;
        [self place:none in:self.loraList];
        for (OVModel *m in mm.all) {
            if (m.hidden || m.catalog) continue;
            OVModelRow *row = [OVModelRow rowFor:m target:self];
            self.rows[m.repo] = row;
            [self place:row in:[self listFor:m]];
        }
        for (OVModel *m in catalog) {
            OVModelRow *row = [OVModelRow rowFor:m target:self];
            self.rows[m.repo] = row;
            [self place:row in:self.catalogList];
        }
    } else {
        [self.rows[kNoLoRA] update:nil];
        for (OVModel *m in mm.all) [self.rows[m.repo] update:m];
    }

    BOOL anyUA = NO;
    for (OVModel *m in catalog) anyUA |= m.ukrainian && ![m.languages containsObject:@"multi"];
    self.catalogStatus.stringValue = mm.catalogLoading ? L(@"Loading catalog…") :
        mm.catalogError ? [NSString stringWithFormat:L(@"Can’t reach Hugging Face: %@"), mm.catalogError] :
        !catalog.count ? L(@"Nothing found") :
        anyUA ? [NSString stringWithFormat:L(@"Found %lu · Ukrainian ones first"), (unsigned long)catalog.count]
              : [NSString stringWithFormat:L(@"Found %lu · no Ukrainian ones yet, they’ll appear here automatically"), (unsigned long)catalog.count];
}

- (OVModel *)model:(NSButton *)b { return [[OVModels shared] modelForRepo:b.identifier]; }

- (void)useModel:(NSButton *)b {
    OVModels *mm = [OVModels shared];
    if ([b.identifier isEqualToString:kNoLoRA]) { [mm selectLoRA:nil]; [self reloadEngine]; return; }
    OVModel *m = [self model:b];
    if (!m) return;
    if (m.kind == OVModelLoRA) { [mm selectLoRA:m]; [self reloadEngine]; return; }
    if (!m.installed) return;
    [mm select:m];
    if (m.kind == OVModelTTS) [self reloadEngine];
}
- (void)reloadEngine { if (![OVWorker shared].busy) [[OVWorker shared] stop]; } // next request loads the new combination
- (void)useCatalogLoRA:(NSButton *)b { OVModel *m = [self model:b]; if (m) { [[OVModels shared] selectLoRA:m]; [self reloadEngine]; } }
- (void)catalogKindChanged:(id)s { [self refresh]; }
- (void)refreshCatalog:(id)s { [[OVModels shared] refreshCatalog]; }
- (void)downloadModel:(NSButton *)b { OVModel *m = [self model:b]; if (m) [[OVModels shared] download:m]; }
- (void)cancelModel:(NSButton *)b { OVModel *m = [self model:b]; if (m) [[OVModels shared] cancelDownload:m]; }
- (void)revealModel:(NSButton *)b {
    OVModel *m = [self model:b];
    if (m.localPath) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:m.localPath]]];
}
- (void)openPage:(NSButton *)b {
    NSString *base = [NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"];
    if (!base.length) base = @"https://huggingface.co";
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", base, b.identifier]]];
}
- (void)deleteModel:(NSButton *)b {
    OVModel *m = [self model:b];
    if (!m) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Delete “%@” from the Hugging Face cache?"), m.title];
    a.informativeText = L(@"The cache is shared: if VoiceStudio or another app needs this model, it will have to download it again. The files will be moved to the Trash.");
    [a addButtonWithTitle:L(@"Move to Trash")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.buttons.firstObject.hasDestructiveAction = YES;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [[OVWorker shared] stop];
    NSError *err = nil;
    if (![[OVModels shared] remove:m error:&err] && err) [[NSAlert alertWithError:err] runModal];
}
- (void)forgetModel:(NSButton *)b { OVModel *m = [self model:b]; if (m) [[OVModels shared] removeCustom:m]; }
- (void)rescan:(id)s { [[OVModels shared] rescan]; }
- (void)openCache:(id)s {
    NSString *c = [OVModels hubCache];
    [NSFileManager.defaultManager createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:c]];
}

- (void)chooseCache:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.canCreateDirectories = YES;
    p.showsHiddenFiles = YES;
    p.message = L(@"Hugging Face cache folder (usually …/huggingface/hub)");
    if ([p runModal] != NSModalResponseOK) return;
    [NSUserDefaults.standardUserDefaults setObject:p.URL.path forKey:@"hfCacheDir"];
    [[OVWorker shared] stop];
    [[OVModels shared] rescan];
}
- (void)resetCache:(id)s {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"hfCacheDir"];
    [[OVWorker shared] stop];
    [[OVModels shared] rescan];
}

- (void)chooseFolder:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.message = L(@"Folder with a LoRA adapter (adapter_config.json + adapter_model.safetensors) or a model");
    if ([p runModal] != NSModalResponseOK) return;
    self.repoField.stringValue = p.URL.path;
    [self addCustom:nil];
}

- (void)addCustom:(id)s {
    NSInteger k = self.kindPopup.indexOfSelectedItem;
    OVModelKind kind = k == 0 ? OVModelLoRA : k == 1 ? OVModelTTS : OVModelASR;
    OVModel *m = [[OVModels shared] addCustomRepo:self.repoField.stringValue kind:kind];
    if (!m) { self.addStatus.stringValue = L(@"Enter a model as “author/name”, a link, or an existing folder."); return; }
    self.repoField.stringValue = @"";
    if (m.kind == OVModelLoRA) {
        [[OVModels shared] selectLoRA:m];
        [self reloadEngine];
        self.addStatus.stringValue = m.installed ? [NSString stringWithFormat:L(@"LoRA “%@” is connected."), m.title]
                                                 : [NSString stringWithFormat:L(@"LoRA “%@” is selected and downloading."), m.title];
    } else {
        if (!m.installed && ![m.repo hasPrefix:@"/"]) [[OVModels shared] download:m];
        self.addStatus.stringValue = m.installed ? [NSString stringWithFormat:L(@"%@ is already in the cache."), m.title]
                                                 : [NSString stringWithFormat:L(@"%@ was added and is downloading."), m.title];
    }
}

- (void)saveAccess:(id)s {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:[self.tokenField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] forKey:@"hfToken"];
    [d setObject:[self.endpointField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] forKey:@"hfEndpoint"];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self saveAccess:nil];
}
@end
