#import "OVPages.h"
#import "OVDesign.h"
#import "OVTrainSheet.h"
#import "OVRuntime.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVMemory.h"
#import "OVExport.h"
#import "OVPresets.h"
#import "OVEffectsView.h"
#import "OVPlayerBar.h"
#import "OVBatchSheet.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kAutoVoice = @"__auto__";
static const CGFloat kTakeRowHeight = 56;
static const NSUInteger kTakeRowsVisible = 8;

#pragma mark - Editor

@interface OVTextEditor : NSTextView
@property (copy) NSString *placeholder;
@end
@implementation OVTextEditor
- (void)drawRect:(NSRect)r {
    [super drawRect:r];
    if (self.string.length || !self.placeholder) return;
    NSDictionary *a = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: OVColor(OVRoleMuted)};
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

#pragma mark - Private helpers

/// SF Symbol of each mood preset (the pictographs of OVSettings moods are not used on screen).
static NSString *MoodSymbol(NSString *moodId) {
    static NSDictionary *symbols;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbols = @{@"neutral": @"face.dashed", @"calm": @"leaf", @"cheerful": @"sun.max", @"energetic": @"bolt",
                    @"serious": @"eyeglasses", @"warm": @"heart", @"sad": @"cloud.rain", @"storyteller": @"book"};
    });
    return symbols[moodId] ?: @"circle";
}

/// Lets a control shrink instead of forcing its column wider (long voice names).
static void ShrinkOnly(NSView *v) {
    [v setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
}

static void Squeezable(NSView *v) {
    ShrinkOnly(v);
    [v setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
}

/// A muted status line that takes no room while it is empty.
@interface OVStatusLabel : NSTextField
@end
@implementation OVStatusLabel
- (void)setStringValue:(NSString *)v { [super setStringValue:v]; self.hidden = v.length == 0; }
@end

/// Field block with a muted hint line below it (built here, so nothing depends on OVFieldBlock's internals).
static NSView *BlockWithHint(NSString *label, NSView *control, NSTextField *hint) {
    return OVFillStack(@[OVFieldBlock(label, nil, control), hint], 6);
}

/// A modal one-line text question. nil when cancelled or empty.
static NSString *AskName(NSString *title, NSString *button, NSString *initial) {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    [a addButtonWithTitle:button];
    [a addButtonWithTitle:L(@"Cancel")];
    NSTextField *f = OVField(L(@"Name"));
    f.stringValue = initial ?: @"";
    f.accessibilityLabel = L(@"Name");
    f.frame = NSMakeRect(0, 0, 300, 34);
    a.accessoryView = f;
    a.window.initialFirstResponder = f;
    if ([a runModal] != NSAlertFirstButtonReturn) return nil;
    NSString *n = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return n.length ? n : nil;
}

/// Fills a popup with the export formats (the ffmpeg lookup can block, so it runs off the main thread); formats this Mac cannot write
/// are grey with the reason as the tooltip. The selected item follows `selectedId`.
static void FillFormatPopup(OVPopup *popup, NSString *selectedId) {
    popup.autoenablesItems = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [OVExport resetFFmpegCache];
        NSArray<NSDictionary *> *formats = [OVExport formats];
        dispatch_async(dispatch_get_main_queue(), ^{
            [popup removeAllItems];
            for (NSDictionary *f in formats) {
                [popup addItemWithTitle:f[@"title"]];
                popup.lastItem.representedObject = f[@"id"];
                BOOL ok = [f[@"available"] boolValue];
                popup.lastItem.enabled = ok;
                popup.lastItem.toolTip = ok ? nil : f[@"reason"];
            }
            NSInteger i = [popup indexOfItemWithRepresentedObject:selectedId];
            if (i >= 0 && !popup.itemArray[i].enabled) {   // saved format that cannot be made now (no ffmpeg): WAV
                [NSUserDefaults.standardUserDefaults setObject:@"wav" forKey:@"exportFormat"];
                [NSUserDefaults.standardUserDefaults setInteger:-1 forKey:@"exportQuality"];
                popup.toolTip = [NSString stringWithFormat:L(@"%@ isn’t available now (ffmpeg is missing), so WAV is used."), [selectedId uppercaseString]];
                i = [popup indexOfItemWithRepresentedObject:@"wav"];
            }
            [popup selectItemAtIndex:MAX(0, i)];
        });
    });
}

#pragma mark - History cell

@interface OVHistoryCell : NSTableCellView
@property NSButton *play, *improve, *reveal, *trash;
@property NSTextField *text, *meta;
@property NSStackView *metaRow;
@property NSView *badge, *formatBadge;
- (void)setLikeness:(double)likeness;   // < 0 = not measured: no badge
- (void)setFormat:(NSString *)formatId effects:(BOOL)effects;   // a badge for a non-WAV copy and for a take with effects
@end

@implementation OVHistoryCell
- (instancetype)initWithTarget:(id)t {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.play = OVPlayButton(t, @selector(playRow:));
        self.play.toolTip = L(@"Listen");
        self.play.accessibilityLabel = L(@"Listen");
        self.text = OVLabel(@"", 14, NSFontWeightRegular, nil);
        self.text.maximumNumberOfLines = 1;
        self.meta = OVLabel(@"", 12, NSFontWeightRegular, OVColor(OVRoleMuted));
        self.meta.maximumNumberOfLines = 1;
        self.improve = OVIconButton(@"sparkles", L(@"Re-speak with auto-improve"), t, @selector(improveRow:));
        self.reveal = OVIconButton(@"folder", L(@"Show in Finder"), t, @selector(revealRow:));
        self.trash = OVIconButton(@"trash", L(@"Delete"), t, @selector(deleteRow:));
        for (NSButton *b in @[self.improve, self.reveal, self.trash]) b.accessibilityLabel = b.toolTip;
        self.metaRow = OVHStack(@[self.meta, OVSpacer()], 8);
        NSStackView *texts = OVFillStack(@[self.text, self.metaRow], 3);
        ShrinkOnly(texts);
        NSStackView *row = OVHStack(@[self.play, texts, self.improve, self.reveal, self.trash], 10);
        [self addSubview:row];
        OVPin(row, self, NSEdgeInsetsMake(8, 12, 8, 12));
    }
    return self;
}
- (void)setLikeness:(double)l {
    [self.badge removeFromSuperview];
    self.badge = nil;
    if (l < 0) return;
    OVRole tone = l >= 0.8 ? OVRoleOK : l >= 0.6 ? OVRoleWarn : OVRoleErr;
    self.badge = OVBadge([NSString stringWithFormat:L(@"voice %.0f%%"), l * 100], tone);
    [self.metaRow insertArrangedSubview:self.badge atIndex:1];
}
- (void)setFormat:(NSString *)formatId effects:(BOOL)effects {
    [self.formatBadge removeFromSuperview];
    self.formatBadge = nil;
    NSMutableArray *parts = [NSMutableArray array];
    if (![formatId isEqualToString:@"wav"]) [parts addObject:formatId.uppercaseString];
    if (effects) [parts addObject:L(@"FX")];
    if (!parts.count) return;
    self.formatBadge = OVCompactBadge([parts componentsJoinedByString:@" · "], OVRoleMuted);
    [self.metaRow insertArrangedSubview:self.formatBadge atIndex:1];
}
@end

#pragma mark - Page

@interface OVSynthPage () <NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate>
@property OVAvatar *avatar;
@property OVPopup *voicePopup, *langPopup, *loraPopup;
@property NSButton *sampleButton, *tuneButton, *adaptCheck, *pronButton;
@property OVSegmented *quality, *moodPicker;
@property NSTextField *counter, *status, *banner, *voiceHint, *detectedHint, *memoryLabel, *pronLabel, *pronDetail, *moodName;
@property NSView *pronRow, *designRow;
@property OVDisclosure *styleDisclosure;
@property NSArray<OVSliderRow *> *styleSliders;
@property OVSliderRow *speedRow;
@property OVSwitch *improveSwitch;
@property NSTextField *improveHint;
@property OVTextEditor *editor;
@property NSButton *synthButton, *stopButton;
@property NSProgressIndicator *progress;
@property NSTableView *table;
@property NSLayoutConstraint *tableHeight;
@property NSView *bannerCard, *playerBar, *emptyHistory;
@property NSTextField *historyTitle, *playerTitle;
@property OVPlayerBar *abBar;
@property OVPopup *presetPopup, *formatPopup;
@property BOOL exporting;   // a copy in the chosen format is being written: no new synth until it is done
@property NSButton *presetRename, *presetDelete, *saveAsButton, *batchButton;
@property OVEffectsView *effects;
@property (copy) NSString *presetId, *lastResultPath;
@property NSPopover *tunePopover;
@property NSTimer *timer;
@property CFAbsoluteTime started;
@property BOOL lastAdaptAccent;
@end

@implementation OVSynthPage

- (void)loadView {
    // ── header and the "something is missing" banner
    NSView *header = OVPageHeader(L(@"Speech"), L(@"Type text and speak it in a cloned voice."), nil);
    self.banner = OVLabel(@"", 14, NSFontWeightMedium, nil);
    NSButton *fix = OVButtonHeight(OVGhostButton(L(@"Open setup"), nil, self, @selector(openSetup:)), 28);
    NSStackView *bannerRow = OVHStack(@[OVSymbol(@"exclamationmark.triangle", 16, OVColor(OVRoleWarn)), self.banner, OVSpacer(), fix], 10);
    OVBoxView *banner = [OVBoxView boxWithFill:OVColorAlpha(OVRoleWarn, 0.08) border:OVColor(OVRoleWarn) radius:10];
    [banner addSubview:bannerRow];
    OVPin(bannerRow, banner, NSEdgeInsetsMake(10, 14, 10, 14));
    self.bannerCard = banner;

    // ── 1 · Text
    NSScrollView *scroll = [OVTextEditor scrollableTextView];
    self.editor = [[OVTextEditor alloc] initWithFrame:scroll.contentView.bounds];
    self.editor.autoresizingMask = NSViewWidthSizable;
    self.editor.verticallyResizable = YES;
    self.editor.textContainer.widthTracksTextView = YES;
    scroll.documentView = self.editor;
    self.editor.font = [NSFont systemFontOfSize:16];
    self.editor.richText = NO;
    self.editor.allowsUndo = YES;
    self.editor.automaticQuoteSubstitutionEnabled = NO;
    self.editor.automaticDashSubstitutionEnabled = NO;
    self.editor.automaticTextReplacementEnabled = NO;
    self.editor.automaticSpellingCorrectionEnabled = NO;
    self.editor.delegate = self;
    self.editor.placeholder = L(@"Type or paste text to speak…");
    NSView *textArea = OVTextArea(scroll, 150);
    [textArea setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    self.editor.string = [NSUserDefaults.standardUserDefaults stringForKey:@"draftText"] ?: @"";   // after the area: it sets text colors

    self.counter = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSButton *stress = OVButtonHeight(OVGhostButton(L(@"Stress ´"), nil, self, @selector(toggleStress:)), 28);
    stress.toolTip = L(@"Mark the stress on the selected vowel (or the one before the cursor): виши́вка. Press again to remove it. Shortcut ⌘'. The mark steers Auto-improve: of the takes of that phrase, the one that stresses this syllable wins. It is not sent to the model — marks make Ukrainian sound Russian.");
    NSButton *sounds = OVButtonHeight(OVGhostButton(L(@"Sound"), @"face.smiling", self, @selector(showSounds:)), 28);
    sounds.toolTip = L(@"Insert a sound: laughter, sigh, surprise…");
    NSStackView *tools = OVHStack(@[stress, sounds, OVSpacer(), self.counter], 8);
    NSView *card1 = OVStepCard(1, @"doc.text", L(@"Text"), nil, OVFillStack(@[textArea, tools], 12));

    // ── 2 · Voice and style
    self.avatar = [OVAvatar avatarWithSize:28];
    [self.avatar.widthAnchor constraintEqualToConstant:28].active = YES;
    [self.avatar.heightAnchor constraintEqualToConstant:28].active = YES;
    self.voicePopup = [OVPopup popup];
    self.voicePopup.target = self;
    self.voicePopup.action = @selector(voicePicked:);
    self.voicePopup.autoenablesItems = NO;
    self.voicePopup.accessibilityLabel = L(@"Voice");
    Squeezable(self.voicePopup);
    NSStackView *voiceControl = OVHStack(@[self.avatar, self.voicePopup], 10);
    self.voiceHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSView *voiceBlock = BlockWithHint(L(@"Voice"), voiceControl, self.voiceHint);

    self.langPopup = [OVPopup popup];
    self.langPopup.target = self;
    self.langPopup.action = @selector(languagePicked:);
    self.langPopup.toolTip = L(@"Speech language. Auto-detect recognizes it from the text.");
    Squeezable(self.langPopup);
    self.detectedHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSView *langBlock = BlockWithHint(L(@"Language"), OVFillPopup(self.langPopup), self.detectedHint);
    [self buildLanguageMenu];

    self.sampleButton = OVButtonHeight(OVGhostButton(L(@"Voice sample"), @"waveform", self, @selector(playSample:)), 28);
    self.tuneButton = OVButtonHeight(OVGhostButton(L(@"LoRA"), @"slider.horizontal.3", self, @selector(showTune:)), 28);
    self.tuneButton.toolTip = L(@"LoRA and accent removal");
    NSView *cardAccessory = OVHStack(@[self.sampleButton, self.tuneButton], 8);

    // pronunciation of the selected voice in the language of the text, and its training
    self.pronLabel = OVLabel(@"", 14, NSFontWeightSemibold, nil);
    self.pronDetail = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.pronButton = OVButtonHeight(OVGhostButton(L(@"Train…"), nil, self, @selector(showTraining:)), 28);
    self.pronButton.toolTip = L(@"Teach the voice clean pronunciation in this language, round by round, with the numbers of every round");
    NSStackView *pronTexts = OVVStack(@[self.pronLabel, self.pronDetail], 1);
    ShrinkOnly(pronTexts);
    [pronTexts setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];   // beats the spacer
    NSStackView *pron = OVHStack(@[OVSymbol(@"graduationcap", 17, OVColor(OVRoleAccent)), pronTexts, OVSpacer(), self.pronButton], 12);
    OVBoxView *pronBox = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
    [pronBox addSubview:pron];
    OVPin(pron, pronBox, NSEdgeInsetsMake(12, 12, 12, 12));
    self.pronRow = pronBox;

    // moods: one icon per preset, the name of the chosen one next to them
    NSArray<NSDictionary *> *moods = [OVSettings moods];
    NSMutableArray *moodItems = [NSMutableArray array];
    for (NSDictionary *m in moods) [moodItems addObject:@[@"", MoodSymbol(m[@"id"]), m[@"title"]]];
    self.moodPicker = [OVSegmented segmentedWithItems:moodItems];
    self.moodPicker.target = self;
    self.moodPicker.action = @selector(moodPicked:);
    self.moodName = OVLabel(@"", 13, NSFontWeightSemibold, OVColor(OVRoleAccent));
    NSStackView *moodControl = OVHStack(@[self.moodPicker, self.moodName, OVSpacer()], 12);
    moodControl.toolTip = L(@"A preset of the controls below. OmniVoice has no emotion switch: a cloned voice takes its feeling from the sample, so record the sample in the mood you need — the presets shape what can be shaped afterwards.");
    NSView *moodBlock = OVFieldBlock(L(@"Mood"), nil, moodControl);

    self.quality = [OVSegmented segmentedWithItems:@[@[L(@"Fast"), @""], @[L(@"Standard"), @""], @[L(@"Maximum"), @""]]];
    self.quality.target = self;
    self.quality.action = @selector(qualityPicked:);
    self.quality.toolTip = L(@"Decoding steps: 16 / 32 / 64");
    NSView *qualityBlock = OVFieldBlock(L(@"Quality"), nil, self.quality);

    __weak typeof(self) w = self;
    void (^retime)(void) = ^{ [w textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]]; };
    void (^custom)(void) = ^{ // a hand-moved slider leaves the preset
        [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:@"styleMood"];
        [w refreshMood];
        retime();
    };
    NSString *(^percent)(double) = ^(double v) { return fabs(v) < 0.005 ? @"0" : [NSString stringWithFormat:@"%+.0f%%", v * 100]; };
    OVSliderRow *(^slider)(NSString *, NSString *, NSString *, double, double, double, NSString *(^)(double), void (^)(void)) =
        ^OVSliderRow *(NSString *title, NSString *tip, NSString *key, double min, double max, double step, NSString *(^fmt)(double), void (^moved)(void)) {
            OVSliderRow *r = [OVSliderRow rowWithTitle:title hint:nil key:key min:min max:max format:@"%.2f" integer:NO];
            r.compact = YES;
            r.step = step;
            r.valueFormatter = fmt;
            r.onChange = moved;
            r.toolTip = tip;
            [r refresh];
            return r;
        };
    self.speedRow = slider(L(@"Speed"), L(@"1.0 is the natural pace as judged by the model."), @"speed", 0.7, 1.4, 0.05,
                           ^(double v) { return [NSString stringWithFormat:@"%.2f×", v]; }, retime);
    // the slider lines up with the Quality control: it sits below the height of a field label
    NSStackView *speedColumn = OVVStack(@[self.speedRow], 0);
    speedColumn.edgeInsets = NSEdgeInsetsMake(31, 0, 0, 0);
    OVFillWidth(@[self.speedRow], speedColumn);
    NSView *qualitySpeed = OVColumns(@[qualityBlock, speedColumn], 16);

    OVSliderRow *intonation = slider(L(@"Intonation"), L(@"Flat ↔ lively: narrows or widens the pitch melody of the voice."), @"styleIntonation", -1, 1, 0.05, percent, custom);
    OVSliderRow *energy = slider(L(@"Energy"), L(@"Relaxed ↔ energetic: pace, pauses, melody, presence and dynamics together."), @"styleEnergy", -1, 1, 0.05, percent, custom);
    OVSliderRow *pitch = slider(L(@"Pitch"), L(@"Deeper ↔ higher voice, in semitones. The timbre moves with it: lower is bigger and darker, higher is lighter."), @"stylePitch", -4, 4, 0.5,
                                ^(double v) { return fabs(v) < 0.05 ? @"0" : [NSString stringWithFormat:L(@"%+.1f st"), v]; }, custom);
    OVSliderRow *tone = slider(L(@"Tone"), L(@"Warm ↔ bright: more body or more clarity in the timbre."), @"styleTone", -1, 1, 0.05, percent, custom);
    OVSliderRow *pauses = slider(L(@"Pauses"), L(@"Pauses between sentences and paragraphs."), @"stylePauses", 0.5, 2.5, 0.1,
                                 ^(double v) { return [NSString stringWithFormat:@"%.1f×", v]; }, custom);
    OVSliderRow *volume = slider(L(@"Volume"), L(@"Loudness of the finished recording."), @"styleVolume", -6, 6, 1,
                                 ^(double v) { return fabs(v) < 0.5 ? @"0" : [NSString stringWithFormat:L(@"%+.0f dB"), v]; }, nil);
    self.styleSliders = @[self.speedRow, intonation, energy, pitch, tone, pauses, volume];
    NSView *sliderColumns = OVColumns(@[OVFillStack(@[intonation, energy, pitch], 14), OVFillStack(@[tone, pauses, volume], 14)], 24);

    // voice design: only the model's own voice listens to these tags, a clone follows its sample
    OVPopup *gender = OVDefaultsPopup(@[@[L(@"Any gender"), @""], @[L(@"Male"), @"male"], @[L(@"Female"), @"female"]], @"designGender", nil, nil);
    OVPopup *age = OVDefaultsPopup(@[@[L(@"Any age"), @""], @[L(@"Child"), @"child"], @[L(@"Teenager"), @"teenager"], @[L(@"Young adult"), @"young adult"],
                                     @[L(@"Middle-aged"), @"middle-aged"], @[L(@"Elderly"), @"elderly"]], @"designAge", nil, nil);
    OVPopup *level = OVDefaultsPopup(@[@[L(@"Any pitch"), @""], @[L(@"Very low"), @"very low pitch"], @[L(@"Low"), @"low pitch"], @[L(@"Medium"), @"moderate pitch"],
                                       @[L(@"High"), @"high pitch"], @[L(@"Very high"), @"very high pitch"]], @"designPitch", nil, nil);
    NSMutableArray *accents = [@[@[L(@"No accent"), @""]] mutableCopy];
    for (NSArray *a in @[@[L(@"American"), @"american"], @[L(@"British"), @"british"], @[L(@"Australian"), @"australian"],
                         @[L(@"Canadian"), @"canadian"], @[L(@"Indian"), @"indian"], @[L(@"Chinese"), @"chinese"],
                         @[L(@"Korean"), @"korean"], @[L(@"Japanese"), @"japanese"], @[L(@"Portuguese"), @"portuguese"],
                         @[L(@"Russian"), @"russian"]])
        [accents addObject:@[a[0], [a[1] stringByAppendingString:@" accent"]]];
    OVPopup *accent = OVDefaultsPopup(accents, @"designAccent", nil, nil);
    accent.toolTip = L(@"Accent of the model’s own voice — for English text only.");
    for (OVPopup *p in @[gender, age, level, accent]) Squeezable(p);
    NSButton *whisper = OVCheckbox(L(@"Whisper"), @"designWhisper");
    NSStackView *designTitle = OVHStack(@[OVLabel(L(@"Model’s voice"), 14, NSFontWeightSemibold, nil), OVSpacer(), whisper], 8);
    NSStackView *design = OVFillStack(@[designTitle, OVColumns(@[OVFillPopup(gender), OVFillPopup(age)], 12), OVColumns(@[OVFillPopup(level), OVFillPopup(accent)], 12)], 10);
    design.toolTip = L(@"What the model’s own voice sounds like (voice design). Cloned voices follow their sample instead.");
    self.designRow = design;

    NSButton *reset = OVButtonHeight(OVGhostButton(L(@"Reset"), nil, self, @selector(resetStyle:)), 28);
    reset.toolTip = L(@"Reset the voice style");
    NSStackView *resetRow = OVHStack(@[OVSpacer(), reset], 8);
    // presets: style + format + effects chain + formants
    self.presetPopup = [OVPopup popup];
    self.presetPopup.target = self;
    self.presetPopup.action = @selector(presetPicked:);
    self.presetPopup.accessibilityLabel = L(@"Preset");
    self.presetPopup.autoenablesItems = NO;
    Squeezable(self.presetPopup);
    OVFlowRow *presetButtons = [OVFlowRow new];
    NSButton *presetSave = OVButtonHeight(OVGhostButton(L(@"Save current as preset…"), nil, self, @selector(presetSave:)), 28);
    self.presetRename = OVButtonHeight(OVGhostButton(L(@"Rename"), nil, self, @selector(presetRename:)), 28);
    self.presetDelete = OVButtonHeight(OVGhostButton(L(@"Delete"), nil, self, @selector(presetDelete:)), 28);
    NSButton *presetImport = OVButtonHeight(OVGhostButton(L(@"Import…"), nil, self, @selector(presetImport:)), 28);
    NSButton *presetExport = OVButtonHeight(OVGhostButton(L(@"Export…"), nil, self, @selector(presetExport:)), 28);
    [presetButtons setItems:@[presetSave, self.presetRename, self.presetDelete, presetImport, presetExport]];
    NSView *presetBlock = OVFieldBlock(L(@"Preset"), L(@"A preset keeps the voice style, the file format and the effects chain."),
                                       OVFillStack(@[OVFillPopup(self.presetPopup), presetButtons], 8));
    NSStackView *styleContent = OVFillStack(@[presetBlock, sliderColumns, design, resetRow], 16);
    self.styleDisclosure = [OVDisclosure disclosureWithTitle:L(@"Voice style") subtitle:L(@"Default") symbol:@"slider.horizontal.3" content:styleContent];
    self.styleDisclosure.expanded = [NSUserDefaults.standardUserDefaults boolForKey:@"stylePanel"];
    self.styleDisclosure.onToggle = ^(BOOL expanded) { [NSUserDefaults.standardUserDefaults setBool:expanded forKey:@"stylePanel"]; };

    self.effects = [OVEffectsView new];
    NSArray *savedChain = [NSUserDefaults.standardUserDefaults arrayForKey:@"effectsChain"];
    if (savedChain) self.effects.chain = savedChain;
    self.effects.onChange = ^{ [NSUserDefaults.standardUserDefaults setObject:w.effects.chain forKey:@"effectsChain"]; };

    NSView *card2 = OVStepCardWithAccessory(2, @"person.wave.2", L(@"Voice and style"), cardAccessory,
        OVFillStack(@[OVColumns(@[voiceBlock, langBlock], 16), self.pronRow, moodBlock, qualitySpeed, self.styleDisclosure, self.effects], 16));

    // ── 3 · Result
    self.improveSwitch = [OVSwitch new];
    self.improveSwitch.target = self;
    self.improveSwitch.action = @selector(improveToggled:);
    self.improveSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:@"improve"];
    self.improveSwitch.accessibilityLabel = L(@"Auto-improve");
    self.improveHint = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSTextField *improveTitle = OVLabel(L(@"Auto-improve"), 14, NSFontWeightSemibold, nil);
    NSStackView *improveTexts = OVVStack(@[improveTitle, self.improveHint], 0);
    ShrinkOnly(improveTexts);
    [improveTexts setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];   // beats the spacer
    NSStackView *improveBox = OVHStack(@[self.improveSwitch, OVSymbol(@"sparkles", 16, OVColor(OVRoleAccent)), improveTexts], 10);
    improveBox.toolTip = L(@"Text is prepared for reading aloud (abbreviations, numbers, years), each phrase is spoken several times and the take that is clearest, sounds most native and most like the voice, with the dictionary stress, is kept. Slower, but the best result.");

    self.synthButton = OVPrimaryButton(L(@"Speak"), self, @selector(synthesize:));
    self.synthButton.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    self.synthButton.keyEquivalent = @"\r";
    self.synthButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.synthButton.toolTip = @"⌘↩";
    [self.synthButton.widthAnchor constraintGreaterThanOrEqualToConstant:118].active = YES;
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.batchButton = OVGhostButton(L(@"Batch…"), @"list.bullet.rectangle", self, @selector(showBatch:));
    self.batchButton.toolTip = L(@"Speak many texts from a file or a list, with one voice and preset");
    NSStackView *actionRow = OVHStack(@[improveBox, OVSpacer(), self.stopButton, self.batchButton, self.synthButton], 12);

    self.progress = OVProgressBar();
    self.progress.hidden = YES;
    OVStatusLabel *status = [OVStatusLabel labelWithString:@""];
    status.font = [NSFont systemFontOfSize:13];
    status.textColor = OVColor(OVRoleMuted);
    status.hidden = YES;
    ShrinkOnly(status);
    self.status = status;
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;

    // player: play / scrubber / time, and Original | Result when the take went through the effects chain
    self.playerTitle = OVLabel(@"", 14, NSFontWeightMedium, nil);
    self.playerTitle.maximumNumberOfLines = 1;
    self.playerTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    ShrinkOnly(self.playerTitle);
    self.abBar = [OVPlayerBar new];
    self.playerBar = OVFillStack(@[self.playerTitle, self.abBar], 6);
    self.playerBar.hidden = YES;

    // the file format of new recordings, and a copy to any place
    self.formatPopup = [OVPopup popup];
    self.formatPopup.target = self;
    self.formatPopup.action = @selector(formatPicked:);
    self.formatPopup.accessibilityLabel = L(@"File format");
    FillFormatPopup(self.formatPopup, [OVSettings exportFormatId]);
    self.saveAsButton = OVButtonHeight(OVGhostButton(L(@"Save as…"), @"square.and.arrow.down", self, @selector(saveAs:)), 28);
    self.saveAsButton.toolTip = L(@"Save the last recording in this format wherever you like. New recordings are also saved next to the WAV in this format.");
    NSStackView *exportRow = OVHStack(@[OVLabel(L(@"Format"), 13, NSFontWeightRegular, OVColor(OVRoleMuted)), self.formatPopup, self.saveAsButton, OVSpacer()], 10);

    self.memoryLabel = OVLabel(@"", 12, NSFontWeightMedium, OVColor(OVRoleMuted));
    self.memoryLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.memoryLabel.toolTip = L(@"Memory used by the speech engine and memory still free on this Mac");
    [self.memoryLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *memoryRow = OVHStack(@[OVSpacer(), OVSymbol(@"memorychip", 12, OVColor(OVRoleMuted)), self.memoryLabel], 6);
    NSView *card3 = OVStepCard(3, @"waveform", L(@"Result"), nil, OVFillStack(@[actionRow, self.progress, self.status, self.playerBar, exportRow, memoryRow], 12));

    // ── recent takes
    NSButton *openFolder = OVButtonHeight(OVGhostButton(L(@"Open folder"), @"folder", self, @selector(openOutputs:)), 28);
    NSStackView *takesHeader = (NSStackView *)OVCardHeader(0, @"clock.arrow.circlepath", L(@"Recent takes"), openFolder);
    for (NSView *v in takesHeader.arrangedSubviews)
        if ([v isKindOfClass:NSTextField.class]) self.historyTitle = (NSTextField *)v;

    self.table = [NSTableView new];
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"g"]];
    self.table.headerView = nil;
    self.table.rowHeight = kTakeRowHeight;
    self.table.style = NSTableViewStylePlain;
    self.table.intercellSpacing = NSZeroSize;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.doubleAction = @selector(playRow:);
    self.table.target = self;
    self.table.accessibilityLabel = L(@"Recent takes");
    NSScrollView *tscroll = [NSScrollView new];
    tscroll.documentView = self.table;
    tscroll.hasVerticalScroller = YES;
    tscroll.autohidesScrollers = YES;
    tscroll.drawsBackground = NO;
    self.tableHeight = [tscroll.heightAnchor constraintEqualToConstant:kTakeRowHeight];
    self.tableHeight.active = YES;
    self.emptyHistory = OVEmptyState(@"waveform", L(@"No recordings yet"),
        [NSString stringWithFormat:L(@"Finished recordings appear here. WAV files are saved to Music → %@."), OVAppName], @[]);
    NSStackView *takesBox = OVVStack(@[tscroll, self.emptyHistory], 0);
    takesBox.alignment = NSLayoutAttributeCenterX;
    OVFillWidth(@[tscroll], takesBox);
    NSStackView *takesBlock = OVFillStack(@[takesHeader, OVCard(takesBox, 8)], 12);

    self.view = OVPageScroll(@[header, self.bannerCard, card1, card2, card3, takesBlock]);

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
    [nc addObserver:self selector:@selector(themeChanged) name:OVThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reloadPresets) name:OVPresetsDidChangeNotification object:nil];

    [self buildTunePopover];
    [self reloadPresets];
    self.lastAdaptAccent = [OVSettings adaptAccent];
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
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
}

- (void)themeChanged {
    [self refreshMood];
    [self refreshState];
    [self refreshVoiceHint];
}

#pragma mark Voice style

/// The mood picker follows the "styleMood" setting; a slider moved by hand leaves no preset selected ("Custom").
- (void)refreshMood {
    NSString *mood = [NSUserDefaults.standardUserDefaults stringForKey:@"styleMood"] ?: @"neutral";
    NSArray<NSDictionary *> *moods = [OVSettings moods];
    NSUInteger idx = [[moods valueForKey:@"id"] indexOfObject:mood];
    BOOL plain = [OVSettings styleIsNeutral] && fabs([NSUserDefaults.standardUserDefaults doubleForKey:@"speed"] - 1) < 0.005;
    if (idx == NSNotFound) {
        self.moodPicker.selectedIndex = -1;
        self.moodName.stringValue = L(@"Custom");
        self.styleDisclosure.subtitle = L(@"Custom");
    } else {
        self.moodPicker.selectedIndex = idx;
        self.moodName.stringValue = moods[idx][@"title"];
        self.styleDisclosure.subtitle = plain && [mood isEqualToString:@"neutral"] ? L(@"Default") : moods[idx][@"title"];
    }
    self.moodName.textColor = OVColor(OVRoleAccent);
}

- (void)moodPicked:(OVSegmented *)c {
    if (c.selectedIndex < 0) return;
    [OVSettings applyMood:[OVSettings moods][c.selectedIndex][@"id"]];
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
    self.adaptCheck = OVCheckbox(L(@"Remove the sample’s accent in other languages"), @"adaptAccent");
    self.adaptCheck.toolTip = L(@"When the text is in another language than the voice sample, the voice first says two short phrases in that language, three times each. The takes are scored by how much they sound like you and how cleanly they are pronounced; the two best become the voice’s sample for that language. Takes about two minutes, once per voice and language.");
    self.loraPopup = [OVPopup popup];
    self.loraPopup.target = self;
    self.loraPopup.action = @selector(loraPicked:);
    self.loraPopup.autoenablesItems = NO;
    self.loraPopup.toolTip = L(@"LoRA adapter on top of the model. The chosen adapter is downloaded automatically.");
    [self.loraPopup.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    NSButton *more = OVButtonHeight(OVGhostButton(L(@"All settings…"), nil, self, @selector(openSettings:)), 28);
    NSGridView *g = [NSGridView gridViewWithViews:@[
        @[OVLabel(L(@"LoRA"), 13, NSFontWeightSemibold, nil), self.loraPopup],
        @[OVLabel(L(@"Accent"), 13, NSFontWeightSemibold, nil), self.adaptCheck],
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

#pragma mark State

- (void)syncControls {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger steps = [d integerForKey:@"numStep"];
    self.quality.selectedIndex = steps <= 20 ? 0 : steps <= 40 ? 1 : 2;
    self.adaptCheck.state = [OVSettings adaptAccent] ? NSControlStateValueOn : NSControlStateValueOff;
    for (OVSliderRow *s in self.styleSliders) [s refresh];
    NSInteger fi = [self.formatPopup indexOfItemWithRepresentedObject:[OVSettings exportFormatId]];
    if (fi >= 0 && fi != self.formatPopup.indexOfSelectedItem) [self.formatPopup selectItemAtIndex:fi];
    [self refreshMood];
    if ([OVSettings adaptAccent] != self.lastAdaptAccent) {   // the accent checkbox (or Settings) changed it: the voice hint depends on it
        self.lastAdaptAccent = [OVSettings adaptAccent];
        [self refreshVoiceHint];
    }
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
    self.banner.toolTip = problem;
    BOOL busy = [OVWorker shared].busy;
    self.synthButton.enabled = !busy && !self.exporting && problem == nil;
    self.batchButton.enabled = self.synthButton.enabled;
    self.stopButton.hidden = !busy;
    self.progress.hidden = !busy && self.progress.doubleValue <= 0;
    // a ghost pill cannot be tinted, so an active adapter is shown by name
    self.tuneButton.title = lora ? [NSString stringWithFormat:L(@"LoRA · %@"), lora.title.length > 16 ? [[lora.title substringToIndex:15] stringByAppendingString:@"…"] : lora.title] : L(@"LoRA");
    self.tuneButton.toolTip = lora ? [NSString stringWithFormat:L(@"LoRA “%@” is on. LoRA and accent removal"), lora.title] : L(@"LoRA and accent removal");
    [self refreshMemory];

    OVModel *asrDl = nil;
    for (OVModel *m in [mm modelsOfKind:OVModelASR]) if (m.downloading) asrDl = m;
    BOOL on = self.improveSwitch.on;
    self.improveHint.stringValue = !on ? L(@"checks every phrase") :
        asrDl ? [NSString stringWithFormat:L(@"downloading Whisper — %.0f%%"), asrDl.progress * 100] :
        mm.asrModel ? [NSString stringWithFormat:L(@"%ld takes per phrase, best kept"), (long)[NSUserDefaults.standardUserDefaults integerForKey:@"improveAttempts"]] :
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
    self.memoryLabel.textColor = OVColor(avail < 1024ULL * 1024 * 1024 ? OVRoleWarn : OVRoleMuted);
}

- (void)improveToggled:(OVSwitch *)s {
    BOOL on = s.on;
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
    BOOL cleans = !mismatch && v.accented && textLang && [v adaptsToLanguage:textLang];  // accented sample, its own language
    NSString *from = mismatch ? [OVLocale nameForLanguage:sampleLang] : nil, *to = mismatch ? [OVLocale nameForLanguage:textLang] : nil;
    if (cleans)
        hint = [v.adaptedLanguages containsObject:textLang]
            ? [NSString stringWithFormat:L(@"%@ sample with an accent → clean %@"), OVFormatDuration(v.seconds), [OVLocale nameForLanguage:textLang]]
            : [NSString stringWithFormat:L(@"%@ sample with an accent → clean %@ after the first run (about two minutes)"), OVFormatDuration(v.seconds), [OVLocale nameForLanguage:textLang]];
    else if (adapts)
        hint = [v.adaptedLanguages containsObject:textLang]
            ? [NSString stringWithFormat:L(@"%@ sample → %@ without its accent"), from, to]
            : [NSString stringWithFormat:L(@"%@ sample → %@: the accent is removed on the first run (about a minute)"), from, to];
    else if (mismatch)
        hint = [NSString stringWithFormat:L(@"%@ sample — its accent carries over into %@"), from, to];
    self.voiceHint.stringValue = hint;
    self.voiceHint.textColor = OVColor(mismatch && !adapts ? OVRoleWarn : OVRoleMuted);
    self.voiceHint.toolTip = cleans ? L(@"The sample has a noticeable accent (Whisper finds its own transcript unlikely). The voice first says two short phrases in this language several times; the takes that sound most like you and most native become its sample, so the accent fades. Switch it off under the sliders button to keep the accent.")
                           : adapts ? L(@"The voice first says a short phrase in the new language; the cleanest take becomes its sample for that language, so the accent of the original sample doesn’t carry over. Switch it off under the sliders button to keep the accent.")
                           : mismatch ? L(@"Train the voice’s pronunciation in this language (Train… next to the voice), or turn on “Remove the sample’s accent” under the sliders button.") : nil;
    self.designRow.hidden = v != nil;  // voice design tags only work for the model’s own voice
    [self refreshPronunciation];
}

/// "Pronunciation · English — 72% · likeness 66%": the last numbers measured for this voice and language.
- (void)refreshPronunciation {
    OVVoice *v = [self selectedVoice];
    NSString *lang = [self textLanguage] ?: v.language;
    self.pronRow.hidden = !v.ready || !lang.length;
    if (self.pronRow.hidden) return;
    NSDictionary *info = [v trainingInfo:lang];
    NSDictionary *now = info[@"trained"] ?: info[@"original"];
    self.pronLabel.stringValue = [NSString stringWithFormat:L(@"Pronunciation · %@"), [OVLocale nameForLanguage:lang]];
    self.pronDetail.stringValue = now ? [NSString stringWithFormat:L(@"%.0f%% · likeness %.0f%%%@"), [now[@"pronunciation"] doubleValue] * 100,
                                         [now[@"likeness"] doubleValue] * 100, info[@"trained"] ? L(@" · trained") : @""]
                                      : L(@"not trained yet");
    self.pronButton.title = info[@"trained"] ? L(@"Retrain…") : L(@"Train…");
}

- (void)showTraining:(id)s {
    OVVoice *v = [self selectedVoice];
    if (!v) return;
    [OVTrainSheet showForVoice:v language:[self textLanguage] ?: v.language text:self.editor.string window:self.view.window];
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

- (void)qualityPicked:(OVSegmented *)s {
    if (s.selectedIndex < 0) return;
    NSInteger steps = ((NSNumber *)@[@16, @32, @64][s.selectedIndex]).integerValue;
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
    BOOL isAuto = [[OVLocale speechLanguageSetting] isEqualToString:@"auto"];
    self.detectedHint.stringValue = !isAuto ? L(@"Language chosen by hand")
        : code ? [NSString stringWithFormat:L(@"Detected in the text: %@"), [OVLocale nameForLanguage:code]] : L(@"Recognized from the text as you type");
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
    if (!has) {
        self.status.stringValue = self.improveSwitch.on
            ? L(@"Stress marked: of this phrase’s takes, the one that stresses it will be kept")
            : L(@"Stress marked. It counts only with Auto-improve on, which picks the take that stresses it — the model itself ignores marks");
    }
}

#pragma mark Presets

- (nullable OVPreset *)selectedPreset {
    for (OVPreset *p in [OVPresets shared].all) if ([p.identifier isEqualToString:self.presetId ?: @""]) return p;
    return nil;
}

- (void)reloadPresets {
    [self.presetPopup removeAllItems];
    [self.presetPopup addItemWithTitle:L(@"No preset")];
    for (OVPreset *p in [OVPresets shared].all) {
        [self.presetPopup addItemWithTitle:p.name];
        self.presetPopup.lastItem.representedObject = p.identifier;
    }
    NSInteger i = self.presetId ? [self.presetPopup indexOfItemWithRepresentedObject:self.presetId] : 0;
    if (i < 0) { i = 0; self.presetId = nil; }
    [self.presetPopup selectItemAtIndex:i];
    self.presetRename.enabled = self.presetDelete.enabled = i > 0;
}

/// Style, format (when the preset has one) and effects chain, the formants included.
- (void)applyPreset:(OVPreset *)p {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (p.style.count) [OVSettings applyStyle:p.style];
    if (p.formatId.length) {
        [d setObject:p.formatId forKey:@"exportFormat"];
        [d setInteger:p.quality forKey:@"exportQuality"];
    }
    NSMutableArray *chain = [p.chain mutableCopy] ?: [NSMutableArray array];
    BOOL hasFormant = NO;
    for (NSDictionary *e in chain) if ([e[@"type"] isEqualToString:@"formant"]) hasFormant = YES;
    if (!hasFormant && fabs(p.formant - 1.0) > 0.001) [chain addObject:@{@"type": @"formant", @"on": @YES, @"params": @{@"ratio": @(p.formant)}}];
    self.effects.chain = chain;
    [d setObject:self.effects.chain forKey:@"effectsChain"];
    [self syncControls];
    [self textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:nil]];
}

- (void)presetPicked:(NSPopUpButton *)pop {
    self.presetId = pop.selectedItem.representedObject;
    self.presetRename.enabled = self.presetDelete.enabled = self.presetId != nil;
    OVPreset *p = [self selectedPreset];
    if (p) [self applyPreset:p];
}

- (void)presetSave:(id)s {
    NSString *name = AskName(L(@"Save the current settings as a preset"), L(@"Save"), nil);
    if (!name) return;
    OVPreset *p = [OVPreset new];
    p.name = name;
    p.style = [OVSettings currentStyle];
    p.formatId = [OVSettings exportFormatId];
    p.quality = [OVSettings exportQuality];
    p.chain = self.effects.activeChain;
    p.formant = 1.0;
    for (NSDictionary *e in p.chain)
        if ([e[@"type"] isEqualToString:@"formant"]) p.formant = [e[@"params"][@"ratio"] doubleValue] ?: 1.0;
    OVPreset *saved = [[OVPresets shared] add:p];
    if (!saved) return;
    self.presetId = saved.identifier;
    [self reloadPresets];
}

- (void)presetRename:(id)s {
    OVPreset *p = [self selectedPreset];
    if (!p) return;
    NSString *name = AskName(L(@"Rename the preset"), L(@"Rename"), p.name);
    if (name) [[OVPresets shared] rename:p to:name];
}

- (void)presetDelete:(id)s {
    OVPreset *p = [self selectedPreset];
    if (!p) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Delete the preset “%@”?"), p.name];
    a.informativeText = L(@"The voice style and the effects stay as they are now.");
    [a addButtonWithTitle:L(@"Delete")];
    [a addButtonWithTitle:L(@"Cancel")];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    self.presetId = nil;
    [[OVPresets shared] remove:p];
}

- (void)presetImport:(id)s {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.message = L(@"Choose a preset exported from Clone’n’Speak");
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSData *data = [NSData dataWithContentsOfURL:panel.URL];
    __weak typeof(self) w = self;
    [[OVPresets shared] importData:data ?: [NSData data] completion:^(OVPreset *preset, NSArray<NSString *> *warnings, NSString *error) {
        if (!preset) { w.status.stringValue = error ?: L(@"This is not a preset file."); return; }
        OVPreset *saved = [[OVPresets shared] add:preset];
        if (!saved) return;
        w.presetId = saved.identifier;
        [w reloadPresets];
        w.status.stringValue = warnings.count ? [NSString stringWithFormat:L(@"Preset imported. %@"), [warnings componentsJoinedByString:@" "]]
                                              : L(@"Preset imported");
        [w applyPreset:saved];
    }];
}

- (void)presetExport:(id)s {
    OVPreset *p = [self selectedPreset];
    if (!p) { self.status.stringValue = L(@"Pick a preset to export"); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    NSString *safe = [[p.name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
    panel.nameFieldStringValue = [safe stringByAppendingPathExtension:@"json"];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSError *err = nil;
    if (![[[OVPresets shared] exportData:p] writeToURL:panel.URL options:NSDataWritingAtomic error:&err])
        self.status.stringValue = err.localizedDescription ?: L(@"The preset could not be saved");
}

#pragma mark Export format

- (void)formatPicked:(NSPopUpButton *)pop {
    NSString *fid = pop.selectedItem.representedObject;
    if (!fid) return;
    [NSUserDefaults.standardUserDefaults setObject:fid forKey:@"exportFormat"];
    if (![fid isEqualToString:@"wav"]) [NSUserDefaults.standardUserDefaults setInteger:-1 forKey:@"exportQuality"];
}

/// The last recording in the chosen format, wherever the user says.
- (void)saveAs:(id)s {
    OVGeneration *g = self.lastResultPath ? [self generationForPath:self.lastResultPath] : [OVHistory shared].all.firstObject;
    if (!g) { self.status.stringValue = L(@"Make a recording first"); return; }
    NSString *fid = self.formatPopup.selectedItem.representedObject ?: @"wav";
    OVExportFormat fmt = [OVExport formatForIdentifier:fid];
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSString *ext = [fid isEqualToString:@"alac"] ? @"m4a" : fid;
    UTType *type = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    if (type) panel.allowedContentTypes = @[type];
    panel.nameFieldStringValue = [g.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:ext ?: @"wav"];
    panel.message = [NSString stringWithFormat:L(@"Save as %@"), fid.uppercaseString];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSString *dst = panel.URL.path.stringByDeletingPathExtension, *src = g.path;
    // the panel already asked about overwriting; OVExport never overwrites ("name 2"), so the confirmed target goes to the Trash first
    if ([NSFileManager.defaultManager fileExistsAtPath:panel.URL.path]) [NSFileManager.defaultManager trashItemAtURL:panel.URL resultingItemURL:nil error:nil];
    NSInteger quality = [OVSettings exportQuality];
    self.status.stringValue = [NSString stringWithFormat:L(@"Saving as %@…"), fid.uppercaseString];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSString *out = [OVExport exportFile:src to:dst format:fmt quality:quality error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!out) { w.status.stringValue = err.localizedDescription ?: L(@"unknown error"); return; }
            w.status.stringValue = [NSString stringWithFormat:L(@"Saved: %@"), out.lastPathComponent];
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:out]]];
        });
    });
}

- (void)showBatch:(id)s {
    if (self.view.window) [OVBatchSheet showInWindow:self.view.window];
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
    [self synthesizeText:text voice:voice improve:self.improveSwitch.on];
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
    OVSynthApplyChain(req, self.effects.activeChain, out);
    NSString *dryOut = req[@"dry_out"];
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
        NSMutableDictionary *rec = [data mutableCopy];
        if (dryOut && [NSFileManager.defaultManager fileExistsAtPath:dryOut]) rec[@"dry_path"] = dryOut;
        [w finishSynth:rec text:text voice:voice];
    }];
}

/// Writes the history entry (with the copy in the chosen format next to the WAV master) and shows the result.
- (void)finishSynth:(NSMutableDictionary *)rec text:(NSString *)text voice:(OVVoice *)voice {
    NSString *master = rec[@"path"], *formatId = [OVSettings exportFormatId];
    OVExportFormat fmt = [OVExport formatForIdentifier:formatId];
    __weak typeof(self) w = self;
    void (^finish)(NSString *, NSString *) = ^(NSString *exported, NSString *exportError) {
        if (exported) { rec[@"exported_path"] = exported; rec[@"format"] = formatId; }
        [[OVHistory shared] record:master text:text voice:voice result:rec];
        [w showResult:rec];
        if (exportError) w.status.stringValue = [w.status.stringValue stringByAppendingFormat:L(@" · not saved as %@: %@"), formatId.uppercaseString, exportError];
        w.lastResultPath = master;
        [w refreshVoiceHint];  // the voice may have just learned a language
        [w showBarForPath:master];
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"autoPlay"]) [[OVPlayer shared] play:master];
        [w.table scrollRowToVisible:0];
    };
    if (fmt == OVExportWAV) { finish(nil, nil); return; }
    self.exporting = YES;
    [self refreshState];
    self.status.stringValue = [NSString stringWithFormat:L(@"Saving as %@…"), formatId.uppercaseString];
    NSInteger quality = [OVSettings exportQuality];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSString *out = [OVExport exportFile:master to:master.stringByDeletingPathExtension format:fmt quality:quality error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{ w.exporting = NO; finish(out, out ? nil : (err.localizedDescription ?: L(@"unknown error"))); });
    });
}

- (void)showResult:(NSDictionary *)data {
    double secs = [data[@"seconds"] doubleValue], el = [data[@"elapsed"] doubleValue];
    NSMutableString *st = [NSMutableString stringWithFormat:L(@"Done: %@ of audio in %.0f s"), OVFormatDuration(secs), el];
    OVWorker *w = [OVWorker shared];
    if (w.peakFootprint > 0) [st appendFormat:L(@" · peak memory %.1f GB"), w.peakFootprint / 1073741824.0];
    NSArray *problems = data[@"problems"];
    if (data[@"likeness"]) [st appendFormat:L(@" · voice likeness %.0f%%"), [data[@"likeness"] doubleValue] * 100];
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

- (nullable OVGeneration *)generationForPath:(NSString *)path {
    for (OVGeneration *g in [OVHistory shared].all)
        if ([g.path isEqualToString:path] || [g.exportedPath isEqualToString:path] || [g.originalPath isEqualToString:path]) return g;
    return nil;
}

/// Points the bar at a take (master as B, the dry file as A when the take has effects) or at any other file.
- (void)showBarForPath:(NSString *)path {
    OVGeneration *g = [self generationForPath:path];
    NSString *result = g ? g.path : path, *original = g.originalPath;
    if (![self.abBar.path isEqualToString:result]) self.abBar.path = result;
    if (self.abBar.originalPath != original && ![self.abBar.originalPath isEqualToString:original]) self.abBar.originalPath = original;
    self.playerTitle.stringValue = g ? [[g.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "]
                                     : L(@"Voice sample");
    self.playerBar.hidden = NO;
}

- (void)playerChanged {
    OVPlayer *p = [OVPlayer shared];
    self.sampleButton.title = [p.currentPath isEqualToString:[self selectedVoice].referencePath] && p.playing ? L(@"Stop") : L(@"Voice sample");
    if (p.currentPath) [self showBarForPath:p.currentPath];
    else self.playerBar.hidden = self.lastResultPath == nil;
    [self.table reloadData];
}

#pragma mark History table

- (void)reloadHistory {
    [self.table reloadData];
    NSUInteger n = [OVHistory shared].all.count;
    self.emptyHistory.hidden = n > 0;
    self.table.enclosingScrollView.hidden = n == 0;
    self.tableHeight.constant = MAX(1, MIN(n, kTakeRowsVisible)) * kTakeRowHeight;   // more rows scroll inside the list
    if (self.lastResultPath && ![self generationForPath:self.lastResultPath]) {
        self.lastResultPath = nil;
        if (![OVPlayer shared].currentPath) self.playerBar.hidden = YES;
    }
    self.historyTitle.stringValue = n ? [NSString stringWithFormat:L(@"Recent takes · %lu"), (unsigned long)n] : L(@"Recent takes");
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return [OVHistory shared].all.count; }

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row { return [OVTableRowView new]; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    OVHistoryCell *cell = [t makeViewWithIdentifier:@"hist" owner:self];
    if (!cell) { cell = [[OVHistoryCell alloc] initWithTarget:self]; cell.identifier = @"hist"; }
    OVGeneration *g = [OVHistory shared].all[row];
    cell.text.stringValue = [[g.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    cell.text.toolTip = g.text;
    NSString *when = [NSDateFormatter localizedStringFromDate:g.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
    NSString *clarity = g.clarity >= 0 ? [NSString stringWithFormat:L(@" · clarity %.0f%%"), g.clarity * 100] : @"";
    cell.meta.stringValue = [NSString stringWithFormat:@"%@ · %@ · %@%@", g.voiceName.length ? g.voiceName : @"—", OVFormatDuration(g.seconds), when, clarity];
    cell.meta.toolTip = g.problems.count ? [NSString stringWithFormat:L(@"Unclear: %@"), [[g.problems valueForKey:@"text"] componentsJoinedByString:@" / "]] : nil;
    [cell setLikeness:g.likeness];
    [cell setFormat:g.formatId effects:g.originalPath != nil];
    cell.improve.enabled = self.synthButton.enabled;
    OVPlayer *p = [OVPlayer shared];
    BOOL playing = ([p.currentPath isEqualToString:g.path] || (g.originalPath && [p.currentPath isEqualToString:g.originalPath])) && p.playing;
    cell.play.image = [NSImage imageWithSystemSymbolName:playing ? @"pause.fill" : @"play.fill" accessibilityDescription:nil];
    cell.play.accessibilityLabel = playing ? L(@"Pause") : L(@"Listen");
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
    if (g) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:g.deliveryPath]]];
}
/// Dragging a row out hands over the file in the chosen format.
- (id<NSPasteboardWriting>)tableView:(NSTableView *)t pasteboardWriterForRow:(NSInteger)row {
    NSArray<OVGeneration *> *all = [OVHistory shared].all;
    return row >= 0 && row < (NSInteger)all.count ? [NSURL fileURLWithPath:all[row].deliveryPath] : nil;
}
- (void)deleteRow:(id)s {
    OVGeneration *g = [self genFor:s];
    if (!g) return;
    if ([[OVPlayer shared].currentPath isEqualToString:g.path]) [[OVPlayer shared] stop];
    [[OVHistory shared] remove:g];
}
@end
