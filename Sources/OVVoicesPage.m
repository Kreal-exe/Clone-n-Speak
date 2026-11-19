#import "OVPages.h"
#import "OVUI.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVStore.h"
#import "OVModels.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVWaveformView.h"
#import "OVPlayerBar.h"
#import "OVVoiceCheck.h"
#import "OVTrim.h"
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSTimeInterval kMaxRecord = 15;

/// Page background that takes an audio file dropped anywhere on it.
@interface OVAudioDropView : NSStackView
@property (copy) void (^onDrop)(NSString *path);
@property (copy) void (^onWindowChange)(BOOL inWindow);
@end
@implementation OVAudioDropView
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; if (self.onWindowChange) self.onWindowChange(self.window != nil); }
- (NSURL *)audioFrom:(id<NSDraggingInfo>)info {
    NSDictionary *opts = @{NSPasteboardURLReadingFileURLsOnlyKey: @YES, NSPasteboardURLReadingContentsConformToTypesKey: @[UTTypeAudio.identifier, UTTypeMovie.identifier]};
    return [[info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:opts] firstObject];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [self audioFrom:info] ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSURL *url = [self audioFrom:info];
    if (url && self.onDrop) self.onDrop(url.path);
    return url != nil;
}
@end

@interface OVVoicesPage () <NSTableViewDataSource, NSTableViewDelegate, AVAudioRecorderDelegate, NSTextFieldDelegate, NSTextViewDelegate>
@property NSTableView *table;
@property NSTextField *nameField, *refInfo, *status;
@property NSView *headerView;
@property NSStackView *sampleBadge;
@property NSTextView *refText;
@property NSButton *recordButton, *playButton, *transcribeButton, *cloneButton, *deleteButton;
@property NSButton *enhanceButton, *revertButton, *previewButton;
@property NSStackView *adaptedRow;
@property NSTextField *adaptedLabel;
@property OVMeterBar *qualityMeter;
@property NSTextField *qualityLabel;
@property OVPopup *sampleLangPopup;
@property NSMutableDictionary<NSString *, NSDictionary *> *analysis; // path|mtime → report
@property NSProgressIndicator *spinner;
// extended check, comparison and Improve modes
@property NSButton *checkButton, *compareButton, *downloadButton;
@property OVWaveformView *waveform;
@property NSTextField *strengthValue;
@property NSStackView *adviceStack, *compareStack, *strengthRow;
@property OVSegmented *modeSeg;
@property OVSlider *strengthSlider;
@property OVPlayerBar *playerBar;
// trimming the edges by hand
@property NSButton *trimButton, *trimPlayButton, *trimApplyButton, *trimCancelButton;
@property NSStackView *trimStack;
@property NSTextField *trimInfo, *trimWarn;
@property BOOL trimming, playingSelection;
@property (nullable, copy) NSString *trimPath;      // the file the handles belong to
@property (nullable) NSTimer *trimTimer;
@property (nullable) NSNumber *dfnInstalled, *musicInstalled;   // nil = not asked yet / the worker was busy
@property BOOL askingEngine;
@property (nullable, copy) NSString *shownKey, *peaksKey;          // analysis key whose details are on screen / being read
@property NSMutableDictionary<NSString *, NSArray *> *peaksCache;

@property (nullable) OVVoice *voice;          // nil = drafting a new voice
@property (nullable) AVAudioRecorder *recorder;
@property (nullable, copy) NSString *recordingVoiceId;  // the voice a recording belongs to ("" = a new voice)
@property (nullable) NSTimer *recTimer;
@end

/// The page's wrapping status line: every new text goes back to the muted color (a warning sets its color after its text).
@interface OVVoiceStatus : NSTextField
@end
@implementation OVVoiceStatus
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        self.editable = NO;
        self.bezeled = NO;
        self.drawsBackground = NO;
        self.lineBreakMode = NSLineBreakByWordWrapping;
        self.usesSingleLineMode = NO;
        self.maximumNumberOfLines = 0;
        self.cell.wraps = YES;
    }
    return self;
}
- (void)setStringValue:(NSString *)v { [super setStringValue:v]; self.textColor = OVColor(OVRoleMuted); }
@end

@implementation OVVoicesPage

/// The page title: the voice name, or "New voice".
- (void)setHeadingText:(NSString *)text {
    OVPageHeaderSetTitle(self.headerView, text.length ? text : L(@"New voice"));
}

- (void)loadView {
    // left: list of voices
    self.table = [NSTableView new];
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"v"]];
    self.table.headerView = nil;
    self.table.rowHeight = 52;
    self.table.style = NSTableViewStylePlain;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.intercellSpacing = NSMakeSize(0, 2);
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.accessibilityLabel = L(@"My voices");
    NSScrollView *ls = [NSScrollView new];
    ls.documentView = self.table;
    ls.hasVerticalScroller = YES;
    ls.drawsBackground = NO;
    ls.borderType = NSNoBorder;
    NSButton *add = OVGhostButton(L(@"New voice"), @"plus", self, @selector(newVoice:));
    NSTextField *listTitle = OVLabel(L(@"My voices"), 18, NSFontWeightBold, nil);
    NSStackView *panel = OVVStack(@[listTitle, add, ls], 12);
    panel.alignment = NSLayoutAttributeLeading;
    panel.edgeInsets = NSEdgeInsetsMake(16, 12, 12, 12);
    OVFillWidth(@[listTitle, add, ls], panel);
    [ls setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    OVBoxView *listBox = [OVBoxView boxWithFill:OVColor(OVRoleSurface) border:OVColor(OVRoleBorder) radius:12];
    [listBox addSubview:panel];
    OVPin(panel, listBox, NSEdgeInsetsZero);
    NSView *left = [NSView new];
    [left addSubview:listBox];
    OVPin(listBox, left, NSEdgeInsetsMake(16, 16, 16, 0));
    [left.widthAnchor constraintEqualToConstant:256].active = YES;

    // right: editor
    self.nameField = OVField(L(@"For example, My voice"));
    self.nameField.font = [NSFont systemFontOfSize:14];
    self.nameField.delegate = self;

    self.playButton = OVPlayButton(self, @selector(playRef:));
    self.recordButton = OVGhostButton(L(@"Record"), @"mic.fill", self, @selector(record:));
    self.refInfo = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.qualityMeter = [OVMeterBar new];
    self.qualityMeter.translatesAutoresizingMaskIntoConstraints = NO;
    [self.qualityMeter.widthAnchor constraintEqualToConstant:120].active = YES;
    [self.qualityMeter.heightAnchor constraintEqualToConstant:6].active = YES;
    self.qualityMeter.accessibilityLabel = L(@"Quality");
    self.qualityLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.enhanceButton = OVGhostButton(L(@"Improve sample"), @"sparkles", self, @selector(enhance:));
    self.enhanceButton.toolTip = L(@"Removes background noise and rumble, trims long pauses and evens out loudness. The original is kept.");
    self.revertButton = OVGhostButton(L(@"Restore original"), @"arrow.uturn.backward", self, @selector(revertSample:));
    __weak typeof(self) weakSelf = self;
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a recording here")
                                            hint:L(@"WAV, MP3, M4A, FLAC · 3–10 s · or click to choose")
                                           types:@[@"wav", @"mp3", @"m4a", @"flac", @"ogg", @"aac", @"mp4", @"mov"]
                                         onFiles:^(NSArray<NSURL *> *urls) {
        // same condition as a drop on the page itself
        if (urls.firstObject) [weakSelf importDropped:urls.firstObject.path];
    }];
    NSStackView *playRow = OVHStack(@[self.playButton, self.refInfo, OVSpacer(), self.recordButton], 12);
    playRow.alignment = NSLayoutAttributeCenterY;
    NSStackView *qualityRow = OVHStack(@[OVLabel(L(@"Quality"), 13, NSFontWeightMedium, OVColor(OVRoleMuted)), self.qualityMeter, OVSpacer()], 10);
    qualityRow.alignment = NSLayoutAttributeCenterY;
    NSStackView *fixRow = OVHStack(@[self.enhanceButton, self.revertButton, OVSpacer()], 10);

    // extended check: waveform with problem regions, advice with action buttons
    self.checkButton = OVGhostButton(L(@"Check sample"), @"waveform.badge.magnifyingglass", self, @selector(checkSample:));
    self.compareButton = OVGhostButton(L(@"Compare samples…"), @"rectangle.on.rectangle", self, @selector(compareSamples:));
    self.compareButton.toolTip = L(@"Choose several recordings of this voice to see which is the best: levels, noise and duplicates.");
    self.trimButton = OVGhostButton(L(@"Trim edges"), @"scissors", self, @selector(trimEdges:));
    self.trimButton.toolTip = L(@"Cut anything you don’t want from the start and the end of the sample: a breath, a word, a click. The original is kept.");
    NSStackView *checkRow = OVHStack(@[self.checkButton, self.compareButton, OVSpacer()], 10);
    self.waveform = [OVWaveformView new];
    self.waveform.translatesAutoresizingMaskIntoConstraints = NO;
    [self.waveform.heightAnchor constraintEqualToConstant:72].active = YES;
    self.waveform.accessibilityLabel = L(@"Waveform of the sample");
    self.waveform.onRegionHover = ^(NSDictionary *region) {
        weakSelf.waveform.toolTip = region ? OVRegionTooltip(region) : nil;
    };
    self.waveform.onSeek = ^(NSTimeInterval t) {
        NSString *a = [weakSelf currentAudio];
        if (!a) return;
        if (![[OVPlayer shared].currentPath isEqualToString:a]) [[OVPlayer shared] play:a];
        [[OVPlayer shared] seek:t];
    };
    self.adviceStack = OVVStack(@[], 8);
    self.compareStack = OVVStack(@[], 4);
    self.waveform.hidden = YES;
    self.waveform.onTrimChange = ^(NSTimeInterval start, NSTimeInterval end) { [weakSelf updateTrimInfo]; };
    self.trimInfo = OVLabel(@"", 13, NSFontWeightMedium, OVColor(OVRoleText));
    self.trimInfo.accessibilityLabel = L(@"Length kept");
    self.trimWarn = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.trimPlayButton = OVGhostButton(L(@"Play selection"), @"play.fill", self, @selector(playSelection:));
    self.trimCancelButton = OVGhostButton(L(@"Cancel"), nil, self, @selector(cancelTrim:));
    self.trimCancelButton.keyEquivalent = @"\033";
    self.trimApplyButton = OVPillButtonMake(L(@"Apply"), @"checkmark", self, @selector(applyTrim:), NO);
    // idle: just "Trim edges"; trimming: the length kept (and a warning), then Play selection … Cancel, Apply
    NSStackView *trimRow = OVHStack(@[self.trimButton, self.trimPlayButton, OVSpacer(), self.trimCancelButton, self.trimApplyButton], 10);
    trimRow.alignment = NSLayoutAttributeCenterY;
    self.trimStack = OVVStack(@[self.trimInfo, self.trimWarn, trimRow], 8);
    OVFillWidth(@[self.trimInfo, self.trimWarn, trimRow], self.trimStack);
    [self showTrimControls:NO];

    // Improve modes
    self.modeSeg = [OVSegmented segmentedWithItems:@[@[L(@"Light cleanup"), @"wand.and.stars"], @[L(@"DeepFilterNet"), @"waveform.path"],
                                                     @[L(@"Remove music"), @"music.note"]]];
    self.modeSeg.target = self;
    self.modeSeg.action = @selector(modePicked:);
    self.modeSeg.accessibilityLabel = L(@"How to improve the sample");
    self.strengthSlider = [OVSlider new];
    self.strengthSlider.minValue = 1;
    self.strengthSlider.maxValue = 30;
    self.strengthSlider.doubleValue = 18;
    self.strengthSlider.target = self;
    self.strengthSlider.action = @selector(strengthChanged:);
    self.strengthSlider.accessibilityLabel = L(@"Noise reduction strength");
    self.strengthValue = OVLabel(@"18 dB", 13, NSFontWeightMedium, OVColor(OVRoleMuted));
    [self.strengthSlider.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
    self.downloadButton = OVGhostButton(L(@"Download"), @"arrow.down.circle", self, @selector(downloadEngine:));
    self.strengthRow = OVHStack(@[OVLabel(L(@"Strength"), 13, NSFontWeightMedium, OVColor(OVRoleMuted)), self.strengthSlider, self.strengthValue,
                                  self.downloadButton], 10);
    self.strengthRow.alignment = NSLayoutAttributeCenterY;
    self.playerBar = [OVPlayerBar new];
    self.playerBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerBar.hidden = YES;
    NSArray *audioViews = @[zone, playRow, qualityRow, self.qualityLabel, checkRow, self.waveform, self.trimStack, self.adviceStack,
                            self.compareStack, self.modeSeg, self.strengthRow, fixRow, self.playerBar];
    NSStackView *audioBox = OVVStack(audioViews, 12);
    OVFillWidth(audioViews, audioBox);
    self.sampleBadge = OVHStack(@[], 0);
    NSView *audioCard = OVStepCardWithAccessory(2, @"waveform", L(@"Voice sample"), self.sampleBadge, audioBox);

    NSScrollView *ts = [NSTextView scrollableTextView];
    NSView *textArea = OVTextArea(ts, 100);
    self.refText = ts.documentView;
    self.refText.font = [NSFont systemFontOfSize:14];
    self.refText.richText = NO;
    self.refText.allowsUndo = YES;
    self.refText.delegate = self;
    self.refText.automaticQuoteSubstitutionEnabled = NO;
    self.refText.automaticDashSubstitutionEnabled = NO;
    self.refText.automaticTextReplacementEnabled = NO;
    self.refText.automaticSpellingCorrectionEnabled = NO;  // the transcript must stay word for word what was said
    self.refText.accessibilityLabel = L(@"What the sample says");
    self.transcribeButton = OVGhostButton(L(@"Transcribe automatically"), @"text.bubble", self, @selector(transcribe:));
    NSTextField *textHint = OVWrapLabel(L(@"Exactly, word for word. You can leave it empty — Whisper will transcribe it."), 13, OVColor(OVRoleMuted));
    NSStackView *transcribeRow = OVHStack(@[self.transcribeButton, OVSpacer()], 10);
    NSStackView *textBox = OVVStack(@[textArea, transcribeRow, textHint], 12);
    [textBox setCustomSpacing:8 afterView:transcribeRow];
    OVFillWidth(@[textArea, transcribeRow, textHint], textBox);
    NSView *textCard = OVStepCardWithAccessory(3, @"text.quote", L(@"What the sample says"), nil, textBox);

    self.cloneButton = OVPrimaryButton(L(@"Clone voice"), self, @selector(clone:));
    self.cloneButton.image = [NSImage imageWithSystemSymbolName:@"person.wave.2.fill" accessibilityDescription:nil];
    self.spinner = OVSpinner();
    self.status = [OVVoiceStatus new];
    self.status.font = [NSFont systemFontOfSize:13];
    self.status.textColor = OVColor(OVRoleMuted);
    self.status.selectable = NO;
    [self.status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.deleteButton = OVGhostButton(L(@"Delete voice"), @"trash", self, @selector(deleteVoice:));
    self.deleteButton.contentTintColor = OVColor(OVRoleErr);
    self.previewButton = OVGhostButton(L(@"Hear the clone"), @"play.fill", self, @selector(playPreview:));
    NSStackView *actions = OVHStack(@[self.cloneButton, self.previewButton, self.spinner, OVSpacer()], 10);
    actions.alignment = NSLayoutAttributeCenterY;
    self.analysis = [NSMutableDictionary dictionary];
    self.peaksCache = [NSMutableDictionary dictionary];

    // languages this voice already speaks without the sample's accent (see OVVoice adaptsToLanguage:)
    self.adaptedLabel = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSButton *adaptedListen = OVGhostButton(L(@"Listen"), nil, self, @selector(playAdapted:));
    adaptedListen.toolTip = L(@"The phrase the voice learned this language on. Speech in that language starts from it instead of the original sample.");
    NSButton *adaptedForget = OVGhostButton(L(@"Forget"), nil, self, @selector(forgetAdapted:));
    adaptedForget.toolTip = L(@"Learn the pronunciation again the next time this voice speaks another language.");
    for (NSButton *b in @[adaptedListen, adaptedForget]) {   // the small variant: 28 pt tall
        b.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        [b.heightAnchor constraintEqualToConstant:28].active = YES;
    }
    self.adaptedRow = OVHStack(@[OVSymbol(@"globe", 13, OVColor(OVRoleMuted)), self.adaptedLabel, adaptedListen, adaptedForget, OVSpacer()], 8);
    self.adaptedRow.alignment = NSLayoutAttributeCenterY;

    // "Auto-detect" first: the language is recognized when the sample is transcribed or cloned.
    // Picking it by hand stays possible — on short clips Whisper can mix up Ukrainian, Belarusian and Russian.
    self.sampleLangPopup = [OVPopup popup];
    [self.sampleLangPopup addItemWithTitle:L(@"Auto-detect")];
    self.sampleLangPopup.lastItem.representedObject = @"auto";
    [self.sampleLangPopup.menu addItem:NSMenuItem.separatorItem];
    self.sampleLangPopup.toolTip = L(@"Auto-detect recognizes the language from the recording when the sample is transcribed or cloned. Pick it by hand if the guess is wrong.");
    NSArray *pinned = [OVLocale pinnedSpeechLanguages];
    for (NSString *c in pinned) { [self.sampleLangPopup addItemWithTitle:[OVLocale nameForLanguage:c]]; self.sampleLangPopup.lastItem.representedObject = c; }
    [self.sampleLangPopup.menu addItem:NSMenuItem.separatorItem];
    for (NSString *c in [OVLocale speechLanguages])
        if (![pinned containsObject:c]) { [self.sampleLangPopup addItemWithTitle:[OVLocale nameForLanguage:c]]; self.sampleLangPopup.lastItem.representedObject = c; }
    self.sampleLangPopup.target = self;
    self.sampleLangPopup.action = @selector(sampleLanguagePicked:);
    NSView *voiceColumns = OVColumns(@[OVFieldBlock(L(@"Name"), nil, self.nameField),
                                       OVFieldBlock(L(@"Language of the sample"), nil, self.sampleLangPopup)], 16);
    NSView *voiceCard = OVStepCardWithAccessory(1, @"person.crop.circle", L(@"Voice"), nil, voiceColumns);

    self.headerView = OVPageHeaderWrapped(L(@"New voice"), L(@"Clone a voice from 3–10 seconds of speech."), self.deleteButton, YES);
    NSScrollView *rightScroll = OVPageScroll(@[self.headerView, voiceCard, audioCard, textCard, actions, self.status, self.adaptedRow]);

    OVAudioDropView *root = [OVAudioDropView stackViewWithViews:@[left, rightScroll]];
    root.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    root.distribution = NSStackViewDistributionFill;
    root.spacing = 0;
    root.alignment = NSLayoutAttributeTop;
    root.onWindowChange = ^(BOOL inWindow) {   // pages are swapped with addSubview, not viewDidAppear
        if (!inWindow) return;
        [weakSelf askEngineStatus:nil];
        // Developer aid for snapshots: OV_VOICES_TRIM=1 opens trim mode on the first voice, OV_VOICES_TRIM=<start>,<end> also sets the handles.
        NSString *aid = NSProcessInfo.processInfo.environment[@"OV_VOICES_TRIM"];
        if (aid.length) dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf trimEdges:nil];
            NSArray *se = [aid componentsSeparatedByString:@","];
            if (weakSelf.trimming && se.count == 2) [weakSelf.waveform setTrimStart:[se[0] doubleValue] end:[se[1] doubleValue]];
            [weakSelf updateTrimInfo];
        });
    };
    [root registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    root.onDrop = ^(NSString *path) {  // a recording dropped on the page becomes the sample of the voice shown
        [weakSelf importDropped:path];
    };
    left.translatesAutoresizingMaskIntoConstraints = NO;
    rightScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [left.heightAnchor constraintEqualToAnchor:root.heightAnchor].active = YES;
    [rightScroll.heightAnchor constraintEqualToAnchor:root.heightAnchor].active = YES;
    self.view = root;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(reload) name:OVVoicesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshButtons) name:OVWorkerDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshButtons) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshButtons) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshButtons) name:OVPlayerDidChangeNotification object:nil];

    [self.table reloadData];
    if ([OVVoices shared].all.count) [self showVoice:[OVVoices shared].all.firstObject];
    else [self newVoice:nil];
}

#pragma mark Table

- (void)reload {
    NSString *keep = self.voice.identifier;
    [self.table reloadData];
    if (keep) {
        OVVoice *v = [[OVVoices shared] voiceWithId:keep];
        if (v) {
            self.voice = v;
            NSUInteger i = [[OVVoices shared].all indexOfObject:v];
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        } else if (![NSFileManager.defaultManager fileExistsAtPath:[self.voice.folder stringByAppendingPathComponent:@"meta.plist"]]) {
            [self newVoice:nil]; // really deleted
        }
    }
    [self refreshButtons];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return [OVVoices shared].all.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    OVVoice *v = [OVVoices shared].all[row];
    NSTableCellView *cell = [NSTableCellView new];
    NSView *icon;
    if (v.ready) {
        OVAvatar *avatar = [OVAvatar avatarWithSize:28];
        [avatar setName:v.name];
        icon = avatar;
    } else {
        icon = OVSymbol(@"exclamationmark.circle", 18, OVColor(OVRoleWarn));
        [icon.widthAnchor constraintEqualToConstant:28].active = YES;
    }
    NSTextField *name = OVLabel(v.name, 14, NSFontWeightSemibold, nil);
    name.toolTip = v.name;
    NSString *lang = v.language ?: (v.refText.length ? [OVLocale detectLanguage:v.refText] : nil);
    NSString *subText = !v.ready ? L(@"not cloned") :
        lang ? [NSString stringWithFormat:@"%@ · %@", OVFormatDuration(v.seconds), [OVLocale nameForLanguage:lang]]
             : [NSString stringWithFormat:L(@"%@ sample"), OVFormatDuration(v.seconds)];
    NSTextField *sub = OVLabel(subText, 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSStackView *texts = OVVStack(@[name, sub], 2);
    texts.alignment = NSLayoutAttributeLeading;
    NSStackView *row2 = OVHStack(@[icon, texts], 10);
    row2.alignment = NSLayoutAttributeCenterY;
    [cell addSubview:row2];
    OVPin(row2, cell, NSEdgeInsetsMake(4, 10, 4, 10));
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row { return [OVTableRowView new]; }

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = self.table.selectedRow;
    if (r >= 0 && r < (NSInteger)[OVVoices shared].all.count) [self showVoice:[OVVoices shared].all[r]];
}

#pragma mark Editor state

- (void)showVoice:(OVVoice *)v {
    self.status.textColor = OVColor(OVRoleMuted);
    [self stopRecording];
    // every keystroke saves the voice, and saving reloads the list, which shows the voice again: leave the field
    // being typed in alone, or it loses a trailing space, the cursor jumps to the end and undo breaks
    BOOL same = [v.identifier isEqualToString:self.voice.identifier];
    self.voice = v;
    [self setHeadingText:v.name];
    if (!(same && self.nameField.currentEditor)) self.nameField.stringValue = v.name ?: @"";
    [self showSampleLanguage:v.language isAuto:v.languageAuto];
    if (!(same && self.view.window.firstResponder == self.refText)) self.refText.string = v.refText ?: @"";
    self.status.stringValue = [self hasPending] ? L(@"New sample saved. Click “Re-clone voice” to apply it.") :
                              v.ready ? L(@"The voice is ready — you can select it on the Speech page.") :
                                        L(@"Sample saved. Enter the sample text and click “Clone voice”.");
    NSUInteger i = [[OVVoices shared].all indexOfObject:v];
    if (i != NSNotFound && self.table.selectedRow != (NSInteger)i)
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    [self refreshButtons];
}

- (void)newVoice:(id)s {
    [self stopRecording];
    self.voice = nil;
    [self.table deselectAll:nil];
    [self setHeadingText:nil];
    self.nameField.stringValue = [NSString stringWithFormat:L(@"Voice %lu"), (unsigned long)[OVVoices shared].all.count + 1];
    self.refText.string = @"";
    self.status.stringValue = @"";
    [self showSampleLanguage:nil isAuto:YES];
    [self refreshButtons];
    [self.view.window makeFirstResponder:self.nameField];
}

/// New sample for an already cloned voice: kept next to it until re-cloning succeeds.
- (NSString *)pendingPath { return [self.voice.folder stringByAppendingPathComponent:@"reference.new.wav"]; }
- (BOOL)hasPending { return self.voice && [NSFileManager.defaultManager fileExistsAtPath:[self pendingPath]]; }

- (NSString *)currentAudio {
    if ([self hasPending]) return [self pendingPath];
    if (self.voice && [NSFileManager.defaultManager fileExistsAtPath:self.voice.referencePath]) return self.voice.referencePath;
    return nil;
}

/// Saves a freshly recorded / imported sample to disk right away, so nothing is lost
/// if the app quits before cloning.
- (BOOL)keepSample:(NSString *)wav { return [self keepSample:wav fresh:NO]; }

/// `fresh`: a new recording or import, not the improved or restored version of the current one.
- (BOOL)keepSample:(NSString *)wav fresh:(BOOL)fresh {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!self.voice) {
        NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        OVVoice *v = [[OVVoices shared] createNamed:name.length ? name : L(@"Untitled")];
        v.refText = self.refText.string;
        v.languageAuto = [self sampleLanguageIsAuto];
        v.language = v.languageAuto ? nil : [self sampleLanguage];
        self.voice = v;
    }
    NSString *dst = self.voice.ready ? [self pendingPath] : self.voice.referencePath;
    [fm removeItemAtPath:dst error:nil];
    // The kept original belonged to the sample being replaced; a stale one would later be
    // "restored" instead of this sample, and would stop a long new recording from being kept.
    if (fresh) [fm removeItemAtPath:[self originalPath] error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:wav toPath:dst error:&err]) {
        self.status.stringValue = [NSString stringWithFormat:L(@"Couldn’t save the sample: %@"), err.localizedDescription ?: @"?"];
        return NO;
    }
    if (!self.voice.ready) self.voice.seconds = OVAudioDuration(dst);
    [self.voice save];
    [[OVVoices shared] reload];
    [self setHeadingText:self.voice.name];
    return YES;
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object != self.nameField || !self.voice) return;
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length) return;
    self.voice.name = name;
    [self setHeadingText:name];
    [self.voice save];
    [self.table reloadData];
    NSUInteger i = [[OVVoices shared].all indexOfObject:self.voice];
    if (i != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
}

- (void)textDidChange:(NSNotification *)n {
    if (n.object != self.refText || !self.voice) return;
    self.voice.refText = self.refText.string;
    [self.voice save];
}

- (void)refreshButtons {
    BOOL busy = [OVWorker shared].busy;
    BOOL recording = self.recorder.recording;
    NSString *audio = [self currentAudio];
    BOOL engine = OVEverythingReady();
    if (self.trimming && (!audio || ![audio isEqualToString:self.trimPath])) [self endTrim];   // another voice or another file

    if (audio) {
        double d = OVAudioDuration(audio);
        NSString *warn = d < 2.5 ? L(@"  · too short") : d > 20 ? L(@"  · longer than 20 s — trim it to 3–10 s") : @"";
        BOOL bad = d < 2.5 || d > 20;
        for (NSView *old in [self.sampleBadge.arrangedSubviews copy]) { [self.sampleBadge removeArrangedSubview:old]; [old removeFromSuperview]; }
        [self.sampleBadge addArrangedSubview:OVBadge(bad ? OVFormatDuration(d) : L(@"OK"), bad ? OVRoleWarn : OVRoleOK)];
        self.refInfo.stringValue = [NSString stringWithFormat:@"%@ · %@%@", [self hasPending] ? L(@"New sample (not applied yet)") : L(@"Sample saved"), OVFormatDuration(d), warn];
    } else {
        for (NSView *old in [self.sampleBadge.arrangedSubviews copy]) { [self.sampleBadge removeArrangedSubview:old]; [old removeFromSuperview]; }
        self.refInfo.stringValue = L(@"No sample yet.");
    }
    if (!recording) {
        self.recordButton.title = L(@"Record");
        self.recordButton.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
    }
    self.recordButton.enabled = !busy;
    BOOL playing = audio && [[OVPlayer shared].currentPath isEqualToString:audio] && [OVPlayer shared].playing;
    self.playButton.accessibilityLabel = playing ? L(@"Stop") : L(@"Listen");
    self.playButton.toolTip = self.playButton.accessibilityLabel;
    self.playButton.image = [NSImage imageWithSystemSymbolName:playing ? @"stop.fill" : @"play.fill" accessibilityDescription:nil];
    self.playButton.enabled = audio != nil && !recording;

    BOOL asr = [OVModels shared].asrModel != nil;
    self.transcribeButton.enabled = audio && engine && !busy && !recording;
    self.transcribeButton.title = asr ? L(@"Transcribe automatically") : L(@"Transcribe (download Whisper…)");

    self.cloneButton.enabled = audio && engine && !busy && !recording;
    self.cloneButton.title = self.voice.ready ? L(@"Re-clone voice") : L(@"Clone voice");
    self.deleteButton.hidden = self.voice == nil;
    self.deleteButton.enabled = !busy;
    if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    if (!engine && !busy) self.status.stringValue = L(@"Finish setup first: the OmniVoice engine and model.");
    self.enhanceButton.enabled = audio && engine && !busy && !recording;
    self.checkButton.enabled = audio && engine && !busy && !recording;
    self.compareButton.enabled = audio && engine && !busy && !recording;
    self.trimButton.enabled = audio && !busy && !recording && !self.trimming;
    self.trimApplyButton.enabled = self.trimming && !busy && !recording;
    [self refreshImproveControls:audio busy:busy];
    self.revertButton.hidden = !(self.voice && [NSFileManager.defaultManager fileExistsAtPath:[self originalPath]]);
    self.revertButton.enabled = !busy && !recording;
    self.previewButton.hidden = !(self.voice.ready && [NSFileManager.defaultManager fileExistsAtPath:[self previewPath]]);
    NSMutableArray *learned = [NSMutableArray array];
    for (NSString *code in self.voice.adaptedLanguages) [learned addObject:[OVLocale nameForLanguage:code]];
    self.adaptedRow.hidden = learned.count == 0;
    self.adaptedLabel.stringValue = [NSString stringWithFormat:L(@"Speaks without the sample’s accent: %@"), [learned componentsJoinedByString:@", "]];
    [self analyzeIfNeeded:audio];
}

#pragma mark Audio input

- (NSString *)draftPath:(NSString *)name {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"OmniVoiceUA"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:name];
}

/// A file from the drop zone or a drop on the page: ignored with an explanation while a job or a recording runs.
- (void)importDropped:(NSString *)path {
    if ([OVWorker shared].busy || self.recorder.recording) {
        self.status.stringValue = self.recorder.recording ? L(@"Stop the recording first — the file was not added.")
                                                          : L(@"The engine is busy — the file was not added. Try again in a moment.");
        self.status.textColor = OVColor(OVRoleWarn);   // after the text: a new text goes back to muted
        return;
    }
    [self importAudio:path];
}

- (void)importAudio:(NSString *)src {
    self.status.textColor = OVColor(OVRoleMuted);
    NSString *dst = [self draftPath:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    NSError *err = nil;
    double secs = 0;
    if (!OVConvertToWav(src, dst, &secs, &err)) {
        self.status.stringValue = [NSString stringWithFormat:L(@"Couldn’t read the audio: %@"), err.localizedDescription ?: @"?"];
        return;
    }
    if (!self.voice && [self.nameField.stringValue hasPrefix:[L(@"Voice %lu") componentsSeparatedByString:@"%"].firstObject])
        self.nameField.stringValue = src.lastPathComponent.stringByDeletingPathExtension;
    BOOL kept = [self keepSample:dst fresh:YES];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    if (kept) self.status.stringValue = L(@"Sample saved. Check the text and click “Clone voice”.");
    [self refreshButtons];
}

- (void)record:(id)s {
    if (self.recorder.recording) { [self.recorder stop]; return; }
    [[OVPlayer shared] stop];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                self.status.stringValue = L(@"No access to the microphone. Allow it in System Settings → Privacy & Security → Microphone.");
                return;
            }
            [self startRecording];
        });
    }];
}

- (void)startRecording {
    NSString *path = [self draftPath:@"recording.wav"];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @24000, AVNumberOfChannelsKey: @1,
                               AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    NSError *err = nil;
    self.recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path] settings:settings error:&err];
    self.recorder.delegate = self;
    if (![self.recorder recordForDuration:kMaxRecord]) {
        self.status.stringValue = err.localizedDescription ?: L(@"Couldn’t start recording");
        self.recorder = nil;
        return;
    }
    self.recordingVoiceId = self.voice.identifier ?: @"";
    self.status.stringValue = L(@"Speak naturally in a quiet room. Recording stops automatically after 15 s.");
    __weak typeof(self) w = self;
    self.recTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        w.recordButton.title = [NSString stringWithFormat:L(@"Stop  %@"), OVFormatDuration(w.recorder.currentTime)];
    }];
    self.recordButton.image = [NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:nil];
    [self refreshButtons];
}

- (void)stopRecording {
    if (self.recorder.recording) [self.recorder stop];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)r successfully:(BOOL)ok {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.recTimer invalidate];
        self.recTimer = nil;
        self.recordButton.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
        NSString *path = r.url.path;
        self.recorder = nil;
        // Another voice (or a new one) was opened while recording: this take isn't its sample.
        BOOL sameVoice = [(self.voice.identifier ?: @"") isEqualToString:self.recordingVoiceId ?: @""];
        self.recordingVoiceId = nil;
        if (!sameVoice) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            [self refreshButtons];
            return;
        }
        if (ok && OVAudioDuration(path) > 0.5) {
            if ([self keepSample:path fresh:YES])
                self.status.stringValue = L(@"Recording saved. Listen to it and enter (or transcribe) the text.");
        } else {
            self.status.stringValue = L(@"Recording failed.");
        }
        [self refreshButtons];
    });
}

- (void)playRef:(id)s {
    NSString *a = [self currentAudio];
    if (a) [[OVPlayer shared] toggle:a];
}

#pragma mark Sample language

/// "auto", or the language picked by hand.
- (NSString *)sampleLanguage { return self.sampleLangPopup.selectedItem.representedObject ?: @"auto"; }
- (BOOL)sampleLanguageIsAuto { return [[self sampleLanguage] isEqualToString:@"auto"]; }

/// Selects the popup item; "Auto-detect" shows what it has found so far ("Auto · Ukrainian").
- (void)showSampleLanguage:(nullable NSString *)code isAuto:(BOOL)isAuto {
    [self.sampleLangPopup itemAtIndex:0].title = isAuto && code.length
        ? [NSString stringWithFormat:L(@"Auto · %@"), [OVLocale nameForLanguage:code]] : L(@"Auto-detect");
    NSInteger i = isAuto ? 0 : [self.sampleLangPopup indexOfItemWithRepresentedObject:code ?: @""];
    [self.sampleLangPopup selectItemAtIndex:MAX(0, i)];
    [self.sampleLangPopup synchronizeTitleAndSelectedItem];
}

- (void)sampleLanguagePicked:(id)s {
    BOOL isAuto = [self sampleLanguageIsAuto];
    OVVoice *v = self.voice;
    if (!v) { [self showSampleLanguage:nil isAuto:isAuto]; return; }
    v.languageAuto = isAuto;
    // until the recording is listened to, the transcript is the best hint
    v.language = !isAuto ? [self sampleLanguage] : v.refText.length ? [OVLocale detectLanguage:v.refText] : nil;
    [v save];
    [self showSampleLanguage:v.language isAuto:isAuto];
}

/// The engine has listened to the sample: remember what language it heard (auto mode only).
- (void)voice:(OVVoice *)v heardLanguage:(nullable NSString *)code {
    if (!v.languageAuto) return;
    v.language = code.length ? code : ([OVLocale detectLanguage:v.refText] ?: v.language);
}

- (void)playAdapted:(NSButton *)b {
    NSArray<NSString *> *langs = self.voice.adaptedLanguages;
    if (langs.count == 1) { [[OVPlayer shared] toggle:[self.voice adaptedSamplePath:langs.firstObject]]; return; }
    NSMenu *menu = [NSMenu new];
    for (NSString *code in langs) {
        NSMenuItem *it = [menu addItemWithTitle:[OVLocale nameForLanguage:code] action:@selector(playAdaptedItem:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = code;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(b.bounds) + 4) inView:b];
}
- (void)playAdaptedItem:(NSMenuItem *)it { [[OVPlayer shared] toggle:[self.voice adaptedSamplePath:it.representedObject]]; }
- (void)forgetAdapted:(id)s {
    [[OVPlayer shared] stop];
    [self.voice forgetAdaptations];
    [self refreshButtons];
}

#pragma mark Sample quality

- (NSString *)originalPath { return [self.voice.folder stringByAppendingPathComponent:@"reference.orig.wav"]; }
- (NSString *)previewPath { return [self.voice.folder stringByAppendingPathComponent:@"preview.wav"]; }

- (NSString *)analysisKey:(NSString *)path {
    NSDate *m = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileModificationDate];
    return [NSString stringWithFormat:@"%@|%f", path, m.timeIntervalSince1970];
}

/// Asks the engine for the extended report of the current sample (no model is loaded for this).
- (void)analyzeIfNeeded:(NSString *)audio { [self analyze:audio force:NO]; }

/// `force`: check again even when a report is cached.
- (void)analyze:(NSString *)audio force:(BOOL)force {
    if (!audio) {
        self.qualityMeter.doubleValue = 0; self.qualityLabel.stringValue = @"";
        self.shownKey = nil;
        [self clearCheckDetails];
        [self clearComparison];
        return;
    }
    NSString *key = [self analysisKey:audio];
    if (![key isEqualToString:self.shownKey]) {   // another sample (or the same one changed): nothing of the old one stays
        self.shownKey = nil;
        [self clearCheckDetails];
        [self clearComparison];
    }
    if (force) { [self.analysis removeObjectForKey:key]; self.shownKey = nil; }
    NSDictionary *r = self.analysis[key];
    if (r) { if (![key isEqualToString:self.shownKey]) [self showAnalysis:r forAudio:audio key:key]; return; }
    if ([OVWorker shared].busy || [OVRuntime shared].state != OVRuntimeReady || self.recorder.recording) return;
    self.qualityLabel.stringValue = L(@"Checking the sample…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"sample_check", @"audio": audio} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        if (error || !data) { w.qualityLabel.stringValue = (error && force) ? error : @""; return; }
        w.analysis[key] = data;
        if ([[w currentAudio] isEqualToString:audio]) [w showAnalysis:data forAudio:audio key:key];
    }];
}

- (void)checkSample:(id)s { [self analyze:[self currentAudio] force:YES]; }

- (void)clearAdvice {
    for (NSView *v in [self.adviceStack.arrangedSubviews copy]) { [self.adviceStack removeView:v]; [v removeFromSuperview]; }
}

- (void)clearCheckDetails {
    self.waveform.regions = @[];
    if (!self.trimming) {   // trimming keeps showing the waveform of the file being cut
        self.waveform.hidden = YES;
        self.waveform.peaks = @[];
        self.waveform.accessibilityHelp = nil;
    }
    [self clearAdvice];
}

- (void)clearComparison {
    for (NSView *v in [self.compareStack.arrangedSubviews copy]) { [self.compareStack removeView:v]; [v removeFromSuperview]; }
}

/// A line of advice with its action button.
- (NSView *)adviceRow:(NSDictionary *)info {
    NSTextField *t = OVWrapLabel(info[@"text"], 13, OVColor(OVRoleWarn));
    if (!info[@"button"]) return t;
    NSButton *b = OVSmallPill(OVGhostButton(info[@"button"], nil, self, @selector(adviceAction:)));
    b.identifier = info[@"action"];
    b.toolTip = L(@"Light cleanup: trims silence, shortens pauses, reduces noise. The original is kept.");
    NSStackView *row = OVHStack(@[t, OVSpacer(), b], 10);
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

/// "Trim silence" / "Denoise": picks the Improve mode and runs it (an engine that is not installed offers its download).
- (void)adviceAction:(NSButton *)b {
    self.modeSeg.selectedIndex = [b.identifier isEqualToString:@"dfn"] ? 1 : 0;
    __weak typeof(self) w = self;
    [self askEngineStatus:^{
        if ([w modeEngineReady]) { if (w.enhanceButton.enabled) [w enhance:nil]; return; }
        if ([w improveEngineKnown]) {   // not installed: say so and point at the Download button
            w.status.stringValue = [[w improveMode] isEqualToString:@"dfn"]
                ? L(@"DeepFilterNet isn’t installed — press Download, then try again.")
                : L(@"The music-removal engine isn’t installed — press Download, then try again.");
            w.status.textColor = OVColor(OVRoleWarn);
            [w.view.window makeFirstResponder:w.downloadButton];
        } else {
            w.status.stringValue = L(@"The engine is busy — try again in a moment.");
        }
    }];
    [self refreshButtons];
}

- (void)showAnalysis:(NSDictionary *)r forAudio:(NSString *)audio key:(NSString *)key {
    self.shownKey = key;
    self.qualityMeter.doubleValue = [r[@"score"] doubleValue];
    NSArray *issues = r[@"issues"];
    NSMutableArray *lines = [NSMutableArray array];
    if ([issues containsObject:@"short"]) [lines addObject:L(@"Too short — the model needs 3–10 seconds of speech.")];
    if ([issues containsObject:@"long"]) [lines addObject:L(@"Longer than 15 s — trim it to the best 5–10 seconds.")];
    NSString *head = [NSString stringWithFormat:L(@"%d/100 · noise margin %.0f dB · %@"), [r[@"score"] intValue], [r[@"snr_db"] doubleValue],
                      OVFormatDuration([r[@"seconds"] doubleValue])];
    if (r[@"lead_silence_s"]) {
        NSDictionary *lp = [r[@"longest_pause"] isKindOfClass:NSDictionary.class] ? r[@"longest_pause"] : nil;
        NSString *pause = lp ? [NSString stringWithFormat:L(@"Longest pause: %.1f s"), [lp[@"seconds"] doubleValue]] : L(@"No long pauses");
        head = [head stringByAppendingFormat:@"\n%@ · %@",
                [NSString stringWithFormat:L(@"Silence at start/end: %.1f s / %.1f s"), [r[@"lead_silence_s"] doubleValue], [r[@"tail_silence_s"] doubleValue]],
                pause];
    }
    NSArray *advice = r[@"advice"];
    BOOL clean = !lines.count && !advice.count;
    self.qualityLabel.stringValue = lines.count ? [NSString stringWithFormat:@"%@\n%@", head, [lines componentsJoinedByString:@"\n"]]
                                                : clean ? [NSString stringWithFormat:@"%@\n%@", head, L(@"Great sample for cloning.")] : head;
    self.qualityLabel.textColor = lines.count ? OVColor(OVRoleWarn) : OVColor(OVRoleMuted);

    // waveform with problem regions (the peaks are read off the main thread and cached), then the advice
    NSArray *regions = r[@"regions"] ?: @[];
    NSMutableArray *tips = [NSMutableArray array];
    for (NSDictionary *reg in regions) [tips addObject:OVRegionTooltip(reg)];
    self.waveform.regions = regions;
    self.waveform.duration = [r[@"seconds"] doubleValue];
    self.waveform.position = 0;
    self.waveform.accessibilityHelp = tips.count ? [tips componentsJoinedByString:@"; "] : L(@"No problems found");
    NSArray *cached = self.peaksCache[key];
    if (cached) {
        self.waveform.peaks = cached;
        self.waveform.hidden = NO;
    } else if (![self.peaksKey isEqualToString:key]) {
        self.peaksKey = key;
        __weak typeof(self) w = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *peaks = OVWaveformPeaksForFile(audio, 400);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([w.peaksKey isEqualToString:key]) w.peaksKey = nil;
                if (!peaks) return;
                w.peaksCache[key] = peaks;
                if ([w.shownKey isEqualToString:key]) { w.waveform.peaks = peaks; w.waveform.hidden = NO; }
            });
        });
    }
    [self clearAdvice];
    for (NSString *code in advice) {
        NSDictionary *info = OVAdviceInfo(code);
        if (!info) continue;
        NSView *row = [self adviceRow:info];
        [self.adviceStack addArrangedSubview:row];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.widthAnchor constraintEqualToAnchor:self.adviceStack.widthAnchor].active = YES;
    }
}

#pragma mark Trim edges

/// 6.4 → "0:06.4": minutes, seconds and tenths.
static NSString *TenthsTime(NSTimeInterval t) {
    long tenths = lround(MAX(0, t) * 10);
    return [NSString stringWithFormat:@"%ld:%02ld.%ld", tenths / 600, (tenths / 10) % 60, tenths % 10];
}

- (void)trimEdges:(id)s {
    NSString *audio = [self currentAudio];
    if (!audio || self.trimming || [OVWorker shared].busy || self.recorder.recording) return;
    double d = OVAudioDuration(audio);
    if (d < OVTrimMinKeep + 0.1) {
        self.status.stringValue = L(@"The sample is too short to trim.");
        self.status.textColor = OVColor(OVRoleWarn);
        return;
    }
    self.trimming = YES;
    self.trimPath = audio;
    NSString *key = [self analysisKey:audio];
    // handles start on the voiced part when the check found silence at the edges, else on the whole sample
    NSTimeInterval start = 0, end = d;
    NSDictionary *r = self.analysis[key];
    if ([r[@"lead_silence_s"] respondsToSelector:@selector(doubleValue)]) {
        NSTimeInterval s = MAX(0, [r[@"lead_silence_s"] doubleValue] - 0.15), e = MIN(d, d - [r[@"tail_silence_s"] doubleValue] + 0.15);
        if (e - s >= OVTrimMinKeep) { start = s; end = e; }
    }
    self.waveform.duration = d;
    self.waveform.position = 0;
    self.waveform.trimEnabled = YES;
    [self.waveform setTrimStart:start end:end];
    self.waveform.accessibilityHelp = L(@"Drag the two handles, or press [ and ] to set the start and the end at the playhead.");
    self.waveform.toolTip = L(@"Drag the handles to choose what stays. [ sets the start and ] the end at the playhead.");
    NSArray *cached = self.peaksCache[key];
    if (cached) self.waveform.peaks = cached;
    else {
        __weak typeof(self) w = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *peaks = OVWaveformPeaksForFile(audio, 400);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!peaks) return;
                w.peaksCache[key] = peaks;
                if (w.trimming && [w.trimPath isEqualToString:audio]) w.waveform.peaks = peaks;
            });
        });
    }
    self.waveform.hidden = NO;
    [self showTrimControls:YES];
    [self updateTrimInfo];
    self.trimTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(trimTick:) userInfo:nil repeats:YES];
    [self refreshButtons];
    [self.view.window makeFirstResponder:self.waveform];
}

- (void)showTrimControls:(BOOL)on {
    self.trimInfo.hidden = self.trimPlayButton.hidden = self.trimCancelButton.hidden = self.trimApplyButton.hidden = !on;
    self.trimButton.hidden = on;
    if (!on) self.trimWarn.hidden = YES;
}

- (void)updateTrimInfo {
    NSTimeInterval kept = self.waveform.trimEnd - self.waveform.trimStart, whole = self.waveform.duration;
    self.trimInfo.stringValue = [NSString stringWithFormat:L(@"Keeps %@ of %@"), TenthsTime(kept), TenthsTime(whole)];
    // the page's own wording for a sample the model can't use well (it warns, it doesn't block)
    self.trimWarn.stringValue = kept < 3 ? L(@"Too short — the model needs 3–10 seconds of speech.") :
                                kept > 15 ? L(@"Longer than 15 s — trim it to the best 5–10 seconds.") : @"";
    self.trimWarn.hidden = self.trimWarn.stringValue.length == 0;
    self.trimApplyButton.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", L(@"Apply"), self.trimInfo.stringValue];
}

- (void)endTrim {
    if (!self.trimming) return;
    [self.trimTimer invalidate];
    self.trimTimer = nil;
    if (self.playingSelection && [[OVPlayer shared].currentPath isEqualToString:self.trimPath]) [[OVPlayer shared] stop];
    self.playingSelection = NO;
    self.trimming = NO;
    self.trimPath = nil;
    self.waveform.trimEnabled = NO;
    self.waveform.toolTip = nil;
    [self showTrimControls:NO];
    self.trimPlayButton.title = L(@"Play selection");
    self.trimPlayButton.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    NSString *shown = self.shownKey, *audio = [self currentAudio];
    if (shown && self.analysis[shown] && audio) [self showAnalysis:self.analysis[shown] forAudio:audio key:shown];   // the check's waveform and help come back
    else self.waveform.hidden = YES;
    [self refreshButtons];
}

- (void)cancelTrim:(id)s { [self endTrim]; [self.view.window makeFirstResponder:self.trimButton]; }

/// Plays only the kept part; the timer stops it at the end handle and follows the playhead.
- (void)playSelection:(id)s {
    OVPlayer *p = [OVPlayer shared];
    if (!self.trimming || !self.trimPath) return;
    if (self.playingSelection) { [p stop]; self.playingSelection = NO; [self refreshTrimPlayButton]; return; }
    [p play:self.trimPath];
    [p seek:self.waveform.trimStart];
    self.playingSelection = p.playing;
    [self refreshTrimPlayButton];
}

- (void)refreshTrimPlayButton {
    self.trimPlayButton.title = self.playingSelection ? L(@"Stop") : L(@"Play selection");
    self.trimPlayButton.image = [NSImage imageWithSystemSymbolName:self.playingSelection ? @"stop.fill" : @"play.fill" accessibilityDescription:nil];
}

- (void)trimTick:(NSTimer *)t {
    OVPlayer *p = [OVPlayer shared];
    BOOL mine = [p.currentPath isEqualToString:self.trimPath];
    if (mine && p.playing) {
        self.waveform.position = p.currentTime;
        if (self.playingSelection && p.currentTime >= self.waveform.trimEnd) { [p stop]; self.playingSelection = NO; [self refreshTrimPlayButton]; }
    } else if (self.playingSelection) {   // finished, or something else took the player
        self.playingSelection = NO;
        [self refreshTrimPlayButton];
    }
}

- (void)applyTrim:(id)s {
    NSString *audio = [self currentAudio];
    if (!self.trimming || !audio || !self.voice || ![audio isEqualToString:self.trimPath]) return;
    if ([OVWorker shared].busy || self.recorder.recording) return;
    NSTimeInterval start = self.waveform.trimStart, end = self.waveform.trimEnd;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = [self draftPath:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    NSError *err = nil;
    if (!OVTrimAudioFile(audio, tmp, start, end, OVTrimDefaultFade, &err)) {
        self.status.stringValue = [NSString stringWithFormat:L(@"Couldn’t trim the sample: %@"), err.localizedDescription ?: @"?"];
        self.status.textColor = OVColor(OVRoleWarn);
        return;
    }
    // the original stays exactly as the Improve flow keeps it: made once, never overwritten
    BOOL madeOriginal = ![fm fileExistsAtPath:[self originalPath]];
    if (madeOriginal) [fm copyItemAtPath:audio toPath:[self originalPath] error:nil];
    [self endTrim];
    if ([self keepSample:tmp]) {
        self.status.textColor = OVColor(OVRoleMuted);
        self.status.stringValue = self.voice.ready ? L(@"Sample trimmed. Re-clone the voice to use it.") : L(@"Sample trimmed.");
    } else if (madeOriginal) {
        [fm removeItemAtPath:[self originalPath] error:nil];   // nothing was changed
    }
    [fm removeItemAtPath:tmp error:nil];
    [self refreshButtons];
}

#pragma mark Compare samples

- (void)compareSamples:(id)s {
    NSString *audio = [self currentAudio];
    if (!audio) return;
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.allowsMultipleSelection = YES;
    op.message = L(@"Choose recordings to compare with the current sample.");
    op.allowedContentTypes = @[UTTypeAudio, UTTypeMovie];
    if ([op runModal] != NSModalResponseOK || !op.URLs.count) return;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:L(@"Current sample")];
    for (NSURL *u in op.URLs) [names addObject:u.lastPathComponent];
    NSArray<NSURL *> *urls = op.URLs;
    NSString *dir = [self draftPath:@""];
    NSString *key = [self analysisKey:audio];
    self.status.stringValue = L(@"Comparing the samples…");
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:audio];
        NSMutableArray<NSString *> *temps = [NSMutableArray array];
        NSString *failure = nil;
        for (NSURL *u in urls) {
            NSString *path = u.path;
            if (![u.pathExtension.lowercaseString isEqualToString:@"wav"]) {   // the engine reads WAV: the app decodes the rest
                NSString *dst = [dir stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
                NSError *err = nil;
                if (!OVConvertToWav(path, dst, NULL, &err)) {
                    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
                    failure = [NSString stringWithFormat:L(@"Couldn’t read the audio: %@"), err.localizedDescription ?: @"?"];
                    break;
                }
                path = dst;
                [temps addObject:dst];
            }
            [paths addObject:path];
        }
        void (^cleanup)(void) = ^{ for (NSString *t in temps) [NSFileManager.defaultManager removeItemAtPath:t error:nil]; };
        dispatch_async(dispatch_get_main_queue(), ^{
            if (failure) { cleanup(); w.status.stringValue = failure; return; }
            [[OVWorker shared] request:@{@"cmd": @"compare_samples", @"audios": paths} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
                cleanup();
                if (error || !data) { w.status.stringValue = error ?: L(@"Error"); return; }
                w.status.stringValue = @"";
                if ([[w analysisKey:[w currentAudio] ?: @""] isEqualToString:key]) [w showComparison:data names:names];   // not for another voice
                [w refreshButtons];
            }];
        });
    });
}

/// One row per sample: level, noise margin and the flags "Duplicate", "Much quieter", "Noisier".
- (void)showComparison:(NSDictionary *)res names:(NSArray<NSString *> *)names {
    for (NSView *v in [self.compareStack.arrangedSubviews copy]) { [self.compareStack removeView:v]; [v removeFromSuperview]; }
    NSArray *samples = res[@"samples"];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:OVLabel(L(@"Comparison"), 13, NSFontWeightSemibold, nil)];
    for (NSUInteger i = 0; i < samples.count; i++) {
        NSDictionary *x = samples[i];
        NSString *name = i < names.count ? names[i] : [x[@"path"] lastPathComponent];
        NSString *line = [NSString stringWithFormat:L(@"%@ · %@ · level %.0f dB · noise margin %.0f dB"), name,
                          OVFormatDuration([x[@"seconds"] doubleValue]), [x[@"rms_db"] doubleValue], [x[@"snr_db"] doubleValue]];
        NSMutableArray *rowViews = [NSMutableArray arrayWithObject:OVWrapLabel(line, 13, OVColor(OVRoleMuted))];
        for (NSString *flag in OVCompareFlags(res, i)) [rowViews addObject:OVCompactBadge(flag, OVRoleWarn)];
        [rowViews addObject:OVSpacer()];
        NSStackView *row = OVHStack(rowViews, 8);
        row.alignment = NSLayoutAttributeCenterY;
        [rows addObject:row];
    }
    for (NSView *v in rows) {
        [self.compareStack addArrangedSubview:v];
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [v.widthAnchor constraintEqualToAnchor:self.compareStack.widthAnchor].active = YES;
    }
}

#pragma mark Improve sample


- (NSString *)improveMode { return @[@"light", @"dfn", @"music"][MAX(0, MIN(2, self.modeSeg.selectedIndex))]; }

- (void)modePicked:(id)s {
    [self askEngineStatus:nil];
    [self refreshButtons];
}

- (void)strengthChanged:(OVSlider *)sl {
    self.strengthValue.stringValue = [NSString stringWithFormat:L(@"%d dB"), (int)round(sl.doubleValue)];
    self.strengthSlider.accessibilityValue = self.strengthValue.stringValue;
}

/// Whether the mode's engine state is known (installed or not) — unknown is not the same as "not installed".
- (BOOL)improveEngineKnown {
    NSString *mode = [self improveMode];
    return [mode isEqualToString:@"light"] || ([mode isEqualToString:@"dfn"] ? self.dfnInstalled : self.musicInstalled) != nil;
}

/// Asks whether DeepFilterNet / the music-removal engine are installed. `then` runs afterwards (also when the answer
/// could not be had because the worker is busy — the state then stays unknown and refreshButtons asks again).
- (void)askEngineStatus:(nullable void (^)(void))then {
    NSString *mode = [self improveMode];
    if ([mode isEqualToString:@"light"] || [OVRuntime shared].state != OVRuntimeReady) { if (then) then(); return; }
    if ([OVWorker shared].busy || self.askingEngine) { if (then) then(); return; }
    self.askingEngine = YES;
    __weak typeof(self) w = self;
    BOOL dfn = [mode isEqualToString:@"dfn"];
    [[OVWorker shared] request:@{@"cmd": dfn ? @"dfn_status" : @"sep_status"} status:nil progress:nil done:^(NSDictionary *d, NSString *e) {
        w.askingEngine = NO;
        if (!e && d) {
            if (dfn) w.dfnInstalled = @([d[@"installed"] boolValue]);
            else w.musicInstalled = @([d[@"onnxruntime"] boolValue] && [d[@"model_ready"] boolValue]);
        }
        [w refreshButtons];
        if (then) then();
    }];
}

/// engine_missing / unsupported from DeepFilterNet or music removal: the engine must be (re)downloaded — offer the Download action.
- (BOOL)noteEngineError:(nullable NSString *)code mode:(NSString *)mode {
    if (![code isEqualToString:@"engine_missing"] && ![code isEqualToString:@"unsupported"]) return NO;
    if ([mode isEqualToString:@"dfn"]) self.dfnInstalled = @NO;
    else if ([mode isEqualToString:@"music"]) self.musicInstalled = @NO;
    else return NO;
    return YES;
}

- (BOOL)modeEngineReady {
    NSString *mode = [self improveMode];
    if ([mode isEqualToString:@"light"]) return YES;
    return [([mode isEqualToString:@"dfn"] ? self.dfnInstalled : self.musicInstalled) boolValue];
}

- (void)refreshImproveControls:(NSString *)audio busy:(BOOL)busy {
    NSString *mode = [self improveMode];
    BOOL ready = [self modeEngineReady];
    BOOL known = [self improveEngineKnown];
    if (!known && !busy) [self askEngineStatus:nil];   // the worker was busy earlier: ask again now
    BOOL dfn = [mode isEqualToString:@"dfn"], music = [mode isEqualToString:@"music"];
    // strength (DeepFilterNet only) and the download button (a mode whose engine is missing)
    for (NSView *v in self.strengthRow.arrangedSubviews) v.hidden = v == self.downloadButton ? (ready || !known) : !dfn;
    self.strengthRow.hidden = !(dfn || (music && !ready && known));
    NSString *what = dfn ? L(@"Download DeepFilterNet (~27 MB)") : L(@"Download the music-removal engine (~140 MB)");
    self.downloadButton.toolTip = what;
    self.downloadButton.accessibilityLabel = what;
    self.downloadButton.enabled = !busy;
    self.enhanceButton.enabled = audio && OVEverythingReady() && !busy && !self.recorder.recording && ready;
    BOOL hasOrig = self.voice && [NSFileManager.defaultManager fileExistsAtPath:[self originalPath]];
    self.playerBar.hidden = !(audio && hasOrig);
    if (!self.playerBar.hidden) {
        self.playerBar.originalPath = [self originalPath];
        self.playerBar.path = audio;
    }
}

/// "Download" next to the mode: DeepFilterNet, or onnxruntime + the vocal-separation model.
- (void)downloadEngine:(id)s {
    NSString *mode = [self improveMode];
    __weak typeof(self) w = self;
    void (^finish)(NSString *) = ^(NSString *error) {
        w.status.stringValue = error ?: L(@"Downloaded.");
        w.dfnInstalled = w.musicInstalled = nil;
        [w askEngineStatus:nil];
        [w refreshButtons];
    };
    if ([mode isEqualToString:@"dfn"]) {
        self.status.stringValue = L(@"Downloading DeepFilterNet…");
        [[OVWorker shared] request:@{@"cmd": @"dfn_install"} status:^(NSString *m) { w.status.stringValue = m; } progress:nil
                              done:^(NSDictionary *d, NSString *e) { finish(e); }];
        return;
    }
    void (^model)(void) = ^{
        w.status.stringValue = L(@"Downloading the music-removal engine…");
        [[OVWorker shared] request:@{@"cmd": @"sep_install_model"} status:^(NSString *m) { w.status.stringValue = m; } progress:nil
                              done:^(NSDictionary *d, NSString *e) { finish(e); }];
    };
    [[OVWorker shared] request:@{@"cmd": @"sep_status"} status:nil progress:nil done:^(NSDictionary *d, NSString *e) {
        if (!e && ![d[@"onnxruntime"] boolValue]) {
            w.status.stringValue = L(@"Installing onnxruntime…");
            [[OVRuntime shared] installOptionalPackages:@[@"onnxruntime==1.31.1"] title:L(@"Installing onnxruntime…")
                                               progress:nil
                                                   done:^(NSString *err) { if (err) finish(err); else model(); }];
        } else model();
    }];
}

- (void)enhance:(id)s {
    NSString *audio = [self currentAudio];
    if (!audio || !self.voice) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = [self draftPath:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    NSString *action = nil;
    NSDictionary *req = OVEnhanceRequest([self improveMode], self.strengthSlider.doubleValue, audio, tmp, [self modeEngineReady], &action);
    if (!req) { if ([action isEqualToString:@"download"]) [self downloadEngine:nil]; return; }
    BOOL madeOriginal = ![fm fileExistsAtPath:[self originalPath]];
    if (madeOriginal) [fm copyItemAtPath:audio toPath:[self originalPath] error:nil];
    NSString *vid = self.voice.identifier;
    BOOL music = [req[@"mode"] isEqualToString:@"music"];
    self.status.stringValue = music ? L(@"Removing the music…") : L(@"Cleaning the sample…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:req status:^(NSString *m) { w.status.stringValue = m; } progress:nil done:^(NSDictionary *data, NSString *error) {
        // Another voice was opened meanwhile: the cleaned sample belongs to the old one, drop it.
        if (![w.voice.identifier isEqualToString:vid]) { [NSFileManager.defaultManager removeItemAtPath:tmp error:nil]; return; }
        if (error) {   // the message names the action (e.g. download the engine)
            BOOL engineGone = [w noteEngineError:[OVWorker shared].lastErrorCode mode:req[@"mode"]];   // code is valid only here
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            if (madeOriginal) [NSFileManager.defaultManager removeItemAtPath:[w originalPath] error:nil];   // nothing was changed
            w.status.stringValue = error;
            w.status.textColor = OVColor(OVRoleWarn);
            if (engineGone) w.status.stringValue = [error stringByAppendingFormat:@" %@", L(@"Press Download, then try again.")];
            else if (![req[@"mode"] isEqualToString:@"light"]) { w.dfnInstalled = w.musicInstalled = nil; [w askEngineStatus:nil]; }
            [w refreshButtons];
            return;
        }
        if ([w keepSample:tmp]) {
            w.status.stringValue = w.voice.ready ? L(@"Sample improved. Re-clone the voice to use it.") : L(@"Sample improved.");
        }
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        [w refreshButtons];
    }];
}

- (void)revertSample:(id)s {
    if (![NSFileManager.defaultManager fileExistsAtPath:[self originalPath]]) return;
    if ([self keepSample:[self originalPath]]) {
        [NSFileManager.defaultManager removeItemAtPath:[self originalPath] error:nil];
        self.status.stringValue = L(@"Original sample restored.");
    }
    [self refreshButtons];
}

- (void)playPreview:(id)s { [[OVPlayer shared] toggle:[self previewPath]]; }

/// A short phrase in the sample's language, spoken with the new voice, so the result is heard right away.
- (void)makePreviewFor:(OVVoice *)v trimmed:(BOOL)trimmed {
    NSDictionary *spec = [OVSettings modelSpec];
    if (!spec || !v.ready) return;
    NSString *vid = v.identifier;
    NSString *lang = v.language ?: [OVLocale detectLanguage:v.refText] ?: [OVLocale speechLanguageForText:v.refText];
    NSDictionary *phrases = @{@"uk": @"Привіт! Тепер мій голос звучить саме так. Як вам?",
                              @"ru": @"Привет! Теперь мой голос звучит именно так. Как вам?",
                              @"en": @"Hi! This is how my voice sounds now. What do you think?",
                              @"de": @"Hallo! So klingt jetzt meine Stimme. Wie gefällt sie dir?",
                              @"pl": @"Cześć! Tak teraz brzmi mój głos. Jak ci się podoba?",
                              @"fr": @"Salut ! Voilà comment sonne ma voix maintenant. Qu'en penses-tu ?",
                              @"es": @"¡Hola! Así suena ahora mi voz. ¿Qué te parece?"};
    NSString *text = phrases[lang] ?: phrases[@"en"];
    if (!phrases[lang]) lang = @"en";
    NSString *out = [v.folder stringByAppendingPathComponent:@"preview.wav"];
    self.status.stringValue = L(@"Speaking a test phrase with the new voice…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"synth", @"model": spec, @"voice": v.workerSpec, @"language": lang, @"text": text,
                                 @"params": [OVSettings generationParams], @"out": out}
                        status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        if (error) { w.status.stringValue = error; return; }
        w.status.stringValue = trimmed
            ? [NSString stringWithFormat:L(@"Ready! The recording was long, so its best %@ became the sample (the original is kept)."), OVFormatDuration(v.seconds)]
            : L(@"Ready! Here is how the clone sounds. The voice is selected on the Speech page.");
        [w refreshButtons];
        if ([w.voice.identifier isEqualToString:vid]) [[OVPlayer shared] play:out];
    }];
}

#pragma mark Worker actions

/// Whisper can't tell accented Ukrainian from Russian. Shows both readings and returns the language picked
/// ("uk" / "ru"), or nil when the alert was dismissed.
- (nullable NSString *)askUkrainianOrRussian:(NSDictionary *)readings {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Is the sample in Ukrainian or in Russian?");
    a.informativeText = [NSString stringWithFormat:L(@"Speech recognition can’t reliably tell Ukrainian from Russian. Pick the reading that matches what is said:\n\nUkrainian: “%@”\n\nRussian: “%@”"),
                         readings[@"uk"] ?: @"", readings[@"ru"] ?: @""];
    [a addButtonWithTitle:[OVLocale nameForLanguage:@"uk"]];
    [a addButtonWithTitle:[OVLocale nameForLanguage:@"ru"]];
    NSModalResponse r = [a runModal];
    return r == NSAlertFirstButtonReturn ? @"uk" : r == NSAlertSecondButtonReturn ? @"ru" : nil;
}

- (void)transcribe:(id)s {
    OVModel *asr = [OVModels shared].asrModel;
    if (!asr) {
        NSAlert *a = [NSAlert new];
        a.messageText = L(@"A speech recognition model is needed");
        a.informativeText = L(@"To fill in the sample text automatically, download Whisper Large v3 Turbo (1.6 GB) on the Models page.");
        [a addButtonWithTitle:L(@"Open Models")];
        [a addButtonWithTitle:L(@"Cancel")];
        if ([a runModal] == NSAlertFirstButtonReturn) OVNavigate(@"models");
        return;
    }
    NSDictionary *spec = [OVSettings modelSpec];
    NSString *audio = [self currentAudio];
    if (!spec || !audio) return;
    self.status.textColor = OVColor(OVRoleMuted);
    self.status.stringValue = L(@"Transcribing…");
    NSString *vid = self.voice.identifier;
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"transcribe", @"model": spec, @"audio": audio, @"asr_path": asr.localPath,
                                 @"language": [self sampleLanguage]}
                        status:^(NSString *m) { w.status.stringValue = m; }
                      progress:nil
                          done:^(NSDictionary *data, NSString *error) {
        if (error) { w.status.stringValue = error; return; }
        OVVoice *v = [[OVVoices shared] voiceWithId:vid ?: @""];  // the voice the sample belongs to, even if another one is shown now
        if (!v) return;
        v.refText = data[@"text"] ?: @"";
        [w voice:v heardLanguage:data[@"language"]];
        NSDictionary *readings = data[@"readings"];
        if (readings) {
            NSString *lang = [w askUkrainianOrRussian:readings] ?: @"uk";
            v.refText = readings[lang] ?: v.refText;
            v.language = lang;
            v.languageAuto = NO;  // decided by the user now
        }
        [v save];
        if (![w.voice.identifier isEqualToString:vid]) return;
        w.refText.string = v.refText;
        [w showSampleLanguage:v.language isAuto:v.languageAuto];
        w.status.stringValue = L(@"Text transcribed — check it and correct it if needed.");
        [w flagWords:data[@"unknown_words"]];
    }];
}

/// Words of the sample text that aren't Ukrainian (usually misheard by Whisper): selected in the text and named
/// in the status line. A wrong word there teaches the voice to say it wrong.
- (void)flagWords:(nullable NSArray<NSString *> *)words {
    if (!words.count) return;
    self.status.stringValue = [NSString stringWithFormat:L(@"Check these words in the sample text — they aren’t Ukrainian dictionary words, probably misheard: %@. The text must match the recording exactly; fix them and re-clone."),
                               [words componentsJoinedByString:@", "]];
    self.status.textColor = OVColor(OVRoleWarn);
    NSMutableArray *ranges = [NSMutableArray array];
    for (NSString *word in words) {
        NSRange r = [self.refText.string rangeOfString:word];
        if (r.location != NSNotFound) [ranges addObject:[NSValue valueWithRange:r]];
    }
    if (ranges.count) {
        self.refText.selectedRanges = ranges;
        [self.view.window makeFirstResponder:self.refText];
    }
}

- (void)clone:(id)s {
    NSString *audio = [self currentAudio];
    NSDictionary *spec = [OVSettings modelSpec];
    if (!audio || !spec) return;
    NSString *text = [self.refText.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    OVModel *asr = [OVModels shared].asrModel;
    if (!text.length && !asr) {
        self.status.stringValue = L(@"Enter the sample text or download Whisper to transcribe it automatically.");
        return;
    }
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length) name = L(@"Untitled");

    OVVoice *v = self.voice;
    if (!v) return;
    v.name = name;
    v.refText = text;
    v.languageAuto = [self sampleLanguageIsAuto];
    if (!v.languageAuto) v.language = [self sampleLanguage];
    [v save];
    NSString *vid = v.identifier;
    NSString *pending = [self hasPending] ? [self pendingPath] : nil;

    NSMutableDictionary *req = [@{@"cmd": @"clone", @"model": spec, @"audio": audio,
                                  @"ref_text": text, @"out": v.promptPath,
                                  @"language": [self sampleLanguage]} mutableCopy];
    if (asr) req[@"asr_path"] = asr.localPath;
    self.status.textColor = OVColor(OVRoleMuted);
    self.status.stringValue = L(@"Cloning…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:req status:^(NSString *m) { w.status.stringValue = m; } progress:nil
                          done:^(NSDictionary *data, NSString *error) {
        if (error) { w.status.stringValue = error; [[OVVoices shared] reload]; return; }
        OVVoice *v = [[OVVoices shared] voiceWithId:vid];  // fresh copy: it may have been renamed meanwhile
        if (!v) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *trimmed = data[@"trimmed"];
        if (trimmed.length) { // a long recording was cut to its best seconds: the cut is the sample now, the original is kept
            NSString *orig = [v.folder stringByAppendingPathComponent:@"reference.orig.wav"];
            if (![fm fileExistsAtPath:orig]) [fm moveItemAtPath:audio toPath:orig error:nil];
            [fm removeItemAtPath:audio error:nil];
            [fm moveItemAtPath:trimmed toPath:audio error:nil];
        }
        if (pending) { // the new sample is now the voice's reference
            [fm removeItemAtPath:v.referencePath error:nil];
            [fm moveItemAtPath:pending toPath:v.referencePath error:nil];
        }
        v.refText = data[@"ref_text"] ?: text;
        v.seconds = [data[@"seconds"] doubleValue] ?: v.seconds;
        [w voice:v heardLanguage:data[@"language"]];
        v.accented = [data[@"accent"][@"accented"] boolValue];
        [v save];
        [NSUserDefaults.standardUserDefaults setObject:v.identifier forKey:@"voice"];
        [fm removeItemAtPath:[v.folder stringByAppendingPathComponent:@"preview.wav"] error:nil];
        v = [[OVVoices shared] voiceWithId:vid] ?: v;  // saving reloaded the list
        [w showVoice:v];
        NSDictionary *readings = data[@"readings"];
        if (readings) {
            NSString *lang = [w askUkrainianOrRussian:readings] ?: @"uk";
            v.language = lang;
            v.languageAuto = NO;
            if ([lang isEqualToString:@"ru"]) {  // the profile was made with the Ukrainian reading: make it again
                v.refText = readings[@"ru"] ?: v.refText;
                [v save];
                w.refText.string = v.refText;
                [w showSampleLanguage:@"ru" isAuto:NO];
                [w clone:nil];
                return;
            }
            [v save];
            [w showSampleLanguage:@"uk" isAuto:NO];
        }
        NSDictionary *mm = data[@"mismatch"];
        if (mm) {
            // the #1 reason for a bad clone: the transcript doesn't match what is actually said
            NSAlert *a = [NSAlert new];
            a.messageText = L(@"The text doesn’t match the recording");
            a.informativeText = [NSString stringWithFormat:L(@"Whisper hears:\n“%@”\n\nA transcript that differs from the audio is the most common cause of a poor clone. Use the recognized text?"), mm[@"heard"]];
            [a addButtonWithTitle:L(@"Use recognized text and re-clone")];
            [a addButtonWithTitle:L(@"Keep my text")];
            if ([a runModal] == NSAlertFirstButtonReturn) {
                w.refText.string = mm[@"heard"] ?: @"";
                v.refText = mm[@"heard"];
                [v save];
                [w clone:nil];
                return;
            }
        }
        NSArray *odd = data[@"unknown_words"];
        if (odd.count) {
            NSAlert *a = [NSAlert new];
            a.messageText = L(@"Some words of the sample text look misheard");
            a.informativeText = [NSString stringWithFormat:L(@"These aren’t Ukrainian dictionary words: %@.\n\nThe voice learns how you speak from the sample and its text together — a misheard word teaches it a wrong pronunciation. Fix them so the text matches the recording word for word, then press “Re-clone voice”."),
                                 [odd componentsJoinedByString:@", "]];
            [a addButtonWithTitle:L(@"Fix the text")];
            [a addButtonWithTitle:L(@"Keep as is")];
            if ([a runModal] == NSAlertFirstButtonReturn) { [w flagWords:odd]; return; }
        }
        w.status.stringValue = v.accented
            ? L(@"Done! The sample has a noticeable accent: before its first speech in its own language the voice learns clean pronunciation (about two minutes, once). The voice is selected on the Speech page.")
            : L(@"Done! The voice is selected on the Speech page.");
        [w makePreviewFor:v trimmed:trimmed.length > 0];
    }];
}

- (void)deleteVoice:(id)s {
    if (!self.voice) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Delete voice “%@”?"), self.voice.name];
    a.informativeText = L(@"The voice folder will be moved to the Trash.");
    [a addButtonWithTitle:L(@"Delete")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.buttons.firstObject.hasDestructiveAction = YES;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [[OVPlayer shared] stop];
    [[OVVoices shared] remove:self.voice];
    self.voice = nil;
    if ([OVVoices shared].all.count) [self showVoice:[OVVoices shared].all.firstObject];
    else [self newVoice:nil];
}
@end
