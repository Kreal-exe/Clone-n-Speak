#import "OVPages.h"
#import "OVDesign.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVNetwork.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVMemory.h"

#pragma mark - Palette tile

/// One palette in the picker: a swatch strip (background, surface, accent dot, CTA bar) and the title. A radio button of a radio group.
@interface OVPaletteTile : NSControl
@property (copy) NSString *paletteId, *paletteTitle;
@property (nonatomic) BOOL selected;
@property NSInteger position, count;                 // for the accessibility help text
@property (copy) void (^moveBy)(NSInteger delta);    // ←/→ from this tile
@end

@implementation OVPaletteTile
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        self.focusRingType = NSFocusRingTypeDefault;
        [self setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.heightAnchor constraintEqualToConstant:84].active = YES;
        [self.widthAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(132, 84); }
- (BOOL)acceptsFirstResponder { return self.selected; }   // the group is one Tab stop: the selected tile
- (BOOL)isFlipped { return NO; }
- (void)setSelected:(BOOL)s { _selected = s; self.needsDisplay = YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill]; }
- (void)mouseDown:(NSEvent *)e {
    [self sendAction:self.action to:self.target];
    [self.window makeFirstResponder:self];
}
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 49 || e.keyCode == 36 || e.keyCode == 76) [self sendAction:self.action to:self.target];
    else if (e.keyCode == 123) { if (self.moveBy) self.moveBy(-1); }
    else if (e.keyCode == 124) { if (self.moveBy) self.moveBy(1); }
    else if (e.keyCode == 126) { if (self.moveBy) self.moveBy(-4); }
    else if (e.keyCode == 125) { if (self.moveBy) self.moveBy(4); }
    else [super keyDown:e];
}
- (void)drawRect:(NSRect)dirty {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                == NSAppearanceNameDarkAqua;
    NSArray<NSColor *> *sw = [OVTheme swatchesForPalette:self.paletteId dark:dark];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:b xRadius:12 yRadius:12];
    [NSGraphicsContext saveGraphicsState];
    [OVColor(OVRoleSurface) setFill];
    [outline fill];
    [outline addClip];
    CGFloat stripH = 52;
    if (sw.count == 4) {
        NSRect strip = NSMakeRect(NSMinX(b), NSMaxY(b) - stripH, NSWidth(b), stripH);
        [sw[0] setFill];
        NSRectFill(strip);
        NSRect bar = NSMakeRect(NSMinX(b) + 10, NSMaxY(b) - stripH + 10, NSWidth(b) - 20, stripH - 20);
        [sw[1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:6 yRadius:6] fill];
        [sw[2] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(bar) + 8, NSMidY(bar) - 4, 8, 8)] fill];
        [sw[3] setFill];
        CGFloat ctaW = MIN(36, NSWidth(bar) - 40);
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMaxX(bar) - 8 - ctaW, NSMidY(bar) - 4, ctaW, 8) xRadius:4 yRadius:4] fill];
    }
    [NSGraphicsContext restoreGraphicsState];

    // caption
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName: OVColor(OVRoleText), NSParagraphStyleAttributeName: ps};
    CGFloat capH = NSHeight(b) - stripH, th = ceil([self.paletteTitle sizeWithAttributes:attrs].height);
    CGFloat right = self.selected ? 30 : 10;
    [self.paletteTitle drawInRect:NSMakeRect(NSMinX(b) + 10, NSMinY(b) + round((capH - th) / 2), MAX(0, NSWidth(b) - 10 - right), th)
                   withAttributes:attrs];

    // border
    if (self.selected) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:12 yRadius:12];
        ring.lineWidth = 2;
        [OVColor(OVRoleFocus) setStroke];
        [ring stroke];
        NSColor *tint = [OVColor(OVRoleFocus) colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: OVColor(OVRoleFocus);
        NSImage *img = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:nil];
        img = [img imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold]
                                                 configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:tint]]];
        NSSize sz = img.size;
        [img drawInRect:NSMakeRect(NSMaxX(b) - 8 - sz.width, NSMinY(b) + round((capH - sz.height) / 2), sz.width, sz.height)];
    } else {
        NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:b xRadius:12 yRadius:12];
        ring.lineWidth = 1;
        [OVColor(OVRoleBorder) setStroke];
        [ring stroke];
    }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioButtonRole; }
- (NSString *)accessibilityLabel { return self.paletteTitle; }
- (id)accessibilityValue { return @(self.selected); }
- (NSString *)accessibilityHelp { return [NSString stringWithFormat:L(@"%ld of %ld"), (long)self.position, (long)self.count]; }
- (BOOL)accessibilityPerformPress { [self sendAction:self.action to:self.target]; return YES; }
@end

#pragma mark - Settings

static NSTextField *MonoMuted(NSString *text) {
    NSTextField *l = OVWrapLabel(text, 13, nil);
    l.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    l.selectable = YES;
    l.lineBreakMode = NSLineBreakByCharWrapping;   // a long path wraps instead of widening the window
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

static NSStackView *CardColumn(NSArray<NSView *> *cards) {
    NSStackView *s = OVVStack(cards, 16);
    OVFillWidth(cards, s);
    return s;
}

static NSStackView *Rows(NSArray<NSView *> *rows, CGFloat gap) {
    NSStackView *s = OVVStack(rows, gap);
    OVFillWidth(rows, s);
    return s;
}

@interface OVSettingsPage ()
@property NSMutableArray<OVSliderRow *> *sliders;
@property NSMutableDictionary<NSString *, NSButton *> *checks;  // defaults key → checkbox
@property NSTextField *seedField, *engineInfo;
@property NSStackView *engineButtons, *engineStatus;
@property OVSegmented *tabs;
@property NSArray<NSView *> *tabViews;
@property NSArray<NSString *> *tabIds;
@property NSMutableArray<OVPaletteTile *> *tiles;
@property NSString *pendingPalette;
@property NSTextField *previewValue;
@property NSStackView *engineEnvs;
@end

@implementation OVSettingsPage

- (void)loadView {
    self.sliders = [NSMutableArray array];
    self.checks = [NSMutableDictionary dictionary];
    self.tiles = [NSMutableArray array];

    self.tabIds = @[@"general", @"appearance", @"audio", @"storage", @"updates"];
    self.tabViews = @[[self generalTab], [self appearanceTab], [self audioTab], [self storageTab], [self updatesTab]];

    self.tabs = [OVSegmented segmentedWithItems:@[@[L(@"General"), @"slider.horizontal.3"], @[L(@"Appearance"), @"paintpalette"],
                                                  @[L(@"Audio"), @"waveform"], @[L(@"Storage"), @"internaldrive"],
                                                  @[L(@"Updates"), @"arrow.triangle.2.circlepath"]]];
    self.tabs.target = self;
    self.tabs.action = @selector(tabPicked:);
    self.tabs.accessibilityLabel = L(@"Settings sections");
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger cur = [self.tabIds indexOfObject:[d stringForKey:@"OVSettingsTab"] ?: [d stringForKey:@"settingsTab"] ?: @"general"];
    [self showTab:cur == NSNotFound ? 0 : cur];

    NSView *header = OVPageHeader(L(@"Settings"), L(@"Language, appearance, generation, memory and the engine."), nil);
    NSMutableArray *views = [NSMutableArray arrayWithObjects:header, OVHStack(@[self.tabs, OVSpacer()], 0), nil];
    [views addObjectsFromArray:self.tabViews];
    self.view = OVPageScroll(views);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshEngine) name:OVRuntimeDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(syncTiles) name:OVThemeDidChangeNotification object:nil];
    [self refreshEngine];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [NSObject cancelPreviousPerformRequestsWithTarget:self]; }

- (void)showTab:(NSInteger)i {
    self.tabs.selectedIndex = i;
    for (NSUInteger k = 0; k < self.tabViews.count; k++) self.tabViews[k].hidden = (NSInteger)k != i;
}

- (void)tabPicked:(OVSegmented *)s {
    NSInteger i = MAX(0, s.selectedIndex);
    [NSUserDefaults.standardUserDefaults setObject:self.tabIds[i] forKey:@"settingsTab"];
    [self showTab:i];
}

#pragma mark Tabs

- (NSView *)generalTab {
    OVPopup *uiLang = [OVPopup popup];
    for (NSArray *it in @[@[L(@"System"), @"system"], @[@"English", @"en"], @[@"Русский", @"ru"]]) {
        [uiLang addItemWithTitle:it[0]];
        uiLang.lastItem.representedObject = it[1];
    }
    [uiLang selectItemAtIndex:MAX(0, [uiLang indexOfItemWithRepresentedObject:[OVLocale uiLanguageSetting]])];
    uiLang.target = self;
    uiLang.action = @selector(uiLanguagePicked:);
    NSView *interface = OVStepCard(0, @"globe", L(@"Interface"), nil,
        OVFieldBlock(L(@"Interface language"), L(@"Language of the menus, buttons and hints. “System” follows your Mac."), uiLang));

    NSButton *autoPlay = OVCheckbox(L(@"Play the result as soon as it’s ready"), @"autoPlay");
    self.checks[@"autoPlay"] = autoPlay;
    NSView *playback = OVStepCard(0, @"play.circle", L(@"Playback"), nil, autoPlay);

    OVSliderRow *attempts = [OVSliderRow rowWithTitle:L(@"Takes per phrase") hint:L(@"How many takes of each phrase are compared. The best one is kept: fewest recognition errors, most native pronunciation, most like the sample, dictionary stress.")
                                                  key:@"improveAttempts" min:1 max:5 format:@"%.0f" integer:YES];
    OVSliderRow *threshold = [OVSliderRow rowWithTitle:L(@"Allowed mismatch") hint:L(@"Share of characters that may differ between the text and what Whisper hears. Lower is stricter.")
                                                   key:@"improveThreshold" min:0.02 max:0.25 format:@"%.2f" integer:NO];
    [self.sliders addObjectsFromArray:@[attempts, threshold]];
    NSButton *prepare = OVCheckbox(L(@"Prepare Ukrainian text: abbreviations, years, units, apostrophes"), @"prepareText");
    self.checks[@"prepareText"] = prepare;
    NSView *improve = OVStepCard(0, @"sparkles", L(@"Auto-improve"),
        L(@"Switch it on next to the Speak button. Each phrase is spoken several times and the best take is kept — slower, but the stress, the accent and the likeness come out best."),
        Rows(@[attempts, threshold, prepare], 16));
    OVSwitch *offline = [OVSwitch new];
    offline.on = OVNetwork.offline;
    offline.target = self;
    offline.action = @selector(offlineToggled:);
    offline.accessibilityLabel = L(@"Offline mode");
    NSTextField *offlineTitle = OVWrapLabel(L(@"Offline mode"), 14, nil);
    offlineTitle.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    NSTextField *offlineHint = OVWrapLabel(L(@"Turns off Edge TTS, YouTube import, Bridge and plugin network access. Model downloads you start yourself still work."), 13, OVColor(OVRoleMuted));
    NSStackView *offlineTexts = OVVStack(@[offlineTitle, offlineHint], 2);
    OVFillWidth(@[offlineTitle, offlineHint], offlineTexts);
    NSButton *resetNet = OVGhostButton(L(@"Reset network permissions"), @"arrow.counterclockwise", self, @selector(resetNetworkPermissions:));
    resetNet.toolTip = L(@"Forget what you agreed to share. Each network feature asks again the next time you use it.");
    NSView *offlineCard = OVStepCard(0, @"wifi.slash", L(@"Offline mode"), nil,
        Rows(@[OVHStack(@[offline, offlineTexts], 12), OVHStack(@[resetNet, OVSpacer()], 0)], 12));
    return CardColumn(@[interface, playback, improve, offlineCard]);
}

- (void)resetNetworkPermissions:(id)s {
    for (OVNetFeature f = OVNetEdgeTTS; f <= OVNetPluginNetwork; f++) [OVNetwork revokeConsentFor:f];
}

- (void)offlineToggled:(OVSwitch *)s {
    [OVNetwork setOffline:s.on];
}

- (NSView *)appearanceTab {
    OVSegmented *theme = [OVSegmented segmentedWithItems:@[@[L(@"Light"), @"sun.max.fill"], @[L(@"Dark"), @"moon.fill"],
                                                           @[L(@"System"), @"circle.lefthalf.filled"]]];
    NSInteger ti = [@[@"light", @"dark", @"system"] indexOfObject:[OVLocale themeSetting]];
    theme.selectedIndex = ti == NSNotFound ? 2 : ti;
    theme.target = self;
    theme.action = @selector(themePicked:);
    theme.accessibilityLabel = L(@"Mode");
    NSView *mode = OVStepCard(0, @"circle.lefthalf.filled", L(@"Mode"), L(@"“System” follows macOS."), OVHStack(@[theme, OVSpacer()], 0));

    NSArray<NSDictionary *> *pals = [OVTheme palettes];
    NSMutableArray<NSStackView *> *rows = [NSMutableArray array];
    NSMutableArray<OVPaletteTile *> *all = [NSMutableArray array];
    for (NSUInteger i = 0; i < pals.count; i++) {
        OVPaletteTile *t = [[OVPaletteTile alloc] initWithFrame:NSMakeRect(0, 0, 132, 84)];
        t.paletteId = pals[i][@"id"];
        t.paletteTitle = pals[i][@"title"];
        t.position = i + 1;
        t.count = pals.count;
        t.target = self;
        t.action = @selector(palettePicked:);
        __weak OVSettingsPage *ws = self;
        __weak OVPaletteTile *wt = t;
        t.moveBy = ^(NSInteger delta) { [ws moveTile:wt by:delta]; };
        [all addObject:t];
        [self.tiles addObject:t];
    }
    for (NSUInteger i = 0; i < all.count; i += 4) {
        NSStackView *row = OVHStack([all subarrayWithRange:NSMakeRange(i, MIN(4, all.count - i))], 12);
        row.distribution = NSStackViewDistributionFillEqually;
        [rows addObject:row];
    }
    NSStackView *grid = OVVStack(rows, 12);
    OVFillWidth(rows, grid);
    grid.accessibilityRole = NSAccessibilityRadioGroupRole;
    grid.accessibilityLabel = L(@"Color palette");
    [self syncTiles];
    NSView *palette = OVStepCard(0, @"paintpalette", L(@"Color palette"), L(@"Applies to the whole app at once."), grid);

    // live sample: not bound to any setting
    OVSlider *sl = [OVSlider new];
    sl.minValue = 0; sl.maxValue = 1; sl.doubleValue = 0.4;
    sl.target = self; sl.action = @selector(previewSlid:);
    sl.accessibilityLabel = L(@"Sample slider");
    self.previewValue = OVLabel(@"0.40", 13, NSFontWeightSemibold, nil);
    NSView *sliderRow = OVHStack(@[OVLabel(L(@"Sample slider"), 14, NSFontWeightSemibold, nil), sl, self.previewValue], 12);
    OVSegmented *sample = [OVSegmented segmentedWithItems:@[@[L(@"First"), @""], @[L(@"Second"), @""], @[L(@"Third"), @""]]];
    sample.selectedIndex = 0;
    NSView *sampleHeader = OVCardHeader(0, @"waveform", L(@"Sample card"), OVBadge(L(@"Ready"), OVRoleOK));
    NSView *buttons = OVHStack(@[OVPrimaryButton(L(@"Primary action"), nil, nil), OVGhostButton(L(@"Secondary"), nil, nil, nil), OVSpacer()], 8);
    NSView *badges = OVHStack(@[OVBadge(L(@"Accent"), OVRoleAccent), OVBadge(L(@"Warning"), OVRoleWarn), OVBadge(L(@"Error"), OVRoleErr), OVSpacer()], 8);
    NSView *preview = OVStepCard(0, @"eye", L(@"Preview"), L(@"A live sample of the colors, so you can see a palette before you leave this page."),
        Rows(@[sampleHeader, buttons, badges, sliderRow, OVHStack(@[sample, OVSpacer()], 0)], 16));
    return CardColumn(@[mode, palette, preview]);
}

- (NSView *)audioTab {
    NSArray *specs = @[
        @[L(@"Decoding steps"), L(@"Higher is cleaner and more stable, but slower. 32 is standard."), @"numStep", @8, @64, @"%.0f", @YES],
        @[L(@"Speech rate"), L(@"1.0 is the natural pace as judged by the model."), @"speed", @0.7, @1.4, @"%.2f×", @NO],
        @[L(@"Text guidance strength"), L(@"Higher gives crisper diction, lower gives more natural intonation."), @"guidance", @1, @4, @"%.1f", @NO],
        @[L(@"Schedule shift (t_shift)"), L(@"Fine-tunes the noise schedule. Default is 0.1."), @"tShift", @0.05, @1, @"%.2f", @NO],
        @[L(@"Token temperature"), L(@"0 is deterministic. 0.3–0.7 adds more variety."), @"classTemp", @0, @1.5, @"%.2f", @NO],
        @[L(@"Position temperature"), L(@"Order in which tokens are revealed. Default is 5."), @"posTemp", @0, @10, @"%.1f", @NO],
        @[L(@"Codebook layer penalty"), L(@"Default is 5."), @"layerPenalty", @0, @10, @"%.1f", @NO],
    ];
    NSMutableArray *basic = [NSMutableArray array], *advanced = [NSMutableArray array];
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSArray *s = specs[i];
        OVSliderRow *r = [OVSliderRow rowWithTitle:s[0] hint:s[1] key:s[2] min:[s[3] doubleValue] max:[s[4] doubleValue]
                                            format:s[5] integer:[s[6] boolValue]];
        [self.sliders addObject:r];
        [i < 2 ? basic : advanced addObject:r];
    }
    NSMutableArray *gen = [NSMutableArray arrayWithArray:basic];
    for (NSArray *c in @[@[L(@"Read numbers as words (2025 → дві тисячі двадцять п’ять)"), @"normalizeText"],
                         @[L(@"Remove the sample’s accent when the text is in another language (learned once per voice, about a minute)"), @"adaptAccent"]]) {
        NSButton *b = OVCheckbox(c[0], c[1]);
        self.checks[c[1]] = b;
        [gen addObject:b];
    }
    [gen addObject:OVWrapLabel(L(@"Mood, intonation, energy, pitch, tone, pauses and volume are on the Speech page, under the masks button."), 13, nil)];

    self.seedField = OVField(@"-1");
    self.seedField.stringValue = [NSString stringWithFormat:@"%ld", (long)[NSUserDefaults.standardUserDefaults integerForKey:@"seed"]];
    self.seedField.target = self;
    self.seedField.action = @selector(seedChanged:);
    self.seedField.cell.sendsActionOnEndEditing = YES;  // saved when focus leaves too, not only on Return
    self.seedField.accessibilityLabel = L(@"Seed");
    [self.seedField.widthAnchor constraintEqualToConstant:140].active = YES;
    [advanced addObject:OVFieldBlock(L(@"Seed"), L(@"-1 gives a different result each time. A number gives a repeatable result."),
                                     OVHStack(@[self.seedField, OVSpacer()], 0))];
    NSStackView *advBox = Rows(advanced, 16);
    OVDisclosure *disc = [OVDisclosure disclosureWithTitle:L(@"Advanced generation") subtitle:nil symbol:@"slider.horizontal.3" content:advBox];
    [gen addObject:disc];
    NSButton *reset = OVGhostButton(L(@"Restore defaults"), @"arrow.counterclockwise", self, @selector(resetGeneration:));
    [gen addObject:OVHStack(@[reset, OVSpacer()], 0)];
    NSView *generation = OVStepCard(0, @"waveform", L(@"Generation"), nil, Rows(gen, 16));

    OVPopup *precision = OVDefaultsPopup(@[@[L(@"Automatic — the best that fits on this Mac"), @"0"],
                                           @[L(@"16-bit — best quality, ~3 GB while speaking"), @"16"],
                                           @[L(@"8-bit — ~2.3 GB while speaking"), @"8"],
                                           @[L(@"4-bit — ~2 GB, noticeably worse"), @"4"]],
                                         @"precision", self, @selector(deviceChanged:));
    OVPopup *asrPrecision = OVDefaultsPopup(@[@[L(@"Automatic — the best that fits on this Mac"), @"0"],
                                              @[L(@"16-bit — most accurate, ~1.9 GB"), @"16"],
                                              @[L(@"8-bit — ~1.2 GB, same accuracy in tests"), @"8"],
                                              @[L(@"4-bit — ~0.7 GB, more mistakes"), @"4"]],
                                            @"asrPrecision", nil, nil);
    OVPopup *idle = OVDefaultsPopup(@[@[L(@"after 1 minute"), @"1"], @[L(@"after 3 minutes"), @"3"], @[L(@"after 10 minutes"), @"10"],
                                      @[L(@"after 30 minutes"), @"30"], @[L(@"never"), @"0"]],
                                    @"idleUnloadMinutes", nil, nil);
    NSButton *lowMem = OVCheckbox(L(@"Memory saver: never keep Whisper and the voice model in memory together"), @"lowMemory");
    self.checks[@"lowMemory"] = lowMem;
    NSString *ramNote = [NSString stringWithFormat:L(@"This Mac has %.0f GB of unified memory, %@ free now. Automatic precision: voice model %ld-bit, Whisper %ld-bit. Speech recognition and synthesis take turns in memory, so only one model is loaded at a time."),
                         [OVSettings physicalMemoryGB], [OVMemory format:[OVMemory availableBytes]], (long)[OVSettings ttsBits], (long)[OVSettings asrBits]];
    NSView *memory = OVStepCard(0, @"memorychip", L(@"Memory & speed"), nil, Rows(@[
        OVFieldBlock(L(@"Voice model precision"), nil, precision),
        OVFieldBlock(L(@"Whisper precision"), nil, asrPrecision),
        OVFieldBlock(L(@"Free memory when idle"), nil, idle),
        lowMem,
        OVWrapLabel(ramNote, 13, nil)], 16));
    return CardColumn(@[generation, memory]);
}

- (NSView *)storageTab {
    NSButton *openOut = OVGhostButton(L(@"Recordings folder"), @"folder", self, @selector(openOutputs:));
    NSButton *openData = OVGhostButton(L(@"App folder"), @"folder", self, @selector(openSupport:));
    NSView *rec = Rows(@[OVLabel(L(@"Recordings"), 14, NSFontWeightSemibold, nil), MonoMuted([[OVPaths outputs] stringByAbbreviatingWithTildeInPath])], 6);
    NSView *app = Rows(@[OVLabel(L(@"Voices, models and Python"), 14, NSFontWeightSemibold, nil),
                         MonoMuted([[OVPaths support] stringByAbbreviatingWithTildeInPath])], 6);
    NSView *files = OVStepCard(0, @"folder", L(@"Files"), nil, Rows(@[rec, app, OVHStack(@[openOut, openData, OVSpacer()], 8)], 16));
    return CardColumn(@[files]);
}

- (NSView *)updatesTab {
    self.engineInfo = OVWrapLabel(@"", 12, OVColor(OVRoleText));
    self.engineInfo.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.engineInfo.selectable = YES;
    [self.engineInfo setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.engineStatus = OVHStack(@[], 8);
    self.engineButtons = OVVStack(@[], 8);   // two rows, so the card fits the narrowest window
    self.engineButtons.alignment = NSLayoutAttributeLeading;
    self.engineEnvs = OVVStack(@[], 6);
    NSView *engine = OVStepCard(0, @"cpu", L(@"Python engine"), nil, Rows(@[self.engineStatus, self.engineInfo, self.engineEnvs, self.engineButtons], 16));
    return CardColumn(@[engine]);
}

#pragma mark Palette

- (void)syncTiles {
    NSString *cur = self.pendingPalette ?: [OVTheme paletteId];
    for (OVPaletteTile *t in self.tiles) t.selected = [t.paletteId isEqualToString:cur];
}

- (void)previewSlid:(NSSlider *)s { self.previewValue.stringValue = [NSString stringWithFormat:@"%.2f", s.doubleValue]; }

- (void)palettePicked:(OVPaletteTile *)t {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPendingPalette) object:nil];   // a click wins over a pending arrow-key choice
    self.pendingPalette = nil;
    if ([t.paletteId isEqualToString:[OVTheme paletteId]]) return;
    [OVTheme setPaletteId:t.paletteId];
    [self syncTiles];
}

/// Arrow keys: the tile selection follows at once, the app-wide repaint waits for the key-repeat burst to end.
- (void)applyPendingPalette {
    NSString *pid = self.pendingPalette;
    self.pendingPalette = nil;
    if (pid && ![pid isEqualToString:[OVTheme paletteId]]) [OVTheme setPaletteId:pid];
}

- (void)moveTile:(OVPaletteTile *)t by:(NSInteger)delta {
    NSInteger i = (NSInteger)[self.tiles indexOfObject:t] + delta;
    if (i < 0 || i >= (NSInteger)self.tiles.count || i == (NSInteger)[self.tiles indexOfObject:t]) return;
    OVPaletteTile *n = self.tiles[i];
    for (OVPaletteTile *o in self.tiles) o.selected = o == n;
    self.pendingPalette = n.paletteId;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applyPendingPalette) object:nil];
    [self performSelector:@selector(applyPendingPalette) withObject:nil afterDelay:0.08];
    [n.window makeFirstResponder:n];
}

#pragma mark Refresh

/// Speed, quality and accent removal can also be changed on the Speech page.
- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshControls];
    [self syncTiles];
}

- (void)refreshControls {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (OVSliderRow *r in self.sliders) [r refresh];
    [self.checks enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSButton *b, BOOL *stop) {
        b.state = [d boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    self.seedField.stringValue = [NSString stringWithFormat:@"%ld", (long)[d integerForKey:@"seed"]];
}

- (void)refreshEngine {
    OVRuntime *rt = [OVRuntime shared];
    NSMutableString *s = [NSMutableString string];
    NSString *badge = nil;
    OVRole tone = OVRoleMuted;
    switch (rt.state) {
        case OVRuntimeReady:
            [s appendFormat:@"%@ · Python %@ · MLX %@ · mlx-audio %@ · %@\n%@",
             rt.sourceName, rt.info[@"python"], rt.info[@"mlx"], rt.info[@"mlx_audio"],
             [rt.info[@"metal"] boolValue] ? L(@"Apple GPU (Metal)") : L(@"CPU only"), rt.pythonPath];
            badge = L(@"Ready"); tone = OVRoleOK;
            break;
        case OVRuntimeInstalling: [s appendFormat:L(@"Installing: %@"), rt.stepTitle]; badge = L(@"Installing"); tone = OVRoleAccent; break;
        case OVRuntimeChecking: [s appendString:L(@"Searching…")]; badge = L(@"Searching"); tone = OVRoleMuted; break;
        case OVRuntimeFailed: [s appendString:rt.errorText ?: L(@"OmniVoice not found.")]; badge = L(@"Failed"); tone = OVRoleErr; break;
        default: [s appendString:rt.errorText ?: L(@"OmniVoice not found.")]; badge = L(@"Missing"); tone = OVRoleWarn; break;
    }
    if (rt.customPython.length) [s appendFormat:L(@"\n\nChosen manually: %@"), rt.customPython];
    self.engineInfo.stringValue = s;
    for (NSView *v in self.engineEnvs.arrangedSubviews.copy) [v removeFromSuperview];
    if (rt.candidates.count) {
        [self.engineEnvs addArrangedSubview:OVLabel([L(@"\n\nChecked environments:") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                                                    14, NSFontWeightSemibold, nil)];
        for (NSDictionary *c in rt.candidates) {
            BOOL ok = [c[@"ok"] boolValue], checked = [c[@"checked"] boolValue];
            NSTextField *l = OVWrapLabel([NSString stringWithFormat:@"%@ — %@", c[@"source"], [c[@"path"] stringByAbbreviatingWithTildeInPath]], 12, nil);
            l.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
            l.selectable = YES;
            l.lineBreakMode = NSLineBreakByCharWrapping;
            [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSView *badge = OVCompactBadge(ok ? L(@"OK") : checked ? L(@"Failed") : L(@"Not checked"), ok ? OVRoleOK : checked ? OVRoleErr : OVRoleMuted);
            [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [badge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSStackView *row = OVVStack(@[badge, l], 4);   // the path wraps under its badge, so the badge is never squeezed
            row.alignment = NSLayoutAttributeLeading;
            [l.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor].active = YES;
            [self.engineEnvs addArrangedSubview:row];
        }
    }

    for (NSView *v in self.engineStatus.arrangedSubviews.copy) [v removeFromSuperview];
    [self.engineStatus addArrangedSubview:OVBadge(badge, tone)];
    [self.engineStatus addArrangedSubview:OVSpacer()];

    for (NSView *v in self.engineButtons.arrangedSubviews.copy) [v removeFromSuperview];
    BOOL installing = rt.state == OVRuntimeInstalling;
    NSMutableArray *bs = [NSMutableArray arrayWithArray:@[OVGhostButton(L(@"Search again"), @"magnifyingglass", self, @selector(redetect:)),
                                                          OVGhostButton(L(@"Choose Python…"), @"folder", self, @selector(choosePython:))]];
    if (rt.customPython.length) [bs addObject:OVGhostButton(L(@"Clear selection"), @"xmark", self, @selector(clearPython:))];
    [bs addObject:OVPrimaryButton(installing ? L(@"Installing…") : L(@"Install own environment"), self, @selector(install:))];
    NSMutableArray *top = [NSMutableArray array];
    for (NSButton *b in bs) b.enabled = !installing || b.action == @selector(redetect:);
    for (NSButton *b in [bs subarrayWithRange:NSMakeRange(0, bs.count - 1)]) [top addObject:b];
    [self.engineButtons addArrangedSubview:OVHStack(top, 8)];
    [self.engineButtons addArrangedSubview:bs.lastObject];
}

#pragma mark Actions

- (void)uiLanguagePicked:(NSPopUpButton *)p { [OVLocale setUILanguageSetting:p.selectedItem.representedObject]; }
- (void)themePicked:(OVSegmented *)s {
    if (s.selectedIndex < 0) return;
    [OVLocale setThemeSetting:@[@"light", @"dark", @"system"][s.selectedIndex]];
}


- (void)seedChanged:(NSTextField *)f {
    [NSUserDefaults.standardUserDefaults setInteger:f.integerValue forKey:@"seed"];
    f.stringValue = [NSString stringWithFormat:@"%ld", (long)f.integerValue];
}

- (void)resetGeneration:(id)s {
    for (NSString *k in @[@"numStep", @"guidance", @"speed", @"tShift", @"classTemp", @"posTemp", @"layerPenalty",
                          @"normalizeText", @"adaptAccent", @"seed",
                          @"improveAttempts", @"improveThreshold", @"prepareText"])
        [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
    [self refreshControls];
}

- (void)deviceChanged:(id)s { if (![OVWorker shared].busy) [[OVWorker shared] stop]; }
- (void)redetect:(id)s { [[OVWorker shared] stop]; [[OVRuntime shared] detect]; }
- (void)clearPython:(id)s { [OVRuntime shared].customPython = nil; [self redetect:nil]; }
- (void)install:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Install a separate environment?");
    a.informativeText = L(@"Python, MLX and OmniVoice (~360 MB) will be downloaded to the app folder.");
    [a addButtonWithTitle:L(@"Install")];
    [a addButtonWithTitle:L(@"Cancel")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [[OVWorker shared] stop];
    [OVRuntime shared].customPython = nil;
    [[OVRuntime shared] install];
    OVNavigate(@"setup");
}
- (void)choosePython:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = L(@"Choose the python of an environment with OmniVoice installed (…/.venv/bin/python)");
    p.showsHiddenFiles = YES;
    p.treatsFilePackagesAsDirectories = YES;
    if ([p runModal] != NSModalResponseOK) return;
    [OVRuntime shared].customPython = p.URL.path;
    [self redetect:nil];
}
- (void)openOutputs:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths outputs]]]; }
- (void)openSupport:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths support]]]; }
@end
