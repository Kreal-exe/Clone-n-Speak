#import "OVPages.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVStore.h"
#import "OVModels.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSTimeInterval kMaxRecord = 15;

@interface OVVoicesPage () <NSTableViewDataSource, NSTableViewDelegate, AVAudioRecorderDelegate, NSTextFieldDelegate, NSTextViewDelegate>
@property NSTableView *table;
@property NSTextField *heading, *nameField, *refInfo, *status;
@property NSTextView *refText;
@property NSButton *chooseButton, *recordButton, *playButton, *transcribeButton, *cloneButton, *deleteButton;
@property NSButton *enhanceButton, *revertButton, *previewButton;
@property NSLevelIndicator *qualityMeter;
@property NSTextField *qualityLabel;
@property NSPopUpButton *sampleLangPopup;
@property NSMutableDictionary<NSString *, NSDictionary *> *analysis; // path|mtime → report
@property NSProgressIndicator *spinner;
@property NSView *emptyHint;

@property (nullable) OVVoice *voice;          // nil = drafting a new voice
@property (nullable) AVAudioRecorder *recorder;
@property (nullable) NSTimer *recTimer;
@end

@implementation OVVoicesPage

- (void)loadView {
    // left: list of voices
    self.table = [NSTableView new];
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"v"]];
    self.table.headerView = nil;
    self.table.rowHeight = 44;
    self.table.style = NSTableViewStyleSourceList;
    self.table.dataSource = self;
    self.table.delegate = self;
    NSScrollView *ls = [NSScrollView new];
    ls.documentView = self.table;
    ls.hasVerticalScroller = YES;
    ls.drawsBackground = NO;
    NSButton *add = OVButton(L(@"New voice"), self, @selector(newVoice:));
    add.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
    add.imagePosition = NSImageLeading;
    NSStackView *left = OVVStack(@[OVSectionTitle(L(@"My voices")), ls, add], 10);
    left.edgeInsets = NSEdgeInsetsMake(30, 20, 20, 12);
    OVFillWidth(@[ls, add], left);
    [ls setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [left.widthAnchor constraintEqualToConstant:190].active = YES;

    // right: editor
    self.heading = OVTitle(L(@"New voice"));
    self.nameField = OVField(L(@"For example, My voice"));
    self.nameField.font = [NSFont systemFontOfSize:15];
    self.nameField.delegate = self;

    self.chooseButton = OVButton(L(@"Choose file…"), self, @selector(chooseFile:));
    self.chooseButton.image = [NSImage imageWithSystemSymbolName:@"doc.badge.plus" accessibilityDescription:nil];
    self.chooseButton.imagePosition = NSImageLeading;
    self.recordButton = OVButton(L(@"Record"), self, @selector(record:));
    self.recordButton.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
    self.recordButton.imagePosition = NSImageLeading;
    self.playButton = OVButton(L(@"Listen"), self, @selector(playRef:));
    self.playButton.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    self.playButton.imagePosition = NSImageLeading;
    self.refInfo = OVWrapLabel(@"", 12, nil);
    self.qualityMeter = [NSLevelIndicator new];
    self.qualityMeter.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    self.qualityMeter.minValue = 0;
    self.qualityMeter.maxValue = 100;
    self.qualityMeter.warningValue = 70;
    self.qualityMeter.criticalValue = 45;
    self.qualityMeter.editable = NO;
    [self.qualityMeter.widthAnchor constraintEqualToConstant:90].active = YES;
    self.qualityLabel = OVWrapLabel(@"", 12, nil);
    self.enhanceButton = OVButton(L(@"Improve sample"), self, @selector(enhance:));
    self.enhanceButton.image = [NSImage imageWithSystemSymbolName:@"wand.and.stars" accessibilityDescription:nil];
    self.enhanceButton.imagePosition = NSImageLeading;
    self.enhanceButton.controlSize = NSControlSizeRegular;
    self.enhanceButton.toolTip = L(@"Removes background noise and rumble, trims long pauses and evens out loudness. The original is kept.");
    self.revertButton = OVButton(L(@"Restore original"), self, @selector(revertSample:));
    self.revertButton.controlSize = NSControlSizeRegular;
    NSStackView *qualityRow = OVHStack(@[OVLabel(L(@"Quality"), 12, NSFontWeightMedium, NSColor.secondaryLabelColor), self.qualityMeter], 8);
    for (NSButton *b in @[self.chooseButton, self.recordButton, self.playButton]) b.controlSize = NSControlSizeRegular;
    NSStackView *audioBox = OVVStack(@[OVHStack(@[self.chooseButton, self.recordButton, self.playButton], 6), self.refInfo, qualityRow,
                                       self.qualityLabel, OVHStack(@[self.enhanceButton, self.revertButton], 6)], 8);
    OVFillWidth(@[self.qualityLabel], audioBox);
    NSView *audioCard = [self sectionCard:L(@"1 · Voice sample")
                                     hint:L(@"3–10 seconds of clean speech from one person, without music or echo. WAV, MP3, M4A and FLAC work.")
                                  content:audioBox];

    NSScrollView *ts = [NSTextView scrollableTextView];
    self.refText = ts.documentView;
    self.refText.font = [NSFont systemFontOfSize:14];
    self.refText.richText = NO;
    self.refText.allowsUndo = YES;
    self.refText.textContainerInset = NSMakeSize(6, 6);
    self.refText.delegate = self;
    self.refText.automaticQuoteSubstitutionEnabled = NO;
    ts.borderType = NSBezelBorder;
    [ts.heightAnchor constraintEqualToConstant:84].active = YES;
    self.transcribeButton = OVButton(L(@"Transcribe automatically"), self, @selector(transcribe:));
    self.transcribeButton.image = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:nil];
    self.transcribeButton.imagePosition = NSImageLeading;
    NSStackView *textBox = OVVStack(@[ts, self.transcribeButton], 8);
    OVFillWidth(@[ts], textBox);
    NSView *textCard = [self sectionCard:L(@"2 · What the sample says")
                                    hint:L(@"Exactly, word for word. You can leave it empty — Whisper will transcribe it.")
                                 content:textBox];

    self.cloneButton = OVPrimaryButton(L(@"Clone voice"), self, @selector(clone:));
    self.cloneButton.image = [NSImage imageWithSystemSymbolName:@"person.wave.2.fill" accessibilityDescription:nil];
    self.cloneButton.imagePosition = NSImageLeading;
    self.spinner = OVSpinner();
    self.status = OVWrapLabel(@"", 12, nil);
    self.deleteButton = OVButton(L(@"Delete voice"), self, @selector(deleteVoice:));
    self.deleteButton.contentTintColor = NSColor.systemRedColor;
    self.previewButton = OVButton(L(@"Hear the clone"), self, @selector(playPreview:));
    self.previewButton.image = [NSImage imageWithSystemSymbolName:@"play.circle" accessibilityDescription:nil];
    self.previewButton.imagePosition = NSImageLeading;
    NSStackView *actions = OVHStack(@[self.cloneButton, self.previewButton, self.spinner, self.status, OVSpacer(), self.deleteButton], 10);
    self.analysis = [NSMutableDictionary dictionary];

    // the language of the sample is set explicitly: Whisper's own guess mixes up Ukrainian, Belarusian and Russian
    self.sampleLangPopup = [NSPopUpButton new];
    NSArray *pinned = [OVLocale pinnedSpeechLanguages];
    for (NSString *c in pinned) { [self.sampleLangPopup addItemWithTitle:[OVLocale nameForLanguage:c]]; self.sampleLangPopup.lastItem.representedObject = c; }
    [self.sampleLangPopup.menu addItem:NSMenuItem.separatorItem];
    for (NSString *c in [OVLocale speechLanguages])
        if (![pinned containsObject:c]) { [self.sampleLangPopup addItemWithTitle:[OVLocale nameForLanguage:c]]; self.sampleLangPopup.lastItem.representedObject = c; }
    self.sampleLangPopup.target = self;
    self.sampleLangPopup.action = @selector(sampleLanguagePicked:);
    NSStackView *nameRow = OVHStack(@[[self captioned:L(@"Name") view:self.nameField], [self captioned:L(@"Language of the sample") view:self.sampleLangPopup]], 14);
    nameRow.alignment = NSLayoutAttributeTop;
    NSStackView *right = OVVStack(@[self.heading, nameRow, audioCard, textCard, actions], 16);
    right.edgeInsets = NSEdgeInsetsMake(30, 24, 24, 32);
    [right setCustomSpacing:20 afterView:self.heading];
    OVFillWidth(@[right.arrangedSubviews[1], audioCard, textCard, actions], right);
    [self.nameField.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;
    NSScrollView *rightScroll = OVScrollPage(right);

    NSBox *sep = [NSBox new];
    sep.boxType = NSBoxSeparator;
    NSStackView *root = OVHStack(@[left, sep, rightScroll], 0);
    root.alignment = NSLayoutAttributeTop;
    left.translatesAutoresizingMaskIntoConstraints = NO;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    rightScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [left.heightAnchor constraintEqualToAnchor:root.heightAnchor].active = YES;
    [sep.heightAnchor constraintEqualToAnchor:root.heightAnchor].active = YES;
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

- (NSView *)captioned:(NSString *)caption view:(NSView *)v {
    return OVVStack(@[OVLabel(caption, 12, NSFontWeightMedium, NSColor.secondaryLabelColor), v], 6);
}

- (NSView *)sectionCard:(NSString *)title hint:(NSString *)hint content:(NSView *)content {
    NSTextField *h = OVWrapLabel(hint, 12, nil);
    NSStackView *s = OVVStack(@[OVSectionTitle(title), h, content], 8);
    [s setCustomSpacing:12 afterView:h];
    OVFillWidth(@[h, content], s);
    return OVCard(s, 16);
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
    NSImageView *icon = OVSymbol(v.ready ? @"person.wave.2.fill" : @"exclamationmark.circle", 15,
                                 v.ready ? OVAccent() : NSColor.systemOrangeColor);
    NSTextField *name = OVLabel(v.name, 13, NSFontWeightMedium, nil);
    NSString *lang = v.language ?: (v.refText.length ? [OVLocale detectLanguage:v.refText] : nil);
    NSString *subText = !v.ready ? L(@"not cloned") :
        lang ? [NSString stringWithFormat:@"%@ · %@", OVFormatDuration(v.seconds), [OVLocale nameForLanguage:lang]]
             : [NSString stringWithFormat:L(@"%@ sample"), OVFormatDuration(v.seconds)];
    NSTextField *sub = OVLabel(subText,
                               11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *row2 = OVHStack(@[icon, OVVStack(@[name, sub], 1)], 8);
    [cell addSubview:row2];
    OVPin(row2, cell, NSEdgeInsetsMake(4, 4, 4, 4));
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = self.table.selectedRow;
    if (r >= 0 && r < (NSInteger)[OVVoices shared].all.count) [self showVoice:[OVVoices shared].all[r]];
}

#pragma mark Editor state

- (void)showVoice:(OVVoice *)v {
    [self stopRecording];
    self.voice = v;
    self.heading.stringValue = v.name ?: @"";
    self.nameField.stringValue = v.name ?: @"";
    [self selectSampleLanguage:v.language ?: [self defaultSampleLanguage]];
    self.refText.string = v.refText ?: @"";
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
    self.heading.stringValue = L(@"New voice");
    self.nameField.stringValue = [NSString stringWithFormat:L(@"Voice %lu"), (unsigned long)[OVVoices shared].all.count + 1];
    self.refText.string = @"";
    self.status.stringValue = @"";
    [self selectSampleLanguage:[self defaultSampleLanguage]];
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
- (BOOL)keepSample:(NSString *)wav {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!self.voice) {
        NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        OVVoice *v = [[OVVoices shared] createNamed:name.length ? name : L(@"Untitled")];
        v.refText = self.refText.string;
        v.language = [self sampleLanguage];
        self.voice = v;
    }
    NSString *dst = self.voice.ready ? [self pendingPath] : self.voice.referencePath;
    [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:wav toPath:dst error:&err]) {
        self.status.stringValue = [NSString stringWithFormat:L(@"Couldn’t save the sample: %@"), err.localizedDescription ?: @"?"];
        return NO;
    }
    if (!self.voice.ready) self.voice.seconds = OVAudioDuration(dst);
    [self.voice save];
    [[OVVoices shared] reload];
    self.heading.stringValue = self.voice.name ?: @"";
    return YES;
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object != self.nameField || !self.voice) return;
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!name.length) return;
    self.voice.name = name;
    self.heading.stringValue = name;
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
        self.refInfo.stringValue = [NSString stringWithFormat:@"%@ · %@%@", [self hasPending] ? L(@"New sample (not applied yet)") : L(@"Sample saved"), OVFormatDuration(d), warn];
    } else {
        self.refInfo.stringValue = L(@"No sample yet.");
    }
    if (!recording) self.recordButton.title = L(@"Record");
    self.recordButton.enabled = !busy;
    self.chooseButton.enabled = !busy && !recording;
    BOOL playing = audio && [[OVPlayer shared].currentPath isEqualToString:audio] && [OVPlayer shared].playing;
    self.playButton.title = playing ? L(@"Stop") : L(@"Listen");
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
    [self analyzeIfNeeded:audio];
}

#pragma mark Audio input

- (NSString *)draftPath:(NSString *)name {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"OmniVoiceUA"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:name];
}

- (void)chooseFile:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[UTTypeAudio];
    p.message = L(@"Choose a voice recording (3–10 seconds)");
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        [self importAudio:p.URL.path];
    }];
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
    BOOL kept = [self keepSample:dst];
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
    self.status.stringValue = L(@"Speak naturally in a quiet room. Recording stops automatically after 15 s.");
    __weak typeof(self) w = self;
    self.recTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        w.recordButton.title = [NSString stringWithFormat:L(@"Stop  %@"), OVFormatDuration(w.recorder.currentTime)];
    }];
    self.recordButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle.fill" accessibilityDescription:nil];
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
        if (ok && OVAudioDuration(path) > 0.5) {
            if ([self keepSample:path])
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

- (NSString *)defaultSampleLanguage {
    NSString *s = [OVLocale speechLanguageSetting];
    return s.length && ![s isEqualToString:@"auto"] ? s : @"uk";
}
- (void)selectSampleLanguage:(NSString *)code {
    NSInteger i = [self.sampleLangPopup indexOfItemWithRepresentedObject:code];
    [self.sampleLangPopup selectItemAtIndex:MAX(0, i)];
}
- (NSString *)sampleLanguage { return self.sampleLangPopup.selectedItem.representedObject ?: @"uk"; }
- (void)sampleLanguagePicked:(id)s {
    if (!self.voice) return;
    self.voice.language = [self sampleLanguage];
    [self.voice save];
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
    self.qualityLabel.textColor = lines.count ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
}

- (void)enhance:(id)s {
    NSString *audio = [self currentAudio];
    if (!audio || !self.voice) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[self originalPath]]) [fm copyItemAtPath:audio toPath:[self originalPath] error:nil];
    NSString *tmp = [self draftPath:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]];
    self.status.stringValue = L(@"Cleaning the sample…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"enhance", @"audio": audio, @"out": tmp} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
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
- (void)makePreviewFor:(OVVoice *)v {
    NSDictionary *spec = [OVSettings modelSpec];
    if (!spec || !v.ready) return;
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
        w.status.stringValue = L(@"Ready! Here is how the clone sounds. The voice is selected on the Speech page.");
        [w refreshButtons];
        if (w.voice == v) [[OVPlayer shared] play:out];
    }];
}

#pragma mark Worker actions

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
    self.status.stringValue = L(@"Transcribing…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:@{@"cmd": @"transcribe", @"model": spec, @"audio": audio, @"asr_path": asr.localPath,
                                 @"language": [self sampleLanguage]}
                        status:^(NSString *m) { w.status.stringValue = m; }
                      progress:nil
                          done:^(NSDictionary *data, NSString *error) {
        if (error) { w.status.stringValue = error; return; }
        w.refText.string = data[@"text"] ?: @"";
        w.status.stringValue = L(@"Text transcribed — check it and correct it if needed.");
    }];
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
    v.language = [self sampleLanguage];
    [v save];
    NSString *pending = [self hasPending] ? [self pendingPath] : nil;

    NSMutableDictionary *req = [@{@"cmd": @"clone", @"model": spec, @"audio": audio,
                                  @"ref_text": text, @"out": v.promptPath,
                                  @"language": [self sampleLanguage]} mutableCopy];
    if (asr) req[@"asr_path"] = asr.localPath;
    self.status.stringValue = L(@"Cloning…");
    __weak typeof(self) w = self;
    [[OVWorker shared] request:req status:^(NSString *m) { w.status.stringValue = m; } progress:nil
                          done:^(NSDictionary *data, NSString *error) {
        if (error) { w.status.stringValue = error; [[OVVoices shared] reload]; return; }
        if (pending) { // the new sample is now the voice's reference
            [NSFileManager.defaultManager removeItemAtPath:v.referencePath error:nil];
            [NSFileManager.defaultManager moveItemAtPath:pending toPath:v.referencePath error:nil];
        }
        v.refText = data[@"ref_text"] ?: text;
        v.seconds = [data[@"seconds"] doubleValue] ?: v.seconds;
        [v save];
        [NSUserDefaults.standardUserDefaults setObject:v.identifier forKey:@"voice"];
        [NSFileManager.defaultManager removeItemAtPath:[v.folder stringByAppendingPathComponent:@"preview.wav"] error:nil];
        [[OVVoices shared] reload];
        [w showVoice:v];
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
        w.status.stringValue = L(@"Done! The voice is selected on the Speech page.");
        [w makePreviewFor:v];
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
