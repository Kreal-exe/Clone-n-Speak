#import "OVPages.h"
#import "OVUI.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVMemory.h"

@interface OVSettingsPage ()
@property NSMutableArray<OVSliderRow *> *sliders;
@property NSMutableDictionary<NSString *, NSButton *> *checks;  // defaults key → checkbox
@property NSTextField *seedField, *engineInfo;
@property NSStackView *engineButtons;
@end

@implementation OVSettingsPage

- (void)loadView {
    self.sliders = [NSMutableArray array];
    self.checks = [NSMutableDictionary dictionary];
    NSStackView *page = OVVStack(@[], 14);
    page.edgeInsets = NSEdgeInsetsMake(30, 32, 30, 32);

    // --- generation
    NSArray *specs = @[
        @[L(@"Decoding steps"), L(@"Higher is cleaner and more stable, but slower. 32 is standard."), @"numStep", @8, @64, @"%.0f", @YES],
        @[L(@"Text guidance strength"), L(@"Higher gives crisper diction, lower gives more natural intonation."), @"guidance", @1, @4, @"%.1f", @NO],
        @[L(@"Speech rate"), L(@"1.0 is the natural pace as judged by the model."), @"speed", @0.7, @1.4, @"%.2f×", @NO],
        @[L(@"Schedule shift (t_shift)"), L(@"Fine-tunes the noise schedule. Default is 0.1."), @"tShift", @0.05, @1, @"%.2f", @NO],
        @[L(@"Token temperature"), L(@"0 is deterministic. 0.3–0.7 adds more variety."), @"classTemp", @0, @1.5, @"%.2f", @NO],
        @[L(@"Position temperature"), L(@"Order in which tokens are revealed. Default is 5."), @"posTemp", @0, @10, @"%.1f", @NO],
        @[L(@"Codebook layer penalty"), L(@"Default is 5."), @"layerPenalty", @0, @10, @"%.1f", @NO],
    ];
    NSMutableArray *genRows = [NSMutableArray array];
    for (NSArray *s in specs) {
        OVSliderRow *r = [OVSliderRow rowWithTitle:s[0] hint:s[1] key:s[2] min:[s[3] doubleValue] max:[s[4] doubleValue]
                                            format:s[5] integer:[s[6] boolValue]];
        [self.sliders addObject:r];
        [genRows addObject:r];
    }
    for (NSArray *c in @[@[L(@"Read numbers as words (2025 → дві тисячі двадцять п’ять)"), @"normalizeText"],
                         @[L(@"Remove the sample’s accent when the text is in another language (learned once per voice, about a minute)"), @"adaptAccent"]]) {
        NSButton *b = OVCheckbox(c[0], c[1]);
        self.checks[c[1]] = b;
        [genRows addObject:b];
    }
    [genRows addObject:OVWrapLabel(L(@"Mood, intonation, energy, pitch, tone, pauses and volume are on the Speech page, under the masks button."), 11.5, nil)];
    self.seedField = OVField(@"-1");
    self.seedField.stringValue = [NSString stringWithFormat:@"%ld", (long)[NSUserDefaults.standardUserDefaults integerForKey:@"seed"]];
    self.seedField.target = self;
    self.seedField.action = @selector(seedChanged:);
    [self.seedField.widthAnchor constraintEqualToConstant:90].active = YES;
    NSStackView *seedLeft = OVVStack(@[OVLabel(@"Seed", 13, NSFontWeightMedium, nil),
                                       OVWrapLabel(L(@"-1 gives a different result each time. A number gives a repeatable result."), 11, nil)], 2);
    [seedLeft.widthAnchor constraintEqualToConstant:210].active = YES;
    [genRows addObject:OVHStack(@[seedLeft, self.seedField], 12)];
    NSButton *reset = OVButton(L(@"Restore defaults"), self, @selector(resetGeneration:));
    reset.controlSize = NSControlSizeRegular;
    [genRows addObject:reset];
    NSStackView *genBox = OVVStack(genRows, 14);
    OVFillWidth(self.sliders, genBox);

    // --- interface
    NSPopUpButton *uiLang = [NSPopUpButton new];
    for (NSArray *it in @[@[L(@"System"), @"system"], @[@"English", @"en"], @[@"Русский", @"ru"]]) {
        [uiLang addItemWithTitle:it[0]];
        uiLang.lastItem.representedObject = it[1];
    }
    [uiLang selectItemAtIndex:MAX(0, [uiLang indexOfItemWithRepresentedObject:[OVLocale uiLanguageSetting]])];
    uiLang.target = self;
    uiLang.action = @selector(uiLanguagePicked:);
    NSSegmentedControl *theme = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:L(@"Light")],
        [NSImage imageWithSystemSymbolName:@"moon.fill" accessibilityDescription:L(@"Dark")],
        [NSImage imageWithSystemSymbolName:@"circle.lefthalf.filled" accessibilityDescription:L(@"System")]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(themePicked:)];
    [theme setToolTip:L(@"Light") forSegment:0];
    [theme setToolTip:L(@"Dark") forSegment:1];
    [theme setToolTip:L(@"Same as macOS") forSegment:2];
    theme.selectedSegment = [@[@"light", @"dark", @"system"] indexOfObject:[OVLocale themeSetting]];
    NSGridView *uiGrid = [NSGridView gridViewWithViews:@[
        @[OVLabel(L(@"Interface language"), 13, NSFontWeightMedium, nil), uiLang],
        @[OVLabel(L(@"Theme"), 13, NSFontWeightMedium, nil), theme],
    ]];
    uiGrid.rowSpacing = 10;
    uiGrid.columnSpacing = 14;
    [uiGrid columnAtIndex:0].width = 160;
    NSStackView *uiBox = OVVStack(@[uiGrid], 10);

    // --- auto-improve
    OVSliderRow *attempts = [OVSliderRow rowWithTitle:L(@"Attempts per phrase") hint:L(@"How many times an unclear phrase is re-spoken.")
                                                  key:@"improveAttempts" min:1 max:5 format:@"%.0f" integer:YES];
    OVSliderRow *threshold = [OVSliderRow rowWithTitle:L(@"Allowed mismatch") hint:L(@"Share of characters that may differ between the text and what Whisper hears. Lower is stricter.")
                                                   key:@"improveThreshold" min:0.02 max:0.25 format:@"%.2f" integer:NO];
    [self.sliders addObjectsFromArray:@[attempts, threshold]];
    NSButton *prepare = OVCheckbox(L(@"Prepare Ukrainian text: abbreviations, years, units, apostrophes"), @"prepareText");
    self.checks[@"prepareText"] = prepare;
    NSStackView *impBox = OVVStack(@[OVWrapLabel(L(@"Switch it on next to the Speak button. Each phrase is checked by speech recognition and unclear ones are re-spoken."), 12, nil),
                                     attempts, threshold, prepare], 14);
    OVFillWidth(@[attempts, threshold, impBox.arrangedSubviews[0]], impBox);

    // --- memory & speed
    NSPopUpButton *precision = OVDefaultsPopup(@[@[L(@"Automatic — the best that fits on this Mac"), @"0"],
                                                 @[L(@"16-bit — best quality, ~3 GB while speaking"), @"16"],
                                                 @[L(@"8-bit — ~2.3 GB while speaking"), @"8"],
                                                 @[L(@"4-bit — ~2 GB, noticeably worse"), @"4"]],
                                               @"precision", self, @selector(deviceChanged:));
    NSPopUpButton *asrPrecision = OVDefaultsPopup(@[@[L(@"Automatic — the best that fits on this Mac"), @"0"],
                                                    @[L(@"16-bit — most accurate, ~1.9 GB"), @"16"],
                                                    @[L(@"8-bit — ~1.2 GB, same accuracy in tests"), @"8"],
                                                    @[L(@"4-bit — ~0.7 GB, more mistakes"), @"4"]],
                                                  @"asrPrecision", nil, nil);
    NSPopUpButton *idle = OVDefaultsPopup(@[@[L(@"after 1 minute"), @"1"], @[L(@"after 3 minutes"), @"3"], @[L(@"after 10 minutes"), @"10"],
                                            @[L(@"after 30 minutes"), @"30"], @[L(@"never"), @"0"]],
                                          @"idleUnloadMinutes", nil, nil);
    NSButton *lowMem = OVCheckbox(L(@"Memory saver: never keep Whisper and the voice model in memory together"), @"lowMemory");
    self.checks[@"lowMemory"] = lowMem;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[OVLabel(L(@"Voice model precision"), 13, NSFontWeightMedium, nil), precision],
        @[OVLabel(L(@"Whisper precision"), 13, NSFontWeightMedium, nil), asrPrecision],
        @[OVLabel(L(@"Free memory when idle"), 13, NSFontWeightMedium, nil), idle],
    ]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 14;
    [grid columnAtIndex:0].width = 180;
    NSString *ramNote = [NSString stringWithFormat:L(@"This Mac has %.0f GB of unified memory, %@ free now. Automatic precision: voice model %ld-bit, Whisper %ld-bit. Speech recognition and synthesis take turns in memory, so only one model is loaded at a time."),
                         [OVSettings physicalMemoryGB], [OVMemory format:[OVMemory availableBytes]], (long)[OVSettings ttsBits], (long)[OVSettings asrBits]];
    NSStackView *devBox = OVVStack(@[grid, lowMem, OVWrapLabel(ramNote, 11.5, nil)], 10);

    // --- engine
    self.engineInfo = OVWrapLabel(@"", 12.5, NSColor.labelColor);
    self.engineInfo.selectable = YES;
    self.engineButtons = OVHStack(@[], 8);
    NSStackView *engBox = OVVStack(@[self.engineInfo, self.engineButtons], 12);
    OVFillWidth(@[self.engineInfo], engBox);

    // --- files
    NSButton *autoPlay = OVCheckbox(L(@"Play the result as soon as it’s ready"), @"autoPlay");
    NSButton *openOut = OVButton(L(@"Recordings folder"), self, @selector(openOutputs:));
    NSButton *openData = OVButton(L(@"App folder"), self, @selector(openSupport:));
    openOut.controlSize = openData.controlSize = NSControlSizeRegular;
    NSStackView *fileBox = OVVStack(@[autoPlay,
                                      OVWrapLabel([NSString stringWithFormat:L(@"Recordings: %@\nVoices, models and Python: %@"),
                                                   [[OVPaths outputs] stringByAbbreviatingWithTildeInPath],
                                                   [[OVPaths support] stringByAbbreviatingWithTildeInPath]], 12, nil),
                                      OVHStack(@[openOut, openData], 8)], 10);

    NSView *genCard = OVCard(genBox, 20), *devCard = OVCard(devBox, 20), *engCard = OVCard(engBox, 20), *fileCard = OVCard(fileBox, 20);
    NSView *uiCard = OVCard(uiBox, 20), *impCard = OVCard(impBox, 20);
    for (NSView *v in @[OVTitle(L(@"Settings")), OVSectionTitle(L(@"Interface")), uiCard, OVSectionTitle(L(@"Generation")), genCard,
                        OVSectionTitle(L(@"✨ Auto-improve")), impCard, OVSectionTitle(L(@"Memory & speed")), devCard,
                        OVSectionTitle(L(@"Python engine")), engCard, OVSectionTitle(L(@"Files")), fileCard]) [page addArrangedSubview:v];
    [page setCustomSpacing:20 afterView:page.arrangedSubviews[0]];
    for (NSView *c in @[uiCard, genCard, impCard, devCard, engCard]) [page setCustomSpacing:26 afterView:c];
    OVFillWidth(@[uiCard, genCard, impCard, devCard, engCard, fileCard], page);
    self.view = OVScrollPage(page);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshEngine) name:OVRuntimeDidChangeNotification object:nil];
    [self refreshEngine];
}

/// Speed, quality and accent removal can also be changed on the Speech page.
- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshControls];
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
    switch (rt.state) {
        case OVRuntimeReady:
            [s appendFormat:@"✓ %@ · Python %@ · MLX %@ · mlx-audio %@ · %@\n%@",
             rt.sourceName, rt.info[@"python"], rt.info[@"mlx"], rt.info[@"mlx_audio"],
             [rt.info[@"metal"] boolValue] ? L(@"Apple GPU (Metal)") : L(@"CPU only"), rt.pythonPath];
            break;
        case OVRuntimeInstalling: [s appendFormat:L(@"Installing: %@"), rt.stepTitle]; break;
        case OVRuntimeChecking: [s appendString:L(@"Searching…")]; break;
        default: [s appendString:rt.errorText ?: L(@"OmniVoice not found.")]; break;
    }
    if (rt.candidates.count) {
        [s appendString:L(@"\n\nChecked environments:")];
        for (NSDictionary *c in rt.candidates)
            [s appendFormat:@"\n%@ %@ — %@", [c[@"ok"] boolValue] ? @"✓" : [c[@"checked"] boolValue] ? @"✗" : @"·",
             c[@"source"], [c[@"path"] stringByAbbreviatingWithTildeInPath]];
    }
    if (rt.customPython.length) [s appendFormat:L(@"\n\nChosen manually: %@"), rt.customPython];
    self.engineInfo.stringValue = s;

    for (NSView *v in self.engineButtons.arrangedSubviews.copy) [v removeFromSuperview];
    BOOL installing = rt.state == OVRuntimeInstalling;
    NSMutableArray *bs = [NSMutableArray arrayWithArray:@[OVButton(L(@"Search again"), self, @selector(redetect:)),
                                                          OVButton(L(@"Choose Python…"), self, @selector(choosePython:))]];
    if (rt.customPython.length) [bs addObject:OVButton(L(@"Clear selection"), self, @selector(clearPython:))];
    [bs addObject:OVButton(installing ? L(@"Installing…") : L(@"Install own environment"), self, @selector(install:))];
    for (NSButton *b in bs) { b.controlSize = NSControlSizeRegular; b.enabled = !installing || b.action == @selector(redetect:); [self.engineButtons addArrangedSubview:b]; }
}

- (void)uiLanguagePicked:(NSPopUpButton *)p { [OVLocale setUILanguageSetting:p.selectedItem.representedObject]; }
- (void)themePicked:(NSSegmentedControl *)s { [OVLocale setThemeSetting:@[@"light", @"dark", @"system"][s.selectedSegment]]; }

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

#pragma mark - Log

@interface OVLogPage ()
@property NSTextView *text;
@end

@implementation OVLogPage
- (void)loadView {
    NSScrollView *sv = [NSTextView scrollableTextView];
    self.text = sv.documentView;
    self.text.editable = NO;
    self.text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.text.textContainerInset = NSMakeSize(10, 10);
    self.text.string = OVLogText();
    NSButton *copy = OVButton(L(@"Copy all"), self, @selector(copyAll:));
    NSButton *folder = OVButton(L(@"Logs folder"), self, @selector(openLogs:));
    copy.controlSize = folder.controlSize = NSControlSizeRegular;
    NSStackView *page = OVVStack(@[OVHStack(@[OVTitle(L(@"Log")), OVSpacer(), copy, folder], 8), OVCard(sv, 4)], 14);
    page.edgeInsets = NSEdgeInsetsMake(30, 32, 24, 32);
    OVFillWidth(page.arrangedSubviews, page);
    [page.arrangedSubviews[1] setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *root = [NSView new];
    [root addSubview:page];
    OVPin(page, root, NSEdgeInsetsZero);
    self.view = root;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(line:) name:OVLogBufferNotification object:nil];
}
- (void)viewDidAppear { [super viewDidAppear]; [self.text scrollToEndOfDocument:nil]; }
- (void)line:(NSNotification *)n {
    NSTextStorage *ts = self.text.textStorage;
    BOOL atEnd = NSMaxY(self.text.visibleRect) >= NSMaxY(self.text.bounds) - 20;
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[n.userInfo[@"line"] stringByAppendingString:@"\n"]
                                                               attributes:@{NSFontAttributeName: self.text.font,
                                                                            NSForegroundColorAttributeName: NSColor.labelColor}]];
    if (ts.length > 300000) [ts deleteCharactersInRange:NSMakeRange(0, ts.length - 200000)];
    if (atEnd) [self.text scrollToEndOfDocument:nil];
}
- (void)copyAll:(id)s {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.text.string forType:NSPasteboardTypeString];
}
- (void)openLogs:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths logs]]]; }
@end
