#import "OVPages.h"
#import "OVUI.h"
#import "OVDesign.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVRuntime.h"
#import "OVLocale.h"
#import "OVNativeAccent.h"

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

/// Card row for one model; rebuilt in place on every models change.
@interface OVModelRow : OVBoxView
@property (weak) id target;
@property NSString *repo;
@property NSButton *radio;
@property NSTextField *title, *details, *meta;
@property NSProgressIndicator *bar;
@property NSStackView *buttons, *titleRow;
@property (nonatomic) NSView *statusBadge;
@end

@implementation OVModelRow
+ (instancetype)rowFor:(OVModel *)m target:(id)t {
    OVModelRow *r = [OVModelRow boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
    r.target = t;
    r.repo = m ? m.repo : kNoLoRA;
    r.radio = OVRadioButton(@"", t, @selector(useModel:));
    r.radio.identifier = r.repo;
    r.radio.toolTip = L(@"Use");
    r.radio.accessibilityLabel = m ? m.title : L(@"No LoRA");
    r.title = OVLabel(m ? m.title : L(@"No LoRA"), 14, NSFontWeightSemibold, nil);
    r.title.lineBreakMode = NSLineBreakByTruncatingMiddle;   // a 100-character repository name is cut in the middle
    r.details = OVWrapLabel(m ? DetailsText(m.details) : L(@"The base model as is."), 13, nil);
    r.meta = OVLabel(@"", 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    r.meta.lineBreakMode = NSLineBreakByTruncatingMiddle;
    r.bar = OVProgressBar();
    r.buttons = OVHStack(@[], 6);
    r.titleRow = OVHStack(@[], 8);   // badges and the download count, under the title
    if (m.recommended) [r.titleRow addArrangedSubview:OVBadge(L(@"recommended"), OVRoleAccent)];
    if (m.ukrainian && !m.recommended) [r.titleRow addArrangedSubview:OVBadge(@"UA", OVRoleWarn)];
    if (m.catalog && m.downloads)
        [r.titleRow addArrangedSubview:OVLabel([NSString stringWithFormat:@"↓ %ld", (long)m.downloads], 12, NSFontWeightRegular, OVColor(OVRoleMuted))];
    [r.titleRow addArrangedSubview:OVSpacer()];
    NSStackView *body = OVVStack(m ? @[r.title, r.titleRow, r.details, r.meta, r.bar] : @[r.title, r.details, r.meta, r.bar], 4);
    OVFillWidth(m ? @[r.title, r.titleRow, r.details, r.meta, r.bar] : @[r.title, r.details, r.meta, r.bar], body);
    r.titleRow.hidden = r.titleRow.arrangedSubviews.count <= 1;
    NSStackView *inner = OVHStack(@[], 12);
    inner.alignment = NSLayoutAttributeTop;
    if (!m.catalog) [inner addArrangedSubview:r.radio];
    [inner addArrangedSubview:body];
    [inner addArrangedSubview:r.buttons];
    [body setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.radio setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.radio setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.radio.widthAnchor constraintEqualToConstant:20].active = YES;
    [r.radio.heightAnchor constraintEqualToConstant:20].active = YES;
    [r addSubview:inner];
    OVPin(inner, r, NSEdgeInsetsMake(14, 14, 14, 14));
    [body.widthAnchor constraintGreaterThanOrEqualToAnchor:r.widthAnchor multiplier:0.5].active = YES;   // a short description must not collapse the body
    [r update:m];
    return r;
}

- (void)setSelected:(BOOL)on {
    self.borderColor = OVColor(on ? OVRoleGhostBorder : OVRoleBorder);
}

- (NSButton *)btn:(NSButton *)b {
    b.identifier = self.repo;
    return b;
}

- (NSButton *)icon:(NSString *)symbol tip:(NSString *)tip sel:(SEL)sel {
    NSButton *b = OVIconButton(symbol, tip, self.target, sel);
    b.identifier = self.repo;
    b.accessibilityLabel = tip;
    return b;
}

- (void)setStatusBadge:(NSView *)badge {
    [_statusBadge removeFromSuperview];
    _statusBadge = badge;
    if (badge) [self.titleRow insertArrangedSubview:badge atIndex:0];
    self.titleRow.hidden = self.titleRow.arrangedSubviews.count <= 1;   // only the spacer left
}

- (void)update:(OVModel *)m {
    OVModels *mm = [OVModels shared];
    for (NSView *v in self.buttons.arrangedSubviews.copy) [v removeFromSuperview];
    if (!m) { // "no LoRA" row
        BOOL on = !mm.loraSelection;
        self.radio.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        self.meta.hidden = YES;
        self.bar.hidden = YES;
        [self setSelected:on];
        return;
    }
    OVModel *selected = m.kind == OVModelTTS ? mm.ttsModel : m.kind == OVModelASR ? mm.asrModel : mm.loraSelection;
    self.radio.state = selected == m ? NSControlStateValueOn : NSControlStateValueOff;
    self.radio.enabled = m.installed || m.kind == OVModelLoRA; // a LoRA can be picked before it's downloaded
    [self setSelected:!m.catalog && selected == m];
    long long size = m.total > 0 ? m.total : m.approxBytes;
    NSString *sizeText = size > 0 ? OVFormatBytes(size) : @"";
    NSString *where = [m.repo hasPrefix:@"/"] ? [m.repo stringByAbbreviatingWithTildeInPath] : m.repo;
    if (m.downloading) {
        self.meta.stringValue = [NSString stringWithFormat:L(@"%@ · %@ of %@ · %@"), where, OVFormatBytes(m.received), sizeText, m.downloadStatus ?: @""];
        self.meta.textColor = OVColor(OVRoleMuted);
        self.statusBadge = nil;
    } else if (m.installed) {
        self.meta.stringValue = [NSString stringWithFormat:@"%@%@", where, sizeText.length ? [@" · " stringByAppendingString:sizeText] : @""];
        self.meta.textColor = OVColor(OVRoleMuted);
        self.statusBadge = OVBadge(L(@"Installed"), OVRoleOK);
    } else if (m.error) {
        self.meta.stringValue = [NSString stringWithFormat:L(@"%@ · Error: %@"), where, m.error];
        self.meta.textColor = OVColor(OVRoleErr);
        self.statusBadge = OVBadge(L(@"Error"), OVRoleErr);
    } else {
        self.meta.stringValue = sizeText.length ? [NSString stringWithFormat:@"%@ · %@", where, sizeText] : where;
        self.meta.textColor = OVColor(OVRoleMuted);
        self.statusBadge = nil;
    }
    self.bar.hidden = !m.downloading;
    self.bar.doubleValue = m.progress;

    NSMutableArray *bs = [NSMutableArray array];
    if (m.downloading) [bs addObject:[self btn:OVSmallPill(OVGhostButton(L(@"Pause"), nil, self.target, @selector(cancelModel:)))]];
    else if (m.catalog && m.kind == OVModelLoRA) [bs addObject:[self btn:OVSmallPill(OVGhostButton(L(@"Use"), nil, self.target, @selector(useCatalogLoRA:)))]];
    else if (!m.installed && ![m.repo hasPrefix:@"/"]) {
        if (m.error) [bs addObject:[self btn:OVSmallPill(OVGhostButton(L(@"Continue"), nil, self.target, @selector(downloadModel:)))]];
        else [bs addObject:[self btn:OVSmallPill(OVPrimaryButton(L(@"Download"), self.target, @selector(downloadModel:)))]];
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
@property OVSegmented *catalogKind, *tabs;
@property NSTextField *catalogStatus, *repoField, *addStatus, *endpointField, *cacheLabel;
@property OVPopup *kindPopup;
@property NSSecureTextField *tokenField;
@property NSTextField *accentMeta;
@property NSProgressIndicator *accentBar;
@property NSStackView *accentButtons;
@property NSView *emptyState;   // catalog empty state; hidden while the catalog loads
@property NSArray<NSView *> *tabViews;   // Library, Catalog, Add model
@property (copy) NSString *layoutSignature;
@end

@implementation OVModelsPage

- (void)loadView {
    self.rows = [NSMutableDictionary dictionary];
    self.cacheLabel = OVWrapLabel(@"", 13, nil);
    self.ttsList = OVVStack(@[], 8);
    self.loraList = OVVStack(@[], 8);
    self.asrList = OVVStack(@[], 8);
    self.tabs = [OVSegmented segmentedWithItems:@[@[L(@"Library"), @"shippingbox"], @[L(@"Catalog"), @"square.grid.2x2"],
                                                  @[L(@"Add model"), @"plus.circle"]]];
    self.tabs.selectedIndex = 0;
    self.tabs.target = self;
    self.tabs.action = @selector(tabChanged:);
    NSView *header = OVPageHeader(L(@"Models"), nil, self.tabs);
    NSStackView *head = OVVStack(@[header, self.cacheLabel], 4);
    OVFillWidth(@[header, self.cacheLabel], head);

    // Library
    NSTextField *loraHint = OVWrapLabel(L(@"Applied on top of the speech synthesis model. The selected adapter is downloaded automatically."), 13, nil);
    NSView *ttsCard = OVStepCard(0, @"cpu", L(@"Speech synthesis model"), nil, self.ttsList);
    NSView *loraCard = OVStepCard(0, @"puzzlepiece", L(@"LoRA adapter"), loraHint.stringValue, self.loraList);
    NSView *asrCard = OVStepCard(0, @"waveform.badge.mic", L(@"Speech recognition"), nil, self.asrList);

    // native accent (optional download)
    NSTextField *accentDetails = OVWrapLabel(L(@"For pronunciation training without an accent: a native speaker (the model’s own voice or "
                                               @"another voice of yours) reads the learning phrases and Seed-VC gives the reading your voice, "
                                               @"so the trained voice speaks without your accent. About 2.7 GB (PyTorch, Seed-VC and its "
                                               @"models) in the app’s folder. Seed-VC (GPL-3.0) is downloaded from its authors and runs as "
                                               @"a separate program."), 13, nil);
    self.accentMeta = OVWrapLabel(@"", 12, nil);
    self.accentBar = OVProgressBar();
    self.accentButtons = OVHStack(@[], 6);
    NSStackView *accentBody = OVVStack(@[accentDetails, self.accentMeta, self.accentBar], 4);
    OVFillWidth(@[accentDetails, self.accentMeta, self.accentBar], accentBody);
    NSStackView *accentRow = OVHStack(@[accentBody, self.accentButtons], 12);
    accentRow.alignment = NSLayoutAttributeTop;
    [accentBody setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.accentButtons setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *accentCard = OVStepCard(0, @"person.wave.2", L(@"Accent removal"), L(@"Seed-VC · native narrator"), accentRow);

    NSButton *rescan = OVGhostButton(L(@"Rescan cache"), @"arrow.clockwise", self, @selector(rescan:));
    NSButton *openCache = OVGhostButton(L(@"Open cache in Finder"), @"folder", self, @selector(openCache:));
    NSStackView *cacheRow = OVHStack(@[rescan, openCache], 10);
    NSStackView *library = OVVStack(@[ttsCard, loraCard, asrCard, accentCard, cacheRow], 16);
    OVFillWidth(@[ttsCard, loraCard, asrCard, accentCard], library);

    // Catalog
    self.catalogKind = [OVSegmented segmentedWithItems:@[@[L(@"LoRA adapters"), @""], @[L(@"Fine-tuned models"), @""]]];
    self.catalogKind.selectedIndex = 0;
    self.catalogKind.target = self;
    self.catalogKind.action = @selector(catalogKindChanged:);
    NSButton *refresh = OVGhostButton(@"", @"arrow.clockwise", self, @selector(refreshCatalog:));
    refresh.toolTip = refresh.accessibilityLabel = L(@"Refresh catalog");
    [refresh.widthAnchor constraintEqualToConstant:40].active = YES;
    self.catalogStatus = OVWrapLabel(@"", 13, nil);
    self.catalogList = OVVStack(@[], 8);
    NSStackView *catBox = OVVStack(@[OVHStack(@[self.catalogKind, refresh, OVSpacer()], 10), self.catalogStatus, self.catalogList], 12);
    OVFillWidth(@[self.catalogStatus, self.catalogList], catBox);
    NSView *catalog = OVCard(catBox, 20);

    // Add model
    self.repoField = OVField(L(@"author/model, huggingface.co/… link, or folder"));
    self.repoField.accessibilityLabel = L(@"Add your own model or LoRA");
    self.kindPopup = [OVPopup popup];
    [self.kindPopup addItemsWithTitles:@[L(@"LoRA adapter"), L(@"Speech synthesis model"), L(@"Speech recognition (Whisper)")]];
    NSButton *add = OVPrimaryButton(L(@"Add"), self, @selector(addCustom:));
    NSButton *folder = OVGhostButton(L(@"Folder…"), @"folder", self, @selector(chooseFolder:));
    self.addStatus = OVWrapLabel(L(@"Your own LoRA (for example, one trained on a rented GPU) can be loaded straight from a folder "
                                 @"with adapter_config.json and adapter_model.safetensors."), 13, nil);
    [self.repoField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.repoField.widthAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    NSStackView *addRow = OVHStack(@[self.repoField, self.kindPopup, folder, add], 8);
    NSStackView *addBox = OVVStack(@[addRow, self.addStatus], 8);
    OVFillWidth(@[addRow, self.addStatus], addBox);
    NSView *addCard = OVStepCard(0, @"plus.circle", L(@"Add your own model or LoRA"), nil, addBox);

    // HF access
    self.tokenField = OVSecureField(L(@"hf_… (only needed for gated models)"));
    self.tokenField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"hfToken"] ?: @"";
    self.tokenField.target = self;
    self.tokenField.action = @selector(saveAccess:);
    self.tokenField.cell.sendsActionOnEndEditing = YES;  // saved when focus leaves too, not only on Return
    self.endpointField = OVField(@"https://huggingface.co");
    self.endpointField.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"] ?: @"";
    self.endpointField.target = self;
    self.endpointField.action = @selector(saveAccess:);
    self.endpointField.cell.sendsActionOnEndEditing = YES;
    NSButton *cacheBtn = OVGhostButton(L(@"Choose folder…"), @"folder", self, @selector(chooseCache:));
    NSButton *cacheReset = OVGhostButton(L(@"Default"), nil, self, @selector(resetCache:));
    for (NSButton *b in @[cacheBtn, cacheReset]) [b.heightAnchor constraintEqualToConstant:36].active = YES;
    NSStackView *cacheBtns = OVHStack(@[cacheBtn, cacheReset, OVSpacer()], 8);
    NSStackView *accessBox = OVVStack(@[OVFieldBlock(L(@"Token"), nil, self.tokenField),
                                        OVFieldBlock(L(@"Mirror"), nil, self.endpointField),
                                        OVFieldBlock(L(@"Cache"), nil, cacheBtns)], 14);
    OVFillWidth(accessBox.arrangedSubviews, accessBox);
    NSView *accessCard = OVStepCard(0, @"key", @"Hugging Face", L(@"Press Return to save the token and mirror."), accessBox);
    NSStackView *addTab = OVVStack(@[addCard, accessCard], 16);
    OVFillWidth(@[addCard, accessCard], addTab);

    self.tabViews = @[library, catalog, addTab];
    self.view = OVPageScroll(@[head, library, catalog, addTab]);
    [self tabChanged:nil];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:OVModelsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:OVThemeDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshAccent) name:OVNativeAccentDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshAccent) name:OVWorkerDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshAccent) name:OVRuntimeDidChangeNotification object:nil];
    [self refresh];
    [self refreshAccent];
}

- (void)tabChanged:(id)s {
    for (NSInteger i = 0; i < (NSInteger)self.tabViews.count; i++) self.tabViews[i].hidden = i != self.tabs.selectedIndex;
}

- (void)refreshAccent {
    OVNativeAccent *a = [OVNativeAccent shared];
    for (NSView *v in self.accentButtons.arrangedSubviews.copy) [v removeFromSuperview];
    self.accentBar.hidden = !a.installing;
    self.accentBar.doubleValue = a.progress;
    if (a.installing) {
        self.accentMeta.stringValue = [NSString stringWithFormat:@"%.0f%% · %@", a.progress * 100, a.step];
    } else if (a.installed) {
        self.accentMeta.stringValue = [NSString stringWithFormat:L(@"%@ · used by Train… next to the voice on the Speech page"),
                                       [[OVPaths accent] stringByAbbreviatingWithTildeInPath]];
        [self.accentButtons addArrangedSubview:OVBadge(L(@"Installed"), OVRoleOK)];
        NSButton *rm = OVIconButton(@"trash", L(@"Delete"), self, @selector(removeAccent:));
        [self.accentButtons addArrangedSubview:rm];
    } else {
        self.accentMeta.stringValue = a.error ? [NSString stringWithFormat:L(@"Error: %@"), a.error] : L(@"Not installed · ~2.7 GB");
        NSButton *dl = OVSmallPill(OVPrimaryButton(L(@"Download"), self, @selector(installAccent:)));
        dl.enabled = [OVRuntime shared].state == OVRuntimeReady && ![OVWorker shared].busy;
        [self.accentButtons addArrangedSubview:dl];
    }
}

- (void)installAccent:(id)s { [[OVNativeAccent shared] install]; }

- (void)removeAccent:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Delete accent removal (Seed-VC)?");
    a.informativeText = L(@"About 2.7 GB is freed. The files will be moved to the Trash; download it again any time.");
    [a addButtonWithTitle:L(@"Move to Trash")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.buttons.firstObject.hasDestructiveAction = YES;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSError *err = nil;
    if (![[OVNativeAccent shared] remove:&err] && err) [[NSAlert alertWithError:err] runModal];
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
    [list addArrangedSubview:row];
    OVFillWidth(@[row], list);
}

- (NSArray<OVModel *> *)visibleCatalog {
    OVModels *mm = [OVModels shared];
    return [[mm catalogOfKind:self.catalogKind.selectedIndex == 0 ? OVModelLoRA : OVModelTTS]
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
        self.emptyState = nil;
        if (!catalog.count) {
            NSStackView *empty = OVVStack(@[OVEmptyState(@"shippingbox", L(@"The catalog is empty"),
                                                        L(@"Press Refresh to load it from Hugging Face."),
                                                        @[OVGhostButton(L(@"Refresh"), @"arrow.clockwise", self, @selector(refreshCatalog:))])], 0);
            empty.alignment = NSLayoutAttributeCenterX;
            empty.edgeInsets = NSEdgeInsetsMake(28, 0, 28, 0);
            [self.catalogList addArrangedSubview:empty];
            OVFillWidth(@[empty], self.catalogList);
            self.emptyState = empty;
        }
    } else {
        [self.rows[kNoLoRA] update:nil];
        for (OVModel *m in mm.all) [self.rows[m.repo] update:m];
    }
    self.emptyState.hidden = mm.catalogLoading;

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
