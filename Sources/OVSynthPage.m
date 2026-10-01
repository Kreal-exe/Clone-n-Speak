#import "OVPages.h"
#import "OVUI.h"
#import "OVRuntime.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVMemory.h"

static NSString *const kAutoVoice = @"__auto__";

#pragma mark - Editor

@interface OVTextEditor : NSTextView
@property (copy) NSString *placeholder;
@end
@implementation OVTextEditor
- (void)drawRect:(NSRect)r {
    [super drawRect:r];
    if (self.string.length || !self.placeholder) return;
    NSDictionary *a = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: NSColor.placeholderTextColor};
    [self.placeholder drawInRect:NSInsetRect(self.bounds, self.textContainerInset.width + 5, self.textContainerInset.height) withAttributes:a];
}
// Ctrl+C/V/X/A/Z (Windows habits) in addition to the standard Cmd shortcuts.
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    NSEventModifierFlags f = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (f == NSEventModifierFlagControl && self.window.firstResponder == self) {
        NSString *k = e.charactersIgnoringModifiers.lowercaseString;
        if ([k isEqualToString:@"c"]) { [self copy:nil]; return YES; }
        if ([k isEqualToString:@"v"]) { [self paste:nil]; return YES; }
        if ([k isEqualToString:@"x"]) { [self cut:nil]; return YES; }
        if ([k isEqualToString:@"a"]) { [self selectAll:nil]; return YES; }
        if ([k isEqualToString:@"z"]) { [self.undoManager undo]; return YES; }
        if ([k isEqualToString:@"y"]) { [self.undoManager redo]; return YES; }
    }
    return [super performKeyEquivalent:e];
}
@end

#pragma mark - Style slider

/// A compact labeled slider of the voice-style panel, bound to a user-defaults key.
@interface OVStyleSlider : NSStackView
@property NSSlider *slider;
@property NSTextField *value;
@property (copy) NSString *key;
@property double step;
@property (copy) NSString *(^format)(double v);
@property (copy, nullable) void (^moved)(void);
- (void)refresh;
@end

@implementation OVStyleSlider
+ (instancetype)sliderWithTitle:(NSString *)title tip:(NSString *)tip key:(NSString *)key min:(double)min max:(double)max
                           step:(double)step format:(NSString *(^)(double))format {
    OVStyleSlider *r = [OVStyleSlider new];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 6;
    r.key = key;
    r.step = step;
    r.format = format;
    NSTextField *t = OVLabel(title, 12, NSFontWeightMedium, nil);
    [t.widthAnchor constraintEqualToConstant:82].active = YES;
    r.slider = [NSSlider sliderWithValue:0 minValue:min maxValue:max target:r action:@selector(moved:)];
    r.slider.controlSize = NSControlSizeSmall;
    [r.slider.widthAnchor constraintGreaterThanOrEqualToConstant:60].active = YES;
    [r.slider setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    r.value = OVLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    r.value.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    r.value.alignment = NSTextAlignmentRight;
    [r.value.widthAnchor constraintEqualToConstant:48].active = YES;
    [r setViews:@[t, r.slider, r.value] inGravity:NSStackViewGravityLeading];
    r.toolTip = t.toolTip = r.slider.toolTip = tip;
    [r refresh];
    return r;
}
- (void)moved:(NSSlider *)s {
    double v = round(s.doubleValue / self.step) * self.step;
    if (fabs(v) < self.step / 2) v = 0; // no "-0"
    [NSUserDefaults.standardUserDefaults setDouble:v forKey:self.key];
    self.value.stringValue = self.format(v);
    if (self.moved) self.moved();
}
- (void)refresh {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:self.key];
    self.slider.doubleValue = v;
    self.value.stringValue = self.format(v);
}
@end

#pragma mark - History cell

@interface OVHistoryCell : NSTableCellView
@property NSButton *play, *improve, *reveal, *trash;
@property NSTextField *text, *meta;
@end

@implementation OVHistoryCell
- (instancetype)initWithTarget:(id)t {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.play = OVIconButton(@"play.circle.fill", L(@"Listen"), t, @selector(playRow:));
        self.play.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightRegular];
        self.play.contentTintColor = OVAccent();
        [self.play.widthAnchor constraintEqualToConstant:30].active = YES;
        [self.play.heightAnchor constraintEqualToConstant:30].active = YES;
        self.text = OVLabel(@"", 13, NSFontWeightRegular, nil);
        self.text.maximumNumberOfLines = 1;
        self.meta = OVLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        self.improve = OVIconButton(@"wand.and.stars", L(@"Re-speak with auto-improve"), t, @selector(improveRow:));
        self.reveal = OVIconButton(@"folder", L(@"Show in Finder"), t, @selector(revealRow:));
        self.trash = OVIconButton(@"trash", L(@"Delete"), t, @selector(deleteRow:));
        NSStackView *texts = OVVStack(@[self.text, self.meta], 2);
        [texts setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [texts setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *row = OVHStack(@[self.play, texts, self.improve, self.reveal, self.trash], 8);
        [self addSubview:row];
        OVPin(row, self, NSEdgeInsetsMake(5, 6, 5, 8));
    }
    return self;
}
@end

#pragma mark - Page

@interface OVSynthPage () <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
@property OVAvatar *avatar;
@property NSPopUpButton *voicePopup, *langPopup, *loraPopup;
@property NSButton *sampleButton, *tuneButton, *styleButton, *adaptCheck;
@property NSSegmentedControl *quality;
@property NSTextField *counter, *status, *banner, *voiceHint, *memoryLabel;
@property NSView *stylePanel, *designRow;
@property NSSegmentedControl *moodPicker;
@property NSTextField *moodName;
@property NSArray<OVStyleSlider *> *styleSliders;
@property NSSwitch *improveSwitch;
@property NSTextField *improveHint;
@property OVTextEditor *editor;
@property NSButton *synthButton, *stopButton;
@property NSProgressIndicator *progress;
@property NSTableView *table;
@property NSView *bannerCard, *playerBar;
@property NSTextField *emptyHistory, *historyTitle, *playerTitle, *playerTime;
@property NSButton *playerButton;
@property NSSlider *playerSlider;
@property NSPopover *tunePopover;
@property NSTimer *timer, *playerTimer;
@property CFAbsoluteTime started;
@end

@implementation OVSynthPage

- (NSButton *)pill:(NSPopUpButton *)p {
    p.bezelStyle = NSBezelStyleRounded;
    p.controlSize = NSControlSizeRegular;
    p.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    return p;
}

- (void)loadView {
    NSStackView *page = OVVStack(@[], 12);
    page.edgeInsets = NSEdgeInsetsMake(26, 28, 18, 28);

    // ── header: voice
    self.avatar = [OVAvatar avatarWithSize:40];
    self.voicePopup = [NSPopUpButton new];
    self.voicePopup.bordered = NO;
    self.voicePopup.font = OVRoundedFont(18, NSFontWeightSemibold);
    self.voicePopup.target = self;
    self.voicePopup.action = @selector(voicePicked:);
    self.voicePopup.autoenablesItems = NO;
    [self.voicePopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.voiceHint = OVLabel(@"", 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *voiceText = OVVStack(@[OVLabel(L(@"Voice"), 11, NSFontWeightMedium, NSColor.tertiaryLabelColor), self.voicePopup, self.voiceHint], 0);
    self.sampleButton = OVButton(L(@"Voice sample"), self, @selector(playSample:));
    self.sampleButton.controlSize = NSControlSizeRegular;
    self.sampleButton.image = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil];
    self.sampleButton.imagePosition = NSImageLeading;
    NSStackView *header = OVHStack(@[self.avatar, voiceText, OVSpacer(), self.sampleButton], 10);
    header.alignment = NSLayoutAttributeCenterY;

    // ── banner shown when something is missing
    self.banner = OVLabel(@"", 13, NSFontWeightMedium, nil);
    NSButton *fix = OVButton(L(@"Open setup"), self, @selector(openSetup:));
    fix.controlSize = NSControlSizeRegular;
    NSStackView *bannerRow = OVHStack(@[OVSymbol(@"exclamationmark.triangle.fill", 14, NSColor.systemOrangeColor), self.banner, OVSpacer(), fix], 10);
    self.bannerCard = OVCard(bannerRow, 9);

    // ── editor
    NSScrollView *scroll = [OVTextEditor scrollableTextView];
    self.editor = [[OVTextEditor alloc] initWithFrame:scroll.contentView.bounds];
    self.editor.autoresizingMask = NSViewWidthSizable;
    self.editor.verticallyResizable = YES;
    self.editor.textContainer.widthTracksTextView = YES;
    scroll.documentView = self.editor;
    self.editor.font = [NSFont systemFontOfSize:17];
    self.editor.textContainerInset = NSMakeSize(14, 14);
    self.editor.richText = NO;
    self.editor.allowsUndo = YES;
    self.editor.automaticQuoteSubstitutionEnabled = NO;
    self.editor.automaticDashSubstitutionEnabled = NO;
    self.editor.automaticTextReplacementEnabled = NO;
    self.editor.automaticSpellingCorrectionEnabled = NO;
    self.editor.drawsBackground = NO;
    self.editor.delegate = self;
    self.editor.placeholder = L(@"Type or paste text to speak…");
    self.editor.string = [NSUserDefaults.standardUserDefaults stringForKey:@"draftText"] ?: @"";
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    self.counter = OVLabel(@"", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    // text tools live with the text: stress mark and sounds on the left, the counter on the right
    NSButton *stress = OVButton(L(@"Stress ´"), self, @selector(toggleStress:));
    stress.controlSize = NSControlSizeSmall;
    stress.toolTip = L(@"Put a stress mark on the selected vowel (or the one before the cursor): виши́вка. Press again to remove it. Shortcut ⌘'");
    NSButton *sounds = OVButton(L(@"Sound"), self, @selector(showSounds:));
    sounds.controlSize = NSControlSizeSmall;
    sounds.image = [NSImage imageWithSystemSymbolName:@"face.smiling" accessibilityDescription:nil];
    sounds.imagePosition = NSImageLeading;
    sounds.toolTip = L(@"Insert a sound: laughter, sigh, surprise…");
    NSStackView *tools = OVHStack(@[stress, sounds, OVSpacer(), self.counter], 8);
    NSStackView *editorStack = OVVStack(@[scroll, tools], 4);
    editorStack.alignment = NSLayoutAttributeCenterX;
    editorStack.edgeInsets = NSEdgeInsetsMake(0, 0, 6, 0);
    OVFillWidth(@[scroll], editorStack);
    tools.translatesAutoresizingMaskIntoConstraints = NO;
    [tools.widthAnchor constraintEqualToAnchor:editorStack.widthAnchor constant:-24].active = YES;

    // ── composer bar: language · tune · auto-improve ········ stop · speak
    self.langPopup = [NSPopUpButton new];
    self.langPopup.target = self;
    self.langPopup.action = @selector(languagePicked:);
    [self pill:self.langPopup];
    self.langPopup.toolTip = L(@"Speech language. Auto-detect recognizes it from the text.");
    [self buildLanguageMenu];
    self.tuneButton = OVIconButton(@"slider.horizontal.3", L(@"LoRA and accent removal"), self, @selector(showTune:));
    self.styleButton = OVIconButton(@"theatermasks", L(@"Voice style: mood, intonation, energy, pitch, tone, speed, pauses, quality"), self, @selector(toggleStylePanel:));
    self.improveSwitch = [NSSwitch new];
    self.improveSwitch.controlSize = NSControlSizeSmall;
    self.improveSwitch.target = self;
    self.improveSwitch.action = @selector(improveToggled:);
    self.improveSwitch.state = [NSUserDefaults.standardUserDefaults boolForKey:@"improve"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *improveTitle = OVLabel(L(@"✨ Auto-improve"), 12.5, NSFontWeightSemibold, nil);
    self.improveHint = OVLabel(@"", 10.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *improveBox = OVHStack(@[self.improveSwitch, OVVStack(@[improveTitle, self.improveHint], 0)], 7);
    improveBox.toolTip = L(@"Text is prepared for reading aloud (abbreviations, numbers, years), each phrase is spoken and checked by speech recognition, unclear phrases are spoken again and the best take is kept. Slower, but cleaner.");
    [improveBox setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.synthButton = OVPrimaryButton(L(@"Speak"), self, @selector(synthesize:));
    self.synthButton.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    self.synthButton.imagePosition = NSImageLeading;
    self.synthButton.keyEquivalent = @"\r";
    self.synthButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.synthButton.toolTip = @"⌘↩";
    [self.synthButton.widthAnchor constraintGreaterThanOrEqualToConstant:118].active = YES;
    self.stopButton = OVButton(L(@"Stop"), self, @selector(stop:));
    self.stopButton.hidden = YES;
    NSStackView *controls = OVHStack(@[self.langPopup, self.styleButton, self.tuneButton, improveBox, OVSpacer(),
                                       self.stopButton, self.synthButton], 10);
    [self buildStylePanel];

    self.progress = OVProgressBar();
    self.progress.hidden = YES;
    self.status = OVLabel(@"", 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;
    self.memoryLabel = OVLabel(@"", 11, NSFontWeightMedium, NSColor.secondaryLabelColor);
    self.memoryLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.memoryLabel.toolTip = L(@"Memory used by the speech engine and memory still free on this Mac");
    [self.memoryLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSImageView *chip = OVSymbol(@"memorychip", 11, NSColor.secondaryLabelColor);
    NSStackView *statusRow = OVHStack(@[self.progress, self.status, OVSpacer(), chip, self.memoryLabel], 8);
    [self.progress.widthAnchor constraintEqualToConstant:140].active = YES;

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    NSStackView *composer = OVVStack(@[editorStack, line, controls, self.stylePanel, statusRow], 8);
    composer.edgeInsets = NSEdgeInsetsMake(0, 0, 10, 0);
    OVFillWidth(@[editorStack, line], composer);
    for (NSView *v in @[controls, self.stylePanel, statusRow]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [v.widthAnchor constraintEqualToAnchor:composer.widthAnchor constant:-28].active = YES;
    }
    [editorStack setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *composerCard = OVCard(composer, 4);
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;

    // ── recent takes
    self.historyTitle = OVLabel(L(@"Recent takes"), 13, NSFontWeightSemibold, nil);
    NSButton *openFolder = OVButton(L(@"Open folder"), self, @selector(openOutputs:));
    openFolder.controlSize = NSControlSizeSmall;
    NSStackView *histHeader = OVHStack(@[self.historyTitle, OVSpacer(), openFolder], 8);

    self.table = [NSTableView new];
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"g"]];
    self.table.headerView = nil;
    self.table.rowHeight = 46;
    self.table.style = NSTableViewStyleInset;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.doubleAction = @selector(playRow:);
    self.table.target = self;
    NSScrollView *tscroll = [NSScrollView new];
    tscroll.documentView = self.table;
    tscroll.hasVerticalScroller = YES;
    tscroll.drawsBackground = NO;
    self.emptyHistory = OVWrapLabel([NSString stringWithFormat:L(@"Finished recordings appear here. WAV files are saved to Music → %@."), OVAppName],
                                    12, NSColor.tertiaryLabelColor);
    self.emptyHistory.alignment = NSTextAlignmentCenter;

    // player bar (visible while something is loaded)
    self.playerButton = OVIconButton(@"pause.fill", L(@"Play / pause"), self, @selector(playerToggle:));
    self.playerTitle = OVLabel(@"", 12, NSFontWeightMedium, nil);
    self.playerSlider = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(playerSeek:)];
    self.playerSlider.controlSize = NSControlSizeSmall;
    self.playerTime = OVLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.playerTime.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSButton *playerClose = OVIconButton(@"xmark", L(@"Stop"), self, @selector(playerStop:));
    [self.playerTitle.widthAnchor constraintLessThanOrEqualToConstant:220].active = YES;
    NSStackView *playerRow = OVHStack(@[self.playerButton, self.playerTitle, self.playerSlider, self.playerTime, playerClose], 8);
    [self.playerSlider setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.playerBar = playerRow;
    self.playerBar.hidden = YES;

    NSStackView *histBox = OVVStack(@[tscroll, self.emptyHistory, self.playerBar], 4);
    histBox.edgeInsets = NSEdgeInsetsMake(4, 4, 6, 4);
    OVFillWidth(@[tscroll, self.playerBar], histBox);
    self.emptyHistory.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyHistory.widthAnchor constraintEqualToAnchor:histBox.widthAnchor constant:-40].active = YES;
    [tscroll.heightAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
    NSView *histCard = OVCard(histBox, 2);

    for (NSView *v in @[header, self.bannerCard, composerCard, histHeader, histCard]) [page addArrangedSubview:v];
    [page setCustomSpacing:16 afterView:composerCard];
    [page setCustomSpacing:6 afterView:histHeader];
    OVFillWidth(@[header, self.bannerCard, composerCard, histHeader, histCard], page);
    // the editor takes the spare height first, recent takes get the rest
    [composerCard setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [composerCard setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    NSLayoutConstraint *share = [histCard.heightAnchor constraintEqualToAnchor:composerCard.heightAnchor multiplier:0.55];
    share.priority = NSLayoutPriorityDefaultLow + 1;
    share.active = YES;

    NSView *root = [NSView new];
    [root addSubview:page];
    OVPin(page, root, NSEdgeInsetsZero);
    self.view = root;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(reloadVoices) name:OVVoicesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reloadHistory) name:OVHistoryDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(playerChanged) name:OVPlayerDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshState) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshState) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reloadLoRAs) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshState) name:OVWorkerDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshMemory) name:OVWorkerMemoryDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(syncControls) name:NSUserDefaultsDidChangeNotification object:nil];

    [self buildTunePopover];
    [self reloadVoices];
    [self reloadLoRAs];
    [self reloadHistory];
    [self syncControls];
    [self textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]];
    [self refreshState];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:self.editor];
}

- (void)dealloc {
    [self.timer invalidate];
    [self.playerTimer invalidate];
}

#pragma mark Voice style panel

- (void)buildStylePanel {
    NSString *(^percent)(double) = ^(double v) { return fabs(v) < 0.005 ? @"0" : [NSString stringWithFormat:@"%+.0f%%", v * 100]; };
    __weak typeof(self) w = self;
    void (^retime)(void) = ^{ [w textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]]; };
    void (^custom)(void) = ^{ // a hand-moved slider leaves the preset
        [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:@"styleMood"];
        [w refreshMood];
        retime();
    };
    OVStyleSlider *intonation = [OVStyleSlider sliderWithTitle:L(@"Intonation") tip:L(@"Flat ↔ lively: narrows or widens the pitch melody of the voice.")
                                                           key:@"styleIntonation" min:-1 max:1 step:0.05 format:percent];
    OVStyleSlider *energy = [OVStyleSlider sliderWithTitle:L(@"Energy") tip:L(@"Relaxed ↔ energetic: pace, pauses, melody, presence and dynamics together.")
                                                       key:@"styleEnergy" min:-1 max:1 step:0.05 format:percent];
    OVStyleSlider *pitch = [OVStyleSlider sliderWithTitle:L(@"Pitch") tip:L(@"Deeper ↔ higher voice, in semitones. The timbre moves with it: lower is bigger and darker, higher is lighter.")
                                                      key:@"stylePitch" min:-4 max:4 step:0.5
                                                   format:^(double v) { return fabs(v) < 0.05 ? @"0" : [NSString stringWithFormat:L(@"%+.1f st"), v]; }];
    OVStyleSlider *tone = [OVStyleSlider sliderWithTitle:L(@"Tone") tip:L(@"Warm ↔ bright: more body or more clarity in the timbre.")
                                                     key:@"styleTone" min:-1 max:1 step:0.05 format:percent];
    OVStyleSlider *pauses = [OVStyleSlider sliderWithTitle:L(@"Pauses") tip:L(@"Pauses between sentences and paragraphs.")
                                                       key:@"stylePauses" min:0.5 max:2.5 step:0.1
                                                    format:^(double v) { return [NSString stringWithFormat:@"%.1f×", v]; }];
    for (OVStyleSlider *s in @[intonation, energy, pitch, tone, pauses]) s.moved = custom;
    OVStyleSlider *speed = [OVStyleSlider sliderWithTitle:L(@"Speed") tip:L(@"1.0 is the natural pace as judged by the model.")
                                                      key:@"speed" min:0.7 max:1.4 step:0.05
                                                   format:^(double v) { return [NSString stringWithFormat:@"%.2f×", v]; }];
    speed.moved = retime;
    OVStyleSlider *volume = [OVStyleSlider sliderWithTitle:L(@"Volume") tip:L(@"Loudness of the finished recording.")
                                                       key:@"styleVolume" min:-6 max:6 step:1
                                                    format:^(double v) { return fabs(v) < 0.5 ? @"0" : [NSString stringWithFormat:L(@"%+.0f dB"), v]; }];
    self.styleSliders = @[intonation, energy, pitch, tone, pauses, speed, volume];

    // moods: one emoji per preset, the name of the chosen one next to them
    NSArray<NSDictionary *> *moods = [OVSettings moods];
    self.moodPicker = [NSSegmentedControl segmentedControlWithLabels:[moods valueForKey:@"emoji"] trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self action:@selector(moodPicked:)];
    self.moodPicker.segmentStyle = NSSegmentStyleRounded;
    [moods enumerateObjectsUsingBlock:^(NSDictionary *m, NSUInteger i, BOOL *stop) {
        [self.moodPicker setToolTip:m[@"title"] forSegment:i];
        [self.moodPicker setWidth:34 forSegment:i];
    }];
    NSString *moodTip = L(@"A preset of the controls below. OmniVoice has no emotion switch: a cloned voice takes its feeling from the sample, so record the sample in the mood you need — the presets shape what can be shaped afterwards.");
    NSTextField *moodTitle = OVLabel(L(@"Mood"), 12, NSFontWeightMedium, nil);
    [moodTitle.widthAnchor constraintEqualToConstant:82].active = YES;
    self.moodName = OVLabel(@"", 12, NSFontWeightSemibold, OVAccent());
    NSButton *reset = OVButton(L(@"Reset"), self, @selector(resetStyle:));
    reset.controlSize = NSControlSizeSmall;
    reset.toolTip = L(@"Reset the voice style");
    NSStackView *moodRow = OVHStack(@[moodTitle, self.moodPicker, self.moodName, OVSpacer(), reset], 8);
    moodRow.toolTip = moodTitle.toolTip = moodTip;

    self.quality = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Fast"), L(@"Standard"), L(@"Maximum")]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(qualityPicked:)];
    self.quality.controlSize = NSControlSizeSmall;
    self.quality.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.quality.toolTip = L(@"Decoding steps: 16 / 32 / 64");
    NSTextField *qualityTitle = OVLabel(L(@"Quality"), 12, NSFontWeightMedium, nil);
    [qualityTitle.widthAnchor constraintEqualToConstant:82].active = YES;
    NSStackView *qualityRow = OVHStack(@[qualityTitle, self.quality, OVSpacer()], 6);

    NSStackView *left = OVVStack(@[intonation, energy, pitch, tone], 7);
    NSStackView *right = OVVStack(@[speed, pauses, volume, qualityRow], 7);
    OVFillWidth(left.arrangedSubviews, left);
    OVFillWidth(right.arrangedSubviews, right);
    for (NSView *row in [left.arrangedSubviews arrayByAddingObjectsFromArray:right.arrangedSubviews])
        [row.heightAnchor constraintEqualToConstant:20].active = YES;  // sliders line up across the columns
    NSStackView *columns = OVHStack(@[left, right], 22);
    columns.alignment = NSLayoutAttributeTop;
    [left.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;

    // voice design: only the model's own voice listens to these tags, a clone follows its sample
    NSPopUpButton *(^small)(NSArray *, NSString *) = ^(NSArray *items, NSString *key) {
        NSPopUpButton *p = OVDefaultsPopup(items, key, nil, nil);
        p.controlSize = NSControlSizeSmall;
        p.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        return p;
    };
    NSPopUpButton *gender = small(@[@[L(@"Any gender"), @""], @[L(@"Male"), @"male"], @[L(@"Female"), @"female"]], @"designGender");
    NSPopUpButton *age = small(@[@[L(@"Any age"), @""], @[L(@"Child"), @"child"], @[L(@"Teenager"), @"teenager"], @[L(@"Young adult"), @"young adult"],
                                 @[L(@"Middle-aged"), @"middle-aged"], @[L(@"Elderly"), @"elderly"]], @"designAge");
    NSPopUpButton *level = small(@[@[L(@"Any pitch"), @""], @[L(@"Very low"), @"very low pitch"], @[L(@"Low"), @"low pitch"], @[L(@"Medium"), @"moderate pitch"],
                                   @[L(@"High"), @"high pitch"], @[L(@"Very high"), @"very high pitch"]], @"designPitch");
    NSMutableArray *accents = [@[@[L(@"No accent"), @""]] mutableCopy];
    for (NSArray *a in @[@[L(@"American"), @"american"], @[L(@"British"), @"british"], @[L(@"Australian"), @"australian"],
                         @[L(@"Canadian"), @"canadian"], @[L(@"Indian"), @"indian"], @[L(@"Chinese"), @"chinese"],
                         @[L(@"Korean"), @"korean"], @[L(@"Japanese"), @"japanese"], @[L(@"Portuguese"), @"portuguese"],
                         @[L(@"Russian"), @"russian"]])
        [accents addObject:@[a[0], [a[1] stringByAppendingString:@" accent"]]];
    NSPopUpButton *accent = small(accents, @"designAccent");
    accent.toolTip = L(@"Accent of the model’s own voice — for English text only.");
    NSButton *whisper = OVCheckbox(L(@"Whisper"), @"designWhisper");
    whisper.controlSize = NSControlSizeSmall;
    whisper.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSTextField *designTitle = OVLabel(L(@"Model’s voice"), 12, NSFontWeightMedium, nil);
    [designTitle.widthAnchor constraintGreaterThanOrEqualToConstant:82].active = YES;
    [designTitle setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *design = OVHStack(@[designTitle, gender, age, level, accent, whisper, OVSpacer()], 6);
    design.toolTip = designTitle.toolTip = L(@"What the model’s own voice sounds like (voice design). Cloned voices follow their sample instead.");
    self.designRow = design;

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    NSStackView *panel = OVVStack(@[line, moodRow, columns, design], 9);
    OVFillWidth(@[line, moodRow, columns, design], panel);
    self.stylePanel = panel;
    self.stylePanel.hidden = ![NSUserDefaults.standardUserDefaults boolForKey:@"stylePanel"];
    [self refreshMood];
}

- (void)toggleStylePanel:(id)s {
    BOOL open = self.stylePanel.hidden;
    self.stylePanel.hidden = !open;
    [NSUserDefaults.standardUserDefaults setBool:open forKey:@"stylePanel"];
}

/// The mood picker follows the "styleMood" setting; a slider moved by hand leaves no preset selected ("Custom").
- (void)refreshMood {
    NSString *mood = [NSUserDefaults.standardUserDefaults stringForKey:@"styleMood"] ?: @"neutral";
    NSArray<NSDictionary *> *moods = [OVSettings moods];
    NSUInteger idx = [[moods valueForKey:@"id"] indexOfObject:mood];
    if (idx == NSNotFound) {
        self.moodPicker.selectedSegment = -1;
        self.moodName.stringValue = L(@"Custom");
    } else {
        self.moodPicker.selectedSegment = idx;
        self.moodName.stringValue = moods[idx][@"title"];
    }
    BOOL plain = [OVSettings styleIsNeutral] && fabs([NSUserDefaults.standardUserDefaults doubleForKey:@"speed"] - 1) < 0.005;
    self.styleButton.contentTintColor = plain ? NSColor.secondaryLabelColor : OVAccent();
}

- (void)moodPicked:(NSSegmentedControl *)c {
    if (c.selectedSegment < 0) return;
    [OVSettings applyMood:[OVSettings moods][c.selectedSegment][@"id"]];
    [self syncControls];
    [self textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]];
}

- (void)resetStyle:(id)s {
    [OVSettings applyMood:@"neutral"];
    for (NSString *k in @[@"speed", @"styleVolume"]) [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
    [self syncControls];
    [self textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]];
}

#pragma mark Sounds between words

- (void)showSounds:(NSButton *)b {
    NSMenu *menu = [NSMenu new];
    NSArray *items = @[@[L(@"Laughter"), @"laughter"], @[L(@"Sigh"), @"sigh"], @[],
                       @[L(@"Surprise: “Ah!”"), @"surprise-ah"], @[L(@"Surprise: “Oh!”"), @"surprise-oh"],
                       @[L(@"Surprise: “Wow!”"), @"surprise-wa"], @[L(@"Surprise: “Yo!”"), @"surprise-yo"], @[],
                       @[L(@"Question: “Ah?”"), @"question-ah"], @[L(@"Question: “Oh?”"), @"question-oh"],
                       @[L(@"Question: “Eh?”"), @"question-ei"], @[L(@"Question: “Yi?”"), @"question-yi"],
                       @[L(@"Question: “Huh?” (English)"), @"question-en"], @[],
                       @[L(@"Agreement: “Uh-huh” (English)"), @"confirmation-en"], @[L(@"Displeasure: “Hmm…”"), @"dissatisfaction-hnn"]];
    for (NSArray *it in items) {
        if (!it.count) { [menu addItem:NSMenuItem.separatorItem]; continue; }
        NSMenuItem *mi = [menu addItemWithTitle:it[0] action:@selector(insertSound:) keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = it[1];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(b.bounds) + 4) inView:b];
}

/// Puts a tag like [laughter] at the cursor: the model voices it as a sound.
- (void)insertSound:(NSMenuItem *)it {
    NSTextView *tv = self.editor;
    NSRange sel = tv.selectedRange;
    NSString *str = tv.string;
    BOOL spaceBefore = sel.location > 0 && ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[str characterAtIndex:sel.location - 1]];
    NSString *tag = [NSString stringWithFormat:@"%@[%@] ", spaceBefore ? @" " : @"", it.representedObject];
    [tv insertText:tag replacementRange:sel];
    [self.view.window makeFirstResponder:tv];
}

#pragma mark Tune popover (LoRA, accent removal)

- (void)buildTunePopover {
    self.adaptCheck = [NSButton checkboxWithTitle:L(@"Remove the sample’s accent in other languages") target:self action:@selector(adaptToggled:)];
    self.adaptCheck.toolTip = L(@"When the text is in another language than the voice sample, the voice first says a short phrase in that language and the cleanest take becomes its sample for it. Takes about a minute, once per voice and language.");
    self.loraPopup = [NSPopUpButton new];
    self.loraPopup.target = self;
    self.loraPopup.action = @selector(loraPicked:);
    self.loraPopup.autoenablesItems = NO;
    self.loraPopup.toolTip = L(@"LoRA adapter on top of the model. The chosen adapter is downloaded automatically.");
    NSButton *more = OVButton(L(@"All settings…"), self, @selector(openSettings:));
    more.controlSize = NSControlSizeSmall;
    NSGridView *g = [NSGridView gridViewWithViews:@[
        @[OVLabel(@"LoRA", 12, NSFontWeightMedium, nil), self.loraPopup],
        @[OVLabel(L(@"Accent"), 12, NSFontWeightMedium, nil), self.adaptCheck],
        @[[NSGridCell emptyContentView], more],
    ]];
    g.rowSpacing = 12;
    g.columnSpacing = 12;
    [g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    NSViewController *vc = [NSViewController new];
    NSView *box = [NSView new];
    [box addSubview:g];
    OVPin(g, box, NSEdgeInsetsMake(16, 16, 14, 16));
    vc.view = box;
    self.tunePopover = [NSPopover new];
    self.tunePopover.contentViewController = vc;
    self.tunePopover.behavior = NSPopoverBehaviorTransient;
}

- (void)showTune:(NSButton *)b {
    if (self.tunePopover.shown) { [self.tunePopover close]; return; }
    [self.tunePopover showRelativeToRect:b.bounds ofView:b preferredEdge:NSRectEdgeMaxY];
}

- (void)openSettings:(id)s { [self.tunePopover close]; OVNavigate(@"settings"); }

- (void)adaptToggled:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:@"adaptAccent"];
    [self refreshVoiceHint];
}

#pragma mark State

- (void)syncControls {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger steps = [d integerForKey:@"numStep"];
    self.quality.selectedSegment = steps <= 20 ? 0 : steps <= 40 ? 1 : 2;
    self.adaptCheck.state = [OVSettings adaptAccent] ? NSControlStateValueOn : NSControlStateValueOff;
    for (OVStyleSlider *s in self.styleSliders) [s refresh];
    [self refreshMood];
}

- (void)refreshState {
    OVRuntime *rt = [OVRuntime shared];
    OVModels *mm = [OVModels shared];
    NSString *problem = nil;
    if (rt.state == OVRuntimeChecking || rt.state == OVRuntimeUnknown) problem = L(@"Looking for the OmniVoice engine…");
    else if (rt.state == OVRuntimeInstalling) problem = [NSString stringWithFormat:L(@"Installing the engine: %@"), rt.stepTitle];
    else if (rt.state != OVRuntimeReady) problem = L(@"The OmniVoice engine isn’t installed.");
    else if (!mm.ttsModel) problem = L(@"The OmniVoice model isn’t downloaded.");
    OVModel *lora = mm.loraSelection;
    if (!problem && lora && !lora.installed)
        problem = lora.downloading ? [NSString stringWithFormat:L(@"Downloading LoRA “%@” — %.0f%%"), lora.title, lora.progress * 100]
                                   : (lora.error ? [NSString stringWithFormat:L(@"LoRA “%@” isn’t downloaded: %@"), lora.title, lora.error] : [NSString stringWithFormat:L(@"LoRA “%@” isn’t downloaded"), lora.title]);
    self.bannerCard.hidden = problem == nil;
    self.banner.stringValue = problem ?: @"";
    BOOL busy = [OVWorker shared].busy;
    self.synthButton.enabled = !busy && problem == nil;
    self.stopButton.hidden = !busy;
    self.progress.hidden = !busy && self.progress.doubleValue <= 0;
    self.tuneButton.contentTintColor = lora ? OVAccent() : NSColor.secondaryLabelColor;
    [self refreshMemory];

    OVModel *asrDl = nil;
    for (OVModel *m in [mm modelsOfKind:OVModelASR]) if (m.downloading) asrDl = m;
    BOOL on = self.improveSwitch.state == NSControlStateValueOn;
    self.improveHint.stringValue = !on ? L(@"checks every phrase") :
        asrDl ? [NSString stringWithFormat:L(@"downloading Whisper — %.0f%%"), asrDl.progress * 100] :
        mm.asrModel ? [NSString stringWithFormat:L(@"up to %ld attempts per phrase"), (long)[NSUserDefaults.standardUserDefaults integerForKey:@"improveAttempts"]] :
                      L(@"downloads Whisper on first run");
    [self refreshVoiceHint];
}

/// "Engine 1.3 GB · peak 2.1 · free 2.7 GB" — live while the engine runs.
- (void)refreshMemory {
    OVWorker *w = [OVWorker shared];
    unsigned long long avail = w.availableMemory ?: [OVMemory availableBytes];
    NSString *free = [NSString stringWithFormat:L(@"free %@"), [OVMemory format:avail]];
    if (w.engineFootprint > 50 * 1024 * 1024) {
        NSString *peak = w.busy && w.peakFootprint > w.engineFootprint ? [NSString stringWithFormat:L(@" · peak %@"), [OVMemory format:w.peakFootprint]] : @"";
        self.memoryLabel.stringValue = [NSString stringWithFormat:L(@"engine %@%@ · %@"), [OVMemory format:w.engineFootprint], peak, free];
    } else {
        self.memoryLabel.stringValue = [NSString stringWithFormat:L(@"engine idle · %@"), free];
    }
    self.memoryLabel.textColor = avail < 1024ULL * 1024 * 1024 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
}

- (void)improveToggled:(NSSwitch *)s {
    BOOL on = s.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"improve"];
    if (on) [[OVModels shared] whenASRReady:^(OVModel *asr, NSString *err) { [self refreshState]; }]; // fetch Whisper right away
    [self refreshState];
}

- (void)reloadLoRAs {
    OVModels *mm = [OVModels shared];
    [self.loraPopup removeAllItems];
    NSMenu *menu = self.loraPopup.menu;
    [menu addItemWithTitle:L(@"No LoRA") action:nil keyEquivalent:@""].representedObject = @"";
    NSArray *loras = [mm modelsOfKind:OVModelLoRA];
    if (loras.count) [menu addItem:NSMenuItem.separatorItem];
    for (OVModel *m in loras) {
        NSString *title = m.installed ? m.title : m.downloading ? [NSString stringWithFormat:@"%@ (%.0f%%)", m.title, m.progress * 100]
                                                                : [NSString stringWithFormat:L(@"%@ (download)"), m.title];
        [menu addItemWithTitle:title action:nil keyEquivalent:@""].representedObject = m.repo;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:L(@"Find LoRA on Hugging Face…") action:nil keyEquivalent:@""].representedObject = @"__find__";
    NSInteger idx = mm.loraSelection ? [self.loraPopup indexOfItemWithRepresentedObject:mm.loraSelection.repo] : 0;
    [self.loraPopup selectItemAtIndex:MAX(0, idx)];
}

- (void)loraPicked:(NSPopUpButton *)p {
    NSString *rep = p.selectedItem.representedObject;
    if ([rep isEqualToString:@"__find__"]) { [self reloadLoRAs]; [self.tunePopover close]; OVNavigate(@"models"); return; }
    [[OVModels shared] selectLoRA:rep.length ? [[OVModels shared] modelForRepo:rep] : nil];
    if (![OVWorker shared].busy) [[OVWorker shared] stop]; // next synthesis loads the new combination
}

- (OVVoice *)selectedVoice {
    return [[OVVoices shared] voiceWithId:self.voicePopup.selectedItem.representedObject ?: @""];
}

- (void)reloadVoices {
    NSString *sel = [NSUserDefaults.standardUserDefaults stringForKey:@"voice"];
    [self.voicePopup removeAllItems];
    NSMenu *menu = self.voicePopup.menu;
    for (OVVoice *v in [OVVoices shared].all) {
        NSMenuItem *it = [menu addItemWithTitle:v.ready ? v.name : [NSString stringWithFormat:L(@"%@ (not ready)"), v.name] action:nil keyEquivalent:@""];
        it.representedObject = v.identifier;
        it.enabled = v.ready;
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:L(@"No cloning (model’s own voice)") action:nil keyEquivalent:@""].representedObject = kAutoVoice;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *add = [menu addItemWithTitle:L(@"Clone new voice…") action:nil keyEquivalent:@""];
    add.representedObject = @"__new__";
    add.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];

    NSInteger idx = [self.voicePopup indexOfItemWithRepresentedObject:sel];
    if (idx < 0 || ![[self.voicePopup itemAtIndex:idx] isEnabled]) {
        idx = -1;
        for (NSInteger i = 0; i < self.voicePopup.numberOfItems; i++)
            if ([self.voicePopup itemAtIndex:i].isEnabled && [self.voicePopup itemAtIndex:i].representedObject) { idx = i; break; }
    }
    if (idx >= 0) [self.voicePopup selectItemAtIndex:idx];
    [self refreshVoiceHint];
}

/// Avatar, sample button and a hint when the text's language differs from the sample's.
- (void)refreshVoiceHint {
    OVVoice *v = [self selectedVoice];
    [self.avatar setName:v.name];
    self.sampleButton.hidden = v == nil;
    NSString *lang = v.language ?: (v.refText.length ? [OVLocale detectLanguage:v.refText] : nil);
    NSString *hint = v ? (lang ? [NSString stringWithFormat:L(@"%@ sample · %@"), OVFormatDuration(v.seconds), [OVLocale nameForLanguage:lang]]
                               : [NSString stringWithFormat:L(@"%@ sample"), OVFormatDuration(v.seconds)])
                       : L(@"Built-in voice of the model");
    NSString *sampleLang = lang;
    NSString *textLang = [self textLanguage];
    BOOL mismatch = sampleLang && textLang && ![sampleLang isEqualToString:textLang];
    BOOL adapts = mismatch && [v adaptsToLanguage:textLang];
    NSString *from = mismatch ? [OVLocale nameForLanguage:sampleLang] : nil, *to = mismatch ? [OVLocale nameForLanguage:textLang] : nil;
    if (adapts)
        hint = [v.adaptedLanguages containsObject:textLang]
            ? [NSString stringWithFormat:L(@"%@ sample → %@ without its accent"), from, to]
            : [NSString stringWithFormat:L(@"%@ sample → %@: the accent is removed on the first run (about a minute)"), from, to];
    else if (mismatch)
        hint = [NSString stringWithFormat:L(@"%@ sample — its accent carries over into %@"), from, to];
    self.voiceHint.stringValue = hint;
    self.voiceHint.textColor = mismatch && !adapts ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    self.voiceHint.toolTip = adapts ? L(@"The voice first says a short phrase in the new language; the cleanest take becomes its sample for that language, so the accent of the original sample doesn’t carry over. Switch it off under the sliders button to keep the accent.")
                           : mismatch ? L(@"Turn on “Remove the sample’s accent” under the sliders button, or record the sample in the language of the text.") : nil;
    self.designRow.hidden = v != nil;  // voice design tags only work for the model’s own voice
}

/// Language the text will be spoken in; nil while there is nothing to go by (empty editor, auto-detect).
- (nullable NSString *)textLanguage {
    NSString *text = [self.editor.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length && [[OVLocale speechLanguageSetting] isEqualToString:@"auto"]) return nil;
    return [OVLocale speechLanguageForText:text];
}

- (void)voicePicked:(NSPopUpButton *)p {
    NSString *rep = p.selectedItem.representedObject;
    if ([rep isEqualToString:@"__new__"]) {
        [self reloadVoices];
        OVNavigate(@"voices");
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:rep forKey:@"voice"];
    [self refreshVoiceHint];
}

- (void)playSample:(id)s {
    OVVoice *v = [self selectedVoice];
    if (v) [[OVPlayer shared] toggle:v.referencePath];
}

- (void)qualityPicked:(NSSegmentedControl *)s {
    NSInteger steps = ((NSNumber *)@[@16, @32, @64][s.selectedSegment]).integerValue;
    [NSUserDefaults.standardUserDefaults setInteger:steps forKey:@"numStep"];
}

- (void)buildLanguageMenu {
    [self.langPopup removeAllItems];
    NSMenu *menu = self.langPopup.menu;
    [menu addItemWithTitle:L(@"Auto-detect") action:nil keyEquivalent:@""].representedObject = @"auto";
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *pinned = [OVLocale pinnedSpeechLanguages];
    for (NSString *c in pinned) [menu addItemWithTitle:[OVLocale nameForLanguage:c] action:nil keyEquivalent:@""].representedObject = c;
    [menu addItem:NSMenuItem.separatorItem];
    for (NSString *c in [OVLocale speechLanguages])
        if (![pinned containsObject:c]) [menu addItemWithTitle:[OVLocale nameForLanguage:c] action:nil keyEquivalent:@""].representedObject = c;
    NSInteger i = [self.langPopup indexOfItemWithRepresentedObject:[OVLocale speechLanguageSetting]];
    [self.langPopup selectItemAtIndex:MAX(0, i)];
    [self refreshDetectedLanguage];
}

- (void)languagePicked:(NSPopUpButton *)p {
    [NSUserDefaults.standardUserDefaults setObject:p.selectedItem.representedObject forKey:@"language"];
    [self refreshDetectedLanguage];
    [self refreshVoiceHint];
}

/// "Auto-detect" shows the language it currently hears in the text.
- (void)refreshDetectedLanguage {
    NSMenuItem *autoItem = [self.langPopup itemAtIndex:0];
    NSString *code = [OVLocale detectLanguage:self.editor.string ?: @""];
    autoItem.title = code ? [NSString stringWithFormat:L(@"Auto · %@"), [OVLocale nameForLanguage:code]] : L(@"Auto-detect");
    if (self.langPopup.indexOfSelectedItem == 0) [self.langPopup synchronizeTitleAndSelectedItem];
    [self refreshVoiceHint];
}

- (void)textDidChange:(NSNotification *)n {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshDetectedLanguage) object:nil];
    [self performSelector:@selector(refreshDetectedLanguage) withObject:nil afterDelay:0.4];
    NSString *t = self.editor.string;
    [NSUserDefaults.standardUserDefaults setObject:t forKey:@"draftText"];
    NSUInteger chars = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    double sec = chars / 14.0 / MAX(0.5, [d doubleForKey:@"speed"] * (1 + 0.1 * [d doubleForKey:@"styleEnergy"]));
    self.counter.stringValue = chars ? [NSString stringWithFormat:L(@"%lu chars · about %@ of speech"), (unsigned long)chars, OVFormatDuration(sec)] : @"";
}

#pragma mark Stress marks

static BOOL IsVowel(unichar c) {
    return [@"аеєиіїоуюяыэёАЕЄИІЇОУЮЯЫЭЁaeiouyAEIOUY" rangeOfString:[NSString stringWithCharacters:&c length:1]].location != NSNotFound;
}

/// Adds U+0301 after the selected vowel (or the vowel before the cursor); removes it if it is already there.
- (void)toggleStress:(id)sender {
    NSTextView *tv = self.editor;
    NSString *str = tv.string;
    NSRange sel = tv.selectedRange;
    NSInteger pos = sel.length ? (NSInteger)NSMaxRange(sel) - 1 : (NSInteger)sel.location - 1;
    if (pos >= 0 && pos < (NSInteger)str.length && [str characterAtIndex:pos] == 0x0301) pos--;  // cursor after the mark
    if (pos < 0 || pos >= (NSInteger)str.length || !IsVowel([str characterAtIndex:pos])) {
        self.status.stringValue = L(@"Select a vowel (or put the cursor right after it) to mark the stress");
        NSBeep();
        return;
    }
    NSUInteger after = pos + 1;
    BOOL has = after < str.length && [str characterAtIndex:after] == 0x0301;
    NSRange target = has ? NSMakeRange(after, 1) : NSMakeRange(after, 0);
    NSString *replacement = has ? @"" : @"\u0301";
    if (![tv shouldChangeTextInRange:target replacementString:replacement]) return;
    [tv.textStorage replaceCharactersInRange:target withString:replacement];
    [tv didChangeText];
    tv.selectedRange = NSMakeRange(after + replacement.length, 0);
    [self.view.window makeFirstResponder:tv];
}

#pragma mark Actions

- (void)openSetup:(id)s { OVNavigate(@"setup"); }
- (void)openOutputs:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths outputs]]]; }

- (void)synthesize:(id)sender {
    NSString *text = [self.editor.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { self.status.stringValue = L(@"Enter text to speak"); return; }
    NSString *voiceId = self.voicePopup.selectedItem.representedObject;
    OVVoice *voice = [[OVVoices shared] voiceWithId:voiceId ?: @""];
    if (!voice && ![voiceId isEqualToString:kAutoVoice]) {
        self.status.stringValue = L(@"Clone a voice on the Voices page first");
        return;
    }
    [self synthesizeText:text voice:voice improve:self.improveSwitch.state == NSControlStateValueOn];
}

- (void)synthesizeText:(NSString *)text voice:(OVVoice *)voice improve:(BOOL)improve {
    if ([OVWorker shared].busy || !self.synthButton.enabled) return;
    NSDictionary *spec = [OVSettings modelSpec];
    if (!spec) { OVNavigate(@"setup"); return; }
    if (improve && ![OVModels shared].asrModel) {
        // Whisper is needed to check clarity: fetch it, then continue by itself
        self.status.stringValue = L(@"Downloading Whisper to check clarity — speech will start by itself…");
        self.synthButton.enabled = NO;
        __weak typeof(self) w = self;
        [[OVModels shared] whenASRReady:^(OVModel *asr, NSString *err) {
            [w refreshState];
            if (err) { w.status.stringValue = err; return; }
            [w synthesizeText:text voice:voice improve:YES];
        }];
        return;
    }
    NSString *out = [[OVHistory shared] newOutputPathForText:text];
    NSString *language = [OVLocale speechLanguageForText:text];
    NSMutableDictionary *req = [@{@"cmd": @"synth", @"model": spec, @"text": text, @"out": out,
                                  @"language": language, @"params": [OVSettings generationParams]} mutableCopy];
    if (voice) req[@"voice"] = [voice workerSpecForLanguage:language];
    // accent removal picks its best take with Whisper when it is there (it works without, too)
    if ([voice adaptsToLanguage:language] && [OVModels shared].asrModel) req[@"asr_path"] = [OVModels shared].asrModel.localPath;
    if (improve) {
        NSMutableDictionary *imp = [[OVSettings improveParams] mutableCopy];
        imp[@"asr_path"] = [OVModels shared].asrModel.localPath;
        req[@"improve"] = imp;
    }

    [[OVPlayer shared] stop];
    self.progress.doubleValue = 0;
    self.progress.hidden = NO;
    self.started = CFAbsoluteTimeGetCurrent();
    self.status.stringValue = L(@"Starting…");
    self.status.toolTip = nil;
    [self.timer invalidate];
    __weak typeof(self) w = self;
    __block NSString *lastStatus = L(@"Starting…");
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        w.status.stringValue = [NSString stringWithFormat:@"%@  %@", lastStatus, OVFormatDuration(CFAbsoluteTimeGetCurrent() - w.started)];
    }];
    [[OVWorker shared] request:req status:^(NSString *msg) {
        lastStatus = msg;
    } progress:^(double v) {
        w.progress.doubleValue = v;
    } done:^(NSDictionary *data, NSString *error) {
        [w.timer invalidate];
        w.progress.doubleValue = 0;
        w.progress.hidden = YES;
        if (error) {
            w.status.stringValue = error;
            return;
        }
        [[OVHistory shared] record:data[@"path"] text:text voice:voice result:data];
        [w showResult:data];
        [w refreshVoiceHint];  // the voice may have just learned a language
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"autoPlay"]) [[OVPlayer shared] play:data[@"path"]];
        [w.table scrollRowToVisible:0];
    }];
}

- (void)showResult:(NSDictionary *)data {
    double secs = [data[@"seconds"] doubleValue], el = [data[@"elapsed"] doubleValue];
    NSMutableString *st = [NSMutableString stringWithFormat:L(@"Done: %@ of audio in %.0f s"), OVFormatDuration(secs), el];
    OVWorker *w = [OVWorker shared];
    if (w.peakFootprint > 0) [st appendFormat:L(@" · peak memory %.1f GB"), w.peakFootprint / 1073741824.0];
    NSArray *problems = data[@"problems"];
    if (data[@"clarity"]) [st appendFormat:L(@" · clarity %.0f%%"), [data[@"clarity"] doubleValue] * 100];
    if (problems.count) {
        [st appendFormat:L(@" · unclear phrases: %lu — hover to see them"), (unsigned long)problems.count];
        NSMutableString *tip = [NSMutableString stringWithString:L(@"The model never pronounced these phrases clearly. Rewriting them more simply, expanding abbreviations or adding commas helps:\n")];
        for (NSDictionary *p in problems) [tip appendFormat:L(@"\n• “%@”\n  heard: “%@”"), p[@"text"], p[@"heard"]];
        self.status.toolTip = tip;
    }
    self.status.stringValue = st;
}

- (void)stop:(id)s {
    [[OVWorker shared] stop];
    self.status.stringValue = L(@"Stopped");
}

#pragma mark Player bar

- (void)playerChanged {
    OVPlayer *p = [OVPlayer shared];
    BOOL loaded = p.currentPath != nil;
    self.playerBar.hidden = !loaded;
    self.playerButton.image = [NSImage imageWithSystemSymbolName:p.playing ? @"pause.fill" : @"play.fill" accessibilityDescription:nil];
    self.sampleButton.title = [p.currentPath isEqualToString:[self selectedVoice].referencePath] && p.playing ? L(@"Stop") : L(@"Voice sample");
    if (loaded) {
        OVGeneration *g = nil;
        for (OVGeneration *x in [OVHistory shared].all) if ([x.path isEqualToString:p.currentPath]) g = x;
        self.playerTitle.stringValue = g ? [[g.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "]
                                         : L(@"Voice sample");
        self.playerSlider.maxValue = MAX(0.1, p.duration);
        if (!self.playerTimer) {
            __weak typeof(self) w = self;
            self.playerTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [w tickPlayer]; }];
        }
        [self tickPlayer];
    } else {
        [self.playerTimer invalidate];
        self.playerTimer = nil;
    }
    [self.table reloadData];
}

- (void)tickPlayer {
    OVPlayer *p = [OVPlayer shared];
    self.playerSlider.doubleValue = p.currentTime;
    self.playerTime.stringValue = [NSString stringWithFormat:@"%@ / %@", OVFormatDuration(p.currentTime), OVFormatDuration(p.duration)];
}

- (void)playerToggle:(id)s { [[OVPlayer shared] pauseOrResume]; }
- (void)playerSeek:(NSSlider *)s { [[OVPlayer shared] seek:s.doubleValue]; }
- (void)playerStop:(id)s { [[OVPlayer shared] stop]; }

#pragma mark History table

- (void)reloadHistory {
    [self.table reloadData];
    NSUInteger n = [OVHistory shared].all.count;
    self.emptyHistory.hidden = n > 0;
    self.table.enclosingScrollView.hidden = n == 0;
    self.historyTitle.stringValue = n ? [NSString stringWithFormat:L(@"Recent takes · %lu"), (unsigned long)n] : L(@"Recent takes");
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return [OVHistory shared].all.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    OVHistoryCell *cell = [t makeViewWithIdentifier:@"hist" owner:self];
    if (!cell) { cell = [[OVHistoryCell alloc] initWithTarget:self]; cell.identifier = @"hist"; }
    OVGeneration *g = [OVHistory shared].all[row];
    cell.text.stringValue = [[g.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    cell.text.toolTip = g.text;
    NSString *when = [NSDateFormatter localizedStringFromDate:g.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    NSString *quality = g.clarity >= 0 ? [NSString stringWithFormat:@" · ✨ %.0f%%", g.clarity * 100] : @"";
    cell.meta.stringValue = [NSString stringWithFormat:@"%@ · %@ · %@%@", g.voiceName.length ? g.voiceName : @"—", OVFormatDuration(g.seconds), when, quality];
    cell.meta.toolTip = g.problems.count ? [NSString stringWithFormat:L(@"Unclear: %@"), [[g.problems valueForKey:@"text"] componentsJoinedByString:@" / "]] : nil;
    cell.improve.enabled = self.synthButton.enabled;
    OVPlayer *p = [OVPlayer shared];
    BOOL playing = [p.currentPath isEqualToString:g.path] && p.playing;
    cell.play.image = [NSImage imageWithSystemSymbolName:playing ? @"pause.circle.fill" : @"play.circle.fill" accessibilityDescription:nil];
    return cell;
}

- (OVGeneration *)genFor:(id)sender {
    NSInteger row = [sender isKindOfClass:NSTableView.class] ? self.table.clickedRow : [self.table rowForView:sender];
    if (row < 0 || row >= (NSInteger)[OVHistory shared].all.count) return nil;
    return [OVHistory shared].all[row];
}

- (void)playRow:(id)s { OVGeneration *g = [self genFor:s]; if (g) [[OVPlayer shared] toggle:g.path]; }
- (void)improveRow:(id)s {
    OVGeneration *g = [self genFor:s];
    if (!g) return;
    OVVoice *v = g.voiceId ? [[OVVoices shared] voiceWithId:g.voiceId] : nil;
    if (g.voiceId && !v.ready) { self.status.stringValue = L(@"This recording’s voice was deleted or isn’t ready"); return; }
    [self synthesizeText:g.text voice:v improve:YES];
}
- (void)revealRow:(id)s {
    OVGeneration *g = [self genFor:s];
    if (g) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:g.path]]];
}
- (void)deleteRow:(id)s {
    OVGeneration *g = [self genFor:s];
    if (!g) return;
    if ([[OVPlayer shared].currentPath isEqualToString:g.path]) [[OVPlayer shared] stop];
    [[OVHistory shared] remove:g];
}
@end
