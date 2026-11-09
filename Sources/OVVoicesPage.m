#import "OVPages.h"
#import "OVUI.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVStore.h"
#import "OVModels.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSTimeInterval kMaxRecord = 15;

/// Page background that takes an audio file dropped anywhere on it.
@interface OVAudioDropView : NSStackView
@property (copy) void (^onDrop)(NSString *path);
@end
@implementation OVAudioDropView
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

@class OVMeterBar;

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

@property (nullable) OVVoice *voice;          // nil = drafting a new voice
@property (nullable) AVAudioRecorder *recorder;
@property (nullable, copy) NSString *recordingVoiceId;  // the voice a recording belongs to ("" = a new voice)
@property (nullable) NSTimer *recTimer;
@end

/// Quality bar: a 6 pt track (field color) with a fill that turns from error to warning to OK at the same thresholds the
/// NSLevelIndicator used (45 and 70). Colors are resolved while drawing, so a palette change repaints it.
@interface OVMeterBar : NSView
@property (nonatomic) double doubleValue;   // 0...100
@end
@implementation OVMeterBar
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) self.accessibilityRole = NSAccessibilityLevelIndicatorRole;
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(120, 6); }
- (void)setDoubleValue:(double)v {
    _doubleValue = MAX(0, MIN(100, v));
    self.accessibilityValue = @((NSInteger)round(_doubleValue));
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [OVColor(OVRoleField) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:3 yRadius:3] fill];
    if (_doubleValue <= 0) return;
    OVRole role = _doubleValue >= 70 ? OVRoleOK : _doubleValue >= 45 ? OVRoleWarn : OVRoleErr;
    NSRect fill = b;
    fill.size.width = MAX(6, round(NSWidth(b) * _doubleValue / 100));
    [OVColor(role) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:3 yRadius:3] fill];
}
@end

/// A numbered step card whose header can carry an accessory (OVStepCard has none).
static NSView *VoiceStepCard(NSInteger step, NSString *symbol, NSString *title, NSView *accessory, NSView *content) {
    NSView *header = OVCardHeader(step, symbol, title, accessory);
    NSStackView *s = OVVStack(@[header, content], 16);
    OVFillWidth(@[header, content], s);
    return OVCard(s, 20);
}

/// The heading field inside an OVPageHeader (found by its accessibility role).
static NSTextField *HeaderTitle(NSView *v) {
    if ([v isKindOfClass:NSTextField.class] && [[(NSTextField *)v accessibilityRole] isEqual:@"AXHeading"]) return (NSTextField *)v;
    for (NSView *sub in v.subviews) { NSTextField *t = HeaderTitle(sub); if (t) return t; }
    return nil;
}

@implementation OVVoicesPage

/// Sets the page title again with the helper's attributes (28 bold, tracking), which a plain stringValue would lose.
- (void)setHeadingText:(NSString *)text {
    NSTextField *t = HeaderTitle(self.headerView);
    if (!t) return;
    NSString *s = text.length ? text : L(@"New voice");
    NSMutableDictionary *attrs = [[t.attributedStringValue attributesAtIndex:0 effectiveRange:NULL] mutableCopy];
    t.attributedStringValue = [[NSAttributedString alloc] initWithString:s attributes:attrs];
    t.toolTip = s;
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
        if (![OVWorker shared].busy && !weakSelf.recorder.recording && urls.firstObject) [weakSelf importAudio:urls.firstObject.path];
    }];
    NSStackView *playRow = OVHStack(@[self.playButton, self.refInfo, OVSpacer(), self.recordButton], 12);
    playRow.alignment = NSLayoutAttributeCenterY;
    NSStackView *qualityRow = OVHStack(@[OVLabel(L(@"Quality"), 13, NSFontWeightMedium, OVColor(OVRoleMuted)), self.qualityMeter, OVSpacer()], 10);
    qualityRow.alignment = NSLayoutAttributeCenterY;
    NSStackView *fixRow = OVHStack(@[self.enhanceButton, self.revertButton, OVSpacer()], 10);
    NSStackView *audioBox = OVVStack(@[zone, playRow, qualityRow, self.qualityLabel, fixRow], 12);
    OVFillWidth(@[zone, playRow, qualityRow, self.qualityLabel, fixRow], audioBox);
    self.sampleBadge = OVHStack(@[], 0);
    NSView *audioCard = VoiceStepCard(2, @"waveform", L(@"Voice sample"), self.sampleBadge, audioBox);

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
    NSView *textCard = VoiceStepCard(3, @"text.quote", L(@"What the sample says"), nil, textBox);

    self.cloneButton = OVPrimaryButton(L(@"Clone voice"), self, @selector(clone:));
    self.cloneButton.image = [NSImage imageWithSystemSymbolName:@"person.wave.2.fill" accessibilityDescription:nil];
    self.spinner = OVSpinner();
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.deleteButton = OVGhostButton(L(@"Delete voice"), @"trash", self, @selector(deleteVoice:));
    self.deleteButton.contentTintColor = OVColor(OVRoleErr);
    self.previewButton = OVGhostButton(L(@"Hear the clone"), @"play.fill", self, @selector(playPreview:));
    NSStackView *actions = OVHStack(@[self.cloneButton, self.previewButton, self.spinner, OVSpacer()], 10);
    actions.alignment = NSLayoutAttributeCenterY;
    self.analysis = [NSMutableDictionary dictionary];

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
    NSView *voiceCard = VoiceStepCard(1, @"person.crop.circle", L(@"Voice"), nil, voiceColumns);

    self.headerView = OVPageHeader(L(@"New voice"), L(@"Clone a voice from 3–10 seconds of speech."), self.deleteButton);
    NSScrollView *rightScroll = OVPageScroll(@[self.headerView, voiceCard, audioCard, textCard, actions, self.status, self.adaptedRow]);

    OVAudioDropView *root = [OVAudioDropView stackViewWithViews:@[left, rightScroll]];
    root.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    root.distribution = NSStackViewDistributionFill;
    root.spacing = 0;
    root.alignment = NSLayoutAttributeTop;
    [root registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    root.onDrop = ^(NSString *path) {  // a recording dropped on the page becomes the sample of the voice shown
        if (![OVWorker shared].busy && !weakSelf.recorder.recording) [weakSelf importAudio:path];
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

    if (audio) {
        double d = OVAudioDuration(audio);
        NSString *warn = d < 2.5 ? L(@"  ⚠︎ too short") : d > 20 ? L(@"  ⚠︎ longer than 20 s — trim it to 3–10 s") : @"";
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

- (void)importAudio:(NSString *)src {
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

/// Asks the engine for a quick quality report of the current sample (no model is loaded for this).
- (void)analyzeIfNeeded:(NSString *)audio {
    if (!audio) { self.qualityMeter.doubleValue = 0; self.qualityLabel.stringValue = @""; return; }
    NSDictionary *r = self.analysis[[self analysisKey:audio]];
    if (r) { [self showAnalysis:r]; return; }
    if ([OVWorker shared].busy || [OVRuntime shared].state != OVRuntimeReady || self.recorder.recording) return;
    NSString *key = [self analysisKey:audio];
    self.qualityLabel.stringValue = L(@"Checking the sample…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"analyze", @"audio": audio} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        if (error || !data) { w.qualityLabel.stringValue = @""; return; }
        w.analysis[key] = data;
        if ([[w currentAudio] isEqualToString:audio]) [w showAnalysis:data];
    }];
}

- (void)showAnalysis:(NSDictionary *)r {
    self.qualityMeter.doubleValue = [r[@"score"] doubleValue];
    NSDictionary *tips = @{
        @"short": L(@"Too short — the model needs 3–10 seconds of speech."),
        @"long": L(@"Longer than 15 s — trim it to the best 5–10 seconds."),
        @"clipping": L(@"Distorted (clipping) — speak a little further from the microphone."),
        @"noisy": L(@"Background noise — press “Improve sample” or record in a quieter room."),
        @"quiet": L(@"Very quiet — speak closer to the microphone."),
        @"pauses": L(@"Lots of silence — “Improve sample” shortens the pauses."),
    };
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *i in r[@"issues"]) if (tips[i]) [lines addObject:tips[i]];
    NSString *head = [NSString stringWithFormat:L(@"%d/100 · noise margin %.0f dB · %@"), [r[@"score"] intValue], [r[@"snr_db"] doubleValue],
                      OVFormatDuration([r[@"seconds"] doubleValue])];
    self.qualityLabel.stringValue = lines.count ? [NSString stringWithFormat:@"%@\n%@", head, [lines componentsJoinedByString:@"\n"]]
                                                : [NSString stringWithFormat:@"%@ · %@", head, L(@"Great sample for cloning.")];
    self.qualityLabel.textColor = lines.count ? OVColor(OVRoleWarn) : OVColor(OVRoleMuted);
}

- (void)enhance:(id)s {
    NSString *audio = [self currentAudio];
    if (!audio || !self.voice) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[self originalPath]]) [fm copyItemAtPath:audio toPath:[self originalPath] error:nil];
    NSString *tmp = [self draftPath:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    NSString *vid = self.voice.identifier;
    self.status.stringValue = L(@"Cleaning the sample…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"enhance", @"audio": audio, @"out": tmp} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        // Another voice was opened meanwhile: the cleaned sample belongs to the old one, drop it.
        if (![w.voice.identifier isEqualToString:vid]) { [NSFileManager.defaultManager removeItemAtPath:tmp error:nil]; return; }
        if (error) { w.status.stringValue = error; return; }
        if ([w keepSample:tmp]) {
            w.analysis[[w analysisKey:[w currentAudio]]] = data;
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
